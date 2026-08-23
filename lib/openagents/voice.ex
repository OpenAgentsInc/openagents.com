defmodule OpenAgents.Voice do
  @moduledoc "Durable, generation-fenced authority for Sarah voice sessions."

  import Ecto.Query

  alias OpenAgents.Conversations.{Conversation, Message}
  alias OpenAgents.Modules.Lifecycle
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo
  alias OpenAgents.Tools.Registry
  alias OpenAgents.Voice.Evaluation.ContractGate

  alias OpenAgents.Voice.{
    Config,
    ClientEvent,
    ContextCapture,
    OperationalTelemetry,
    PersistedEvent,
    ProviderEvent,
    ResponseContext,
    ResponseReceipt,
    ReleaseControl,
    Session,
    ToolStep,
    TranscriptItem,
    Usage
  }

  @active_statuses ~w(connecting listening responding interrupted reconnecting)
  @terminal_statuses ~w(ended failed)

  @spec admit_session(Conversation.t(), Config.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def admit_session(%Conversation{} = conversation, %Config{enabled?: true} = config) do
    with {:ok, tool_snapshot} <- Lifecycle.capture(Registry.current!()) do
      admit_session_with_registry(conversation, config, tool_snapshot)
    end
  end

  def admit_session(%Conversation{}, %Config{}), do: {:error, :voice_disabled}

  defp admit_session_with_registry(conversation, config, tool_snapshot) do
    with {:ok, capture} <- ContextCapture.admission(conversation, tool_snapshot) do
      context = capture.context
      program_snapshot = capture.program_snapshot

      result =
        Repo.transaction(fn ->
          _admission_lock = Repo.query!("SELECT pg_advisory_xact_lock($1)", [83_472_019])
          release_control = ReleaseControl.lock_current!()

          case ReleaseControl.require_open(release_control) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          enforce_concurrent_session_limit!()
          _locked_conversation = Repo.get_for_update!(Conversation, conversation.id)

          if active_session_query(conversation.id) |> Repo.exists?() do
            Repo.rollback(:voice_session_in_progress)
          end

          enforce_attempt_rate!(conversation.id)

          generation =
            Repo.aggregate(
              from(session in Session, where: session.conversation_id == ^conversation.id),
              :max,
              :generation
            ) || 0

          attributes = %{
            conversation_id: conversation.id,
            release_control_id: release_control.id,
            generation: generation + 1,
            status: "connecting",
            architecture: Atom.to_string(config.architecture),
            provider_id: config.provider,
            model_id: config.model,
            voice_artifact_id: voice_artifact_id(config.voice),
            persona_id: context.persona_id,
            persona_digest: context.persona_digest,
            role_id: context.role_id,
            role_digest: context.role_digest,
            role_selection: context.role_selection,
            instruction_digest: context.instruction_digest,
            instructions: context.instructions,
            tool_catalog_digest: tool_snapshot.digest,
            tool_catalog: capture.tool_catalog,
            blueprint_revision: context.blueprint_revision,
            blueprint_digest: context.blueprint_digest,
            program_artifact_id: ContextCapture.program_artifact_id(program_snapshot),
            program_artifact_digest: ContextCapture.program_artifact_digest(program_snapshot),
            program_artifact_receipt: program_snapshot.receipt,
            started_at: DateTime.utc_now()
          }

          %Session{}
          |> Session.create_changeset(attributes)
          |> insert_or_rollback()
        end)

      case result do
        {:ok, session} ->
          :ok = OperationalTelemetry.emit(:session_admitted, session)
          {:ok, session}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec active_session(Conversation.t()) :: Session.t() | nil
  def active_session(%Conversation{id: conversation_id}) do
    conversation_id
    |> active_session_query()
    |> Repo.one()
  end

  @doc """
  The most recent session for a conversation, active or terminal.

  Recording uploads need this rather than `active_session/1`: the last audio
  slice and the finalize both legitimately arrive after the call has ended.
  Generation fencing still decides what those writes may touch.
  """
  @spec latest_session(Conversation.t()) :: Session.t() | nil
  def latest_session(%Conversation{id: conversation_id}) do
    Repo.one(
      from(session in Session,
        where: session.conversation_id == ^conversation_id,
        order_by: [desc: session.generation],
        limit: 1
      )
    )
  end

  @doc """
  The most recent sessions for a conversation, newest first, bounded.

  A read-only sidebar projection. Each entry pairs the session with the id of
  its earliest durable transcript message when one exists, so a row can point
  at durable transcript evidence without a per-row query; `nil` means the call
  produced no transcript message and the row has nothing to scroll to.
  """
  @spec recent_sessions(Conversation.t(), pos_integer()) ::
          [%{session: Session.t(), first_message_id: Ecto.UUID.t() | nil}]
  def recent_sessions(%Conversation{id: conversation_id}, limit)
      when is_integer(limit) and limit > 0 do
    sessions =
      Repo.all(
        from(session in Session,
          where: session.conversation_id == ^conversation_id,
          order_by: [desc: session.generation],
          limit: ^limit
        )
      )

    first_message_ids =
      case Enum.map(sessions, & &1.id) do
        [] ->
          %{}

        session_ids ->
          Repo.all(
            from(message in Message,
              where: message.voice_session_id in ^session_ids,
              distinct: message.voice_session_id,
              order_by: [
                asc: message.voice_session_id,
                asc: message.inserted_at,
                asc: message.id
              ],
              select: {message.voice_session_id, message.id}
            )
          )
          |> Map.new()
      end

    Enum.map(sessions, fn session ->
      %{session: session, first_message_id: Map.get(first_message_ids, session.id)}
    end)
  end

  @spec get_session!(Ecto.UUID.t()) :: Session.t()
  def get_session!(session_id), do: Repo.get!(Session, session_id)

  @spec attach_provider(Session.t(), pos_integer(), String.t()) ::
          {:ok, Session.t()} | {:error, atom() | Ecto.Changeset.t()}
  def attach_provider(%Session{} = session, generation, provider_session_id)
      when is_integer(generation) and is_binary(provider_session_id) do
    Repo.transaction(fn ->
      locked_session = Repo.get_for_update!(Session, session.id)

      with :ok <- require_generation(locked_session, generation),
           :ok <- require_active(locked_session) do
        locked_session
        |> Session.lifecycle_changeset(%{provider_session_id: provider_session_id})
        |> update_or_rollback()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec record_provider_event(Session.t(), pos_integer(), ProviderEvent.t()) ::
          {:ok, Session.t(), PersistedEvent.t(), :created | :duplicate}
          | {:error, atom() | Ecto.Changeset.t()}
  def record_provider_event(
        %Session{} = session,
        generation,
        %ProviderEvent{} = provider_event
      ) do
    record_provider_event(session, generation, provider_event, [])
  end

  @spec record_provider_event(Session.t(), pos_integer(), ProviderEvent.t(), keyword()) ::
          {:ok, Session.t(), PersistedEvent.t(), :created | :duplicate}
          | {:error, atom() | Ecto.Changeset.t()}
  def record_provider_event(
        %Session{} = session,
        generation,
        %ProviderEvent{} = provider_event,
        options
      ) do
    Repo.transaction(fn ->
      locked_session = Repo.get_for_update!(Session, session.id)

      with :ok <- require_generation(locked_session, generation),
           :ok <- require_active(locked_session),
           :ok <- require_event_state(locked_session, provider_event) do
        case duplicate_event(locked_session, provider_event) do
          %PersistedEvent{} = persisted_event ->
            {locked_session, persisted_event, :duplicate}

          nil ->
            observed_at = DateTime.utc_now()
            sequence = locked_session.event_sequence + 1
            lifecycle = lifecycle_attributes(locked_session, provider_event, observed_at)

            updated_session =
              locked_session
              |> Session.lifecycle_changeset(Map.put(lifecycle, :event_sequence, sequence))
              |> update_or_rollback()

            persisted_event =
              %PersistedEvent{}
              |> PersistedEvent.create_changeset(%{
                voice_session_id: locked_session.id,
                generation: generation,
                sequence: sequence,
                provider_event_id: provider_event.provider_event_id,
                kind: Atom.to_string(provider_event.kind),
                payload: durable_event_payload(provider_event),
                observed_at: observed_at
              })
              |> insert_or_rollback()

            :ok =
              persist_response_receipt(
                locked_session,
                provider_event,
                persisted_event,
                Keyword.get(options, :response_context),
                Keyword.get(options, :inherited_tool_steps, [])
              )

            :ok = persist_transcript(locked_session, provider_event, observed_at)
            {updated_session, persisted_event, :created}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {updated_session, persisted_event, disposition}} ->
        broadcast(updated_session)
        broadcast_message_projection(updated_session, provider_event)

        # Voice usage accumulates on the session row, so a changed usage map is
        # the signal that this account's total moved. Comparing against the
        # caller's copy can only over-signal, and the recompute is coalesced.
        if updated_session.usage != session.usage, do: :ok = OpenAgents.Leaderboard.invalidate()

        :ok =
          OperationalTelemetry.emit(:provider_event, updated_session, %{
            event_kind: provider_event.kind,
            disposition: disposition
          })

        :ok = maybe_evaluate_response_contract(updated_session, provider_event, disposition)

        {:ok, updated_session, persisted_event, disposition}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Runtime promotion of the offline contract gate (observability only): every
  # event that terminates a response scores the latest terminal receipt, and a
  # violation emits one content-free telemetry code. Claims-based lenses
  # (false completion) still need a semantic claims extractor and stay vacuous
  # here; the deterministically checkable lens is interrupted authority.
  defp maybe_evaluate_response_contract(session, %ProviderEvent{kind: kind}, :created)
       when kind in [:response_completed, :speech_started, :response_cancelled, :provider_error] do
    receipt =
      Repo.one(
        from(receipt in ResponseReceipt,
          where:
            receipt.voice_session_id == ^session.id and
              receipt.generation == ^session.generation and
              receipt.status in ["completed", "interrupted", "failed"],
          order_by: [desc: receipt.terminal_event_sequence],
          limit: 1
        )
      )

    with %ResponseReceipt{} = receipt <- receipt do
      identity = %{
        "persona_id" => session.persona_id,
        "persona_digest" => session.persona_digest,
        "role_id" => session.role_id,
        "role_digest" => session.role_digest,
        "instruction_digest" => session.instruction_digest
      }

      tool_steps =
        Repo.all(
          from(step in ToolStep,
            where: step.voice_response_receipt_id == ^receipt.id,
            select: %{id: step.id, tool_name: step.tool_name, status: step.status}
          )
        )

      assistant_message_status =
        Repo.one(
          from(message in Message,
            where:
              message.voice_session_id == ^receipt.voice_session_id and
                message.provider_response_id == ^receipt.provider_response_id and
                message.role == "assistant",
            order_by: [desc: message.status == "complete"],
            limit: 1,
            select: message.status
          )
        )

      trace = %{
        "admitted_identity" => identity,
        "observed_identity" => identity,
        "selected_evidence_refs" => [],
        "memory_claims" => [],
        "required_tool_names" => [],
        "tool_steps" =>
          Enum.map(tool_steps, fn step ->
            %{
              "step_ref" => "voice-tool-step:#{step.id}",
              "tool_name" => step.tool_name,
              "status" => step.status
            }
          end),
        "response_receipt" => %{
          "status" => receipt.status,
          "used_tool_step_refs" => receipt.used_tool_step_refs
        },
        "action_completion_claims" => [],
        "assistant_message" => %{
          "status" => assistant_message_status || "cancelled",
          "authoritative" => false
        },
        "correction" => nil
      }

      case ContractGate.evaluate(trace) do
        {:ok, %{"passed" => true}} ->
          :ok

        {:ok, %{"violations" => violations}} ->
          OperationalTelemetry.emit(:contract_gate, session, %{
            event_kind: "contract_violation:" <> Enum.join(violations, ",")
          })
      end
    else
      nil -> :ok
    end
  end

  defp maybe_evaluate_response_contract(_session, _provider_event, _disposition), do: :ok

  @spec end_session(Session.t(), pos_integer(), String.t()) ::
          {:ok, Session.t()} | {:error, atom() | Ecto.Changeset.t()}
  def end_session(%Session{} = session, generation, reason) when is_binary(reason) do
    terminal_transition(session, generation, "ended", reason, nil)
  end

  @spec fail_session(Session.t(), pos_integer(), atom() | String.t()) ::
          {:ok, Session.t()} | {:error, atom() | Ecto.Changeset.t()}
  def fail_session(%Session{} = session, generation, reason) do
    failure_code = normalize_failure_code(reason)
    terminal_transition(session, generation, "failed", "runtime_failure", failure_code)
  end

  @spec interrupt_response(Session.t(), pos_integer()) ::
          {:ok, Session.t(), PersistedEvent.t(), :created | :duplicate}
          | {:error, atom() | Ecto.Changeset.t()}
  def interrupt_response(%Session{} = session, generation) do
    record_provider_event(session, generation, %ProviderEvent{
      kind: :response_cancelled,
      provider_event_id: nil,
      payload: %{"source" => "user_control"}
    })
  end

  # Compaction summaries are bounded continuity evidence for long calls; the
  # cap keeps one summary from becoming an unbounded content sink on the
  # session row. Transcript and message authority are never displaced by it.
  @maximum_compaction_summary_bytes 8_192

  @doc """
  Durably records one in-call compaction summary on the fenced session row.

  The summary is byte-bounded (~8KB, trimmed at a UTF-8 boundary) and
  increments `compaction_count`. Returns the bounded summary actually stored
  so the runtime injects exactly what was persisted.
  """
  @spec record_compaction_summary(Session.t(), pos_integer(), String.t()) ::
          {:ok, Session.t(), String.t()} | {:error, term()}
  def record_compaction_summary(%Session{} = session, generation, summary)
      when is_integer(generation) and is_binary(summary) do
    bounded = bounded_utf8(summary, @maximum_compaction_summary_bytes)

    result =
      Repo.transaction(fn ->
        locked_session = Repo.get_for_update!(Session, session.id)

        with :ok <- require_generation(locked_session, generation),
             :ok <- require_active(locked_session) do
          locked_session
          |> Session.compaction_changeset(%{
            compaction_summary: bounded,
            compaction_count: locked_session.compaction_count + 1
          })
          |> update_or_rollback()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, updated_session} -> {:ok, updated_session, bounded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_utf8(binary, maximum) when byte_size(binary) <= maximum, do: binary

  defp bounded_utf8(binary, maximum) do
    binary
    |> binary_part(0, maximum)
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_to_valid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  @spec recover_interrupted_sessions() :: :ok
  def recover_interrupted_sessions do
    now = DateTime.utc_now()

    {:ok, :recovered} =
      Repo.transaction(fn ->
        from(step in ToolStep,
          join: session in Session,
          on: session.id == step.voice_session_id,
          where: session.status in ^@active_statuses and step.status in ["requested", "running"]
        )
        |> Repo.all()
        |> Enum.each(fn step ->
          terminate_tool_step(step, "interrupted", "runtime_restarted", now)
        end)

        from(session in Session, where: session.status in ^@active_statuses)
        |> Repo.update_all(
          set: [
            status: "failed",
            ended_at: now,
            termination_reason: "runtime_restart",
            failure_code: "runtime_interrupted",
            updated_at: now
          ]
        )

        :recovered
      end)

    :ok
  end

  @spec list_events(Session.t()) :: [PersistedEvent.t()]
  def list_events(%Session{id: session_id}) do
    Repo.all(
      from(event in PersistedEvent,
        where: event.voice_session_id == ^session_id,
        order_by: [asc: event.sequence]
      )
    )
  end

  @spec list_transcript_items(Session.t()) :: [TranscriptItem.t()]
  def list_transcript_items(%Session{id: session_id}) do
    Repo.all(
      from(item in TranscriptItem,
        where: item.voice_session_id == ^session_id,
        order_by: [asc: item.observed_at, asc: item.id]
      )
    )
  end

  @spec list_response_receipts(Session.t()) :: [ResponseReceipt.t()]
  def list_response_receipts(%Session{id: session_id}) do
    Repo.all(
      from(receipt in ResponseReceipt,
        where: receipt.voice_session_id == ^session_id,
        order_by: [asc: receipt.started_event_sequence]
      )
    )
  end

  @spec list_response_contexts(Session.t()) :: [ResponseContext.t()]
  def list_response_contexts(%Session{id: session_id}) do
    Repo.all(
      from(context in ResponseContext,
        where: context.voice_session_id == ^session_id,
        order_by: [asc: context.captured_at, asc: context.id]
      )
    )
  end

  @spec response_context_for_input(Session.t(), String.t()) ::
          {:ok, ResponseContext.t()} | {:error, :voice_response_context_missing}
  def response_context_for_input(%Session{id: session_id, generation: generation}, item_id) do
    case Repo.get_by(ResponseContext,
           voice_session_id: session_id,
           generation: generation,
           provider_input_item_id: item_id
         ) do
      nil -> {:error, :voice_response_context_missing}
      context -> {:ok, context}
    end
  end

  @spec capture_response_context(Session.t(), String.t(), OpenAgents.Tools.Snapshot.t()) ::
          {:ok, ResponseContext.t()} | {:error, term()}
  def capture_response_context(%Session{} = session, provider_input_item_id, tool_snapshot)
      when is_binary(provider_input_item_id) do
    case Repo.get_by(TranscriptItem,
           voice_session_id: session.id,
           generation: session.generation,
           provider_item_id: provider_input_item_id,
           role: "user"
         ) do
      nil -> {:error, :voice_user_transcript_missing}
      transcript -> ContextCapture.capture_response(session, transcript, tool_snapshot)
    end
  end

  @spec get_response_receipt(Session.t(), String.t()) ::
          {:ok, ResponseReceipt.t()} | {:error, :voice_response_not_started}
  def get_response_receipt(%Session{} = session, provider_response_id) do
    case Repo.get_by(ResponseReceipt,
           voice_session_id: session.id,
           generation: session.generation,
           provider_response_id: provider_response_id
         ) do
      nil -> {:error, :voice_response_not_started}
      receipt -> {:ok, receipt}
    end
  end

  @spec list_tool_steps(Session.t()) :: [ToolStep.t()]
  def list_tool_steps(%Session{id: session_id}) do
    Repo.all(
      from(step in ToolStep,
        where: step.voice_session_id == ^session_id,
        order_by: [asc: step.sequence]
      )
    )
  end

  @spec list_tool_step_activity(Session.t()) :: [map()]
  def list_tool_step_activity(%Session{id: session_id}) do
    Repo.all(
      from(step in ToolStep,
        where: step.voice_session_id == ^session_id,
        order_by: [asc: step.sequence],
        select: %{
          id: step.id,
          sequence: step.sequence,
          tool_name: step.tool_name,
          status: step.status,
          raw_arguments: step.raw_arguments,
          result: step.result,
          error: step.error,
          executor_id: step.executor_id,
          executor_disclosure: step.executor_disclosure,
          requested_at: step.requested_at,
          started_at: step.started_at,
          completed_at: step.completed_at
        }
      )
    )
  end

  @doc """
  Voice tool-step activity keyed by the assistant message each step belongs to.

  A voice tool call is durable evidence of the same authority a text tool call
  has, so it belongs beside the assistant message it produced rather than only
  in the live session panel, which empties when the call ends or the page
  reloads. The response receipt carries the assistant message, so the join is
  the receipt.

  Selects the same bounded projection as `list_tool_step_activity/1`, so
  INVARIANTS.md UI-002 holds: already-scrubbed durable values and never a
  provider identifier.
  """
  @spec list_tool_step_activity_by_message([String.t()]) :: %{String.t() => [map()]}
  def list_tool_step_activity_by_message([]), do: %{}

  def list_tool_step_activity_by_message(assistant_message_ids)
      when is_list(assistant_message_ids) do
    from(step in ToolStep,
      join: receipt in ResponseReceipt,
      on: receipt.id == step.voice_response_receipt_id,
      where: receipt.assistant_message_id in ^assistant_message_ids,
      order_by: [asc: step.sequence],
      select:
        {receipt.assistant_message_id,
         %{
           id: step.id,
           sequence: step.sequence,
           tool_name: step.tool_name,
           status: step.status,
           raw_arguments: step.raw_arguments,
           result: step.result,
           error: step.error,
           executor_id: step.executor_id,
           executor_disclosure: step.executor_disclosure,
           requested_at: step.requested_at,
           started_at: step.started_at,
           completed_at: step.completed_at
         }}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @spec record_client_event(Session.t(), String.t(), {String.t(), integer() | nil}) ::
          {:ok, ClientEvent.t()} | {:error, term()}
  def record_client_event(%Session{} = session, kind, {browser_family, browser_major}) do
    Repo.transaction(fn ->
      locked_session = Repo.get_for_update!(Session, session.id)

      with :ok <- require_generation(locked_session, session.generation),
           :ok <- require_active(locked_session) do
        sequence =
          Repo.aggregate(
            from(event in ClientEvent,
              where:
                event.voice_session_id == ^locked_session.id and
                  event.generation == ^locked_session.generation
            ),
            :max,
            :sequence
          ) || 0

        if sequence >= 64, do: Repo.rollback(:voice_client_event_limit_reached)

        %ClientEvent{}
        |> ClientEvent.create_changeset(%{
          voice_session_id: locked_session.id,
          generation: locked_session.generation,
          sequence: sequence + 1,
          kind: kind,
          browser_family: browser_family,
          browser_major: browser_major,
          observed_at: DateTime.utc_now()
        })
        |> insert_or_rollback()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec request_tool_step(Session.t(), ProviderEvent.t(), OpenAgents.Tools.Snapshot.t()) ::
          {:ok, ToolStep.t(), :created | :existing} | {:error, term()}
  def request_tool_step(
        %Session{} = session,
        %ProviderEvent{kind: :tool_call_requested, payload: payload},
        tool_snapshot
      ) do
    raw_arguments = payload["raw_arguments"]

    with :ok <- validate_raw_tool_arguments(raw_arguments),
         :ok <- verify_tool_catalog(session, tool_snapshot),
         {:ok, argument_digest} <- tool_argument_digest(raw_arguments) do
      result =
        Repo.transaction(fn ->
          locked_session = Repo.get_for_update!(Session, session.id)

          with :ok <- require_generation(locked_session, session.generation),
               :ok <- require_active(locked_session) do
            receipt = response_receipt_or_rollback(locked_session, payload["response_id"])

            {module_id, version} = tool_identity(tool_snapshot, payload["tool_name"])

            identity = %{
              voice_session_id: locked_session.id,
              voice_response_receipt_id: receipt.id,
              generation: locked_session.generation,
              provider_call_id: payload["call_id"],
              provider_item_id: payload["item_id"],
              provider_response_id: payload["response_id"],
              tool_name: payload["tool_name"],
              tool_version: version,
              module_id: module_id,
              catalog_digest: locked_session.tool_catalog_digest,
              raw_arguments: raw_arguments,
              argument_digest: argument_digest
            }

            case Repo.get_by(ToolStep,
                   voice_session_id: locked_session.id,
                   generation: locked_session.generation,
                   provider_call_id: identity.provider_call_id
                 ) do
              %ToolStep{} = existing_step ->
                if same_voice_tool_identity?(existing_step, identity),
                  do: {existing_step, :existing},
                  else: Repo.rollback(:provider_call_id_conflict)

              nil ->
                sequence =
                  Repo.aggregate(
                    from(step in ToolStep,
                      where:
                        step.voice_session_id == ^locked_session.id and
                          step.generation == ^locked_session.generation
                    ),
                    :max,
                    :sequence
                  ) || 0

                if sequence >= 32, do: Repo.rollback(:tool_step_limit_reached)

                step =
                  %ToolStep{}
                  |> ToolStep.requested_changeset(
                    identity
                    |> Map.put(:sequence, sequence + 1)
                    |> Map.put(:status, "requested")
                    |> Map.put(:requested_at, DateTime.utc_now())
                  )
                  |> insert_or_rollback()

                {step, :created}
            end
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {step, disposition}} ->
          broadcast_tool_activity(session, step)
          {:ok, step, disposition}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def request_tool_step(%Session{}, %ProviderEvent{}, _tool_snapshot),
    do: {:error, :invalid_voice_tool_event}

  @spec start_tool_step(Session.t(), ToolStep.t()) ::
          {:ok, ToolStep.t(), :started | :already_running} | {:error, term()}
  def start_tool_step(%Session{} = session, %ToolStep{} = step) do
    result =
      Repo.transaction(fn ->
        locked_session = Repo.get_for_update!(Session, session.id)

        with :ok <- require_generation(locked_session, session.generation),
             :ok <- require_active(locked_session) do
          locked_step = Repo.get_for_update!(ToolStep, step.id)

          case locked_step.status do
            "requested" ->
              running_step =
                locked_step
                |> ToolStep.running_changeset(%{
                  status: "running",
                  started_at: DateTime.utc_now()
                })
                |> update_or_rollback()

              {running_step, :started}

            "running" ->
              {locked_step, :already_running}

            _terminal ->
              Repo.rollback(:tool_step_is_terminal)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {running_step, disposition}} ->
        broadcast_tool_activity(session, running_step)
        {:ok, running_step, disposition}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec complete_tool_step(Session.t(), ToolStep.t(), map()) ::
          {:ok, ToolStep.t()} | {:error, term()}
  def complete_tool_step(
        %Session{} = session,
        %ToolStep{} = step,
        %{"schema" => "sarah.tool_outcome.v1"} = outcome
      ) do
    with :ok <- validate_tool_outcome(step, outcome),
         {:ok, outcome_digest} <- Canonical.digest(outcome) do
      result =
        Repo.transaction(fn ->
          locked_session = Repo.get_for_update!(Session, session.id)

          with :ok <- require_generation(locked_session, session.generation),
               :ok <- require_active(locked_session) do
            locked_step = Repo.get_for_update!(ToolStep, step.id)

            completed_step =
              if locked_step.status in ~w(requested running) do
                locked_step
                |> ToolStep.terminal_changeset(%{
                  status: outcome["status"],
                  outcome_digest: outcome_digest,
                  result: outcome["result"],
                  error: outcome["error"],
                  executor_id: get_in(outcome, ["executor_ref", "id"]),
                  executor_disclosure: get_in(outcome, ["executor_ref", "disclosure"]),
                  target_receipt_refs: outcome["target_receipt_refs"],
                  attribution_refs: outcome["attribution_refs"],
                  completed_at: DateTime.utc_now()
                })
                |> update_or_rollback()
              else
                if locked_step.outcome_digest == outcome_digest,
                  do: locked_step,
                  else: Repo.rollback(:tool_outcome_conflict)
              end

            update_voice_receipt_evidence(completed_step)
            completed_step
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, completed_step} ->
          broadcast_tool_activity(session, completed_step)
          {:ok, completed_step}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def complete_tool_step(%Session{}, %ToolStep{}, _outcome),
    do: {:error, :invalid_tool_outcome}

  @doc """
  Refuses a requested tool step with a typed host reason.

  A host limit that only answers the provider is invisible: the caller hears a
  turn that stops using tools and no one can tell whether the tool ran, failed,
  or was never allowed. Writing the refusal as a terminal step puts the reason
  in the same ordered activity stream a text refusal appears in.
  """
  @spec refuse_tool_step(Session.t(), ToolStep.t(), String.t(), String.t()) ::
          {:ok, ToolStep.t()} | {:error, term()}
  def refuse_tool_step(%Session{} = session, %ToolStep{} = step, code, message)
      when is_binary(code) and is_binary(message) do
    complete_tool_step(session, step, %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version
      },
      "executor_ref" => %{"id" => "sarah.host", "disclosure" => "Sarah host execution limits"},
      "status" => "refused",
      "result" => nil,
      "error" => %{"code" => code, "message" => message},
      "target_receipt_refs" => [],
      "attribution_refs" => []
    })
  end

  @spec tool_continuation_output(ToolStep.t()) :: {:ok, map()} | {:error, term()}
  def tool_continuation_output(%ToolStep{id: step_id}) do
    step = Repo.get!(ToolStep, step_id)

    if step.status in ~w(succeeded failed refused cancelled unavailable interrupted) and
         is_binary(step.outcome_digest) do
      {:ok,
       %{
         "schema" => "sarah.tool_continuation.v1",
         "call_id" => step.provider_call_id,
         "outcome_digest" => step.outcome_digest,
         "output" => %{
           "status" => step.status,
           "result" => step.result,
           "error" => step.error,
           "executor" => %{
             "id" => step.executor_id,
             "disclosure" => step.executor_disclosure
           },
           "target_receipt_refs" => step.target_receipt_refs,
           "attribution_refs" => step.attribution_refs
         }
       }}
    else
      {:error, :tool_step_not_terminal}
    end
  end

  @spec subscribe(Conversation.t()) :: :ok | {:error, term()}
  def subscribe(%Conversation{id: conversation_id}) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "voice:#{conversation_id}")
  end

  @doc """
  Broadcasts an in-progress transcript projection so the UI can show speech as
  it arrives. Live transcripts are ephemeral and never persisted; the durable
  transcript message replaces them when the final event is recorded.
  """
  @spec broadcast_live_transcript(Session.t(), String.t(), String.t(), String.t()) :: :ok
  def broadcast_live_transcript(%Session{} = session, item_id, role, content)
      when is_binary(item_id) and role in ["user", "assistant"] and is_binary(content) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "voice:#{session.conversation_id}",
      {:voice_live_transcript,
       %{
         voice_session_id: session.id,
         conversation_id: session.conversation_id,
         item_id: item_id,
         role: role,
         content: content
       }}
    )
  end

  defp active_session_query(conversation_id) do
    from(session in Session,
      where: session.conversation_id == ^conversation_id and session.status in ^@active_statuses,
      order_by: [desc: session.generation],
      limit: 1
    )
  end

  defp voice_artifact_id(voice), do: "sarah.voice.openai.#{voice}.v1"

  defp duplicate_event(_session, %ProviderEvent{provider_event_id: nil}), do: nil

  defp duplicate_event(session, provider_event) do
    Repo.get_by(PersistedEvent,
      voice_session_id: session.id,
      generation: session.generation,
      provider_event_id: provider_event.provider_event_id
    )
  end

  # The durable event ledger stays digest-only by choice: the durable
  # `voice_tool_steps` row is the raw arguments' home (issue #72).
  defp durable_event_payload(%ProviderEvent{
         kind: :tool_call_requested,
         payload: payload
       }) do
    argument_digest =
      case tool_argument_digest(payload["raw_arguments"]) do
        {:ok, digest} -> digest
        {:error, _reason} -> Canonical.sha256("")
      end

    payload
    |> Map.take(["response_id", "item_id", "call_id", "tool_name"])
    |> Map.put("argument_digest", argument_digest)
  end

  defp durable_event_payload(%ProviderEvent{payload: payload}), do: payload

  defp lifecycle_attributes(session, provider_event, observed_at) do
    base = %{status: next_status(session.status, provider_event.kind)}

    base
    |> maybe_mark_connected(provider_event.kind, observed_at)
    |> maybe_mark_failed(provider_event, observed_at)
    |> maybe_add_usage(session, provider_event)
  end

  defp next_status(_status, :session_ready), do: "listening"

  defp next_status(_status, :sideband_connected), do: "listening"

  defp next_status(_status, :sideband_disconnected), do: "reconnecting"
  defp next_status("responding", :speech_started), do: "interrupted"
  defp next_status("interrupted", :speech_started), do: "interrupted"
  defp next_status(_status, :speech_stopped), do: "responding"
  defp next_status(_status, :response_started), do: "responding"
  defp next_status("responding", :response_cancelled), do: "interrupted"
  defp next_status(_status, :response_completed), do: "listening"
  defp next_status(_status, :provider_error), do: "failed"
  defp next_status(status, _kind), do: status

  defp maybe_mark_connected(attributes, :session_ready, observed_at),
    do: Map.put_new(attributes, :connected_at, observed_at)

  defp maybe_mark_connected(attributes, :sideband_connected, observed_at),
    do: Map.put_new(attributes, :connected_at, observed_at)

  defp maybe_mark_connected(attributes, _kind, _observed_at), do: attributes

  defp maybe_mark_failed(attributes, %ProviderEvent{kind: :provider_error, payload: payload}, now) do
    attributes
    |> Map.put(:ended_at, now)
    |> Map.put(:termination_reason, "provider_error")
    |> Map.put(:failure_code, payload["code"] || "provider_error")
  end

  defp maybe_mark_failed(attributes, _event, _now), do: attributes

  defp maybe_add_usage(attributes, session, %ProviderEvent{
         kind: :response_completed,
         payload: %{"usage" => usage, "response_id" => response_id}
       })
       when is_map(usage) do
    if response_completion_recorded?(session, response_id) do
      attributes
    else
      priced_usage = Usage.price(usage, session.model_id)
      Map.put(attributes, :usage, Usage.merge(session.usage, priced_usage))
    end
  end

  defp maybe_add_usage(attributes, _session, _event), do: attributes

  defp response_completion_recorded?(session, response_id) when is_binary(response_id) do
    Repo.exists?(
      from(event in PersistedEvent,
        where:
          event.voice_session_id == ^session.id and event.generation == ^session.generation and
            event.kind == "response_completed" and
            fragment("? ->> 'response_id' = ?", event.payload, ^response_id)
      )
    )
  end

  defp response_completion_recorded?(_session, _response_id), do: false

  defp persist_transcript(session, %ProviderEvent{kind: kind, payload: payload}, observed_at)
       when kind in [:user_transcript_final, :assistant_transcript_final] do
    role = if kind == :user_transcript_final, do: "user", else: "assistant"
    transcript_status = transcript_status(session, kind, payload)

    message =
      %Message{}
      |> Message.changeset(%{
        conversation_id: session.conversation_id,
        role: role,
        content: payload["content"],
        status: message_status(kind, transcript_status),
        provider_response_id: payload["response_id"],
        modality: "voice",
        voice_session_id: session.id,
        provider_item_id: payload["item_id"],
        transcript_kind: transcript_kind(kind),
        interrupted: transcript_status == "interrupted"
      })
      |> insert_or_rollback()

    changeset =
      TranscriptItem.create_changeset(%TranscriptItem{}, %{
        voice_session_id: session.id,
        message_id: message.id,
        generation: session.generation,
        provider_item_id: payload["item_id"],
        provider_response_id: payload["response_id"],
        role: role,
        content: payload["content"],
        status: transcript_status,
        observed_at: observed_at
      })

    case Repo.insert(changeset) do
      {:ok, _item} ->
        maybe_attach_assistant_message(session, kind, payload, message)

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp persist_transcript(_session, _event, _observed_at), do: :ok

  defp transcript_status(_session, :user_transcript_final, _payload), do: "final"

  defp transcript_status(session, :assistant_transcript_final, payload) do
    case response_receipt_or_rollback(session, payload["response_id"]) do
      %ResponseReceipt{status: "responding"} -> "final"
      %ResponseReceipt{status: "interrupted"} -> "interrupted"
      %ResponseReceipt{} -> Repo.rollback(:voice_transcript_out_of_order)
    end
  end

  defp message_status(:user_transcript_final, _transcript_status), do: "complete"
  defp message_status(:assistant_transcript_final, "final"), do: "streaming"
  defp message_status(:assistant_transcript_final, "interrupted"), do: "cancelled"

  defp transcript_kind(:user_transcript_final), do: "provider_input_transcription"
  defp transcript_kind(:assistant_transcript_final), do: "provider_output_transcript"

  defp maybe_attach_assistant_message(_session, :user_transcript_final, _payload, _message),
    do: :ok

  defp maybe_attach_assistant_message(session, :assistant_transcript_final, payload, message) do
    receipt = response_receipt_or_rollback(session, payload["response_id"])
    message_id = message.id

    case receipt.assistant_message_id do
      nil ->
        receipt
        |> ResponseReceipt.assistant_message_changeset(message.id)
        |> update_or_rollback()

        :ok

      ^message_id ->
        :ok

      _earlier_response_item ->
        :ok
    end
  end

  defp persist_response_receipt(
         session,
         %ProviderEvent{kind: :response_started, payload: %{"response_id" => response_id}},
         event,
         response_context,
         inherited_tool_steps
       ) do
    receipt =
      case Repo.get_by(ResponseReceipt,
             voice_session_id: session.id,
             generation: session.generation,
             provider_response_id: response_id
           ) do
        nil ->
          %ResponseReceipt{}
          |> ResponseReceipt.create_changeset(%{
            voice_session_id: session.id,
            response_context_id: response_context_id(response_context),
            generation: session.generation,
            provider_response_id: response_id,
            status: "responding",
            started_event_sequence: event.sequence,
            usage: %{}
          })
          |> insert_or_rollback()

        %ResponseReceipt{} = receipt ->
          if receipt.response_context_id == response_context_id(response_context),
            do: receipt,
            else: Repo.rollback(:voice_response_context_conflict)
      end

    inherit_tool_evidence(session, receipt, inherited_tool_steps)
  end

  defp persist_response_receipt(
         session,
         %ProviderEvent{
           kind: :response_completed,
           payload: %{"response_id" => response_id} = payload
         },
         event,
         _response_context,
         _inherited_tool_steps
       ) do
    receipt = response_receipt_or_rollback(session, response_id)

    usage =
      if is_map(payload["usage"]),
        do: Usage.price(payload["usage"], session.model_id),
        else: %{}

    case receipt.status do
      "responding" ->
        receipt
        |> ResponseReceipt.terminal_changeset(%{
          status: response_terminal_status(payload["status"]),
          terminal_event_sequence: event.sequence,
          usage: usage,
          assistant_message_id: receipt.assistant_message_id
        })
        |> update_or_rollback()
        |> finalize_response_message()

      _terminal_status ->
        receipt
        |> ResponseReceipt.usage_changeset(usage)
        |> update_or_rollback()
    end

    :ok
  end

  defp persist_response_receipt(
         session,
         %ProviderEvent{kind: kind},
         event,
         _response_context,
         _inherited_tool_steps
       )
       when kind in [:speech_started, :response_cancelled] do
    interrupt_current_response(session, event.sequence)
  end

  defp persist_response_receipt(
         session,
         %ProviderEvent{kind: :provider_error},
         event,
         _response_context,
         _inherited_tool_steps
       ) do
    terminate_current_response(session, event.sequence, "failed")
    terminate_active_tool_steps(session, "failed", "provider_error")
  end

  defp persist_response_receipt(
         _session,
         _provider_event,
         _persisted_event,
         _response_context,
         _inherited_tool_steps
       ),
       do: :ok

  defp interrupt_current_response(session, event_sequence) do
    terminate_current_response(session, event_sequence, "interrupted")
  end

  defp terminate_current_response(session, event_sequence, status) do
    case current_response_receipt(session) do
      nil ->
        :ok

      receipt ->
        updated_receipt =
          receipt
          |> ResponseReceipt.terminal_changeset(%{
            status: status,
            terminal_event_sequence: event_sequence,
            usage: receipt.usage,
            assistant_message_id: receipt.assistant_message_id
          })
          |> update_or_rollback()

        finalize_response_message(updated_receipt)

        :ok
    end
  end

  defp current_response_receipt(session) do
    Repo.one(
      from(receipt in ResponseReceipt,
        where:
          receipt.voice_session_id == ^session.id and
            receipt.generation == ^session.generation and receipt.status == "responding",
        order_by: [desc: receipt.started_event_sequence],
        limit: 1
      )
    )
  end

  defp response_receipt_or_rollback(session, response_id) do
    case Repo.get_by(ResponseReceipt,
           voice_session_id: session.id,
           generation: session.generation,
           provider_response_id: response_id
         ) do
      nil -> Repo.rollback(:voice_response_not_started)
      receipt -> receipt
    end
  end

  defp response_terminal_status("completed"), do: "completed"
  defp response_terminal_status("cancelled"), do: "interrupted"
  defp response_terminal_status("canceled"), do: "interrupted"
  defp response_terminal_status(_status), do: "failed"

  defp response_context_id(%ResponseContext{id: id}), do: id
  defp response_context_id(_response_context), do: nil

  defp finalize_response_message(%ResponseReceipt{assistant_message_id: nil} = receipt),
    do: receipt

  defp finalize_response_message(%ResponseReceipt{} = receipt) do
    {message_status, interrupted?} =
      if receipt.status == "completed", do: {"complete", false}, else: {"cancelled", true}

    response_message_ids =
      Repo.all(
        from(message in Message,
          where:
            message.voice_session_id == ^receipt.voice_session_id and
              message.provider_response_id == ^receipt.provider_response_id and
              message.role == "assistant",
          select: message.id
        )
      )

    Enum.each(response_message_ids, fn message_id ->
      message = Repo.get_for_update!(Message, message_id)

      _updated_message =
        message
        |> Message.changeset(%{status: message_status, interrupted: interrupted?})
        |> update_or_rollback()
    end)

    if interrupted? do
      from(item in TranscriptItem,
        where:
          item.voice_session_id == ^receipt.voice_session_id and
            item.generation == ^receipt.generation and
            item.provider_response_id == ^receipt.provider_response_id and
            item.role == "assistant"
      )
      |> Repo.update_all(set: [status: "interrupted", updated_at: DateTime.utc_now()])
    end

    receipt
  end

  defp broadcast_message_projection(
         session,
         %ProviderEvent{kind: kind, payload: %{"item_id" => item_id}}
       )
       when kind in [:user_transcript_final, :assistant_transcript_final] do
    role = if kind == :user_transcript_final, do: "user", else: "assistant"

    case Repo.get_by(Message,
           voice_session_id: session.id,
           provider_item_id: item_id,
           role: role
         ) do
      nil -> :ok
      message -> OpenAgents.Conversations.notify_message_updated(message)
    end
  end

  defp broadcast_message_projection(
         session,
         %ProviderEvent{payload: %{"response_id" => response_id}}
       ) do
    case Repo.get_by(ResponseReceipt,
           voice_session_id: session.id,
           generation: session.generation,
           provider_response_id: response_id
         ) do
      %ResponseReceipt{assistant_message_id: message_id} when is_binary(message_id) ->
        session
        |> message_for_session(message_id)
        |> maybe_notify_message()

      _missing ->
        :ok
    end
  end

  defp broadcast_message_projection(session, %ProviderEvent{
         kind: kind
       })
       when kind in [:speech_started, :response_cancelled, :provider_error] do
    case current_or_latest_response_receipt(session) do
      %ResponseReceipt{assistant_message_id: message_id} when is_binary(message_id) ->
        session
        |> message_for_session(message_id)
        |> maybe_notify_message()

      _missing ->
        :ok
    end
  end

  defp broadcast_message_projection(_session, _event), do: :ok

  defp current_or_latest_response_receipt(session) do
    Repo.one(
      from(receipt in ResponseReceipt,
        where:
          receipt.voice_session_id == ^session.id and receipt.generation == ^session.generation,
        order_by: [desc: receipt.started_event_sequence],
        limit: 1
      )
    )
  end

  defp message_for_session(session, message_id) do
    Repo.get_by(Message, id: message_id, voice_session_id: session.id)
  end

  defp maybe_notify_message(nil), do: :ok

  defp maybe_notify_message(message) do
    OpenAgents.Conversations.notify_message_updated(message)
  end

  defp terminal_transition(session, generation, status, reason, failure_code) do
    Repo.transaction(fn ->
      locked_session = Repo.get_for_update!(Session, session.id)

      with :ok <- require_generation(locked_session, generation) do
        if locked_session.status in @terminal_statuses do
          locked_session
        else
          {tool_status, tool_code} =
            if status == "ended", do: {"cancelled", reason}, else: {"failed", failure_code}

          terminate_active_tool_steps(locked_session, tool_status, tool_code)

          locked_session
          |> Session.lifecycle_changeset(%{
            status: status,
            ended_at: DateTime.utc_now(),
            termination_reason: reason,
            failure_code: failure_code
          })
          |> update_or_rollback()
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, updated_session} ->
        broadcast(updated_session)
        :ok = OperationalTelemetry.emit(:session_terminal, updated_session)
        {:ok, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_generation(%Session{generation: generation}, generation), do: :ok
  defp require_generation(%Session{}, _generation), do: {:error, :stale_voice_generation}

  defp require_active(%Session{status: status}) when status in @active_statuses, do: :ok
  defp require_active(%Session{}), do: {:error, :voice_session_terminal}

  defp require_event_state(%Session{status: "responding"}, %ProviderEvent{
         kind: :response_cancelled
       }),
       do: :ok

  defp require_event_state(%Session{}, %ProviderEvent{kind: :response_cancelled}),
    do: {:error, :voice_not_responding}

  defp require_event_state(%Session{}, %ProviderEvent{}), do: :ok

  defp enforce_attempt_rate!(conversation_id) do
    limit = Application.fetch_env!(:openagents, :voice_attempt_limit)
    window_seconds = Application.fetch_env!(:openagents, :voice_attempt_window_seconds)
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    count =
      Repo.aggregate(
        from(session in Session,
          where: session.conversation_id == ^conversation_id and session.started_at >= ^cutoff
        ),
        :count
      )

    if count >= limit, do: Repo.rollback(:voice_rate_limited)
    :ok
  end

  defp enforce_concurrent_session_limit! do
    limit = Application.fetch_env!(:openagents, :voice_maximum_concurrent_sessions)

    count =
      Repo.aggregate(
        from(session in Session, where: session.status in ^@active_statuses),
        :count
      )

    if count >= limit, do: Repo.rollback(:voice_capacity_reached)
    :ok
  end

  defp normalize_failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp normalize_failure_code(reason) when is_binary(reason) do
    reason
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
    |> String.slice(0, 128)
  end

  defp normalize_failure_code(_reason), do: "runtime_failure"

  defp terminate_active_tool_steps(session, status, code) do
    Repo.all(
      from(step in ToolStep,
        where:
          step.voice_session_id == ^session.id and step.generation == ^session.generation and
            step.status in ["requested", "running"]
      )
    )
    |> Enum.each(fn step -> terminate_tool_step(step, status, code, DateTime.utc_now()) end)

    :ok
  end

  defp terminate_tool_step(step, status, code, now) do
    outcome = %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version
      },
      "executor_ref" => %{"id" => "sarah.host", "disclosure" => "Sarah voice lifecycle"},
      "status" => status,
      "result" => nil,
      "error" => %{
        "code" => normalize_failure_code(code || "voice_session_ended"),
        "message" => "The voice lifecycle ended this tool call."
      },
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => DateTime.to_iso8601(step.started_at || now),
      "completed_at" => DateTime.to_iso8601(now)
    }

    step
    |> ToolStep.terminal_changeset(%{
      status: status,
      outcome_digest: Canonical.digest!(outcome),
      result: nil,
      error: outcome["error"],
      executor_id: "sarah.host",
      executor_disclosure: "Sarah voice lifecycle",
      target_receipt_refs: [],
      attribution_refs: [],
      completed_at: now
    })
    |> update_or_rollback()
  end

  defp verify_tool_catalog(session, %{digest: digest}) do
    if session.tool_catalog_digest == digest,
      do: :ok,
      else: {:error, :voice_tool_catalog_changed}
  end

  defp verify_tool_catalog(_session, _snapshot), do: {:error, :invalid_tool_catalog}

  defp tool_identity(%{tools: tools}, name) do
    case Map.fetch(tools, name) do
      {:ok, tool} -> {tool.module_id, tool.version}
      :error -> {"sarah.host", 1}
    end
  end

  defp validate_raw_tool_arguments(arguments)
       when is_binary(arguments) and byte_size(arguments) <= 16_384,
       do: :ok

  defp validate_raw_tool_arguments(_arguments), do: {:error, :invalid_tool_arguments}

  defp tool_argument_digest(raw_arguments) do
    case Jason.decode(raw_arguments) do
      {:ok, decoded} ->
        Canonical.digest(decoded)

      {:error, _decode_error} ->
        Canonical.digest(%{"invalid_json_sha256" => Canonical.sha256(raw_arguments)})
    end
  end

  defp same_voice_tool_identity?(step, identity) do
    Enum.all?(
      [
        :voice_session_id,
        :voice_response_receipt_id,
        :generation,
        :provider_call_id,
        :provider_item_id,
        :provider_response_id,
        :tool_name,
        :tool_version,
        :module_id,
        :catalog_digest,
        :argument_digest
      ],
      &(Map.get(step, &1) == Map.get(identity, &1))
    )
  end

  defp validate_tool_outcome(step, outcome) do
    statuses = ~w(succeeded failed refused cancelled unavailable)

    cond do
      outcome["call_id"] != step.provider_call_id ->
        {:error, :tool_outcome_call_id_mismatch}

      get_in(outcome, ["module_ref", "module_id"]) != step.module_id ->
        {:error, :tool_outcome_module_mismatch}

      get_in(outcome, ["module_ref", "tool_name"]) != step.tool_name ->
        {:error, :tool_outcome_name_mismatch}

      get_in(outcome, ["module_ref", "version"]) != step.tool_version ->
        {:error, :tool_outcome_version_mismatch}

      outcome["status"] not in statuses ->
        {:error, :invalid_tool_outcome_status}

      not is_list(outcome["target_receipt_refs"]) or
          not is_list(outcome["attribution_refs"]) ->
        {:error, :invalid_tool_outcome_references}

      true ->
        :ok
    end
  end

  defp inherit_tool_evidence(_session, _receipt, []), do: :ok

  defp inherit_tool_evidence(session, receipt, steps) when is_list(steps) do
    Enum.reduce(steps, receipt, fn
      %ToolStep{id: step_id}, current_receipt ->
        step = Repo.get_for_update!(ToolStep, step_id)

        if step.voice_session_id == session.id and step.generation == session.generation and
             step.status in ~w(succeeded failed refused cancelled unavailable interrupted) do
          merge_voice_receipt_step(current_receipt, step)
        else
          Repo.rollback(:invalid_inherited_voice_tool_step)
        end

      _invalid_step, _current_receipt ->
        Repo.rollback(:invalid_inherited_voice_tool_step)
    end)

    :ok
  end

  defp inherit_tool_evidence(_session, _receipt, _steps),
    do: Repo.rollback(:invalid_inherited_voice_tool_steps)

  defp update_voice_receipt_evidence(step) do
    receipt = Repo.get_for_update!(ResponseReceipt, step.voice_response_receipt_id)

    merge_voice_receipt_step(receipt, step)
  end

  defp merge_voice_receipt_step(receipt, step) do
    source_refs = merge_refs(receipt.used_source_refs, step.target_receipt_refs)
    tool_step_refs = merge_refs(receipt.used_tool_step_refs, ["voice-tool-step:#{step.id}"])
    existing_evidence = receipt.used_memory_evidence["items"]

    memory_evidence =
      step.result
      |> memory_evidence_usage()
      |> Enum.filter(&(&1["source_ref"] in source_refs))

    ledger = %{
      "schema" => "sarah.memory_evidence_usage.v1",
      "items" =>
        (existing_evidence ++ memory_evidence)
        |> Enum.uniq_by(&{&1["source_ref"], &1["classification"]})
    }

    receipt
    |> ResponseReceipt.evidence_changeset(%{
      used_source_refs: source_refs,
      used_tool_step_refs: tool_step_refs,
      used_memory_evidence: ledger
    })
    |> update_or_rollback()
  end

  defp memory_evidence_usage(%{"evidence" => evidence}) when is_map(evidence) do
    case evidence do
      %{"source_ref" => source_ref, "classification" => classification} ->
        [%{"source_ref" => source_ref, "classification" => classification}]

      _invalid ->
        []
    end
  end

  defp memory_evidence_usage(_result), do: []

  defp merge_refs(existing, additions) do
    (existing ++ additions)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp broadcast_tool_activity(session, step) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "voice:#{session.conversation_id}",
      {:voice_tool_activity_updated, session.id, step.id}
    )
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp broadcast(session) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "voice:#{session.conversation_id}",
      {:voice_session_updated, session}
    )
  end
end
