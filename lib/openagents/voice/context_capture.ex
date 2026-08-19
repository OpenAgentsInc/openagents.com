defmodule OpenAgents.Voice.ContextCapture do
  @moduledoc "Builds immutable admission and per-response Sarah context captures for voice."

  import Ecto.Query

  alias OpenAgents.{Blueprint, Conversations, Machines, ProfileMemory, ProgramArtifacts, Repo}
  alias OpenAgents.Context.Composer
  alias OpenAgents.Conversations.{Conversation, Message, Turn}
  alias OpenAgents.Conversations.ToolStep, as: TurnToolStep
  alias OpenAgents.Memory.LexicalRecall
  alias OpenAgents.Tools.{Registry, Snapshot}
  alias OpenAgents.Voice.{ResponseContext, Session, TranscriptItem}
  alias OpenAgents.Voice.ToolStep, as: VoiceToolStep

  @voice_signature "sarah.voice.response.v1"
  @maximum_profile_evidence 8
  @maximum_conversation_evidence 12
  @maximum_tool_evidence 8
  @maximum_tool_result_bytes 500
  @terminal_tool_statuses ~w(succeeded failed refused cancelled unavailable interrupted)

  @spec admission(Conversation.t(), Snapshot.t()) :: {:ok, map()} | {:error, term()}
  def admission(%Conversation{} = conversation, %Snapshot{} = tool_snapshot) do
    program_snapshot = ProgramArtifacts.capture(@voice_signature)
    evidence = conversation_evidence(conversation, nil) ++ tool_activity_evidence(conversation)
    owner = Conversations.get_conversation_owner!(conversation)

    with {:ok, blueprint} <- Blueprint.current_projection(),
         {:ok, context} <-
           Composer.compose(
             surface: "voice",
             capabilities: Registry.prompt_capability_descriptors(tool_snapshot),
             blueprint: blueprint,
             recalled_evidence: Enum.map(evidence, &Map.take(&1, [:source_ref, :content]))
           ) do
      {:ok,
       %{
         context: context,
         blueprint: blueprint,
         program_snapshot: program_snapshot,
         tool_catalog:
           Registry.realtime_catalog(tool_snapshot, voice_intent(conversation),
             machine_paired?: Machines.active_machine?(owner.user_id)
           )
       }}
    end
  end

  # Voice fixes its tool catalog once at admission, so the intent is the topic
  # of the conversation so far — the recent user turns. A delegation-heavy
  # conversation surfaces the computer tools; a memory conversation the memory
  # tools. module_discover is always included as the escape hatch. A paired
  # machine also keeps the computer delegation tools attached.
  defp voice_intent(%Conversation{id: conversation_id}) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and m.role == "user",
      order_by: [desc: m.inserted_at],
      limit: 5,
      select: m.content
    )
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  @spec capture_response(Session.t(), TranscriptItem.t(), Snapshot.t()) ::
          {:ok, ResponseContext.t()} | {:error, term()}
  def capture_response(
        %Session{} = session,
        %TranscriptItem{role: "user", message_id: message_id} = transcript,
        %Snapshot{} = tool_snapshot
      )
      when is_binary(message_id) do
    conversation = Repo.get!(Conversation, session.conversation_id)
    owner = Conversations.get_conversation_owner!(conversation)
    user_message = Repo.get!(Message, message_id)
    program_snapshot = ProgramArtifacts.capture(@voice_signature)

    with :ok <- verify_tool_snapshot(session, tool_snapshot),
         {:ok, blueprint} <- Blueprint.current_projection(),
         :ok <- verify_blueprint(session, blueprint),
         {:ok, profile_snapshot} <- ProfileMemory.capture_snapshot(owner),
         {:ok, profile_records} <-
           ProfileMemory.project_active(owner, profile_snapshot, limit: @maximum_profile_evidence),
         {:ok, memory_snapshot_ref} <-
           LexicalRecall.capture_ref(Repo, conversation.id, user_message.id),
         evidence <-
           selected_evidence(conversation, user_message, profile_records),
         {:ok, context} <-
           Composer.compose(
             surface: "voice",
             capabilities: Registry.prompt_capability_descriptors(tool_snapshot),
             blueprint: blueprint,
             recalled_evidence: Enum.map(evidence, &Map.take(&1, [:source_ref, :content]))
           ),
         :ok <- verify_identity(session, context),
         {:ok, stored} <-
           %ResponseContext{}
           |> ResponseContext.create_changeset(%{
             voice_session_id: session.id,
             generation: session.generation,
             user_message_id: user_message.id,
             provider_input_item_id: transcript.provider_item_id,
             instructions: context.instructions,
             instruction_digest: context.instruction_digest,
             memory_snapshot_ref: memory_snapshot_ref,
             profile_memory_snapshot_ref: profile_snapshot.ref,
             selected_evidence: %{
               "schema" => "sarah.voice_selected_evidence.v1",
               "items" => Enum.map(evidence, &stringify_item/1)
             },
             selected_source_refs: Enum.map(evidence, & &1.source_ref),
             program_artifact_id: program_artifact_id(program_snapshot),
             program_artifact_digest: program_artifact_digest(program_snapshot),
             program_artifact_receipt: program_snapshot.receipt,
             captured_at: DateTime.utc_now()
           })
           |> Repo.insert() do
      {:ok, stored}
    end
  end

  def capture_response(%Session{}, %TranscriptItem{}, %Snapshot{}),
    do: {:error, :invalid_voice_response_context}

  defp selected_evidence(conversation, user_message, profile_records) do
    conversation_evidence(conversation, user_message) ++
      tool_activity_evidence(conversation) ++ profile_evidence(profile_records)
  end

  # Interrupted assistant speech stays visible as labeled cancelled evidence —
  # never as a completed claim — so the model can still see its own truncated
  # commitments after a barge-in instead of losing its train of thought.
  defp conversation_evidence(%Conversation{id: conversation_id}, anchor_message) do
    query =
      from(message in Message,
        where:
          message.conversation_id == ^conversation_id and
            message.role in ["user", "assistant"] and
            message.status in ["complete", "cancelled"],
        order_by: [desc: message.inserted_at, desc: message.id],
        limit: @maximum_conversation_evidence
      )

    query =
      case anchor_message do
        %Message{} = user_message ->
          from(message in query,
            where:
              message.id != ^user_message.id and
                (message.inserted_at < ^user_message.inserted_at or
                   (message.inserted_at == ^user_message.inserted_at and
                      message.id < ^user_message.id))
          )

        nil ->
          query
      end

    query
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn message ->
      %{
        source_ref: "message:#{message.id}",
        classification: "conversation_history",
        content: bounded_content("#{message_label(message)}: #{message.content}", 2_000)
      }
    end)
  end

  defp message_label(%Message{role: "assistant", interrupted: true}),
    do: "assistant (interrupted mid-speech; not a completed claim)"

  defp message_label(%Message{role: role, status: "cancelled"}),
    do: "#{role} (cancelled; not a completed claim)"

  defp message_label(%Message{role: role}), do: role

  # Recent terminal tool steps from both surfaces, so a new voice generation or
  # response knows which tools already ran and with what outcome. The durable
  # step keeps the full result; evidence carries only a bounded fragment.
  defp tool_activity_evidence(%Conversation{id: conversation_id}) do
    voice_steps =
      Repo.all(
        from(step in VoiceToolStep,
          join: session in Session,
          on: session.id == step.voice_session_id,
          where:
            session.conversation_id == ^conversation_id and
              step.status in ^@terminal_tool_statuses,
          order_by: [desc: step.completed_at, desc: step.id],
          limit: @maximum_tool_evidence
        )
      )
      |> Enum.map(&tool_evidence_item(&1, "voice-tool-step"))

    turn_steps =
      Repo.all(
        from(step in TurnToolStep,
          join: turn in Turn,
          on: turn.id == step.turn_id,
          where:
            turn.conversation_id == ^conversation_id and
              step.status in ^@terminal_tool_statuses,
          order_by: [desc: step.completed_at, desc: step.id],
          limit: @maximum_tool_evidence
        )
      )
      |> Enum.map(&tool_evidence_item(&1, "turn-tool-step"))

    (voice_steps ++ turn_steps)
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.take(@maximum_tool_evidence)
    |> Enum.reverse()
    |> Enum.map(&Map.delete(&1, :completed_at))
  end

  defp tool_evidence_item(step, ref_prefix) do
    %{
      source_ref: "#{ref_prefix}:#{step.id}",
      classification: "tool_activity",
      completed_at: step.completed_at || step.updated_at,
      content:
        bounded_content(
          "tool #{step.tool_name} #{step.status}#{tool_outcome_fragment(step)}",
          @maximum_tool_result_bytes + 200
        )
    }
  end

  defp tool_outcome_fragment(%{status: "succeeded", result: result}) when is_map(result) do
    case Jason.encode(result) do
      {:ok, encoded} -> ": #{bounded_content(encoded, @maximum_tool_result_bytes)}"
      {:error, _reason} -> ""
    end
  end

  defp tool_outcome_fragment(%{error: %{"message" => message}}) when is_binary(message),
    do: ": #{bounded_content(message, @maximum_tool_result_bytes)}"

  defp tool_outcome_fragment(_step), do: ""

  defp profile_evidence(records) do
    records
    |> Enum.filter(&(&1["projection"] == "admitted" and is_binary(&1["claim"])))
    |> Enum.map(fn record ->
      %{
        source_ref: "profile-memory:v1:#{record["id"]}:#{record["generation"]}",
        classification: "active_profile_memory",
        content: "#{record["category"]}: #{record["claim"]}"
      }
    end)
  end

  defp bounded_content(content, maximum_bytes) do
    content
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, bounded ->
      candidate = bounded <> grapheme

      if byte_size(candidate) <= maximum_bytes,
        do: {:cont, candidate},
        else: {:halt, bounded}
    end)
  end

  defp stringify_item(item) do
    %{
      "source_ref" => item.source_ref,
      "classification" => item.classification,
      "content" => item.content
    }
  end

  defp verify_tool_snapshot(session, tool_snapshot) do
    if session.tool_catalog_digest == tool_snapshot.digest,
      do: :ok,
      else: {:error, :voice_tool_catalog_changed}
  end

  defp verify_blueprint(%Session{blueprint_revision: nil, blueprint_digest: nil}, nil), do: :ok

  defp verify_blueprint(session, blueprint) do
    if session.blueprint_revision == blueprint.revision and
         session.blueprint_digest == blueprint.digest,
       do: :ok,
       else: {:error, :voice_blueprint_changed}
  end

  defp verify_identity(session, context) do
    if session.persona_id == context.persona_id and
         session.persona_digest == context.persona_digest and session.role_id == context.role_id and
         session.role_digest == context.role_digest,
       do: :ok,
       else: {:error, :voice_identity_changed}
  end

  def program_artifact_id(%{artifact: nil}), do: nil
  def program_artifact_id(%{artifact: artifact}), do: artifact.id
  def program_artifact_digest(%{artifact: nil}), do: nil
  def program_artifact_digest(%{artifact: artifact}), do: artifact.digest
end
