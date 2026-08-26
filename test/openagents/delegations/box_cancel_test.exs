defmodule OpenAgents.Delegations.BoxCancelTest do
  @moduledoc """
  The delegation surface is the second consumer of `BoxRuns.cancel/1`, and it
  reads the same association the run projection does. A run returned without
  `:conversation_box` preloaded fails here exactly as it fails in the controller.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Box.Run
  alias OpenAgents.Conversations
  alias OpenAgents.Delegations
  alias OpenAgents.Repo

  test "cancelling a box delegation answers with the delegation projection" do
    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: 918_273,
        github_login: "delegation-box-cancel",
        github_avatar_url: "https://avatars.githubusercontent.com/u/918273?v=4"
      })

    {:ok, conversation} = Conversations.ensure_conversation(user)

    box =
      %ConversationBox{}
      |> ConversationBox.changeset(%{
        conversation_id: conversation.id,
        box_id: "bx_8bhkse3n",
        state: "ready",
        setup_status: "done"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    id = Ecto.UUID.generate()

    run =
      %Run{id: id}
      |> Run.changeset(%{
        conversation_id: conversation.id,
        conversation_box_id: box.id,
        requesting_principal: %{"type" => "user", "id" => user.id},
        command: "echo delegated",
        idempotency_key: "delegation-cancel",
        state: "completed",
        exit_status: 0,
        output: "delegated",
        last_output_offset: 9,
        run_directory: "$HOME/.openagents/box-runs/users/#{user.id}/#{id}",
        admitted_at: now,
        dispatch_attempted_at: now,
        finished_at: now,
        deadline_at: DateTime.add(now, 60, :second)
      })
      |> Repo.insert!()

    caller = %{user: user, agent: nil, scopes: ["box:control"]}

    assert {:ok, projection} =
             Delegations.cancel(caller, conversation.id, "box-run:" <> run.id)

    assert projection["id"] == "box-run:" <> run.id
    assert projection["kind"] == "box"
    assert projection["target_id"] == "box:" <> box.id
    assert projection["state"] == "completed"
  end
end
