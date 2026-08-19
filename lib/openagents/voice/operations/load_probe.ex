defmodule OpenAgents.Voice.Operations.LoadProbe do
  @moduledoc "Runs a bounded HTTP readiness load probe and reports latency percentiles."

  alias OpenAgents.Voice.Operations.Report

  @spec run(String.t(), pos_integer(), pos_integer()) :: map()
  def run(url, requests, concurrency)
      when is_binary(url) and requests in 1..10_000 and concurrency in 1..100 do
    results =
      1..requests
      |> Task.async_stream(
        fn _request -> timed_request(url) end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> %{status: "task_exit", latency_ms: 15_000}
      end)

    successes = Enum.count(results, &(&1.status == 200))

    %{
      "schema" => "sarah.voice_http_load_probe.v1",
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "target" => URI.parse(url) |> Map.take([:scheme, :host, :port, :path]),
      "requests" => requests,
      "concurrency" => concurrency,
      "successes" => successes,
      "failures" => requests - successes,
      "failure_rate" => Float.round((requests - successes) / requests, 6),
      "latency_ms" => results |> Enum.map(& &1.latency_ms) |> Report.distribution(),
      "status_counts" => Enum.frequencies_by(results, &to_string(&1.status))
    }
  end

  defp timed_request(url) do
    started = System.monotonic_time(:millisecond)

    status =
      case Req.get(url, retry: false, receive_timeout: 10_000) do
        {:ok, response} -> response.status
        {:error, error} -> error.__struct__ |> Module.split() |> List.last()
      end

    %{status: status, latency_ms: System.monotonic_time(:millisecond) - started}
  end
end
