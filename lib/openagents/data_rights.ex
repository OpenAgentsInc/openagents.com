defmodule OpenAgents.DataRights do
  @moduledoc "Account-authorized export and deletion of Sarah's first-party product data."

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Conversations.{Conversation, Message, Visitor}
  alias OpenAgents.ExperienceMemory.DeletionReceipt, as: ExperienceDeletionReceipt

  alias OpenAgents.GraphMemory.{
    CascadePlan,
    OperationReceipt,
    OutboxEvent,
    SourceMembership
  }

  alias OpenAgents.Memory.SemanticDerivativeReceipt
  alias OpenAgents.{Accounts, ApiTokens, Conversations, ProfileMemory, Repo}
  alias OpenAgents.Voice.{ResponseContext, ResponseReceipt, Session, TranscriptItem}

  @maximum_export_messages 10_000
  @maximum_export_voice_sessions 2_000
  @maximum_export_tool_steps 10_000
  @maximum_export_chat_runs 5_000
  @maximum_export_chat_events 20_000

  @doc """
  Whether the one-click full reset control is enabled.

  Development and staging only. The control deletes every message, memory, and
  voice session an account has, with one confirmation and no undo — reasonable
  to hand someone exercising a build, never something to leave on a page a
  customer is using. The flag alone was the gate, so a production deployment
  that set it got the control; the environment now decides last, and enabling
  the flag against production is inert rather than destructive.
  """
  @spec reset_enabled?() :: boolean()
  def reset_enabled? do
    Application.get_env(:openagents, :conversation_reset_enabled, false) == true and
      Application.get_env(:openagents, :runtime_environment) != :production
  end

  @spec export(User.t(), Visitor.t(), Conversation.t()) :: {:ok, map()} | {:error, term()}
  def export(
        %User{id: user_id} = user,
        %Visitor{id: visitor_id, user_id: user_id} = owner,
        %Conversation{visitor_id: visitor_id} = conversation
      ) do
    with {:ok, memory} <- ProfileMemory.export(owner) do
      messages =
        Repo.all(
          from(message in Message,
            where: message.conversation_id == ^conversation.id,
            order_by: [asc: message.inserted_at, asc: message.id],
            limit: ^(@maximum_export_messages + 1)
          )
        )

      sessions =
        Repo.all(
          from(session in Session,
            where: session.conversation_id == ^conversation.id,
            order_by: [asc: session.started_at, asc: session.generation],
            limit: ^(@maximum_export_voice_sessions + 1),
            preload: [:recording]
          )
        )

      tool_steps = tool_steps(conversation)
      chat_runs = chat_runs(conversation)

      {:ok,
       %{
         "schema" => "sarah.account_data_export.v1",
         "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
         "scope" => "authenticated_github_user",
         "github_connection" => github_connection_export(user),
         "api_credentials" => Enum.map(ApiTokens.metadata(user), &api_credential_export/1),
         "messages" =>
           messages |> Enum.take(@maximum_export_messages) |> Enum.map(&message_export/1),
         "messages_truncated" => length(messages) > @maximum_export_messages,
         "profile_memory" => memory,
         "voice_sessions" =>
           sessions |> Enum.take(@maximum_export_voice_sessions) |> Enum.map(&voice_export/1),
         "voice_sessions_truncated" => length(sessions) > @maximum_export_voice_sessions,
         "tool_steps" =>
           tool_steps |> Enum.take(@maximum_export_tool_steps) |> Enum.map(&tool_step_export/1),
         "tool_steps_truncated" => length(tool_steps) > @maximum_export_tool_steps,
         "chat_runs" => chat_runs.records,
         "chat_runs_truncated" => chat_runs.records_truncated,
         "chat_run_events_truncated" => chat_runs.events_truncated
       }}
    end
  end

  @spec delete(User.t(), Visitor.t(), Conversation.t()) ::
          {:ok, :deleted} | {:error, term()}
  def delete(
        %User{id: user_id},
        %Visitor{id: visitor_id, user_id: user_id},
        %Conversation{visitor_id: visitor_id} = conversation
      ) do
    Repo.transaction(fn ->
      owner = Repo.get_for_update!(Visitor, visitor_id)
      locked_conversation = Repo.get_for_update!(Conversation, conversation.id)

      if Conversations.active_turn(locked_conversation), do: Repo.rollback(:text_turn_in_progress)

      if OpenAgents.Voice.active_session(locked_conversation),
        do: Repo.rollback(:voice_session_in_progress)

      session_ids =
        from(session in Session,
          where: session.conversation_id == ^locked_conversation.id,
          select: session.id
        )

      {_deleted_voice_receipts, nil} =
        Repo.delete_all(
          from(receipt in ResponseReceipt,
            where: receipt.voice_session_id in subquery(session_ids)
          )
        )

      {_deleted_voice_contexts, nil} =
        Repo.delete_all(
          from(context in ResponseContext,
            where: context.voice_session_id in subquery(session_ids)
          )
        )

      {_deleted_voice_transcript_items, nil} =
        Repo.delete_all(
          from(item in TranscriptItem, where: item.voice_session_id in subquery(session_ids))
        )

      turn_ids =
        from(turn in OpenAgents.Conversations.Turn,
          where: turn.conversation_id == ^locked_conversation.id,
          select: turn.id
        )

      {_deleted_tool_steps, nil} =
        Repo.delete_all(
          from(step in OpenAgents.Conversations.ToolStep,
            where: step.turn_id in subquery(turn_ids)
          )
        )

      {_deleted_memory_records, nil} =
        Repo.delete_all(
          from(record in ProfileMemory.Record, where: record.owner_visitor_id == ^visitor_id)
        )

      Repo.delete!(owner)

      {_deleted_receipts, nil} =
        Repo.delete_all(
          from(receipt in SemanticDerivativeReceipt,
            where: receipt.conversation_id == ^locked_conversation.id
          )
        )

      {_deleted_experience_receipts, nil} =
        Repo.delete_all(
          from(receipt in ExperienceDeletionReceipt,
            where: receipt.owner_visitor_id == ^visitor_id
          )
        )

      {_deleted_graph_memberships, nil} =
        Repo.delete_all(
          from(membership in SourceMembership,
            where: membership.owner_visitor_id == ^visitor_id
          )
        )

      {_deleted_graph_outbox_events, nil} =
        Repo.delete_all(from(event in OutboxEvent, where: event.owner_visitor_id == ^visitor_id))

      {_deleted_graph_cascade_plans, nil} =
        Repo.delete_all(from(plan in CascadePlan, where: plan.owner_visitor_id == ^visitor_id))

      {_deleted_graph_operation_receipts, nil} =
        Repo.delete_all(
          from(receipt in OperationReceipt, where: receipt.owner_visitor_id == ^visitor_id)
        )

      :deleted
    end)
  end

  # The account chat backend records its own runs and their event stream, keyed
  # on the same conversation. They are the account's requests and the answers
  # it received, so the conversation export carries them rather than leaving
  # the `chat` family's portability claim resting on messages alone.
  defp chat_runs(conversation) do
    runs =
      Repo.all(
        from(run in OpenAgents.Chat.AccountRun,
          where: run.conversation_id == ^conversation.id,
          order_by: [asc: run.inserted_at, asc: run.id],
          limit: ^(@maximum_export_chat_runs + 1)
        )
      )

    kept = Enum.take(runs, @maximum_export_chat_runs)
    run_ids = Enum.map(kept, & &1.id)

    events =
      Repo.all(
        from(event in OpenAgents.Chat.AccountEvent,
          where: event.run_id in ^run_ids,
          order_by: [asc: event.run_id, asc: event.sequence],
          limit: ^(@maximum_export_chat_events + 1)
        )
      )

    by_run = events |> Enum.take(@maximum_export_chat_events) |> Enum.group_by(& &1.run_id)

    %{
      records: Enum.map(kept, &chat_run_export(&1, Map.get(by_run, &1.id, []))),
      records_truncated: length(runs) > @maximum_export_chat_runs,
      events_truncated: length(events) > @maximum_export_chat_events
    }
  end

  defp chat_run_export(run, events) do
    %{
      "id" => run.id,
      "status" => run.status,
      "backend" => run.backend,
      "reasoning_effort" => run.reasoning_effort,
      "user_content" => run.user_content,
      "assistant_content" => run.assistant_content,
      "usage" => run.usage,
      "error" => run.error,
      "error_code" => run.error_code,
      "latency_ms" => run.latency_ms,
      "started_at" => iso8601(run.started_at),
      "completed_at" => iso8601(run.completed_at),
      "events" =>
        Enum.map(events, fn event ->
          %{
            "sequence" => event.sequence,
            "kind" => event.kind,
            "payload" => event.payload,
            "observed_at" => iso8601(event.observed_at)
          }
        end)
    }
  end

  # Tool steps carry the raw model arguments as user-owned conversation
  # evidence (issue #72), so the account export includes them alongside their
  # canonical digest. Results stay server-side; arguments are the account's
  # own request material.
  defp tool_steps(conversation) do
    text_steps =
      Repo.all(
        from(step in OpenAgents.Conversations.ToolStep,
          join: turn in OpenAgents.Conversations.Turn,
          on: turn.id == step.turn_id,
          where: turn.conversation_id == ^conversation.id,
          order_by: [asc: step.requested_at, asc: step.id],
          limit: ^(@maximum_export_tool_steps + 1)
        )
      )

    voice_steps =
      Repo.all(
        from(step in OpenAgents.Voice.ToolStep,
          join: session in Session,
          on: session.id == step.voice_session_id,
          where: session.conversation_id == ^conversation.id,
          order_by: [asc: step.requested_at, asc: step.id],
          limit: ^(@maximum_export_tool_steps + 1)
        )
      )

    (Enum.map(text_steps, &{&1, "text"}) ++ Enum.map(voice_steps, &{&1, "voice"}))
    |> Enum.sort_by(fn {step, _surface} -> {step.requested_at, step.id} end)
  end

  defp tool_step_export({step, surface}) do
    %{
      "surface" => surface,
      "tool_name" => step.tool_name,
      "tool_version" => step.tool_version,
      "module_id" => step.module_id,
      "status" => step.status,
      "raw_arguments" => step.raw_arguments,
      "argument_digest" => step.argument_digest,
      "requested_at" => iso8601(step.requested_at),
      "completed_at" => iso8601(step.completed_at)
    }
  end

  defp message_export(message) do
    %{
      "role" => message.role,
      "content" => message.content,
      "status" => message.status,
      "modality" => message.modality,
      "interrupted" => message.interrupted,
      "inserted_at" => DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp voice_export(session) do
    %{
      "generation" => session.generation,
      "status" => session.status,
      "provider" => session.provider_id,
      "model" => session.model_id,
      "voice_artifact" => session.voice_artifact_id,
      "usage" => session.usage,
      "started_at" => DateTime.to_iso8601(session.started_at),
      "connected_at" => iso8601(session.connected_at),
      "ended_at" => iso8601(session.ended_at),
      "termination_reason" => session.termination_reason,
      "failure_code" => session.failure_code,
      "operational_purged_at" => iso8601(session.operational_purged_at),
      "recording" => recording_export(session.recording)
    }
  end

  # The audio itself is not embedded: a JSON export is the wrong container for
  # megabytes of Opus, and base64 in a text field would be worse. What the export
  # owes the account is the fact that a recording exists, how large and complete
  # it is, and that deletion removes it — which is what this carries.
  defp recording_export(nil), do: nil

  defp recording_export(recording) do
    %{
      "status" => recording.status,
      "container" => recording.container,
      "codec" => recording.codec,
      "channel_layout" => recording.channel_layout,
      "encrypted_at_rest" => recording.sealed,
      "byte_size" => recording.byte_size,
      "chunk_count" => recording.chunk_count,
      "client_duration_ms" => recording.client_duration_ms,
      "content_digest" => recording.content_digest,
      "started_at" => iso8601(recording.started_at),
      "completed_at" => iso8601(recording.completed_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(timestamp), do: DateTime.to_iso8601(timestamp)

  defp github_connection_export(user) do
    connection = Accounts.github_connection(user)

    %{
      "connected" => connection.connected,
      "scopes" => connection.scopes,
      "connected_at" => iso8601(connection.connected_at),
      "rotated_at" => iso8601(connection.rotated_at),
      "credential_exported" => false,
      "product_data_deletion" => "retained_until_explicit_disconnect"
    }
  end

  defp api_credential_export(credential) do
    %{
      "id" => credential.id,
      "name" => credential.name,
      "scopes" => credential.scopes,
      "created_at" => iso8601(credential.inserted_at),
      "expires_at" => iso8601(credential.expires_at),
      "last_used_at" => iso8601(credential.last_used_at),
      "revoked_at" => iso8601(credential.revoked_at),
      "credential_exported" => false,
      "product_data_deletion" => "retained_until_explicit_revocation"
    }
  end
end
