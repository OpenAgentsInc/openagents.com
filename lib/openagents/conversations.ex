defmodule OpenAgents.Conversations do
  @moduledoc """
  Durable account conversations and their turn lifecycle.

  PostgreSQL is authoritative. PubSub events are projections used to keep every
  connected view of the same account-scoped conversation current. The binary
  browser-key entry point remains only for isolated legacy rows and domain
  fixtures; web authority always enters through `OpenAgents.Accounts.User`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts.User

  alias OpenAgents.Conversations.{
    Conversation,
    Message,
    ProviderStep,
    ToolStep,
    Turn,
    TurnReceipt,
    Visitor
  }

  alias OpenAgents.Context
  alias OpenAgents.Memory.LexicalRecall
  alias OpenAgents.Persona
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.ProgramArtifacts.{Reader, Snapshot}
  alias OpenAgents.Providers.Request
  alias OpenAgents.Repo

  @active_statuses ~w(queued streaming)

  def ensure_conversation(%User{id: user_id}) do
    Repo.transaction(fn ->
      visitor = ensure_user_visitor(user_id)
      ensure_conversation_with_greeting(visitor)
    end)
  end

  @doc false
  def ensure_conversation(browser_key) when is_binary(browser_key) do
    Repo.transaction(fn ->
      visitor = ensure_visitor(:crypto.hash(:sha256, browser_key))
      ensure_conversation_with_greeting(visitor)
    end)
  end

  @doc """
  The account's owner visitor, created if absent, without creating a
  conversation.

  The visitor is the account's storage root: conversations, profile memory,
  inference grants, and now threads all hang off it, and DATA-004 cascades
  from it. A thread needs that root and nothing else, so this is the entry
  point that lets an account own work without owning a second conversation.
  """
  @spec ensure_owner_visitor(User.t()) :: Visitor.t()
  def ensure_owner_visitor(%User{id: user_id}), do: ensure_user_visitor(user_id)

  @doc """
  Whether this account has ever sent a message to the agent.

  Asks for a message the *person* wrote. Every conversation is created with an
  assistant greeting already in it, so "has any message" is true for an account
  that has never opened chat, and would grandfather everyone.

  Existence only, and bounded by `limit: 1`: this runs on every page render to
  decide whether the sidebar shows the agent's surfaces at all.
  """
  @spec user_has_messages?(User.t() | nil) :: boolean()
  def user_has_messages?(nil), do: false

  def user_has_messages?(%User{id: user_id}) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      join: v in assoc(c, :visitor),
      where: v.user_id == ^user_id and m.role == "user",
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> is_integer()
  end

  def get_conversation_for_user(%User{id: user_id}) do
    from(c in Conversation,
      join: v in assoc(c, :visitor),
      where: v.user_id == ^user_id
    )
    |> Repo.one()
  end

  @doc "Gets a conversation owned by the account, returning nil for other accounts or invalid IDs."
  @spec get_conversation_for_user(User.t(), String.t()) :: Conversation.t() | nil
  def get_conversation_for_user(%User{id: user_id}, conversation_id)
      when is_binary(conversation_id) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id) do
      from(c in Conversation,
        join: v in assoc(c, :visitor),
        where: c.id == ^conversation_id and v.user_id == ^user_id
      )
      |> Repo.one()
    else
      :error -> nil
    end
  end

  @doc false
  def get_conversation_for_browser(browser_key) when is_binary(browser_key) do
    browser_key_hash = :crypto.hash(:sha256, browser_key)

    from(c in Conversation,
      join: v in assoc(c, :visitor),
      where: v.browser_key_hash == ^browser_key_hash
    )
    |> Repo.one()
  end

  def get_conversation_owner!(%Conversation{visitor_id: visitor_id}),
    do: Repo.get!(Visitor, visitor_id)

  def list_messages(%Conversation{} = conversation, before_id \\ nil) do
    page_size = Application.fetch_env!(:openagents, :conversation_page_size)

    query =
      from(m in Message,
        where: m.conversation_id == ^conversation.id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^(page_size + 1)
      )
      |> before_message(conversation.id, before_id)

    results = Repo.all(query)
    has_older? = length(results) > page_size

    messages =
      results
      |> Enum.take(page_size)
      |> Enum.reverse()

    {messages, has_older?}
  end

  def active_turn(%Conversation{} = conversation) do
    Repo.one(
      from(t in Turn,
        where: t.conversation_id == ^conversation.id and t.status in ^@active_statuses,
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end

  def create_turn(%Conversation{} = conversation, raw_content) when is_binary(raw_content) do
    content = String.trim(raw_content)

    with :ok <- validate_content(content),
         :ok <- enforce_rate_limit(conversation.id) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.insert(
        :user_message,
        Message.changeset(%Message{}, %{
          conversation_id: conversation.id,
          role: "user",
          content: content,
          status: "complete"
        })
      )
      |> Multi.insert(
        :assistant_message,
        Message.changeset(%Message{}, %{
          conversation_id: conversation.id,
          role: "assistant",
          content: "",
          status: "streaming"
        })
      )
      |> Multi.insert(:turn, fn %{
                                  user_message: user_message,
                                  assistant_message: assistant_message
                                } ->
        Turn.changeset(%Turn{}, %{
          conversation_id: conversation.id,
          user_message_id: user_message.id,
          assistant_message_id: assistant_message.id,
          status: "queued",
          started_at: now
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, records} -> {:ok, records}
        {:error, :turn, changeset, _changes} -> normalize_turn_error(changeset)
        {:error, _operation, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Persists a complete typed user message without opening a text turn, so a
  live voice session keeps owning the conversation's response chronology.
  """
  def create_voice_context_message(%Conversation{} = conversation, raw_content)
      when is_binary(raw_content) do
    content = String.trim(raw_content)

    with :ok <- validate_content(content),
         :ok <- enforce_message_rate_limit(conversation.id) do
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "user",
        content: content,
        status: "complete"
      })
      |> Repo.insert()
      |> case do
        {:ok, message} ->
          broadcast(conversation.id, {:message_updated, message})
          {:ok, message}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def provider_messages(conversation_id) do
    from(m in Message,
      where:
        m.conversation_id == ^conversation_id and m.role in ["user", "assistant"] and
          m.status == "complete",
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 32,
      select: %{role: m.role, content: m.content}
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  def begin_inference(
        %Turn{} = turn,
        %Context{} = context,
        %Request{} = request,
        provider_id,
        options \\ []
      )
      when is_binary(provider_id) and is_list(options) do
    tool_catalog_digest = Keyword.get(options, :tool_catalog_digest)
    profile_memory_snapshot_ref = Keyword.get(options, :profile_memory_snapshot_ref)
    preference_snapshot_ref = Keyword.get(options, :preference_snapshot_ref)

    preference_usage =
      Keyword.get(options, :preference_usage, %{
        "schema" => "sarah.preference_usage.v1",
        "applied" => [],
        "overridden" => []
      })

    experience_bank_ref = Keyword.get(options, :experience_bank_ref)

    experience_usage =
      Keyword.get(options, :experience_usage, %{
        "schema" => "sarah.experience_usage.v1",
        "record_refs" => [],
        "pattern_refs" => [],
        "bank_digest" => nil
      })

    program_snapshot =
      Keyword.get_lazy(options, :program_snapshot, fn ->
        OpenAgents.ProgramLifecycle.capture("sarah.memory.intent.v1")
      end)

    with :ok <- validate_inference_capture(context, request, provider_id),
         :ok <- validate_optional_digest(tool_catalog_digest),
         :ok <- validate_optional_reference(profile_memory_snapshot_ref),
         :ok <- validate_optional_preference_reference(preference_snapshot_ref),
         :ok <-
           OpenAgents.Preferences.validate_turn_capture(
             turn,
             preference_snapshot_ref,
             preference_usage
           ),
         :ok <- validate_preference_context(context, preference_usage),
         :ok <-
           OpenAgents.ExperienceMemory.validate_turn_capture(
             turn,
             experience_bank_ref,
             experience_usage
           ),
         :ok <- validate_experience_context(context, experience_usage),
         :ok <- validate_program_snapshot(program_snapshot),
         {:ok, canonical_input} <- Canonical.encode(request.input) do
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.run(:locked_turn, fn repo, _changes ->
        locked_turn = repo.get_for_update!(Turn, turn.id)

        if locked_turn.status == "queued",
          do: {:ok, locked_turn},
          else: {:error, :turn_not_queued}
      end)
      |> Multi.update(:turn, fn %{locked_turn: locked_turn} ->
        Turn.changeset(locked_turn, %{status: "streaming"})
      end)
      |> Multi.run(:memory_snapshot_ref, fn repo, %{locked_turn: locked_turn} ->
        LexicalRecall.capture_ref(
          repo,
          locked_turn.conversation_id,
          locked_turn.user_message_id
        )
      end)
      |> Multi.insert(:receipt, fn %{
                                     locked_turn: locked_turn,
                                     memory_snapshot_ref: memory_snapshot_ref
                                   } ->
        TurnReceipt.create_changeset(%TurnReceipt{}, %{
          turn_id: locked_turn.id,
          schema_version: 1,
          status: "captured",
          model_id: request.model_id,
          persona_id: context.persona_id,
          persona_digest: context.persona_digest,
          role_id: context.role_id,
          role_digest: context.role_digest,
          role_selection: context.role_selection,
          instruction_digest: context.instruction_digest,
          input_digest: Canonical.sha256(canonical_input),
          input_message_count: length(request.input),
          input_bytes: byte_size(canonical_input),
          tool_catalog_digest: tool_catalog_digest,
          blueprint_revision: context.blueprint_revision,
          blueprint_digest: context.blueprint_digest,
          program_artifact_id: program_artifact_id(program_snapshot),
          program_artifact_digest: program_artifact_digest(program_snapshot),
          program_artifact_receipt: program_snapshot.receipt,
          memory_snapshot_ref: memory_snapshot_ref,
          profile_memory_snapshot_ref: profile_memory_snapshot_ref,
          preference_snapshot_ref: preference_snapshot_ref,
          used_preferences: preference_usage,
          experience_bank_ref: experience_bank_ref,
          used_experiences: experience_usage,
          used_source_refs: [],
          used_tool_step_refs: [],
          provider_started_at: now
        })
      end)
      |> Multi.insert(:provider_step, fn %{receipt: receipt} ->
        ProviderStep.create_changeset(%ProviderStep{}, %{
          turn_receipt_id: receipt.id,
          sequence: 1,
          provider_id: provider_id,
          model_id: request.model_id,
          status: "started",
          started_at: now
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{turn: updated_turn} = records} ->
          broadcast(updated_turn.conversation_id, {:turn_updated, updated_turn})
          {:ok, records}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def get_turn_receipt(%Turn{id: turn_id}) do
    case Repo.get_by(TurnReceipt, turn_id: turn_id) do
      nil -> {:error, :legacy_turn_without_receipt}
      receipt -> {:ok, receipt}
    end
  end

  def list_provider_steps(%TurnReceipt{id: receipt_id}) do
    Repo.all(
      from(step in ProviderStep,
        where: step.turn_receipt_id == ^receipt_id,
        order_by: [asc: step.sequence]
      )
    )
  end

  def start_provider_step(%TurnReceipt{} = receipt, provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    Repo.transaction(fn ->
      locked_receipt = Repo.get_for_update!(TurnReceipt, receipt.id)

      if locked_receipt.status != "captured" do
        Repo.rollback(:turn_receipt_is_terminal)
      end

      active_step_count =
        Repo.aggregate(
          from(step in ProviderStep,
            where: step.turn_receipt_id == ^receipt.id and step.status == "started"
          ),
          :count
        )

      if active_step_count != 0 do
        Repo.rollback(:provider_step_in_progress)
      end

      sequence =
        Repo.aggregate(
          from(step in ProviderStep, where: step.turn_receipt_id == ^receipt.id),
          :max,
          :sequence
        ) || 0

      if sequence >= 32 do
        Repo.rollback(:provider_step_limit_reached)
      end

      %ProviderStep{}
      |> ProviderStep.create_changeset(%{
        turn_receipt_id: receipt.id,
        sequence: sequence + 1,
        provider_id: provider_id,
        model_id: model_id,
        status: "started",
        started_at: DateTime.utc_now()
      })
      |> insert_or_rollback()
    end)
  end

  def record_provider_step_completion(
        %TurnReceipt{} = receipt,
        provider_response_id,
        usage \\ nil
      )
      when is_binary(provider_response_id) do
    Repo.transaction(fn ->
      locked_receipt = Repo.get_for_update!(TurnReceipt, receipt.id)

      if locked_receipt.status != "captured" do
        Repo.rollback(:turn_receipt_is_terminal)
      end

      case latest_provider_step(receipt.id, "started") do
        nil ->
          Repo.rollback(:started_provider_step_missing)

        step ->
          step
          |> ProviderStep.lifecycle_changeset(%{
            status: "completed",
            provider_response_id: provider_response_id,
            usage: usage,
            completed_at: DateTime.utc_now()
          })
          |> update_or_rollback()
      end
    end)
  end

  def record_provider_response_started(%TurnReceipt{} = receipt, provider_response_id)
      when is_binary(provider_response_id) and provider_response_id != "" and
             byte_size(provider_response_id) <= 512 do
    Repo.transaction(fn ->
      locked_receipt = Repo.get_for_update!(TurnReceipt, receipt.id)

      if locked_receipt.status != "captured" do
        Repo.rollback(:turn_receipt_is_terminal)
      end

      case latest_provider_step(receipt.id, "started") do
        %ProviderStep{provider_response_id: nil} = step ->
          step
          |> ProviderStep.lifecycle_changeset(%{provider_response_id: provider_response_id})
          |> update_or_rollback()

        %ProviderStep{provider_response_id: ^provider_response_id} = step ->
          step

        %ProviderStep{} ->
          Repo.rollback(:provider_response_id_changed)

        nil ->
          Repo.rollback(:started_provider_step_missing)
      end
    end)
  end

  def record_provider_response_started(%TurnReceipt{}, _provider_response_id),
    do: {:error, :invalid_provider_response_id}

  def record_used_refs(%TurnReceipt{} = receipt, attributes) when is_list(attributes) do
    with {:ok, source_refs} <- normalize_refs(Keyword.get(attributes, :source_refs, [])),
         {:ok, tool_step_refs} <- normalize_refs(Keyword.get(attributes, :tool_step_refs, [])),
         {:ok, memory_evidence} <-
           OpenAgents.Memory.Evidence.normalize_usage_items(
             Keyword.get(attributes, :memory_evidence, [])
           ) do
      Repo.transaction(fn ->
        locked_receipt = Repo.get_for_update!(TurnReceipt, receipt.id)

        if locked_receipt.status != "captured" do
          Repo.rollback(:turn_receipt_is_terminal)
        end

        updated_source_refs = merge_refs(locked_receipt.used_source_refs, source_refs)
        updated_tool_step_refs = merge_refs(locked_receipt.used_tool_step_refs, tool_step_refs)
        existing_evidence = locked_receipt.used_memory_evidence["items"]

        if Enum.any?(memory_evidence, &(&1["source_ref"] not in updated_source_refs)) do
          Repo.rollback(:memory_evidence_source_not_used)
        end

        updated_evidence =
          (existing_evidence ++ memory_evidence)
          |> Enum.uniq_by(&{&1["source_ref"], &1["classification"]})

        evidence_ledger = %{
          "schema" => "sarah.memory_evidence_usage.v1",
          "items" => updated_evidence
        }

        locked_receipt
        |> TurnReceipt.lifecycle_changeset(%{
          used_source_refs: updated_source_refs,
          used_tool_step_refs: updated_tool_step_refs,
          used_memory_evidence: evidence_ledger
        })
        |> update_or_rollback()
      end)
    end
  end

  def request_tool_step(%Turn{} = turn, %TurnReceipt{} = receipt, attributes)
      when is_map(attributes) do
    raw_arguments = Map.get(attributes, :raw_arguments)

    with :ok <- validate_raw_tool_arguments(raw_arguments),
         {:ok, argument_digest} <- tool_argument_digest(raw_arguments) do
      result =
        Repo.transaction(fn ->
          locked_turn = Repo.get_for_update!(Turn, turn.id)
          locked_receipt = Repo.get_for_update!(TurnReceipt, receipt.id)

          if locked_turn.status != "streaming" or locked_receipt.status != "captured" or
               locked_receipt.turn_id != locked_turn.id do
            Repo.rollback(:turn_not_accepting_tool_steps)
          end

          identity = %{
            turn_id: locked_turn.id,
            turn_receipt_id: locked_receipt.id,
            provider_call_id: Map.get(attributes, :provider_call_id),
            provider_item_id: Map.get(attributes, :provider_item_id),
            provider_response_id: Map.get(attributes, :provider_response_id),
            tool_name: Map.get(attributes, :tool_name),
            tool_version: Map.get(attributes, :tool_version),
            module_id: Map.get(attributes, :module_id),
            module_artifact_digest: Map.get(attributes, :module_artifact_digest),
            executor_implementation_digest: Map.get(attributes, :executor_implementation_digest),
            routing_receipt_id: Map.get(attributes, :routing_receipt_id),
            side_effect_class: Map.get(attributes, :side_effect_class, "read_only"),
            attribution_policy_id: Map.get(attributes, :attribution_policy_id),
            attribution_policy_version: Map.get(attributes, :attribution_policy_version),
            attribution_policy_digest: Map.get(attributes, :attribution_policy_digest),
            cost_units: Map.get(attributes, :cost_units, 0),
            catalog_digest: locked_receipt.tool_catalog_digest,
            raw_arguments: raw_arguments,
            argument_digest: argument_digest
          }

          invocation_key =
            Canonical.digest!(%{
              "turn_id" => locked_turn.id,
              "provider_call_id" => identity.provider_call_id,
              "module_id" => identity.module_id,
              "module_version" => identity.tool_version,
              "module_artifact_digest" => identity.module_artifact_digest,
              "catalog_digest" => identity.catalog_digest
            })

          billable = identity.cost_units > 0

          identity =
            identity
            |> Map.put(:invocation_key, invocation_key)
            |> Map.put(:billable, billable)
            |> Map.put(
              :billable_attribution_key,
              if(billable,
                do:
                  Canonical.digest!(%{
                    "invocation_key" => invocation_key,
                    "attribution_policy_digest" => identity.attribution_policy_digest
                  }),
                else: nil
              )
            )

          case Repo.get_by(ToolStep,
                 turn_id: locked_turn.id,
                 provider_call_id: identity.provider_call_id
               ) do
            %ToolStep{} = existing_step ->
              if same_tool_step_identity?(existing_step, identity),
                do: {existing_step, :existing},
                else: Repo.rollback(:provider_call_id_conflict)

            nil ->
              sequence =
                Repo.aggregate(
                  from(step in ToolStep, where: step.turn_id == ^locked_turn.id),
                  :max,
                  :sequence
                ) || 0

              if sequence >= 32 do
                Repo.rollback(:tool_step_limit_reached)
              end

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
        end)

      case result do
        {:ok, {step, disposition}} ->
          broadcast_tool_activity(step)
          {:ok, step, disposition}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def start_tool_step(%ToolStep{} = step) do
    Repo.transaction(fn ->
      locked_step = Repo.get_for_update!(ToolStep, step.id)

      case locked_step.status do
        "requested" ->
          running_step =
            locked_step
            |> ToolStep.running_changeset(%{status: "running", started_at: DateTime.utc_now()})
            |> update_or_rollback()

          {running_step, :started}

        "running" ->
          {locked_step, :already_running}

        _terminal ->
          Repo.rollback(:tool_step_is_terminal)
      end
    end)
    |> case do
      {:ok, {running_step, disposition}} ->
        broadcast_tool_activity(running_step)
        {:ok, running_step, disposition}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete_tool_step(%ToolStep{} = step, %{"schema" => "sarah.tool_outcome.v1"} = outcome) do
    with :ok <- validate_tool_outcome(step, outcome),
         {:ok, outcome_digest} <- Canonical.digest(outcome) do
      result =
        Repo.transaction(fn ->
          locked_step = Repo.get_for_update!(ToolStep, step.id)

          if locked_step.status in ~w(requested running) do
            locked_step
            |> ToolStep.terminal_changeset(%{
              status: outcome["status"],
              outcome_digest: outcome_digest,
              outcome_receipt_ref: "module-outcome:v1:#{outcome_digest}",
              usage: Map.get(outcome, "usage", %{"invocations" => 1}),
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
        end)

      case result do
        {:ok, completed_step} ->
          broadcast_tool_activity(completed_step)
          {:ok, completed_step}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def complete_tool_step(%ToolStep{}, _outcome), do: {:error, :invalid_tool_outcome}

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
           "attribution_refs" => step.attribution_refs,
           "outcome_receipt_ref" => step.outcome_receipt_ref,
           "usage" => step.usage,
           "cost" => %{"units" => step.cost_units, "billable" => step.billable},
           "attribution_policy" => %{
             "id" => step.attribution_policy_id,
             "version" => step.attribution_policy_version,
             "digest" => step.attribution_policy_digest
           }
         }
       }}
    else
      {:error, :tool_step_not_terminal}
    end
  end

  @doc "Fetches one message by id, for refreshing a transcript row."
  def get_message(message_id), do: Repo.get(Message, message_id)

  @doc """
  Tool activity for a page of the transcript, keyed by the assistant message the
  turn produced.

  Activity used to be readable only for the turn currently running, which is why
  it vanished the moment a turn finished. Keying it by assistant message lets the
  transcript show what Sarah did alongside what she said, and lets a reload
  rebuild it from PostgreSQL rather than from a live subscription.

  Selects the same bounded projection as `list_tool_step_activity/1`, so
  INVARIANTS.md UI-002 holds: the durable already-scrubbed step values
  (arguments, bounded result/error, executor identity, timestamps) and never a
  provider identifier or private recall content.
  """
  def list_tool_step_activity_by_message(assistant_message_ids)

  def list_tool_step_activity_by_message([]), do: %{}

  def list_tool_step_activity_by_message(assistant_message_ids) do
    from(step in ToolStep,
      join: turn in Turn,
      on: turn.id == step.turn_id,
      where: turn.assistant_message_id in ^assistant_message_ids,
      order_by: [asc: step.sequence],
      select:
        {turn.assistant_message_id,
         %{
           id: step.id,
           sequence: step.sequence,
           tool_name: step.tool_name,
           module_id: step.module_id,
           module_version: step.tool_version,
           module_artifact_digest: step.module_artifact_digest,
           status: step.status,
           raw_arguments: step.raw_arguments,
           result: step.result,
           error: step.error,
           executor_id: step.executor_id,
           executor_disclosure: step.executor_disclosure,
           outcome_receipt_ref: step.outcome_receipt_ref,
           attribution_policy_id: step.attribution_policy_id,
           cost_units: step.cost_units,
           billable: step.billable,
           requested_at: step.requested_at,
           started_at: step.started_at,
           completed_at: step.completed_at
         }}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def list_tool_step_activity(%Turn{id: turn_id}) do
    Repo.all(
      from(step in ToolStep,
        where: step.turn_id == ^turn_id,
        order_by: [asc: step.sequence],
        select: %{
          id: step.id,
          sequence: step.sequence,
          tool_name: step.tool_name,
          module_id: step.module_id,
          module_version: step.tool_version,
          module_artifact_digest: step.module_artifact_digest,
          status: step.status,
          raw_arguments: step.raw_arguments,
          result: step.result,
          error: step.error,
          executor_id: step.executor_id,
          executor_disclosure: step.executor_disclosure,
          outcome_receipt_ref: step.outcome_receipt_ref,
          attribution_policy_id: step.attribution_policy_id,
          cost_units: step.cost_units,
          billable: step.billable,
          requested_at: step.requested_at,
          started_at: step.started_at,
          completed_at: step.completed_at
        }
      )
    )
  end

  @doc """
  Deep-work rollups for a page of the transcript, keyed by the report message
  the job produced.

  A `work_jobs` report message renders as a "Worked for <duration>" event
  header, so the transcript needs the job's terminal shape — status, duration,
  and step-outcome counts — as a read-only projection beside the message. Only
  bounded durable fields are selected; a job that has not completed carries no
  rollup and its report renders as an ordinary message.
  """
  def list_work_job_rollups_by_message(messages) when is_list(messages) do
    job_ids =
      messages
      |> Enum.filter(&(&1.role == "assistant" and is_binary(&1.work_job_id)))
      |> Enum.map(&{&1.work_job_id, &1.id})
      |> Map.new()

    case Map.keys(job_ids) do
      [] ->
        %{}

      ids ->
        step_counts =
          from(step in OpenAgents.Work.JobStep,
            where: step.work_job_id in ^ids,
            group_by: [step.work_job_id, step.status],
            select: {step.work_job_id, step.status, count(step.id)}
          )
          |> Repo.all()
          |> Enum.group_by(&elem(&1, 0), fn {_job_id, status, count} -> {status, count} end)
          |> Map.new(fn {job_id, pairs} -> {job_id, Map.new(pairs)} end)

        from(job in OpenAgents.Work.Job,
          where: job.id in ^ids and not is_nil(job.completed_at),
          select: %{
            id: job.id,
            status: job.status,
            error_code: job.error_code,
            tool_call_count: job.tool_call_count,
            started_at: job.started_at,
            completed_at: job.completed_at
          }
        )
        |> Repo.all()
        |> Map.new(fn job ->
          counts = Map.get(step_counts, job.id, %{})

          {Map.fetch!(job_ids, job.id),
           job
           |> Map.put(:succeeded_count, Map.get(counts, "succeeded", 0))
           |> Map.put(:refused_count, Map.get(counts, "refused", 0))}
        end)
    end
  end

  def append_assistant_delta(%Turn{} = turn, delta) when is_binary(delta) do
    maximum_bytes = Application.fetch_env!(:openagents, :maximum_message_bytes)

    result =
      Repo.transaction(fn ->
        message = Repo.get_for_update!(Message, turn.assistant_message_id)
        content = message.content <> delta

        if byte_size(content) > maximum_bytes do
          Repo.rollback(:assistant_message_limit_reached)
        end

        message
        |> Message.changeset(%{content: content})
        |> Repo.update!()
      end)

    case result do
      {:ok, message} ->
        broadcast(turn.conversation_id, {:message_updated, message})
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete_turn(%Turn{} = turn, provider_response_id \\ nil, usage \\ nil) do
    finish_turn(turn, "completed", "complete", provider_response_id, nil, usage, nil)
  end

  def fail_turn(%Turn{} = turn, reason, usage \\ nil) do
    finish_turn(turn, "failed", "failed", nil, public_error(reason), usage, error_code(reason))
  end

  def cancel_turn(%Turn{} = turn, usage \\ nil) do
    finish_turn(turn, "cancelled", "cancelled", nil, nil, usage, "cancelled")
  end

  def get_turn!(turn_id), do: Repo.get!(Turn, turn_id)

  def get_turn_owner!(%Turn{} = turn) do
    Repo.one!(
      from(visitor in Visitor,
        join: conversation in Conversation,
        on: conversation.visitor_id == visitor.id,
        where: conversation.id == ^turn.conversation_id
      )
    )
  end

  def subscribe(%Conversation{id: id}) do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, topic(id))
  end

  @doc false
  def notify_message_updated(%Message{} = message) do
    broadcast(message.conversation_id, {:message_updated, message})
  end

  def recover_interrupted_turns do
    now = DateTime.utc_now()

    turn_ids =
      from(t in Turn, where: t.status in ^@active_statuses, select: t.id)
      |> Repo.all()

    if turn_ids != [] do
      {:ok, :recovered} =
        Repo.transaction(fn ->
          receipt_ids =
            from(receipt in TurnReceipt,
              where: receipt.turn_id in ^turn_ids,
              select: receipt.id
            )

          from(step in ToolStep,
            where: step.turn_id in ^turn_ids and step.status in ["requested", "running"]
          )
          |> Repo.all()
          |> Enum.each(fn step ->
            outcome = lifecycle_tool_outcome(step, "interrupted", "runtime_restarted", now)

            step
            |> ToolStep.terminal_changeset(tool_step_terminal_attributes(outcome, now))
            |> Repo.update!()
          end)

          from(step in ProviderStep,
            where: step.turn_receipt_id in subquery(receipt_ids) and step.status == "started"
          )
          |> Repo.update_all(
            set: [
              status: "interrupted",
              error_code: "runtime_restarted",
              completed_at: now,
              updated_at: now
            ]
          )

          from(receipt in TurnReceipt,
            where: receipt.turn_id in ^turn_ids and receipt.status == "captured"
          )
          |> Repo.update_all(
            set: [status: "interrupted", provider_completed_at: now, updated_at: now]
          )

          from(t in Turn, where: t.id in ^turn_ids)
          |> Repo.update_all(
            set: [
              status: "failed",
              error_message: "Sarah restarted before this response finished.",
              error_code: "runtime_restarted",
              completed_at: now,
              updated_at: now
            ]
          )

          from(m in Message,
            join: t in Turn,
            on: t.assistant_message_id == m.id,
            where: t.id in ^turn_ids
          )
          |> Repo.update_all(set: [status: "failed", updated_at: now])

          :recovered
        end)
    end

    :ok
  end

  defp ensure_visitor(browser_key_hash) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Visitor,
      [
        %{
          id: Ecto.UUID.generate(),
          browser_key_hash: browser_key_hash,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:browser_key_hash]
    )

    Repo.get_by!(Visitor, browser_key_hash: browser_key_hash)
  end

  defp ensure_user_visitor(user_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Visitor,
      [
        %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_id]
    )

    Repo.get_by!(Visitor, user_id: user_id)
  end

  defp ensure_conversation_with_greeting(visitor) do
    {conversation, created?} = ensure_conversation_for_visitor(visitor)

    if created? do
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "assistant",
        content: Persona.greeting(),
        status: "complete"
      })
      |> Repo.insert!()
    end

    conversation
  end

  defp ensure_conversation_for_visitor(visitor) do
    now = DateTime.utc_now()

    {inserted_count, _returned_rows} =
      Repo.insert_all(
        Conversation,
        [
          %{
            id: Ecto.UUID.generate(),
            visitor_id: visitor.id,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:visitor_id]
      )

    {Repo.get_by!(Conversation, visitor_id: visitor.id), inserted_count == 1}
  end

  defp before_message(query, _conversation_id, nil), do: query

  defp before_message(query, conversation_id, before_id) do
    case Repo.get_by(Message, id: before_id, conversation_id: conversation_id) do
      nil ->
        query

      cursor ->
        from(m in query,
          where:
            m.inserted_at < ^cursor.inserted_at or
              (m.inserted_at == ^cursor.inserted_at and m.id < ^cursor.id)
        )
    end
  end

  defp validate_content(""), do: {:error, :empty_message}

  defp validate_content(content) do
    maximum_bytes = Application.fetch_env!(:openagents, :maximum_message_bytes)

    if byte_size(content) <= maximum_bytes,
      do: :ok,
      else: {:error, :message_too_long}
  end

  defp enforce_rate_limit(conversation_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

    count =
      Repo.aggregate(
        from(t in Turn,
          where: t.conversation_id == ^conversation_id and t.inserted_at >= ^cutoff
        ),
        :count
      )

    if count < Application.fetch_env!(:openagents, :turn_rate_limit),
      do: :ok,
      else: {:error, :rate_limited}
  end

  # Typed messages sent into a live voice call open no turn, so they carry
  # their own bound: the same per-minute budget counted on user messages.
  defp enforce_message_rate_limit(conversation_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

    count =
      Repo.aggregate(
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and m.role == "user" and
              m.inserted_at >= ^cutoff
        ),
        :count
      )

    if count < Application.fetch_env!(:openagents, :turn_rate_limit),
      do: :ok,
      else: {:error, :rate_limited}
  end

  defp normalize_turn_error(changeset) do
    if Keyword.has_key?(changeset.errors, :conversation_id),
      do: {:error, :turn_in_progress},
      else: {:error, changeset}
  end

  defp finish_turn(
         turn,
         turn_status,
         message_status,
         provider_response_id,
         error_message,
         usage,
         provider_error_code
       ) do
    now = DateTime.utc_now()

    result =
      Multi.new()
      |> Multi.run(:locked_turn, fn repo, _changes ->
        {:ok, repo.get_for_update!(Turn, turn.id)}
      end)
      |> Multi.run(:tool_steps, fn repo, %{locked_turn: locked_turn} ->
        case turn_status do
          "completed" ->
            ensure_no_active_tool_steps(repo, locked_turn.id)

          "failed" ->
            # Carry the turn's real reason onto the torn-down tool step instead of
            # a synthetic "turn_failed", so a delegation cut down mid-flight names
            # the actual cause rather than erasing it.
            terminate_active_tool_steps(
              repo,
              locked_turn.id,
              "failed",
              provider_error_code || "turn_failed",
              now
            )

          "cancelled" ->
            terminate_active_tool_steps(repo, locked_turn.id, "cancelled", "cancelled", now)
        end
      end)
      |> Multi.run(:message, fn repo, %{locked_turn: locked_turn} ->
        repo.get_for_update!(Message, locked_turn.assistant_message_id)
        |> Message.changeset(%{
          status: message_status,
          provider_response_id: provider_response_id
        })
        |> repo.update()
      end)
      |> Multi.run(:turn, fn repo, %{locked_turn: locked_turn} ->
        locked_turn
        |> Turn.changeset(%{
          status: turn_status,
          provider_response_id: provider_response_id,
          error_message: error_message,
          error_code: provider_error_code,
          completed_at: now
        })
        |> repo.update()
      end)
      |> Multi.run(:receipt, fn repo, %{locked_turn: locked_turn} ->
        case repo.get_by_for_update(TurnReceipt, turn_id: locked_turn.id) do
          nil ->
            {:ok, nil}

          receipt ->
            receipt
            |> TurnReceipt.lifecycle_changeset(%{
              status: receipt_status(turn_status),
              usage: usage,
              provider_completed_at: now
            })
            |> repo.update()
        end
      end)
      |> Multi.run(:provider_step, fn repo, %{receipt: receipt} ->
        finish_provider_step(
          repo,
          receipt,
          turn_status,
          provider_response_id,
          usage,
          provider_error_code,
          now
        )
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{message: message, turn: updated_turn}} ->
        broadcast(turn.conversation_id, {:message_updated, message})
        broadcast(turn.conversation_id, {:turn_updated, updated_turn})

        # The terminal receipt above is where a typed turn's token total lands,
        # so this is the one place a text total can change.
        :ok = OpenAgents.Leaderboard.invalidate()

        {:ok, updated_turn}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp ensure_no_active_tool_steps(repo, turn_id) do
    count =
      repo.aggregate(
        from(step in ToolStep,
          where: step.turn_id == ^turn_id and step.status in ["requested", "running"]
        ),
        :count
      )

    if count == 0, do: {:ok, 0}, else: {:error, :active_tool_step_exists}
  end

  defp terminate_active_tool_steps(repo, turn_id, status, error_code, now) do
    steps =
      repo.all(
        from(step in ToolStep,
          where: step.turn_id == ^turn_id and step.status in ["requested", "running"],
          lock: "FOR UPDATE"
        )
      )

    Enum.reduce_while(steps, {:ok, 0}, fn step, {:ok, count} ->
      outcome = lifecycle_tool_outcome(step, status, error_code, now)

      case repo.update(
             ToolStep.terminal_changeset(step, tool_step_terminal_attributes(outcome, now))
           ) do
        {:ok, _step} -> {:cont, {:ok, count + 1}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp lifecycle_tool_outcome(step, status, error_code, now) do
    %{
      "schema" => "sarah.tool_outcome.v1",
      "call_id" => step.provider_call_id,
      "module_ref" => %{
        "module_id" => step.module_id,
        "tool_name" => step.tool_name,
        "version" => step.tool_version,
        "artifact_digest" => step.module_artifact_digest
      },
      "executor_ref" => %{
        "id" => "sarah.host",
        "disclosure" => "Sarah host lifecycle",
        "implementation_digest" => nil
      },
      "status" => status,
      "result" => nil,
      "error" => %{
        "code" => error_code,
        "message" => lifecycle_tool_message(status, error_code)
      },
      "target_receipt_refs" => [],
      "attribution_refs" => [],
      "started_at" => DateTime.to_iso8601(step.started_at || step.requested_at),
      "completed_at" => DateTime.to_iso8601(now)
    }
  end

  # Name the real reason on a tool step torn down by its turn, so the durable
  # record explains the delegation's death instead of hiding it behind a
  # generic marker. Cancellations and the legacy synthetic code keep the plain
  # sentence.
  defp lifecycle_tool_message(_status, code) when code in [nil, "turn_failed", "cancelled"],
    do: "The tool call ended with the containing turn."

  defp lifecycle_tool_message("failed", code),
    do: "The tool call ended when the turn failed (#{code})."

  defp lifecycle_tool_message(_status, _code),
    do: "The tool call ended with the containing turn."

  defp tool_step_terminal_attributes(outcome, now) do
    outcome_digest = Canonical.digest!(outcome)

    %{
      status: outcome["status"],
      outcome_digest: outcome_digest,
      outcome_receipt_ref: "module-outcome:v1:#{outcome_digest}",
      usage: Map.get(outcome, "usage", %{"invocations" => 1}),
      result: outcome["result"],
      error: outcome["error"],
      executor_id: get_in(outcome, ["executor_ref", "id"]),
      executor_disclosure: get_in(outcome, ["executor_ref", "disclosure"]),
      target_receipt_refs: outcome["target_receipt_refs"],
      attribution_refs: outcome["attribution_refs"],
      completed_at: now
    }
  end

  defp finish_provider_step(_repo, nil, _status, _response_id, _usage, _error_code, _now),
    do: {:ok, nil}

  defp finish_provider_step(
         repo,
         receipt,
         turn_status,
         provider_response_id,
         usage,
         provider_error_code,
         now
       ) do
    step = latest_provider_step(receipt.id, "started", repo)

    if step do
      terminal_response_id = provider_response_id || step.provider_response_id

      step
      |> ProviderStep.lifecycle_changeset(%{
        status: provider_step_status(turn_status),
        provider_response_id: terminal_response_id,
        usage: usage,
        error_code: provider_error_code,
        completed_at: now
      })
      |> repo.update()
    else
      accept_already_completed_step(repo, receipt, turn_status, provider_response_id)
    end
  end

  defp accept_already_completed_step(repo, receipt, "completed", provider_response_id) do
    case latest_provider_step(receipt.id, "completed", repo) do
      %ProviderStep{provider_response_id: ^provider_response_id} = step -> {:ok, step}
      _step -> {:error, :started_provider_step_missing}
    end
  end

  defp accept_already_completed_step(repo, receipt, turn_status, _provider_response_id)
       when turn_status in ["failed", "cancelled"] do
    case latest_provider_step(receipt.id, "completed", repo) do
      %ProviderStep{} = step -> {:ok, step}
      nil -> {:error, :started_provider_step_missing}
    end
  end

  defp accept_already_completed_step(
         _repo,
         _receipt,
         _turn_status,
         _provider_response_id
       ),
       do: {:error, :started_provider_step_missing}

  defp latest_provider_step(receipt_id, status, repo \\ Repo) do
    repo.one(
      from(step in ProviderStep,
        where: step.turn_receipt_id == ^receipt_id and step.status == ^status,
        order_by: [desc: step.sequence],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_inference_capture(context, request, provider_id) do
    cond do
      request.instructions != context.instructions ->
        {:error, :request_context_mismatch}

      context.instruction_digest != Canonical.sha256(request.instructions) ->
        {:error, :instruction_digest_mismatch}

      not is_binary(request.model_id) or request.model_id == "" or
          byte_size(request.model_id) > 256 ->
        {:error, :invalid_model_id}

      provider_id == "" or byte_size(provider_id) > 128 ->
        {:error, :invalid_provider_id}

      true ->
        :ok
    end
  end

  defp validate_optional_digest(nil), do: :ok

  defp validate_optional_digest(digest) when is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: :ok,
      else: {:error, :invalid_tool_catalog_digest}
  end

  defp validate_optional_digest(_digest), do: {:error, :invalid_tool_catalog_digest}

  defp validate_optional_reference(nil), do: :ok

  defp validate_optional_reference(reference) when is_binary(reference) do
    if Regex.match?(
         ~r/\Aprofile-memory-snapshot:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
         reference
       ),
       do: :ok,
       else: {:error, :invalid_profile_memory_snapshot_ref}
  end

  defp validate_optional_reference(_reference),
    do: {:error, :invalid_profile_memory_snapshot_ref}

  defp validate_optional_preference_reference(nil), do: :ok

  defp validate_optional_preference_reference(reference) when is_binary(reference) do
    if Regex.match?(
         ~r/\Apreference-snapshot:v1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
         reference
       ),
       do: :ok,
       else: {:error, :invalid_preference_snapshot_ref}
  end

  defp validate_optional_preference_reference(_reference),
    do: {:error, :invalid_preference_snapshot_ref}

  defp validate_preference_context(%Context{applied_preferences: applied}, usage)
       when is_list(applied) and is_map(usage) do
    if usage["applied"] == applied,
      do: :ok,
      else: {:error, :invalid_preference_capture}
  end

  defp validate_preference_context(_context, _usage),
    do: {:error, :invalid_preference_capture}

  defp validate_experience_context(%Context{applied_experiences: applied}, usage) do
    if applied["record_refs"] == usage["record_refs"] and
         applied["pattern_refs"] == usage["pattern_refs"],
       do: :ok,
       else: {:error, :invalid_experience_capture}
  end

  defp validate_program_snapshot(%Snapshot{artifact: nil, degraded?: true} = snapshot) do
    receipt = snapshot.receipt

    if receipt["schema"] == "sarah.program_capture.v1" and
         receipt["signature_id"] == snapshot.signature_id and
         receipt["artifact_id"] == nil and receipt["artifact_digest"] == nil and
         receipt["degraded"] == true and receipt["activation_status"] == "baseline" and
         receipt["reason"] == snapshot.reason,
       do: :ok,
       else: {:error, :invalid_program_snapshot}
  end

  defp validate_program_snapshot(%Snapshot{artifact: artifact, degraded?: false} = snapshot)
       when not is_nil(artifact) do
    receipt = snapshot.receipt

    if artifact.signature_id == snapshot.signature_id and
         artifact.activation_status in ~w(shadow active) and
         Reader.digest(artifact.document) == artifact.digest and
         receipt["schema"] == "sarah.program_capture.v1" and
         receipt["signature_id"] == snapshot.signature_id and
         receipt["artifact_id"] == artifact.id and
         receipt["artifact_digest"] == artifact.digest and receipt["degraded"] == false and
         receipt["activation_status"] == artifact.activation_status and
         receipt["reason"] == snapshot.reason,
       do: :ok,
       else: {:error, :invalid_program_snapshot}
  end

  defp validate_program_snapshot(_snapshot), do: {:error, :invalid_program_snapshot}

  defp program_artifact_id(%Snapshot{artifact: nil}), do: nil
  defp program_artifact_id(%Snapshot{artifact: artifact}), do: artifact.id

  defp program_artifact_digest(%Snapshot{artifact: nil}), do: nil
  defp program_artifact_digest(%Snapshot{artifact: artifact}), do: artifact.digest

  defp normalize_refs(refs) when is_list(refs) and length(refs) <= 100 do
    if Enum.all?(refs, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 256)),
      do: {:ok, refs |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_provenance_reference}
  end

  defp normalize_refs(_refs), do: {:error, :invalid_provenance_reference}

  defp validate_raw_tool_arguments(arguments)
       when is_binary(arguments) and byte_size(arguments) <= 262_144,
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

  defp same_tool_step_identity?(step, identity) do
    Enum.all?(
      [
        :turn_id,
        :turn_receipt_id,
        :provider_call_id,
        :provider_item_id,
        :provider_response_id,
        :tool_name,
        :tool_version,
        :module_id,
        :module_artifact_digest,
        :executor_implementation_digest,
        :routing_receipt_id,
        :side_effect_class,
        :invocation_key,
        :attribution_policy_id,
        :attribution_policy_version,
        :attribution_policy_digest,
        :billable,
        :billable_attribution_key,
        :cost_units,
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

      get_in(outcome, ["module_ref", "artifact_digest"]) != step.module_artifact_digest ->
        {:error, :tool_outcome_artifact_mismatch}

      step.executor_implementation_digest != nil and
        get_in(outcome, ["executor_ref", "id"]) != "sarah.host" and
          get_in(outcome, ["executor_ref", "implementation_digest"]) !=
            step.executor_implementation_digest ->
        {:error, :tool_outcome_executor_digest_mismatch}

      outcome["status"] not in statuses ->
        {:error, :invalid_tool_outcome_status}

      not is_map(outcome["executor_ref"]) ->
        {:error, :invalid_tool_outcome_executor}

      not is_list(outcome["target_receipt_refs"]) or
          not is_list(outcome["attribution_refs"]) ->
        {:error, :invalid_tool_outcome_refs}

      true ->
        :ok
    end
  end

  defp merge_refs(existing_refs, new_refs) do
    (existing_refs ++ new_refs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp receipt_status("completed"), do: "completed"
  defp receipt_status("failed"), do: "failed"
  defp receipt_status("cancelled"), do: "cancelled"

  defp provider_step_status("completed"), do: "completed"
  defp provider_step_status("failed"), do: "failed"
  defp provider_step_status("cancelled"), do: "cancelled"

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code({code, _detail, _extra}) when is_atom(code), do: Atom.to_string(code)

  defp error_code(reason) when is_binary(reason) do
    if error_code_token?(reason), do: String.slice(reason, 0, 64), else: "task_exit"
  end

  defp error_code(%{__exception__: true, __struct__: module}) when is_atom(module) do
    name = module |> Module.split() |> List.last() |> String.slice(0, 64)
    "task_exit:#{name}"
  end

  defp error_code(_reason), do: "task_exit"

  defp error_code_token?(token) do
    byte_size(token) in 1..64 and Regex.match?(~r/\A[a-z][a-z0-9_]*(?::[a-z0-9_]+)*\z/, token)
  end

  defp public_error(:missing_api_key), do: "Sarah is not configured to answer yet."
  defp public_error(:provider_timeout), do: "Sarah took too long to answer. Please try again."

  defp public_error({:provider_error, _status}),
    do: "Sarah could not answer just now. Please try again."

  defp public_error(_reason), do: "Sarah could not finish that response. Please try again."

  defp broadcast(conversation_id, event) do
    Phoenix.PubSub.broadcast(OpenAgents.PubSub, topic(conversation_id), event)
  end

  defp broadcast_tool_activity(%ToolStep{} = step) do
    conversation_id =
      Repo.one!(
        from(turn in Turn,
          where: turn.id == ^step.turn_id,
          select: turn.conversation_id
        )
      )

    broadcast(conversation_id, {:tool_activity_updated, step.turn_id})
  end

  defp topic(conversation_id), do: "conversation:#{conversation_id}"
end
