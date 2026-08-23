defmodule OpenAgents.DataRights.ExportInventoryTest do
  @moduledoc """
  EXIT-001. The export ledger has to match the surface in both directions.

  A test that only checked the `:portable` claims would let the ledger go
  pessimistic without anyone noticing, and a fix that quietly closed a gap
  would leave a stale "you cannot export this" standing in the documentation.
  So every probed family is asserted against observed behavior, and a family
  that starts working turns this red until the ledger is corrected.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens
  alias OpenAgents.DataRights.ExportInventory
  alias OpenAgents.Issues
  alias OpenAgents.Repositories
  alias OpenAgentsWeb.ApiRouteAuthority

  # Families whose recorded status this test observes rather than trusts.
  @probed [
    :issue,
    :project,
    :repository,
    :comment,
    :label,
    :milestone,
    :assignee,
    :issue_label,
    :issue_assignee,
    :push_receipt
  ]

  describe "coverage" do
    test "every published API family is classified, and no stale family remains" do
      assert ExportInventory.api_family_drift() == %{unclassified: [], stale: []}
      assert ApiRouteAuthority.families() != []
    end

    test "each family appears once" do
      families = Enum.map(ExportInventory.entries(), & &1.family)
      assert families == Enum.uniq(families)
    end
  end

  describe "claim discipline" do
    test "a portable claim names a mechanism and a proof, and owes no issue" do
      for entry <- ExportInventory.with_status(:portable) do
        assert is_binary(entry.mechanism) and entry.mechanism != "",
               "#{entry.family} is portable with no mechanism"

        assert entry.proof != nil, "#{entry.family} is portable with no proof"
        assert entry.issue == nil, "#{entry.family} is portable and still names an issue"
      end
    end

    test "a blocked family is probed here, not asserted from prose" do
      blocked = ExportInventory.with_status(:blocked)
      assert blocked != []

      for entry <- blocked do
        assert entry.proof == :inventory, "#{entry.family} is blocked without a probe"
        assert entry.mechanism == nil, "#{entry.family} is blocked and still names a mechanism"
        assert is_integer(entry.issue) and entry.issue > 0
      end
    end

    test "a gap names the open issue that closes it" do
      for entry <- ExportInventory.with_status(:partial) do
        assert is_integer(entry.issue) and entry.issue > 0,
               "#{entry.family} is partial with no issue"
      end
    end

    test "a family excluded as non-user data says why and claims nothing" do
      for entry <- ExportInventory.with_status(:not_user_data) do
        assert String.length(entry.note) > 20, "#{entry.family} is excluded without a reason"
        assert entry.mechanism == nil
        assert entry.proof == nil
        assert entry.issue == nil
      end
    end

    test "every named proof resolves to a file or a current invariant" do
      ledger = File.read!("INVARIANTS.md")

      for entry <- ExportInventory.entries() do
        case entry.proof do
          {:test, path} ->
            assert File.exists?(path), "#{entry.family} names missing proof #{path}"

          {:invariant, id} ->
            assert String.contains?(ledger, "### #{id} — "),
                   "#{entry.family} names missing invariant #{id}"

          _inventory_or_none ->
            :ok
        end
      end
    end

    test "every probed family is in the ledger and every probe has a family" do
      classified = Enum.map(ExportInventory.entries(), & &1.family)
      assert @probed -- classified == []
    end
  end

  describe "probes" do
    setup %{conn: conn} do
      owner = github_user("export-inventory-owner", "exit-owner")

      {:ok, repository, :created} =
        Repositories.create_user_repository(
          owner,
          %{name: "private-work", visibility: "private"},
          "export-inventory-create"
        )

      repository =
        repository
        |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
        |> OpenAgents.Repo.update!()

      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "exportable"})
      {:ok, _comment} = Issues.create_comment(issue, %{body: "a comment of mine"}, owner)
      _label = OpenAgents.LabelsFixtures.label_fixture(repository, %{name: "mine"})
      _milestone = OpenAgents.MilestonesFixtures.milestone_fixture(repository)
      _project = OpenAgents.ProjectsFixtures.project_fixture(repository, %{title: "my board"})

      {:ok, _credential, token} =
        ApiTokens.create(owner, %{name: "export inventory probe", scopes: ["forge:write"]})

      %{
        conn: put_req_header(conn, "authorization", "Bearer " <> token),
        owner: owner,
        repository: repository,
        issue: issue
      }
    end

    test "the repository really is private, so a blocked probe means blocked", %{
      repository: repository
    } do
      assert repository.visibility == "private"

      assert build_conn()
             |> get(~p"/api/v3/repos/exit-owner/private-work/issues")
             |> json_response(404)
    end

    test "each probed family behaves the way the ledger records", context do
      for family <- @probed do
        entry = ExportInventory.entry(family)
        observed = probe(family, context)

        assert observed == entry.status,
               "#{family}: the ledger records #{inspect(entry.status)} but the surface is " <>
                 "#{inspect(observed)}. Update OpenAgents.DataRights.ExportInventory in the " <>
                 "same change that moved the surface."
      end
    end
  end

  ## ── probes ─────────────────────────────────────────────────────────────

  defp probe(:issue, %{conn: conn, issue: issue}) do
    case get(conn, ~p"/api/v3/repos/exit-owner/private-work/issues") do
      %{status: 200} = response ->
        numbers =
          response |> json_response(200) |> Map.fetch!("issues") |> Enum.map(& &1["number"])

        if issue.number in numbers, do: :portable, else: :partial

      _refused ->
        :blocked
    end
  end

  defp probe(:project, %{conn: conn}) do
    case get(conn, ~p"/api/v3/repos/exit-owner/private-work/projectsV2") do
      %{status: 200} = response ->
        titles =
          response |> json_response(200) |> Map.fetch!("projects") |> Enum.map(& &1["title"])

        if "my board" in titles, do: :portable, else: :partial

      _refused ->
        :blocked
    end
  end

  defp probe(:repository, %{conn: conn}) do
    case get(conn, ~p"/api/v3/user/repos") do
      %{status: 200} = response ->
        names =
          response
          |> json_response(200)
          |> then(fn body -> body["repositories"] || body end)
          |> Enum.map(& &1["name"])

        if "private-work" in names, do: :portable, else: :partial

      _refused ->
        :blocked
    end
  end

  defp probe(:comment, %{conn: conn, issue: issue}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/issues/#{issue.number}/comments")
  end

  defp probe(:label, %{conn: conn}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/labels")
  end

  defp probe(:milestone, %{conn: conn}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/milestones")
  end

  defp probe(:assignee, %{conn: conn}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/assignees")
  end

  defp probe(:issue_label, %{conn: conn, issue: issue}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/issues/#{issue.number}/labels")
  end

  defp probe(:issue_assignee, %{conn: conn, issue: issue}) do
    read_probe(conn, ~p"/api/v3/repos/exit-owner/private-work/issues/#{issue.number}/assignees")
  end

  # A receipt family cannot be probed by calling a route, because the point is
  # that no route exists. Ask the published inventory instead: a read route
  # that serves push receipts would have to be classified there first.
  defp probe(:push_receipt, _context) do
    serves_receipts? =
      ApiRouteAuthority.inventory_entries()
      |> Enum.reject(& &1["mutation"])
      |> Enum.any?(fn route ->
        route["family"] == "push_receipt" or String.contains?(route["path"], "/receipts")
      end)

    if serves_receipts?, do: :portable, else: :blocked
  end

  defp read_probe(conn, path) do
    case get(conn, path) do
      %{status: 200} -> :portable
      _refused -> :blocked
    end
  end
end
