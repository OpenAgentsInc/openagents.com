defmodule OpenAgents.Threads.GrantFenceTest do
  @moduledoc """
  THREAD-001, at the database. Every claim here bypasses the Ecto changeset and
  writes raw SQL, because the property is that PostgreSQL refuses the row —
  not that the application declines to build it.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgentsWeb.ConnCase, only: [github_user: 1]

  alias OpenAgents.Conversations
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  @insert """
  INSERT INTO inference_grants
    (id, owner_visitor_id, conversation_id, thread_id, machine_id, model_id,
     token_digest, status, max_total_tokens, max_calls, max_cost_microusd,
     call_count, usage, expires_at, inserted_at, updated_at)
  VALUES ($1, $2, $3, $4, NULL, 'model-under-test', $5, 'active',
          1000, 4, 1000, 0, '{}', $6, $6, $6)
  """

  setup do
    user = github_user("fence-#{System.unique_integer([:positive])}")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    {:ok, thread} = Threads.open(user, "Prove the fence")

    %{
      visitor_id: uuid(conversation.visitor_id),
      conversation_id: uuid(conversation.id),
      thread_id: uuid(thread.id),
      thread: thread,
      user: user
    }
  end

  describe "a grant names exactly one fence" do
    test "a conversation grant is admitted", context do
      assert {:ok, %{num_rows: 1}} =
               insert_grant(context.visitor_id, context.conversation_id, nil)
    end

    test "a thread grant is admitted", context do
      assert {:ok, %{num_rows: 1}} = insert_grant(context.visitor_id, nil, context.thread_id)
    end

    test "naming both is refused", context do
      assert {:error, %Postgrex.Error{} = error} =
               insert_grant(context.visitor_id, context.conversation_id, context.thread_id)

      assert error.postgres.constraint == "inference_grant_exactly_one_fence"
    end

    test "naming neither is refused", context do
      assert {:error, %Postgrex.Error{} = error} = insert_grant(context.visitor_id, nil, nil)
      assert error.postgres.constraint == "inference_grant_exactly_one_fence"
    end
  end

  describe "a thread holds at most one live grant" do
    test "a second active grant for the same thread is refused", context do
      assert {:ok, %{num_rows: 1}} = insert_grant(context.visitor_id, nil, context.thread_id)

      assert {:error, %Postgrex.Error{} = error} =
               insert_grant(context.visitor_id, nil, context.thread_id)

      assert error.postgres.constraint == "inference_grants_one_active_thread_index"
    end

    test "a revoked grant frees the slot", context do
      {:ok, _thread, grant, _token} = Threads.mint_grant(context.thread)
      {:ok, _revoked} = OpenAgents.Inference.revoke(grant)

      assert {:ok, %{num_rows: 1}} = insert_grant(context.visitor_id, nil, context.thread_id)
    end
  end

  describe "the immutability guard is NULL-safe on both fences" do
    test "a thread grant cannot acquire a conversation", context do
      {:ok, _thread, grant, _token} = Threads.mint_grant(context.thread)

      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(
                 "UPDATE inference_grants SET conversation_id = $1 WHERE id = $2",
                 [context.conversation_id, uuid(grant.id)]
               )

      assert error.postgres.message =~ "immutable identity/budget fields"
    end

    test "a conversation grant cannot acquire a thread", context do
      {:ok, grant, _token} =
        OpenAgents.Inference.mint(%{
          owner_visitor_id: context.thread.owner_visitor_id,
          conversation_id: Ecto.UUID.load!(context.conversation_id),
          machine_id: nil
        })

      assert {:error, %Postgrex.Error{} = error} =
               Repo.query(
                 "UPDATE inference_grants SET thread_id = $1 WHERE id = $2",
                 [context.thread_id, uuid(grant.id)]
               )

      assert error.postgres.message =~ "immutable identity/budget fields"
    end
  end

  defp insert_grant(visitor_id, conversation_id, thread_id) do
    now = DateTime.utc_now()

    Repo.query(@insert, [
      uuid(Ecto.UUID.generate()),
      visitor_id,
      conversation_id,
      thread_id,
      :crypto.strong_rand_bytes(32),
      DateTime.add(now, 900, :second)
    ])
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
