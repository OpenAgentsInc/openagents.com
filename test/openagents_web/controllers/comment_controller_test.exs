defmodule OpenAgentsWeb.CommentControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Issues

  setup do
    {:ok, issue} = Issues.create_issue(%{title: "Comment target"})
    %{issue: issue}
  end

  test "GET /api/v3/repos/:owner/:repo/issues/:issue_number/comments lists comments", %{
    conn: conn,
    issue: issue
  } do
    Issues.create_comment(%{issue_id: issue.id, body: "First comment"})

    conn =
      get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/#{issue.number}/comments")

    assert %{"comments" => [comment]} = json_response(conn, 200)
    assert comment["body"] == "First comment"
  end

  test "POST /api/v3/repos/:owner/:repo/issues/:issue_number/comments creates a comment", %{
    conn: conn,
    issue: issue
  } do
    conn =
      post(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/#{issue.number}/comments", %{
        body: "New comment"
      })

    assert %{"body" => "New comment"} = json_response(conn, 201)
  end

  test "GET /api/v3/repos/:owner/:repo/issues/comments/:id returns a comment", %{
    conn: conn,
    issue: issue
  } do
    {:ok, comment} = Issues.create_comment(%{issue_id: issue.id, body: "Show me"})

    conn =
      get(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/comments/#{comment.id}")

    assert %{"body" => "Show me"} = json_response(conn, 200)
  end

  test "PATCH /api/v3/repos/:owner/:repo/issues/comments/:id updates a comment", %{
    conn: conn,
    issue: issue
  } do
    {:ok, comment} = Issues.create_comment(%{issue_id: issue.id, body: "Before"})

    conn =
      patch(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/comments/#{comment.id}", %{
        body: "After"
      })

    assert %{"body" => "After"} = json_response(conn, 200)
  end

  test "DELETE /api/v3/repos/:owner/:repo/issues/comments/:id removes a comment", %{
    conn: conn,
    issue: issue
  } do
    {:ok, comment} = Issues.create_comment(%{issue_id: issue.id, body: "Delete me"})

    conn =
      delete(conn, ~p"/api/v3/repos/OpenAgents/openagents/issues/comments/#{comment.id}")

    assert response(conn, 204)
  end
end
