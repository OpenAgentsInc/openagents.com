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
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Reputation
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
    :push_receipt,
    :forum,
    :thread,
    :box,
    :computer,
    :agent,
    :deployment,
    :pull_request,
    :stack,
    :issue_dependency,
    :reputation
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

    # The ledger records no blocked family today: #142 opened the
    # private-repository metadata reads and #143 exported the forge-owned and
    # forum-owned families. The shape check stays rather than being deleted,
    # because the honest move when a family becomes unreadable is to record it
    # blocked, and this is what that record has to look like when it appears.
    test "a blocked family is probed here, not asserted from prose" do
      for entry <- ExportInventory.with_status(:blocked) do
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
        |> Repo.update!()

      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "exportable"})
      {:ok, _comment} = Issues.create_comment(issue, %{body: "a comment of mine"}, owner)
      _label = OpenAgents.LabelsFixtures.label_fixture(repository, %{name: "mine"})
      _milestone = OpenAgents.MilestonesFixtures.milestone_fixture(repository)
      _project = OpenAgents.ProjectsFixtures.project_fixture(repository, %{title: "my board"})

      {:ok, _credential, token} =
        ApiTokens.create(owner, %{name: "export inventory probe", scopes: ["forge:write"]})

      account_export = seed_and_export(owner, repository)

      %{
        conn: put_req_header(conn, "authorization", "Bearer " <> token),
        owner: owner,
        repository: repository,
        issue: issue,
        account_export: account_export
      }
    end

    test "the repository really is private, so a blocked probe means blocked", %{
      repository: repository
    } do
      assert repository.visibility == "private"

      assert build_conn()
             |> get(~p"/api/v1/repos/exit-owner/private-work/issues")
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

  ## ── the account-scoped export ──────────────────────────────────────────

  # Every family the ledger records as portable through GET /data/export/account
  # is probed by seeding one record and reading it back through the route, so a
  # portability claim here is a round trip and not a reading of the source.
  defp seed_and_export(owner, repository) do
    board =
      Repo.insert!(%OpenAgents.Forum.Forum{
        slug: "exit-inventory",
        title: "Exit inventory",
        visibility: "public"
      })

    topic =
      Repo.insert!(%OpenAgents.Forum.Topic{
        forum_id: board.id,
        idempotency_key: "exit-inventory-topic",
        slug: "exit-inventory-topic",
        title: "Mine",
        actor_ref: "user:" <> owner.id,
        actor_display_name: "exit-owner",
        post_count: 1
      })

    Repo.insert!(%OpenAgents.Forum.Post{
      topic_id: topic.id,
      idempotency_key: "exit-inventory-post",
      post_number: 1,
      body_text: "The account's own post.",
      actor_ref: "user:" <> owner.id,
      actor_display_name: "exit-owner"
    })

    {:ok, thread} = OpenAgents.Threads.open(owner, "Prove the export reaches a thread.")
    {:ok, _thread} = OpenAgents.Threads.record_event(thread, "thread.probe", %{"probe" => true})

    Repo.insert!(%OpenAgents.Forge.PushReceipt{
      repo: repository.storage_key,
      wal_seq: 0,
      principal: "user:" <> owner.id,
      refs: %{"refs/heads/main" => String.duplicate("0", 40)}
    })

    Repo.insert!(%OpenAgents.Machines.Machine{
      user_id: owner.id,
      name: "exit-inventory-computer",
      token_digest: :crypto.hash(:sha256, "exit-inventory"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    agent =
      Repo.insert!(%OpenAgents.Agents.Agent{
        handle: "exit-inventory-agent",
        display_name: "Exit inventory",
        registration_ip_digest: :crypto.hash(:sha256, "exit-inventory-agent")
      })

    Repo.insert!(%OpenAgents.Agents.AgentUserLink{agent_id: agent.id, user_id: owner.id})

    {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(owner)

    box =
      Repo.insert!(%OpenAgents.Box.ConversationBox{
        conversation_id: conversation.id,
        box_id: "box_exit_inventory",
        label: "exit-inventory",
        state: "ready"
      })

    now = DateTime.utc_now()

    Repo.insert!(%OpenAgents.Box.Run{
      conversation_id: conversation.id,
      conversation_box_id: box.id,
      requesting_principal: %{"kind" => "user", "id" => owner.id},
      idempotency_key: "exit-inventory-run",
      run_directory: "/tmp/exit-inventory-run",
      command: "echo exit",
      state: "completed",
      exit_status: 0,
      output: "exit\n",
      admitted_at: now,
      deadline_at: DateTime.add(now, 600, :second)
    })

    _environment = OpenAgents.DeploymentsFixtures.environment_fixture(repository, owner)
    _run = OpenAgents.DeploymentsFixtures.run_fixture(repository, owner)

    seed_repository_work(owner, repository)

    build_conn()
    |> Plug.Test.init_test_session(%{"user_id" => owner.id})
    |> get(~p"/data/export/account")
    |> json_response(200)
  end

  # The three repository-keyed families the account export reads across every
  # repository. They are seeded in the same private repository the metadata
  # probes use, so a widened read that lost the readable_by join would still
  # pass here — that direction is proven in the account export's own test,
  # where the account is not a member.
  defp seed_repository_work(owner, repository) do
    issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "PR exit-inventory"})

    {:ok, pull_request} =
      %OpenAgents.PullRequests.PullRequest{}
      |> OpenAgents.PullRequests.PullRequest.changeset(%{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: repository.id,
        opened_by_user_id: owner.id,
        head_ref: "exit-inventory-branch",
        head_sha: String.duplicate("b", 40),
        base_ref: "main",
        base_sha: String.duplicate("c", 40),
        state: "open"
      })
      |> Repo.insert()

    {:ok, _stack} = OpenAgents.Stacks.create(repository, [pull_request], owner)

    blocked = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "exit blocked"})
    blocker = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "exit blocker"})
    :ok = Issues.add_dependencies(blocked, [blocker.number], owner)

    seed_attestation(owner, repository)

    :ok
  end

  # A reputation attestation names its subject with a bare string, so the seed
  # has to establish the binding as well as the record: a claim the account
  # makes and the operator decides. Without the linked claim the export
  # returns nothing here, which is what this family recorded before #171.
  defp seed_attestation(owner, repository) do
    {:ok, claim} =
      Reputation.claim_subject(owner, %{
        subject_kind: "account",
        subject_id: "user:" <> owner.id
      })

    {:ok, _linked} = Reputation.approve_subject_claim(claim)

    issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "exit attested"})

    policy =
      case Reputation.admit_policy(%{
             authenticated: true,
             actor_id: "operator:export-inventory",
             auth_method: "test_session",
             approval_receipt_ref: "export-inventory:#{System.unique_integer([:positive])}"
           }) do
        {:ok, policy} -> policy
        {:error, _already_admitted} -> List.last(Reputation.policies())
      end

    keypair = OpenAgents.Reputation.Claim.generate_keypair()

    {:ok, key} =
      Reputation.admit_key(%{public_key: keypair.public_key, issuer: "export-inventory"})

    decision = OpenAgents.CompensationFixtures.outcome_decision_fixture()

    {:ok, _attestation} =
      Reputation.issue(policy, %{key_id: key.key_id, private_key: keypair.private_key}, %{
        event_type: "completion",
        subject_id: "user:" <> owner.id,
        outcome: %{kind: "compensation_outcome_decision", ref: decision.decision_receipt_ref},
        repository: repository,
        issue_number: issue.number,
        revision: String.duplicate("a", 40),
        artifact_digest: String.duplicate("1", 64),
        confidence_ppm: 900_000,
        transparency_tier: "repository",
        evidence: [
          %{
            kind: "outcome",
            ref: decision.decision_receipt_ref,
            digest: decision.outcome_digest,
            observed_at: DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      })

    :ok
  end

  ## ── probes ─────────────────────────────────────────────────────────────

  defp probe(:reputation, %{account_export: export}) do
    attestations = export["repository_work"]["attestations"]

    if Enum.any?(
         attestations["records"],
         &(&1["subject_id"] in attestations["established_subjects"])
       ),
       do: :portable,
       else: :partial
  end

  defp probe(:pull_request, %{account_export: export}) do
    if Enum.any?(
         export["repository_work"]["pull_requests"]["records"],
         &(&1["head_ref"] == "exit-inventory-branch")
       ),
       do: :portable,
       else: :partial
  end

  defp probe(:stack, %{account_export: export}) do
    stack = List.first(export["repository_work"]["stacks"]["records"])

    cond do
      stack == nil -> :partial
      Enum.any?(stack["entries"], &(&1["head_ref"] == "exit-inventory-branch")) -> :portable
      true -> :partial
    end
  end

  defp probe(:issue_dependency, %{account_export: export}) do
    if Enum.any?(
         export["repository_work"]["issue_dependencies"]["records"],
         &(&1["blocked_by_issue_title"] == "exit blocker")
       ),
       do: :portable,
       else: :partial
  end

  defp probe(:forum, %{account_export: export}) do
    if Enum.any?(export["forum"]["posts"], &(&1["body_text"] == "The account's own post.")) and
         Enum.any?(export["forum"]["topics"], &(&1["title"] == "Mine")),
       do: :portable,
       else: :partial
  end

  defp probe(:thread, %{account_export: export}) do
    thread = Enum.find(export["threads"]["records"], &(&1["objective"] =~ "Prove the export"))

    cond do
      thread == nil -> :partial
      Enum.any?(thread["events"], &(&1["event_type"] == "thread.probe")) -> :portable
      true -> :partial
    end
  end

  defp probe(:box, %{account_export: export}) do
    if Enum.any?(export["boxes"]["leases"], &(&1["box_id"] == "box_exit_inventory")) and
         Enum.any?(export["boxes"]["runs"], &(&1["command"] == "echo exit")),
       do: :portable,
       else: :partial
  end

  defp probe(:computer, %{account_export: export}) do
    if Enum.any?(export["computers"], &(&1["name"] == "exit-inventory-computer")),
      do: :portable,
      else: :partial
  end

  defp probe(:agent, %{account_export: export}) do
    if Enum.any?(export["agent_links"], &(&1["agent"]["handle"] == "exit-inventory-agent")),
      do: :portable,
      else: :partial
  end

  defp probe(:deployment, %{account_export: export}) do
    if export["deployments"]["requests"] != [], do: :portable, else: :partial
  end

  defp probe(:issue, %{conn: conn, issue: issue}) do
    case get(conn, ~p"/api/v1/repos/exit-owner/private-work/issues") do
      %{status: 200} = response ->
        numbers =
          response |> json_response(200) |> Map.fetch!("issues") |> Enum.map(& &1["number"])

        if issue.number in numbers, do: :portable, else: :partial

      _refused ->
        :blocked
    end
  end

  defp probe(:project, %{conn: conn}) do
    case get(conn, ~p"/api/v1/repos/exit-owner/private-work/projectsV2") do
      %{status: 200} = response ->
        titles =
          response |> json_response(200) |> Map.fetch!("projects") |> Enum.map(& &1["title"])

        if "my board" in titles, do: :portable, else: :partial

      _refused ->
        :blocked
    end
  end

  defp probe(:repository, %{conn: conn}) do
    case get(conn, ~p"/api/v1/user/repos") do
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
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/issues/#{issue.number}/comments")
  end

  defp probe(:label, %{conn: conn}) do
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/labels")
  end

  defp probe(:milestone, %{conn: conn}) do
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/milestones")
  end

  defp probe(:assignee, %{conn: conn}) do
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/assignees")
  end

  defp probe(:issue_label, %{conn: conn, issue: issue}) do
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/issues/#{issue.number}/labels")
  end

  defp probe(:issue_assignee, %{conn: conn, issue: issue}) do
    read_probe(conn, ~p"/api/v1/repos/exit-owner/private-work/issues/#{issue.number}/assignees")
  end

  # No /api/v1 route serves receipts and none is expected to; the claim is that
  # the account export returns the account's own rows, so that is what is
  # probed. A receipt whose principal is not this account must not appear.
  defp probe(:push_receipt, %{account_export: export, owner: owner}) do
    records = export["push_receipts"]["records"]
    principals = records |> Enum.map(& &1["principal"]) |> Enum.uniq()

    cond do
      records == [] -> :blocked
      principals != ["user:" <> owner.id] -> :partial
      true -> :portable
    end
  end

  defp read_probe(conn, path) do
    case get(conn, path) do
      %{status: 200} -> :portable
      _refused -> :blocked
    end
  end
end
