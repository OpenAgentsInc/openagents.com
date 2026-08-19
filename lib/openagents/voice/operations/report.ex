defmodule OpenAgents.Voice.Operations.Report do
  @moduledoc "Builds aggregate, transcript-free release indicators from durable voice evidence."

  import Ecto.Query

  alias OpenAgents.Repo

  alias OpenAgents.Voice.{
    ClientEvent,
    PersistedEvent,
    ReleaseControl,
    ResponseReceipt,
    Session,
    ToolStep
  }

  @spec build(DateTime.t()) :: map()
  def build(since) do
    sessions =
      Repo.all(
        from(session in Session,
          where: session.started_at >= ^since,
          order_by: [asc: session.started_at]
        )
      )

    session_ids = Enum.map(sessions, & &1.id)
    events = provider_events(session_ids)
    client_events = client_events(session_ids)
    receipts = response_receipts(session_ids)
    tool_steps = tool_steps(session_ids)
    sessions_by_id = Map.new(sessions, &{&1.id, &1})

    setup_latencies =
      for session <- sessions,
          not is_nil(session.connected_at),
          do: milliseconds(session.connected_at, session.started_at)

    session_durations =
      for session <- sessions,
          not is_nil(session.ended_at),
          do: milliseconds(session.ended_at, session.started_at)

    first_audio_latencies =
      client_events
      |> Enum.filter(&(&1.kind == "first_remote_track"))
      |> Enum.group_by(& &1.voice_session_id)
      |> Enum.map(fn {session_id, observations} ->
        first = Enum.min_by(observations, & &1.observed_at, DateTime)
        milliseconds(first.observed_at, sessions_by_id[session_id].started_at)
      end)

    response_latencies = response_latencies(receipts, events)

    tool_latencies =
      for step <- tool_steps,
          not is_nil(step.completed_at),
          do: milliseconds(step.completed_at, step.requested_at)

    attempts = length(sessions)
    connected = Enum.count(sessions, &(!is_nil(&1.connected_at)))
    provider_errors = Enum.count(events, &(&1.kind == "provider_error"))
    responses = length(receipts)
    interrupted = Enum.count(receipts, &(&1.status == "interrupted"))

    report = %{
      "schema" => "sarah.voice_release_report.v1",
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "window_started_at" => DateTime.to_iso8601(since),
      "release_control" => release_control(),
      "counts" => %{
        "attempts" => attempts,
        "connected" => connected,
        "responses" => responses,
        "interruptions" => interrupted,
        "reconnects" => Enum.count(events, &(&1.kind == "sideband_disconnected")),
        "provider_errors" => provider_errors,
        "tool_steps" => length(tool_steps)
      },
      "rates" => %{
        "setup_success" => ratio(connected, attempts),
        "provider_error_per_attempt" => ratio(provider_errors, attempts),
        "interrupted_response" => ratio(interrupted, responses)
      },
      "latency_ms" => %{
        "setup" => distribution(setup_latencies),
        "first_remote_audio" => distribution(first_audio_latencies),
        "response_start" => distribution(response_latencies),
        "tool" => distribution(tool_latencies),
        "session_duration" => distribution(session_durations)
      },
      "usage" => usage(sessions),
      "browser_matrix" => browser_matrix(client_events)
    }

    Map.put(report, "gate", gate(report))
  end

  @spec distribution([non_neg_integer()]) :: map()
  def distribution(values) when is_list(values) do
    sorted = Enum.sort(values)

    %{
      "samples" => length(sorted),
      "p50" => percentile(sorted, 0.50),
      "p95" => percentile(sorted, 0.95),
      "p99" => percentile(sorted, 0.99),
      "maximum" => List.last(sorted)
    }
  end

  defp provider_events([]), do: []

  defp provider_events(session_ids) do
    Repo.all(
      from(event in PersistedEvent,
        where: event.voice_session_id in ^session_ids,
        select: %{
          voice_session_id: event.voice_session_id,
          sequence: event.sequence,
          kind: event.kind,
          observed_at: event.observed_at
        }
      )
    )
  end

  defp client_events([]), do: []

  defp client_events(session_ids) do
    Repo.all(
      from(event in ClientEvent,
        where: event.voice_session_id in ^session_ids,
        select: %{
          voice_session_id: event.voice_session_id,
          kind: event.kind,
          browser_family: event.browser_family,
          browser_major: event.browser_major,
          observed_at: event.observed_at
        }
      )
    )
  end

  defp response_receipts([]), do: []

  defp response_receipts(session_ids) do
    Repo.all(
      from(receipt in ResponseReceipt,
        where: receipt.voice_session_id in ^session_ids,
        select: %{
          voice_session_id: receipt.voice_session_id,
          started_event_sequence: receipt.started_event_sequence,
          status: receipt.status
        }
      )
    )
  end

  defp tool_steps([]), do: []

  defp tool_steps(session_ids),
    do: Repo.all(from(step in ToolStep, where: step.voice_session_id in ^session_ids))

  defp response_latencies(receipts, events) do
    by_session = Enum.group_by(events, & &1.voice_session_id)

    Enum.flat_map(receipts, fn receipt ->
      session_events = Map.get(by_session, receipt.voice_session_id, [])

      with %{observed_at: started_at} <-
             Enum.find(session_events, &(&1.sequence == receipt.started_event_sequence)),
           %{observed_at: input_at} <-
             session_events
             |> Enum.filter(
               &(&1.kind == "user_transcript_final" and
                   &1.sequence < receipt.started_event_sequence)
             )
             |> Enum.max_by(& &1.sequence, fn -> nil end) do
        [milliseconds(started_at, input_at)]
      else
        _missing -> []
      end
    end)
  end

  defp usage(sessions) do
    reported_sessions =
      Enum.count(sessions, fn session ->
        is_map(session.usage) and session.usage["schema"] == "sarah.voice_usage.v1"
      end)

    totals =
      Enum.reduce(sessions, %{}, fn session, accumulator ->
        Enum.reduce(
          ~w(input_tokens output_tokens total_tokens estimated_cost_microusd),
          accumulator,
          fn key, next ->
            Map.update(
              next,
              key,
              integer(session.usage[key]),
              &(&1 + integer(session.usage[key]))
            )
          end
        )
      end)

    totals
    |> Map.put("sessions_reported", reported_sessions)
    |> Map.put(
      "average_estimated_cost_microusd_per_reported_session",
      ratio(totals["estimated_cost_microusd"], reported_sessions)
    )
  end

  defp browser_matrix(events) do
    events
    |> Enum.filter(&(&1.kind == "peer_connected"))
    |> Enum.frequencies_by(&%{"family" => &1.browser_family, "major" => &1.browser_major})
    |> Enum.map(fn {browser, count} -> Map.put(browser, "connections", count) end)
    |> Enum.sort_by(&{&1["family"], &1["major"] || 0})
  end

  defp release_control do
    control = ReleaseControl.current!()

    %{
      "id" => control.id,
      "state" => control.state,
      "reason" => control.reason,
      "source_revision" => control.source_revision,
      "changed_at" => DateTime.to_iso8601(control.inserted_at)
    }
  end

  defp gate(report) do
    failures =
      []
      |> require_gate(report["counts"]["attempts"] >= 20, "at_least_20_voice_attempts")
      |> require_gate(
        report["rates"]["setup_success"] >= 0.95,
        "setup_success_at_least_95_percent"
      )
      |> require_gate(
        report["rates"]["provider_error_per_attempt"] <= 0.02,
        "provider_errors_at_most_2_percent"
      )
      |> require_gate(
        report["latency_ms"]["first_remote_audio"]["samples"] >= 10,
        "at_least_10_first_audio_samples"
      )
      |> require_gate(
        (report["latency_ms"]["first_remote_audio"]["p95"] || 1_000_000) <= 3_000,
        "first_audio_p95_at_most_3000_ms"
      )
      |> require_gate(
        report["latency_ms"]["response_start"]["samples"] >= 10,
        "at_least_10_response_start_samples"
      )
      |> require_gate(
        (report["latency_ms"]["response_start"]["p95"] || 1_000_000) <= 3_000,
        "response_start_p95_at_most_3000_ms"
      )
      |> require_gate(
        report["usage"]["sessions_reported"] >= 10,
        "at_least_10_provider_usage_samples"
      )
      |> require_gate(
        report["usage"]["average_estimated_cost_microusd_per_reported_session"] <=
          Application.fetch_env!(:sarah, :voice_maximum_estimated_cost_microusd),
        "average_session_cost_within_budget"
      )
      |> require_gate(report["release_control"]["state"] == "open", "release_control_open")

    %{"decision" => if(failures == [], do: "candidate", else: "hold"), "failures" => failures}
  end

  defp require_gate(failures, true, _name), do: failures
  defp require_gate(failures, false, name), do: failures ++ [name]

  defp percentile([], _fraction), do: nil

  defp percentile(sorted, fraction) do
    index = max(ceil(length(sorted) * fraction) - 1, 0)
    Enum.at(sorted, index)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 6)
  defp milliseconds(later, earlier), do: max(DateTime.diff(later, earlier, :millisecond), 0)
  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
