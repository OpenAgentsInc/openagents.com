defmodule OpenAgents.Box.Reconciler do
  @moduledoc """
  Scheduled, supervised reconciliation of provider Box lifecycle state.

  Successful provider responses can move a ledger row toward a terminal state.
  Transport failures and rate limits record retry metadata only; they never infer
  deletion. Reconciliation never resumes or recreates a provider Box.
  """

  use GenServer
  import Ecto.Query

  alias OpenAgents.Box
  alias OpenAgents.Box.{Client, ConversationBox, ReconciliationEvent, Run}
  alias OpenAgents.Repo

  @default_interval_ms 60_000
  @default_idle_seconds 1_800
  @default_backoff_ms 5_000
  @default_receive_timeout_ms 15_000
  @maximum_backoff_ms 300_000
  @terminal_provider_states ~w(archived stopped terminated deleted error)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc "Runs one complete reconciliation pass synchronously."
  @spec reconcile() :: {:ok, map()} | {:error, term()}
  def reconcile do
    case Client.list_boxes(receive_timeout: receive_timeout_ms()) do
      {:ok, body} ->
        with {:ok, provider_boxes} <- provider_boxes(body) do
          records =
            Repo.all(
              from box in ConversationBox,
                where: is_nil(box.stopped_at) or is_nil(box.usage_settled_at),
                order_by: [asc: box.inserted_at]
            )

          Enum.each(records, fn record ->
            _ = reconcile_record(record)
          end)

          reconcile_leaks(provider_boxes)
          {:ok, %{boxes: length(records), provider_boxes: length(provider_boxes)}}
        end

      {:error, reason} ->
        if reason in [:box_unreachable, :box_rate_limited] do
          Repo.all(
            from box in ConversationBox,
              where: is_nil(box.stopped_at) or is_nil(box.usage_settled_at)
          )
          |> Enum.each(fn record -> _ = mark_reconciliation_failure(record, reason) end)
        end

        {:error, reason}
    end
  end

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, interval_ms())
    initial_delay_ms = Keyword.get(options, :initial_delay_ms, interval_ms)
    schedule(initial_delay_ms)
    {:ok, %{interval_ms: interval_ms, backoff_ms: 0}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    result = reconcile()
    success? = match?({:ok, _}, result)
    delay = if success?, do: state.interval_ms, else: next_backoff(state.backoff_ms)
    schedule(delay)

    {:noreply, %{state | backoff_ms: if(success?, do: 0, else: delay)}}
  end

  defp reconcile_record(%ConversationBox{stopped_at: %DateTime{}, usage_settled_at: nil} = record) do
    reconcile_settled_usage(record)
  end

  defp reconcile_record(%ConversationBox{stopped_at: %DateTime{}}), do: :ok

  defp reconcile_record(%ConversationBox{next_reconciliation_at: next} = record)
       when not is_nil(next) do
    if DateTime.compare(next, now()) == :gt, do: :backoff, else: reconcile_active(record)
  end

  defp reconcile_record(%ConversationBox{} = record), do: reconcile_active(record)

  defp reconcile_active(%ConversationBox{} = record) do
    case Client.get_box(record.box_id, receive_timeout: receive_timeout_ms()) do
      {:ok, body} ->
        _ = refresh_observation(record, body)
        _ = mark_reconciled(record)

        cond do
          terminal_provider_state?(body) ->
            _ = mark_terminal(record, provider_terminal_state(body), "provider_terminal", body)

          expired?(record) ->
            if Box.provider_owned?(body), do: stop_if_claimed(record, "ttl_expired"), else: :ok

          idle?(record) ->
            if Box.provider_owned?(body), do: stop_if_claimed(record, "idle_timeout"), else: :ok

          true ->
            :ok
        end

      {:error, :box_not_found} ->
        _ = mark_terminal(record, "archived", "provider_missing", %{})

      {:error, reason} when reason in [:box_unreachable, :box_rate_limited] ->
        _ = mark_reconciliation_failure(record, reason)

      {:error, _reason} ->
        :ok
    end
  end

  defp stop_if_claimed(record, reason) do
    case Box.claim_stop(record) do
      {:ok, :claimed} ->
        case Client.stop_box(record.box_id, receive_timeout: receive_timeout_ms()) do
          {:ok, body} ->
            _ = Box.complete_stop(record, reason, body)
            :ok

          {:error, stop_reason} ->
            _ = Box.release_stop_claim(record)
            _ = mark_reconciliation_failure(record, stop_reason)
            :ok
        end

      {:ok, {_status, _updated}} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp reconcile_settled_usage(record) do
    case Client.get_box(record.box_id, receive_timeout: receive_timeout_ms()) do
      {:ok, body} ->
        _ = settle_usage(record, body)
        :ok

      {:error, :box_not_found} ->
        _ = settle_usage(record, %{})
        :ok

      {:error, reason} when reason in [:box_unreachable, :box_rate_limited] ->
        _ = mark_reconciliation_failure(record, reason)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp settle_usage(record, body) do
    attrs =
      Map.merge(
        %{usage_settled_at: now()},
        settled_cost_attrs(body)
      )

    record
    |> ConversationBox.changeset(attrs)
    |> Repo.update()
  end

  defp mark_terminal(record, state, reason, body) do
    result =
      Repo.transaction(fn ->
        locked =
          Repo.one!(from box in ConversationBox, where: box.id == ^record.id, lock: "FOR UPDATE")

        if is_nil(locked.stopped_at) do
          stopped_at = now()

          cost_attrs = settled_cost_attrs(body)

          updated =
            locked
            |> ConversationBox.changeset(
              Map.merge(
                %{
                  state: state,
                  stopped_at: stopped_at,
                  stop_reason: reason,
                  stop_requested_at: nil,
                  lifetime_seconds: DateTime.diff(stopped_at, locked.inserted_at, :second),
                  usage_settled_at: stopped_at
                },
                cost_attrs
              )
            )
            |> Repo.update!()

          {updated, true}
        else
          {locked, false}
        end
      end)

    with {:ok, {updated, transitioned?}} <- result do
      if transitioned? do
        _ = Box.Fanout.promote_queued(updated.conversation_id)
      end

      :ok
    end
  end

  defp mark_reconciled(record) do
    record
    |> ConversationBox.changeset(%{
      last_reconciled_at: now(),
      reconciliation_failures: 0,
      reconciliation_error: nil,
      next_reconciliation_at: nil
    })
    |> Repo.update()
  end

  defp refresh_observation(record, body) do
    observed = unwrapped(body)

    record
    |> ConversationBox.changeset(%{
      state: observed_state(observed),
      setup_status: observed_setup_status(observed)
    })
    |> Repo.update()
  end

  defp mark_reconciliation_failure(record, reason) do
    failures = record.reconciliation_failures + 1
    delay = min(@maximum_backoff_ms, @default_backoff_ms * Integer.pow(2, min(failures - 1, 6)))

    record
    |> ConversationBox.changeset(%{
      reconciliation_failures: failures,
      next_reconciliation_at: DateTime.add(now(), delay, :millisecond),
      reconciliation_error: Atom.to_string(reason)
    })
    |> Repo.update()
  end

  defp reconcile_leaks(provider_boxes) do
    provider_boxes
    |> Enum.reject(&claimed_provider_box?(&1["id"]))
    |> Enum.each(fn provider_box ->
      provider_id = provider_box["id"]
      report_leak(provider_id, provider_box)

      case Box.provider_owned?(provider_box) &&
             Client.stop_box(provider_id, receive_timeout: receive_timeout_ms()) do
        {:ok, _body} -> mark_leak_handled(provider_id)
        {:error, _reason} -> :ok
        false -> :ok
      end
    end)
  end

  defp claimed_provider_box?(provider_id) when is_binary(provider_id) do
    Repo.exists?(from box in ConversationBox, where: box.box_id == ^provider_id)
  end

  defp report_leak(provider_id, details) when is_binary(provider_id) do
    %ReconciliationEvent{}
    |> Ecto.Changeset.cast(
      %{
        provider_box_id: provider_id,
        event_type: "leak",
        reason: "provider_box_without_ledger_claim",
        details: details,
        observed_at: now()
      },
      [:provider_box_id, :event_type, :reason, :details, :observed_at]
    )
    |> Ecto.Changeset.validate_required([:provider_box_id, :event_type, :reason, :observed_at])
    |> Ecto.Changeset.unique_constraint([:provider_box_id, :event_type],
      name: :box_reconciliation_events_provider_box_id_event_type_index
    )
    |> Repo.insert(on_conflict: :nothing)
  end

  defp report_leak(_provider_id, _details), do: :ok

  defp mark_leak_handled(provider_id) do
    from(event in ReconciliationEvent,
      where: event.provider_box_id == ^provider_id and event.event_type == "leak"
    )
    |> Repo.update_all(set: [handled_at: now(), updated_at: now()])
  end

  defp provider_boxes(%{"boxes" => boxes}), do: validate_provider_boxes(boxes)
  defp provider_boxes(%{"data" => boxes}), do: validate_provider_boxes(boxes)
  defp provider_boxes(_body), do: {:error, :box_response_invalid}

  defp validate_provider_boxes(boxes) when is_list(boxes) do
    if Enum.all?(boxes, &(is_map(&1) and is_binary(&1["id"]))) do
      {:ok, boxes}
    else
      {:error, :box_response_invalid}
    end
  end

  defp validate_provider_boxes(_boxes), do: {:error, :box_response_invalid}

  defp terminal_provider_state?(body), do: provider_state(body) in @terminal_provider_states

  defp provider_terminal_state(body) do
    if provider_state(body) == "error", do: "error", else: "archived"
  end

  defp provider_state(body) do
    body = unwrapped(body)
    Map.get(body, "state") || Map.get(body, "status")
  end

  defp receive_timeout_ms do
    Keyword.get(settings(), :reconciliation_receive_timeout_ms, @default_receive_timeout_ms)
  end

  defp observed_state(body) do
    state = body["state"] || body["status"]
    if state in ConversationBox.states(), do: state, else: "provisioning"
  end

  defp observed_setup_status(body) do
    case body["setupStatus"] || body["setup_status"] do
      status when status in ~w(pending running done failed) -> status
      _unknown -> "pending"
    end
  end

  defp unwrapped(%{"box" => %{} = box}), do: box
  defp unwrapped(%{} = body), do: body
  defp unwrapped(_body), do: %{}

  defp expired?(record), do: DateTime.diff(now(), record.inserted_at, :second) >= ttl_seconds()

  defp idle?(record) do
    latest_run =
      Repo.one(
        from run in Run,
          where: run.conversation_box_id == ^record.id,
          order_by: [desc: run.admitted_at],
          limit: 1
      )

    cond do
      latest_run && not Run.terminal?(latest_run) ->
        false

      latest_run ->
        activity_at =
          latest_run.finished_at || latest_run.started_at || latest_run.admitted_at ||
            record.inserted_at

        DateTime.diff(now(), activity_at, :second) >= idle_seconds()

      true ->
        DateTime.diff(now(), record.inserted_at, :second) >= idle_seconds()
    end
  end

  defp settled_cost_attrs(body) when is_map(body) do
    body = unwrapped(body)

    value =
      body["settledCostMicrousd"] || body["settled_cost_microusd"] ||
        body["costMicrousd"] || body["cost_microusd"] ||
        get_in(body, ["usage", "settledCostMicrousd"]) ||
        get_in(body, ["usage", "settled_cost_microusd"])

    case value do
      value when is_integer(value) and value >= 0 ->
        %{settled_cost_microusd: value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> %{settled_cost_microusd: parsed}
          _invalid -> %{}
        end

      _unknown ->
        %{}
    end
  end

  defp settled_cost_attrs(_body), do: %{}
  defp ttl_seconds, do: Keyword.get(settings(), :ttl_seconds, 3_600)
  defp idle_seconds, do: Keyword.get(settings(), :idle_timeout_seconds, @default_idle_seconds)
  defp interval_ms, do: Keyword.get(settings(), :reconciliation_interval_ms, @default_interval_ms)
  defp settings, do: Application.get_env(:openagents, :box_api, [])
  defp next_backoff(0), do: @default_backoff_ms
  defp next_backoff(previous), do: min(@maximum_backoff_ms, previous * 2)
  defp schedule(delay), do: Process.send_after(self(), :reconcile, max(delay, 1))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
