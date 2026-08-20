defmodule OpenAgentsWeb.AtifExportControllerTest do
  use OpenAgentsWeb.SarahConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations.Visitor
  alias OpenAgents.{Conversations, Repo}

  test "the account owner downloads one ATIF v1.7 attachment for the conversation", %{
    conn: conn
  } do
    token = "atif-export-owner-browser-credential-0000000000000"
    user = github_user(token)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    Repo.insert!(%OpenAgents.Conversations.Message{
      conversation_id: conversation.id,
      role: "user",
      content: "Export me as a trajectory.",
      status: "complete"
    })

    Repo.insert!(%OpenAgents.Conversations.Message{
      conversation_id: conversation.id,
      role: "assistant",
      content: "One trajectory, coming up.",
      status: "complete"
    })

    conn =
      conn
      |> log_in_github_user(token)
      |> get(~p"/data/export/atif")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "sarah-conversation-#{conversation.id}-atif.json"

    export = json_response(conn, 200)
    assert export["schema_version"] == "ATIF-v1.7"
    assert export["session_id"] == conversation.id
    assert export["trajectory_id"] == conversation.id
    assert export["agent"]["name"] == "simply-sarah"

    # Sarah's seeded greeting opens the conversation, then the two inserts.
    assert [
             %{"step_id" => 1, "source" => "agent"},
             %{"step_id" => 2, "source" => "user", "message" => "Export me as a trajectory."},
             %{"step_id" => 3, "source" => "agent", "message" => "One trajectory, coming up."}
           ] = export["steps"]

    assert export["final_metrics"]["total_steps"] == 3
  end

  test "an anonymous request redirects before any data loads", %{conn: conn} do
    response = get(conn, ~p"/data/export/atif")

    assert redirected_to(response) == ~p"/"
    assert Repo.aggregate(Visitor, :count) == 0
  end

  test "the chat command bar carries the export chip as a download link", %{conn: conn} do
    conn = log_in_github_user(conn, "atif-export-chip-browser")
    assert {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, ~s(a#export-atif[href="/data/export/atif"][download]))
  end
end
