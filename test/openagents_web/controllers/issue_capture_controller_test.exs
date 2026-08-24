defmodule OpenAgentsWeb.IssueCaptureControllerTest do
  @moduledoc """
  `POST /api/v3/repos/:owner/:repo/issues/capture` (#77).

  The API operation and the `capture_issue` chat tool are two transports over
  `OpenAgents.Issues.Capture`, so what this file proves is that the transport
  does not lose anything: the same draft, the same authorization decision, and
  the same deduplication answer reach a client that never opens a chat.
  """

  use OpenAgentsWeb.ConnCase

  import OpenAgents.AccountsFixtures

  alias OpenAgents.{Issues, Repositories}

  describe "capturing a request" do
    setup %{conn: conn} do
      {:ok, conn: put_forge_api_token(conn, "issue-capture", repository())}
    end

    test "POST .../issues/capture files a drafted issue and answers 201", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "Let me export a board to CSV.",
          current_behavior: "The board only renders on screen.",
          acceptance_criteria: ["A CSV downloads"]
        })

      assert %{"number" => number, "title" => title, "body" => body, "state" => "open"} =
               json_response(conn, 201)

      assert title == "Let me export a board to CSV"
      assert body =~ "## Outcome"
      assert body =~ "## Current behavior"
      assert body =~ "## Acceptance criteria"
      assert body =~ "- [ ] A CSV downloads"

      assert Issues.get_issue_by_number!(repository(), number).title == title
    end

    # Retrying is the normal client behavior, and #77 requires it return the
    # issue already filed. The status is what carries the difference, so a
    # client can tell the two apart without a body key of ours.
    test "a repeat answers 200 with the same issue", %{conn: conn} do
      created =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "Let me export a board to CSV."
        })

      assert %{"number" => number} = json_response(created, 201)

      repeated =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "let me export a board to CSV!"
        })

      assert %{"number" => ^number} = json_response(repeated, 200)
      assert length(Issues.list_issues(repository(), state: "all")) == 1
    end

    test "a blank statement is a validation failure, not a filed issue", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{problem: "  "})

      assert %{"code" => "validation_failed", "errors" => errors} = json_response(conn, 422)
      assert errors["problem"] == ["can't be blank"]
      assert Issues.list_issues(repository(), state: "all") == []
    end
  end

  describe "authorization is the caller's" do
    test "a reader who cannot write is told which role is missing", %{conn: conn} do
      reader = github_user("api-token-issue-capture-reader")
      {:ok, _membership} = Repositories.add_member(repository(), reader, "viewer")
      conn = put_forge_api_token(conn, "issue-capture-reader")

      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "Let me export a board to CSV."
        })

      assert %{"code" => "repository_write_access_required", "message" => message} =
               json_response(conn, 403)

      assert message =~ "owner, maintainer, or contributor"
      assert Issues.list_issues(repository(), state: "all") == []
    end

    # The refusal above is only safe to give for a repository the caller can
    # already read. One they cannot read stays a 404.
    test "a private repository the caller cannot see stays a 404", %{conn: conn} do
      owner = github_user("issue-capture-private-owner")
      private = repository_with_member_fixture(owner, %{visibility: "private"}, "owner")

      conn = put_forge_api_token(conn, "issue-capture-private-stranger")

      conn =
        post(conn, ~p"/api/v3/repos/#{private.owner}/#{private.name}/issues/capture", %{
          problem: "Let me export a board to CSV."
        })

      assert json_response(conn, 404)
    end

    test "an anonymous caller is refused before the controller runs", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "Let me export a board to CSV."
        })

      assert json_response(conn, 401)
      assert Issues.list_issues(repository(), state: "all") == []
    end

    # Filing under a personal membership is the point of the operation, and an
    # agent principal holds none, so it is refused rather than silently filed
    # under nobody.
    test "an agent credential cannot capture", %{conn: conn} do
      {:ok, _agent, credential} =
        OpenAgents.Agents.register(%{
          handle: "issue-capture-agent",
          display_name: "Issue capture agent",
          registration_ip: "192.0.2.77"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{credential}")
        |> post(~p"/api/v3/repos/OpenAgentsInc/openagents.com/issues/capture", %{
          problem: "Let me export a board to CSV."
        })

      assert json_response(conn, 403)
      assert Issues.list_issues(repository(), state: "all") == []
    end
  end

  defp repository do
    Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
  end
end
