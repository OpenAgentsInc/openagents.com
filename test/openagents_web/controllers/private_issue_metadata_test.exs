defmodule OpenAgentsWeb.PrivateIssueMetadataTest do
  @moduledoc """
  Issue metadata reads for a private repository, from three principals.

  The six ancillary issue families — comments, labels, milestones, assignees,
  issue labels, and issue assignees — resolved through a public-only query, so
  a private repository answered `404` to its own owner. These tests fix the
  three answers that matter: a member reads their own records, an anonymous
  caller sees what it saw before, and a non-member cannot tell a private
  repository from one that does not exist.
  """

  use OpenAgentsWeb.ConnCase

  import OpenAgents.IssuesFixtures
  import OpenAgents.LabelsFixtures
  import OpenAgents.MilestonesFixtures

  alias OpenAgents.Issues
  alias OpenAgents.Repositories

  setup %{conn: conn} do
    owner = github_user("private-metadata-owner", "metadata-owner")

    repository =
      repository_with_member_fixture(owner, %{
        owner: "metadata-owner",
        name: "private-work",
        visibility: "private"
      })

    issue = issue_fixture(repository, %{title: "a private issue"})
    {:ok, comment} = Issues.create_comment(issue, %{body: "a comment of mine"}, owner)
    {:ok, issue} = Issues.add_labels(issue, ["mine"], owner)
    {:ok, issue} = Issues.add_assignees(issue, [owner.github_login], owner)
    label = label_fixture(repository, %{name: "shipped", color: "0075ca"})
    milestone = milestone_fixture(repository, %{title: "first release", number: 1})

    %{
      owner: owner,
      repository: repository,
      issue: issue,
      comment: comment,
      label: label,
      milestone: milestone,
      member_conn: put_forge_api_token(conn, "private-metadata-member", repository),
      outsider_conn: put_forge_api_token(conn, "private-metadata-outsider")
    }
  end

  defp paths(%{issue: issue, comment: comment, label: label, milestone: milestone, owner: owner}) do
    base = "/api/v3/repos/metadata-owner/private-work"

    %{
      "issue comments" => "#{base}/issues/#{issue.number}/comments",
      "one comment" => "#{base}/issues/comments/#{comment.id}",
      "issue labels" => "#{base}/issues/#{issue.number}/labels",
      "issue assignees" => "#{base}/issues/#{issue.number}/assignees",
      "labels" => "#{base}/labels",
      "one label" => "#{base}/labels/#{label.name}",
      "milestones" => "#{base}/milestones",
      "one milestone" => "#{base}/milestones/#{milestone.number}",
      "assignees" => "#{base}/assignees",
      "one assignee" => "#{base}/assignees/#{owner.github_login}"
    }
  end

  describe "a member of a private repository" do
    test "reads every issue metadata family with a bearer token", context do
      for {name, path} <- paths(context) do
        conn = get(context.member_conn, path)

        assert conn.status == 200,
               "#{name} answered #{conn.status} to a member of the private repository"
      end
    end

    test "reads the records themselves, not an empty envelope", context do
      %{member_conn: conn, issue: issue, comment: comment} = context

      assert %{"comments" => [read]} =
               conn
               |> get("/api/v3/repos/metadata-owner/private-work/issues/#{issue.number}/comments")
               |> json_response(200)

      assert read["id"] == comment.id
      assert read["body"] == "a comment of mine"

      assert %{"labels" => labels} =
               conn
               |> get("/api/v3/repos/metadata-owner/private-work/labels")
               |> json_response(200)

      assert "shipped" in Enum.map(labels, & &1["name"])

      assert %{"milestones" => [milestone]} =
               conn
               |> get("/api/v3/repos/metadata-owner/private-work/milestones")
               |> json_response(200)

      assert milestone["title"] == "first release"

      assert %{"assignees" => assignees} =
               conn
               |> get("/api/v3/repos/metadata-owner/private-work/assignees")
               |> json_response(200)

      assert context.owner.github_login in Enum.map(assignees, & &1["login"])

      assert %{"labels" => [issue_label]} =
               conn
               |> get("/api/v3/repos/metadata-owner/private-work/issues/#{issue.number}/labels")
               |> json_response(200)

      assert issue_label["name"] == "mine"
    end
  end

  describe "a caller with no claim on the repository" do
    test "an anonymous caller cannot tell the private repository from a missing one", context do
      for {name, path} <- paths(context) do
        absent = String.replace(path, "/metadata-owner/private-work", "/nobody/nonexistent")

        private_body = build_conn() |> get(path) |> assert_api_error(404, "not_found")
        absent_body = build_conn() |> get(absent) |> assert_api_error(404, "not_found")

        assert Map.delete(private_body, "request_id") == Map.delete(absent_body, "request_id"),
               "#{name} answers a private repository differently from an absent one"
      end
    end

    test "a member of another repository gets the same refusal", context do
      for {name, path} <- paths(context) do
        absent = String.replace(path, "/metadata-owner/private-work", "/nobody/nonexistent")

        private_body = context.outsider_conn |> get(path) |> assert_api_error(404, "not_found")
        absent_body = context.outsider_conn |> get(absent) |> assert_api_error(404, "not_found")

        assert Map.delete(private_body, "request_id") == Map.delete(absent_body, "request_id"),
               "#{name} discloses the private repository to a non-member"
      end
    end
  end

  describe "a public repository" do
    setup do
      repository =
        repository_fixture(%{
          owner: "metadata-public",
          name: "open-work",
          visibility: "public"
        })

      issue = issue_fixture(repository, %{title: "a public issue"})
      {:ok, comment} = Issues.create_comment(issue, %{body: "a public comment"})
      _label = label_fixture(repository, %{name: "shipped", color: "0075ca"})
      _milestone = milestone_fixture(repository, %{title: "first release", number: 1})

      %{public_issue: issue, public_comment: comment, public_repository: repository}
    end

    test "still answers an anonymous caller exactly as before", %{
      public_issue: issue,
      public_comment: comment
    } do
      base = "/api/v3/repos/metadata-public/open-work"

      for path <- [
            "#{base}/issues/#{issue.number}/comments",
            "#{base}/issues/comments/#{comment.id}",
            "#{base}/issues/#{issue.number}/labels",
            "#{base}/issues/#{issue.number}/assignees",
            "#{base}/labels",
            "#{base}/labels/shipped",
            "#{base}/milestones",
            "#{base}/milestones/1",
            "#{base}/assignees"
          ] do
        assert build_conn() |> get(path) |> Map.get(:status) == 200,
               "#{path} stopped answering an anonymous caller"
      end

      assert %{"comments" => [read]} =
               build_conn()
               |> get("#{base}/issues/#{issue.number}/comments")
               |> json_response(200)

      assert read["body"] == "a public comment"
    end

    test "a bearer token widens nothing that was already public", %{
      conn: conn,
      public_issue: issue
    } do
      base = "/api/v3/repos/metadata-public/open-work"
      path = "#{base}/issues/#{issue.number}/comments"

      anonymous = build_conn() |> get(path) |> json_response(200)

      authenticated =
        conn
        |> put_forge_api_token("private-metadata-stranger")
        |> get(path)
        |> json_response(200)

      assert anonymous == authenticated
    end
  end

  describe "the repository really is private" do
    test "so a refusal means the visibility predicate ran", %{repository: repository} do
      assert repository.visibility == "private"
      assert Repositories.get_by_path!("metadata-owner", "private-work").id == repository.id
    end
  end
end
