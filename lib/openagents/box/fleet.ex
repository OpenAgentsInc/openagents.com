defmodule OpenAgents.Box.Fleet do
  @moduledoc """
  Durable, bounded projection of a conversation's Box fleet.

  The projection reads the Box, run, fan-out, and assignment ledgers on every
  request. PubSub and LiveView assigns can refresh it, but they are never its
  source of truth.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Box
  alias OpenAgents.Box.{ConversationBox, FanoutItem, FanoutRequest, Run}
  alias OpenAgents.BoxRuns
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Repo
  alias OpenAgents.Tools.BoxOutput

  @maximum_rendered_boxes 10
  @maximum_rendered_queue_items 100

  @spec projection(String.t()) :: map()
  def projection(conversation_id) when is_binary(conversation_id) do
    boxes = list_boxes(conversation_id)
    box_ids = Enum.map(boxes, & &1.id)
    runs = latest_runs(conversation_id, box_ids)
    assignments = latest_assignments(conversation_id, box_ids)
    queued = queued_items(conversation_id)
    plan = latest_plan(conversation_id)

    %{
      admitted_count: Enum.count(boxes, &is_nil(&1.stopped_at)),
      effective_cap: effective_cap(plan),
      effective_limits: effective_limits(plan),
      boxes:
        Enum.map(boxes, fn box ->
          box_view(box, Map.get(runs, box.id), Map.get(assignments, box.id))
        end),
      queued: Enum.map(queued.items, &queued_view/1),
      queued_truncated?: queued.truncated?,
      maximum_boxes: @maximum_rendered_boxes
    }
  end

  @spec stop(User.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stop(%User{} = user, label) when is_binary(label) do
    with {:ok, conversation} <- owned_conversation(user),
         {:ok, box} <- owned_box(conversation.id, label),
         {:ok, _box} <- Box.stop_box(conversation.id, box.box_id) do
      {:ok, projection(conversation.id)}
    else
      {:error, :conversation_not_found} -> {:error, :conversation_not_found}
      error -> error
    end
  end

  @spec cancel_run(User.t(), String.t(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  def cancel_run(%User{} = user, label, run_id)
      when is_binary(label) and is_binary(run_id) do
    with {:ok, conversation} <- owned_conversation(user),
         {:ok, box} <- owned_box(conversation.id, label),
         {:ok, run} <- BoxRuns.get_run(conversation.id, box.box_id, run_id),
         {:ok, cancelled} <- BoxRuns.cancel(run) do
      {:ok, cancelled}
    else
      {:error, :conversation_not_found} -> {:error, :conversation_not_found}
      error -> error
    end
  end

  @spec owns_conversation?(User.t(), String.t()) :: boolean()
  def owns_conversation?(%User{} = user, conversation_id) when is_binary(conversation_id) do
    not is_nil(Conversations.get_conversation_for_user(user, conversation_id))
  end

  defp owned_conversation(%User{} = user) do
    case Conversations.get_conversation_for_user(user) do
      nil -> {:error, :conversation_not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp owned_box(conversation_id, label) do
    case Repo.one(
           from box in ConversationBox,
             where: box.conversation_id == ^conversation_id and box.label == ^label
         ) do
      %ConversationBox{} = box -> {:ok, box}
      nil -> {:error, :not_found}
    end
  end

  defp list_boxes(conversation_id) do
    Repo.all(
      from box in ConversationBox,
        where: box.conversation_id == ^conversation_id,
        order_by: [desc: box.stopped_at, asc: box.inserted_at],
        limit: ^@maximum_rendered_boxes
    )
  end

  defp latest_runs(_conversation_id, []), do: %{}

  defp latest_runs(conversation_id, box_ids) do
    Repo.all(
      from run in Run,
        where: run.conversation_id == ^conversation_id and run.conversation_box_id in ^box_ids,
        distinct: run.conversation_box_id,
        order_by: [asc: run.conversation_box_id, desc: run.inserted_at, desc: run.id]
    )
    |> Map.new(&{&1.conversation_box_id, &1})
  end

  defp latest_assignments(_conversation_id, []), do: %{}

  defp latest_assignments(conversation_id, box_ids) do
    Repo.all(
      from assignment in Assignment,
        join: box in ConversationBox,
        on: box.id == assignment.conversation_box_id,
        where:
          assignment.conversation_box_id in ^box_ids and box.conversation_id == ^conversation_id,
        distinct: assignment.conversation_box_id,
        order_by: [
          asc: assignment.conversation_box_id,
          desc: assignment.inserted_at,
          desc: assignment.id
        ]
    )
    |> Map.new(&{&1.conversation_box_id, &1})
  end

  defp queued_items(conversation_id) do
    items =
      Repo.all(
        from item in FanoutItem,
          where: item.conversation_id == ^conversation_id and item.state == "queued",
          order_by: [asc: item.queue_sequence],
          limit: ^(@maximum_rendered_queue_items + 1)
      )

    {items, truncated?} = Enum.split(items, @maximum_rendered_queue_items)
    %{items: items, truncated?: truncated? != []}
  end

  defp latest_plan(conversation_id) do
    Repo.one(
      from request in FanoutRequest,
        where: request.conversation_id == ^conversation_id,
        order_by: [desc: request.inserted_at, desc: request.id],
        limit: 1
    )
  end

  defp effective_cap(%FanoutRequest{effective_limits: limits}) when is_map(limits) do
    case limits["conversation_active_limit"] do
      cap when is_integer(cap) and cap > 0 -> cap
      _missing -> Box.default_active_boxes()
    end
  end

  defp effective_cap(_plan), do: Box.default_active_boxes()

  defp effective_limits(%FanoutRequest{effective_limits: limits}) when is_map(limits),
    do: limits

  defp effective_limits(_plan), do: %{"conversation_active_limit" => Box.default_active_boxes()}

  defp box_view(box, run, assignment) do
    %{
      id: box.id,
      box_id: safe_text(box.box_id),
      label: safe_text(box.label),
      kind: :admitted,
      state: safe_text(box.state),
      queue_reason: nil,
      age_seconds: age_seconds(box.inserted_at),
      stopped_at: box.stopped_at,
      run: run_view(run),
      assignment: assignment_view(assignment)
    }
  end

  defp queued_view(item) do
    %{
      id: item.id,
      label: safe_text(item.label),
      kind: :queued,
      state: "queued",
      queue_reason: safe_text(item.queue_reason),
      age_seconds: age_seconds(item.queued_at),
      run: nil,
      assignment: nil
    }
  end

  defp run_view(nil), do: nil

  defp run_view(%Run{} = run) do
    {output, output_truncated?} = BoxOutput.bounded(run.output)

    %{
      id: run.id,
      state: safe_text(run.state),
      terminal?: Run.terminal?(run),
      output: output,
      output_truncated?: output_truncated?,
      exit_status: run.exit_status,
      failure_reason: safe_text(run.failure_reason),
      finished_at: run.finished_at
    }
  end

  defp assignment_view(nil), do: nil

  defp assignment_view(%Assignment{} = assignment) do
    %{
      id: assignment.id,
      state: safe_text(assignment.state),
      branch: safe_text(assignment.terminal_branch || assignment.branch),
      commit: safe_text(assignment.terminal_commit),
      failure_reason: safe_text(assignment.failure_reason)
    }
  end

  defp age_seconds(nil), do: 0

  defp age_seconds(inserted_at) do
    max(DateTime.diff(DateTime.utc_now(), inserted_at, :second), 0)
  end

  defp safe_text(nil), do: nil

  defp safe_text(value) when is_binary(value) do
    {redacted, _truncated?} = BoxOutput.bounded(value)
    redacted
  end

  defp safe_text(value), do: to_string(value)
end
