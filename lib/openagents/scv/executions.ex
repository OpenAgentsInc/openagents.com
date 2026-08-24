defmodule OpenAgents.SCV.Executions do
  @moduledoc "Claims, fences, records, and completes durable SCV executions."

  import Ecto.Query

  require Logger

  alias OpenAgents.Repo
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.Execution
  alias OpenAgents.SCV.ExecutionEvent

  @lease_seconds 120
  @maximum_public_entries 32
  @expired_report "The SCV lease expired before a terminal receipt was persisted."
  @event_keys ~w(
    activity_kind driver duration_ms emitted_at error_code input_tokens model
    output_tokens permission_profile reasoning_effort run_id schema status text_bytes
    thread_ref tool total_tokens turn_ref type
  )

  @spec claim(DriverAccount.t(), String.t(), String.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, atom() | Ecto.Changeset.t()}
  def claim(%DriverAccount{} = account, repository_revision, objective, options \\ []) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      account = Repo.one!(from a in DriverAccount, where: a.id == ^account.id, lock: "FOR UPDATE")

      with :ok <- admit_account(account, options),
           :ok <- release_stale_execution(account, now) do
        generation = next_generation(account.id)

        attributes = %{
          driver_account_id: account.id,
          principal: "scv:codex_app_server:#{account.id}",
          repository_revision: repository_revision,
          objective: objective,
          reasoning_effort: Keyword.get(options, :reasoning_effort, "low"),
          owner_node: to_string(node()),
          generation: generation,
          lease_expires_at: DateTime.add(now, @lease_seconds, :second),
          started_at: now
        }

        case %Execution{} |> Execution.claim_changeset(attributes) |> Repo.insert() do
          {:ok, execution} -> execution
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec record_event(Execution.t(), map()) :: :ok | {:error, atom()}
  def record_event(%Execution{} = execution, event) when is_map(event) do
    with {:ok, sanitized} <- sanitize_event(execution.id, event),
         {:ok, _result} <- persist_event(execution, sanitized) do
      log_event(execution, sanitized)
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :event_persistence_failed}
    end
  end

  def record_event(%Execution{}, _event), do: {:error, :event_invalid}

  @spec record_session(Execution.t(), map()) :: {:ok, Execution.t()} | {:error, atom()}
  def record_session(%Execution{} = execution, attributes) when is_map(attributes) do
    update_fenced(execution, fn current -> Execution.session_changeset(current, attributes) end)
  end

  @spec finish(Execution.t(), map()) :: {:ok, Execution.t()} | {:error, atom()}
  def finish(%Execution{} = execution, result) when is_map(result) do
    report = terminal_report(result)

    attributes = %{
      status: terminal_status(result),
      report: report,
      report_digest: digest(report),
      usage: bounded_map(Map.get(result, :usage) || Map.get(result, "usage")),
      resources: bounded_map(Map.get(result, :resources) || Map.get(result, "resources")),
      error_code: normalized_error_code(result),
      completed_at: DateTime.utc_now()
    }

    update_fenced(execution, fn current -> Execution.terminal_changeset(current, attributes) end)
  end

  @spec get!(Ecto.UUID.t()) :: Execution.t()
  def get!(id), do: Repo.get!(Execution, id)

  @spec list_active() :: [Execution.t()]
  def list_active do
    now = DateTime.utc_now()

    Repo.all(
      from execution in Execution,
        where: execution.status == "running" and execution.lease_expires_at > ^now,
        order_by: [desc: execution.started_at],
        limit: @maximum_public_entries
    )
  end

  @doc "Returns active SCVs as a bounded, content-free public projection."
  @spec public_projection() :: [OpenAgents.SCV.Activity.public_entry()]
  def public_projection do
    active = Enum.take(list_active(), @maximum_public_entries)
    run_ids = Enum.map(active, & &1.id)

    latest_events =
      if run_ids == [] do
        %{}
      else
        Repo.all(
          from event in ExecutionEvent,
            where: event.run_id in ^run_ids,
            distinct: event.run_id,
            order_by: [asc: event.run_id, desc: event.id],
            select: {event.run_id, event.payload}
        )
        |> Map.new()
      end

    Enum.map(active, fn execution ->
      event =
        Map.get(latest_events, execution.id) ||
          %{
            "schema" => "openagents.scv.event.v1",
            "run_id" => execution.id,
            "type" => "run_preparing"
          }

      OpenAgents.SCV.Activity.project_event(event) ||
        OpenAgents.SCV.Activity.project_event(%{
          "schema" => "openagents.scv.event.v1",
          "run_id" => execution.id,
          "type" => "heartbeat"
        })
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Marks every expired running lease uncertain and releases its account slot."
  @spec expire_stale() :: non_neg_integer()
  def expire_stale do
    now = DateTime.utc_now()

    {count, nil} =
      from(execution in Execution,
        where: execution.status == "running" and execution.lease_expires_at <= ^now
      )
      |> Repo.update_all(
        set: [
          status: "uncertain",
          report: @expired_report,
          report_digest: digest(@expired_report),
          error_code: "lease_expired",
          completed_at: now,
          updated_at: now
        ]
      )

    count
  end

  defp admit_account(%DriverAccount{status: "ready"} = account, options) do
    reasoning_effort = Keyword.get(options, :reasoning_effort, "low")

    cond do
      "gpt-5.6-luna" not in account.available_models -> {:error, :required_model_unavailable}
      reasoning_effort not in account.reasoning_efforts -> {:error, :reasoning_effort_unavailable}
      reasoning_effort not in ["none", "low"] -> {:error, :reasoning_effort_not_admitted}
      true -> :ok
    end
  end

  defp admit_account(%DriverAccount{}, _options), do: {:error, :account_not_ready}

  defp release_stale_execution(account, now) do
    active =
      Repo.one(
        from execution in Execution,
          where: execution.driver_account_id == ^account.id and execution.status == "running",
          lock: "FOR UPDATE"
      )

    case active do
      nil ->
        :ok

      %Execution{lease_expires_at: expires_at} = execution ->
        if DateTime.compare(expires_at, now) != :gt do
          execution
          |> Execution.terminal_changeset(%{
            status: "uncertain",
            report: @expired_report,
            report_digest: digest(@expired_report),
            error_code: "lease_expired",
            completed_at: now
          })
          |> Repo.update!()

          :ok
        else
          {:error, :account_capacity_unavailable}
        end
    end
  end

  defp next_generation(account_id) do
    Repo.one(
      from execution in Execution,
        where: execution.driver_account_id == ^account_id,
        select: coalesce(max(execution.generation), 0)
    ) + 1
  end

  defp persist_event(execution, event) do
    Repo.transaction(fn ->
      lease_expires_at = DateTime.add(DateTime.utc_now(), @lease_seconds, :second)

      {count, nil} =
        from(current in Execution,
          where:
            current.id == ^execution.id and current.status == "running" and
              current.owner_node == ^execution.owner_node and
              current.generation == ^execution.generation
        )
        |> Repo.update_all(
          inc: [event_count: 1],
          set: [lease_expires_at: lease_expires_at, updated_at: DateTime.utc_now()]
        )

      if count != 1, do: Repo.rollback(:stale_execution_generation)

      attributes = %{
        run_id: execution.id,
        schema: event["schema"],
        event_type: event["type"],
        payload: event,
        emitted_at: parse_emitted_at(event["emitted_at"])
      }

      case %ExecutionEvent{} |> ExecutionEvent.changeset(attributes) |> Repo.insert() do
        {:ok, persisted} -> persisted
        {:error, _changeset} -> Repo.rollback(:event_persistence_failed)
      end
    end)
  end

  defp update_fenced(execution, changeset_function) do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from current in Execution,
            where:
              current.id == ^execution.id and current.status == "running" and
                current.owner_node == ^execution.owner_node and
                current.generation == ^execution.generation,
            lock: "FOR UPDATE"
        )

      if is_nil(current), do: Repo.rollback(:stale_execution_generation)

      case current |> changeset_function.() |> Repo.update() do
        {:ok, updated} -> updated
        {:error, _changeset} -> Repo.rollback(:execution_persistence_failed)
      end
    end)
  end

  defp sanitize_event(run_id, event) do
    normalized = Map.new(event, fn {key, value} -> {to_string(key), value} end)

    with "openagents.scv.event.v1" <- normalized["schema"],
         ^run_id <- normalized["run_id"],
         type when is_binary(type) and byte_size(type) in 1..80 <- normalized["type"] do
      sanitized =
        normalized
        |> Map.take(@event_keys)
        |> Map.put("run_id", run_id)
        |> Map.put("schema", "openagents.scv.event.v1")
        |> Map.put("type", type)
        |> Map.put_new("emitted_at", DateTime.utc_now() |> DateTime.to_iso8601())

      if byte_size(Jason.encode!(sanitized)) <= 16_384,
        do: {:ok, sanitized},
        else: {:error, :event_too_large}
    else
      _invalid -> {:error, :event_invalid}
    end
  end

  defp terminal_report(result) do
    report = Map.get(result, :report) || Map.get(result, "report") || %{}
    text = Map.get(report, :text) || Map.get(report, "text")

    if is_binary(text) and byte_size(text) in 1..32_768,
      do: text,
      else: "The SCV finished without a valid bounded report."
  end

  defp terminal_status(result) do
    case Map.get(result, :status) || Map.get(result, "status") do
      status when status in ["succeeded", "failed", "cancelled", "uncertain"] -> status
      _status -> "failed"
    end
  end

  defp normalized_error_code(result) do
    case Map.get(result, :error_code) || Map.get(result, "error_code") do
      code when is_binary(code) -> String.slice(code, 0, 80)
      _code -> nil
    end
  end

  defp bounded_map(value) when is_map(value) do
    if byte_size(Jason.encode!(value)) <= 16_384, do: value, else: %{"truncated" => true}
  end

  defp bounded_map(_value), do: %{}

  defp parse_emitted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> DateTime.utc_now()
    end
  end

  defp parse_emitted_at(_value), do: DateTime.utc_now()

  defp log_event(execution, %{"type" => type})
       when type in ["heartbeat", "message_delta", "usage_updated"] do
    Logger.debug("SCV run #{execution.id} event #{type}")
  end

  defp log_event(execution, %{"type" => type}) do
    Logger.info("SCV run #{execution.id} event #{type}")
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
