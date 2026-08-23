defmodule OpenAgents.BoxRuns do
  @moduledoc "Durable detach-and-poll runs for long Box commands."

  import Ecto.Query

  alias OpenAgents.Box
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
  alias OpenAgents.Repo
  alias OpenAgents.Tools.BoxOutput

  @terminal_states Run.terminal_states()

  @spec start_run(String.t(), String.t(), map(), String.t(), String.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def start_run(conversation_id, box_id, principal, command, idempotency_key)
      when is_binary(conversation_id) and is_binary(box_id) and is_map(principal) and
             is_binary(command) and is_binary(idempotency_key) do
    with {:ok, _box} <- Box.get_box(conversation_id, box_id),
         {:ok, box_record} <- box_record(conversation_id, box_id),
         {:ok, result} <- admit(box_record, principal, command, idempotency_key) do
      case result do
        {:existing, run} ->
          {:ok, Repo.preload(run, :conversation_box)}

        {:new, run} ->
          case start_worker(run.id) do
            {:ok, _pid} -> {:ok, Repo.preload(run, :conversation_box)}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @spec list_runs(String.t(), String.t()) :: [Run.t()]
  def list_runs(conversation_id, box_id) do
    Repo.all(
      from run in Run,
        join: box in ConversationBox,
        on: box.id == run.conversation_box_id,
        where: run.conversation_id == ^conversation_id and box.box_id == ^box_id,
        order_by: [desc: run.inserted_at],
        preload: [conversation_box: box]
    )
  end

  @spec get_run(String.t(), String.t(), String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def get_run(conversation_id, box_id, run_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(run_id) do
      case Repo.one(
             from run in Run,
               join: box in ConversationBox,
               on: box.id == run.conversation_box_id,
               where:
                 run.id == ^run_id and run.conversation_id == ^conversation_id and
                   box.box_id == ^box_id,
               preload: [conversation_box: box]
           ) do
        %Run{} = run -> {:ok, run}
        nil -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @spec cancel(Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def cancel(%Run{} = run) do
    case Repo.transaction(fn ->
           locked = Repo.one!(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE")

           if Run.terminal?(locked) do
             locked
           else
             locked
             |> Run.changeset(%{
               cancellation_requested_at: locked.cancellation_requested_at || now()
             })
             |> Repo.update!()
           end
         end) do
      {:ok, cancelled_run} ->
        if Run.terminal?(cancelled_run),
          do: {:ok, cancelled_run},
          else: cancel_worker(cancelled_run)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  @spec read_output(Run.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def read_output(%Run{} = run, offset) when is_integer(offset) and offset >= 0 do
    start_offset = max(offset, run.output_base_offset)
    relative = min(start_offset - run.output_base_offset, byte_size(run.output))
    output = binary_part(run.output, relative, byte_size(run.output) - relative)

    {:ok,
     %{
       "output" => output,
       "offset" => offset,
       "next_offset" => run.last_output_offset,
       "output_base_offset" => run.output_base_offset,
       "truncated" => offset < run.output_base_offset
     }}
  end

  @spec reconcile_non_terminal() :: :ok
  def reconcile_non_terminal do
    Repo.all(from run in Run, where: run.state not in ^@terminal_states)
    |> Enum.each(fn run -> _ = start_worker(run.id) end)

    :ok
  end

  @spec start_worker(String.t()) :: DynamicSupervisor.on_start_child()
  def start_worker(run_id) do
    DynamicSupervisor.start_child(OpenAgents.BoxRunSupervisor, {OpenAgents.BoxRunServer, run_id})
  end

  @spec claim_dispatch(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def claim_dispatch(run_id) do
    Repo.transaction(fn ->
      run = Repo.one!(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")

      if is_nil(run.dispatch_attempted_at) and run.state == "admitted" do
        run
        |> Run.changeset(%{dispatch_attempted_at: now()})
        |> Repo.update!()
      else
        run
      end
    end)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  @spec mark_dispatched(String.t(), integer() | nil) :: {:ok, Run.t()}
  def mark_dispatched(run_id, pid) do
    update_run(run_id, %{
      state: "dispatched",
      pid: pid,
      dispatched_at: now(),
      started_at: now()
    })
  end

  @spec mark_probe_attempted(String.t()) :: {:ok, Run.t()}
  def mark_probe_attempted(run_id) do
    update_run(run_id, %{probe_attempted_at: now()})
  end

  @spec mark_lost(String.t(), String.t()) :: {:ok, Run.t()}
  def mark_lost(run_id, reason), do: update_run(run_id, terminal_attrs("lost", reason))

  @spec record_poll(String.t(), map()) :: {:ok, Run.t()}
  def record_poll(run_id, %{present: true, log_size: log_size, output: chunk} = result) do
    Repo.transaction(fn ->
      run = Repo.one!(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")

      if Run.terminal?(run) do
        run
      else
        {chunk, _truncated_chunk} =
          if log_size > run.last_output_offset do
            BoxOutput.bounded(chunk)
          else
            {"", false}
          end

        accepted_offset = max(run.last_output_offset, log_size)
        combined = run.output <> chunk
        {bounded, truncated} = BoxOutput.bounded(combined)

        base_offset =
          if truncated, do: accepted_offset - byte_size(bounded), else: run.output_base_offset

        attrs = %{
          output: bounded,
          output_base_offset: max(base_offset, 0),
          last_output_offset: accepted_offset,
          state: if(result[:exit_status] == nil, do: "running", else: run.state)
        }

        run
        |> Run.changeset(attrs)
        |> Repo.update!()
      end
    end)
  end

  def record_poll(run_id, _result), do: mark_lost(run_id, "run_directory_missing")

  @spec finish(String.t(), String.t(), integer() | nil, String.t() | nil) ::
          {:ok, Run.t()}
  def finish(run_id, state, exit_status \\ nil, reason \\ nil)
      when state in @terminal_states do
    attrs = %{state: state, exit_status: exit_status, finished_at: now()}
    attrs = if state == "timed_out", do: Map.put(attrs, :timed_out, true), else: attrs
    attrs = if reason, do: Map.put(attrs, :failure_reason, reason), else: attrs
    update_run(run_id, attrs)
  end

  @spec mark_cancellation_effective(String.t()) :: {:ok, Run.t()}
  def mark_cancellation_effective(run_id) do
    update_run(run_id, %{
      state: "cancelled",
      cancellation_effective_at: now(),
      finished_at: now()
    })
  end

  @spec mark_timeout(String.t()) :: {:ok, Run.t()}
  def mark_timeout(run_id), do: update_run(run_id, %{timed_out: true})

  defp admit(box_record, principal, command, idempotency_key) do
    Repo.transaction(fn ->
      existing =
        Repo.one(
          from run in Run,
            where:
              run.conversation_id == ^box_record.conversation_id and
                run.idempotency_key == ^idempotency_key
        )

      cond do
        existing && existing.conversation_box_id == box_record.id && existing.command == command ->
          {:existing, existing}

        existing ->
          Repo.rollback(:box_run_idempotency_conflict)

        Repo.exists?(
          from run in Run,
            where:
              run.conversation_box_id == ^box_record.id and
                  run.state not in ^@terminal_states
        ) ->
          Repo.rollback(:box_run_in_progress)

        true ->
          admitted_at = now()
          deadline_at = DateTime.add(admitted_at, maximum_duration_seconds(), :second)
          run_id = Ecto.UUID.generate()

          attrs = %{
            conversation_id: box_record.conversation_id,
            conversation_box_id: box_record.id,
            requesting_principal: principal,
            command: command,
            idempotency_key: idempotency_key,
            id: run_id,
            run_directory: run_directory(principal, run_id),
            admitted_at: admitted_at,
            deadline_at: deadline_at
          }

          run =
            %Run{}
            |> Run.changeset(attrs)
            |> Repo.insert!()

          {:new, run}
      end
    end)
  end

  defp box_record(conversation_id, box_id) do
    case Repo.one(
           from box in ConversationBox,
             where: box.conversation_id == ^conversation_id and box.box_id == ^box_id
         ) do
      %ConversationBox{} = box -> {:ok, box}
      nil -> {:error, :box_not_owned}
    end
  end

  defp cancel_worker(run) do
    case Registry.lookup(OpenAgents.BoxRunRegistry, run.id) do
      [{pid, _value}] ->
        GenServer.cast(pid, :cancel)
        {:ok, run}

      [] ->
        case start_worker(run.id) do
          {:ok, pid} ->
            GenServer.cast(pid, :cancel)
            {:ok, run}

          {:error, {:already_started, _pid}} ->
            {:ok, run}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp update_run(run_id, attrs) do
    with {:ok, _uuid} <- Ecto.UUID.cast(run_id) do
      case Repo.get(Run, run_id) do
        %Run{} = run -> {:ok, run |> Run.changeset(attrs) |> Repo.update!()}
        nil -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp terminal_attrs(state, reason),
    do: %{state: state, failure_reason: reason, finished_at: now()}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp maximum_duration_seconds do
    settings = Application.get_env(:openagents, :box_api, [])
    configured = Keyword.get(settings, :run_max_duration_seconds, 1_800)
    ttl = Keyword.get(settings, :ttl_seconds, 3_600)
    configured |> max(1) |> min(max(ttl, 1))
  end

  defp run_directory(principal, run_id) do
    principal_id = Map.get(principal, "id") || Map.get(principal, :id) || "unknown"
    principal_id = principal_path_segment(principal_id)
    "$HOME/.openagents/box-runs/users/#{principal_id}/#{run_id}"
  end

  defp principal_path_segment(principal_id) when is_binary(principal_id) do
    Regex.replace(~r/[^A-Za-z0-9_-]/, principal_id, "-")
  end

  defp principal_path_segment(_principal_id), do: "unknown"
end
