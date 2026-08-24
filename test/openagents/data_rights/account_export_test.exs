defmodule OpenAgents.DataRights.AccountExportTest do
  @moduledoc """
  The proof behind every `:portable` claim `OpenAgents.DataRights.ExportInventory`
  names `GET /data/export/account` for.

  Three questions, and the ledger is only honest if all three hold: does an
  account get its own records back, does it get *only* its own, and does the
  document say what it leaves out.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Ecto.Query

  alias OpenAgents.DataRights.AccountExport
  alias OpenAgents.Deployments.Approval
  alias OpenAgents.Deployments.Request
  alias OpenAgents.DeploymentsFixtures
  alias OpenAgents.Forum
  alias OpenAgents.Forum.{Post, TipDestination, Topic}
  alias OpenAgents.Forum.Forum, as: Board
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Issues
  alias OpenAgents.Machines.Machine
  alias OpenAgents.PullRequests.PullRequest
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Membership
  alias OpenAgents.Reputation
  alias OpenAgents.Stacks
  alias OpenAgents.Threads

  setup do
    board =
      Repo.insert!(%Board{
        slug: "account-export",
        title: "Account export",
        visibility: "public"
      })

    %{board: board}
  end

  describe "what the account gets back" do
    test "forum topics and posts written on this surface come back", %{board: board} do
      user = github_user("account-export-forum", "export-forum")
      topic = topic_fixture(board, "user:" <> user.id, "Mine")
      post = post_fixture(topic, "user:" <> user.id, "A post I wrote.")

      assert {:ok, export} = AccountExport.build(user)

      assert [exported_topic] = export["forum"]["topics"]
      assert exported_topic["id"] == topic.id
      assert exported_topic["board_slug"] == "account-export"

      assert [exported_post] = export["forum"]["posts"]
      assert exported_post["id"] == post.id
      assert exported_post["body_text"] == "A post I wrote."
      assert exported_post["topic_slug"] == topic.slug
      refute export["forum"]["posts_truncated"]
    end

    test "threads and their transcripts come back", %{board: _board} do
      user = github_user("account-export-thread", "export-thread")
      {:ok, thread} = Threads.open(user, "Export the account's own work.")
      {:ok, _thread} = Threads.record_event(thread, "thread.opened", %{"note" => "first"})

      assert {:ok, export} = AccountExport.build(user)

      assert [exported] = export["threads"]["records"]
      assert exported["id"] == thread.id
      assert exported["objective"] == "Export the account's own work."

      assert %{"payload" => %{"note" => "first"}} =
               Enum.find(exported["events"], &(&1["payload"] == %{"note" => "first"}))

      assert exported["events_exported"] == length(exported["events"])
      refute export["threads"]["records_truncated"]
      refute export["threads"]["events_truncated"]
    end

    test "push receipts come back with the WAL sequence a clone does not carry" do
      user = github_user("account-export-push", "export-push")

      receipt =
        Repo.insert!(%PushReceipt{
          repo: "export-push/work.git",
          wal_seq: 7,
          principal: "user:" <> user.id,
          refs: %{"refs/heads/main" => "0" |> String.duplicate(40)},
          duration_ms: 12
        })

      assert {:ok, export} = AccountExport.build(user)
      assert [exported] = export["push_receipts"]["records"]
      assert exported["id"] == receipt.id
      assert exported["wal_seq"] == 7
      assert exported["refs"] == receipt.refs
    end

    test "paired computers, agent links, and Box work come back" do
      user = github_user("account-export-fleet", "export-fleet")

      Repo.insert!(%Machine{
        user_id: user.id,
        name: "workshop",
        platform: "darwin-arm64",
        token_digest: :crypto.hash(:sha256, "export-fleet-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      agent =
        Repo.insert!(%OpenAgents.Agents.Agent{
          handle: "export-fleet-agent",
          display_name: "Fleet",
          registration_ip_digest: :crypto.hash(:sha256, "export-fleet")
        })

      {:ok, _link} = OpenAgents.Agents.request_link(agent, user)

      {:ok, conversation} = OpenAgents.Conversations.ensure_conversation(user)

      box =
        Repo.insert!(%OpenAgents.Box.ConversationBox{
          conversation_id: conversation.id,
          box_id: "box_export_fleet",
          label: "export",
          state: "ready"
        })

      Repo.insert!(%OpenAgents.Box.Run{
        conversation_id: conversation.id,
        conversation_box_id: box.id,
        requesting_principal: %{"kind" => "user", "id" => user.id},
        idempotency_key: "account-export-run",
        run_directory: "/tmp/account-export-run",
        admitted_at: DateTime.utc_now(),
        deadline_at: DateTime.add(DateTime.utc_now(), 600, :second),
        command: "echo mine",
        state: "completed",
        exit_status: 0,
        output: "mine\n"
      })

      assert {:ok, export} = AccountExport.build(user)

      assert [computer] = export["computers"]
      assert computer["name"] == "workshop"

      assert [link] = export["agent_links"]
      assert link["agent"]["handle"] == "export-fleet-agent"

      assert [lease] = export["boxes"]["leases"]
      assert lease["box_id"] == "box_export_fleet"

      assert [run] = export["boxes"]["runs"]
      assert run["command"] == "echo mine"
      assert run["output"] == "mine\n"
      refute run["output_truncated"]
    end

    test "deployment requests and approvals the account authored come back" do
      user = github_user("account-export-deploy", "export-deploy")

      {:ok, repository, :created} =
        Repositories.create_user_repository(
          user,
          %{name: "shipping", visibility: "private"},
          "account-export-deploy"
        )

      repository =
        repository
        |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
        |> Repo.update!()

      _environment = OpenAgents.DeploymentsFixtures.environment_fixture(repository, user)
      _run = OpenAgents.DeploymentsFixtures.run_fixture(repository, user)

      assert {:ok, export} = AccountExport.build(user)
      assert [request] = export["deployments"]["requests"]
      assert request["commit_sha"] == OpenAgents.DeploymentsFixtures.commit_sha()
      assert request["repository"] == "export-deploy/shipping"
    end
  end

  # The repository's current owner and name are the repository's, not the
  # account's, and `readable_by/2` is the only thing withholding them here:
  # each account gets these records back through a column naming it, so no
  # other gate stands between the export and the path. Replacing the
  # `readable_repositories/1` subquery with the repositories table turns every
  # assertion in this block red and nothing else in this file.
  describe "a repository the account can no longer read" do
    test "a push receipt keeps every field that is the account's own and loses the path" do
      user = github_user("account-export-push-gone", "export-push-gone")
      owner = github_user("account-export-push-owner", "export-push-owner")
      repository = private_repository_with_member("export-push-private", owner)
      {:ok, _membership} = Repositories.add_member(repository, user, "contributor")

      refs = %{"refs/heads/main" => String.duplicate("b", 40)}

      Repo.insert!(%PushReceipt{
        repo: repository.storage_key,
        wal_seq: 9,
        principal: "user:" <> user.id,
        refs: refs,
        duration_ms: 31
      })

      # While the account is still a member, the document names the repository.
      assert {:ok, before_removal} = AccountExport.build(user)
      assert [named] = before_removal["push_receipts"]["records"]
      assert named["repository"] == repository.owner <> "/" <> repository.name

      drop_membership!(repository, user)
      refute Repositories.member?(repository, user)

      assert {:ok, export} = AccountExport.build(user)
      assert [receipt] = export["push_receipts"]["records"]

      assert receipt["repository"] == nil
      assert receipt["storage_key"] == repository.storage_key
      assert receipt["wal_seq"] == 9
      assert receipt["refs"] == refs
      assert receipt["duration_ms"] == 31
    end

    test "a deployment request and an approval keep the record and lose the path" do
      user = github_user("account-export-deploy-gone", "export-deploy-gone")
      owner = github_user("account-export-deploy-owner", "export-deploy-owner")
      repository = private_repository_with_member("export-deploy-private", owner)
      {:ok, _membership} = Repositories.add_member(repository, user, "maintainer")

      _environment = DeploymentsFixtures.environment_fixture(repository, user)
      run = DeploymentsFixtures.run_fixture(repository, user)
      request = Repo.get!(Request, run.deployment_request_id)

      Repo.insert!(%Approval{
        repository_id: repository.id,
        deployment_run_id: run.id,
        approver_user_id: user.id,
        decision: "approved",
        rule: "manual",
        request_digest: request.request_digest,
        decided_at: DateTime.utc_now()
      })

      drop_membership!(repository, user)
      refute Repositories.member?(repository, user)

      assert {:ok, export} = AccountExport.build(user)

      assert [exported_request] = export["deployments"]["requests"]
      assert exported_request["repository"] == nil
      assert exported_request["commit_sha"] == DeploymentsFixtures.commit_sha()
      assert exported_request["request_digest"] == request.request_digest

      assert [exported_approval] = export["deployments"]["approvals"]
      assert exported_approval["repository"] == nil
      assert exported_approval["decision"] == "approved"
      assert exported_approval["request_digest"] == request.request_digest
    end

    test "the document names the rule it applies to a repository it will not name" do
      user = github_user("account-export-disclosure", "export-disclosure")
      assert {:ok, export} = AccountExport.build(user)

      assert gap =
               Enum.find(export["not_included"], &(&1["family"] == "repository_identity"))

      assert gap["mechanism"] == "OpenAgents.Repositories.readable_by/2"
      assert gap["reason"] =~ "null repository"
    end
  end

  describe "who a legacy forum post belongs to" do
    test "an unclaimed legacy identity does not export", %{board: board} do
      user = github_user("account-export-unclaimed", "export-unclaimed")
      topic = topic_fixture(board, "agent:legacy_unclaimed", "Legacy")
      _post = post_fixture(topic, "agent:legacy_unclaimed", "Written under a legacy name.")

      assert {:ok, export} = AccountExport.build(user)
      assert export["forum"]["posts"] == []
      assert export["identities"]["authored_actor_refs"] == ["user:" <> user.id]
    end

    test "a pending claim does not export, and approving it does", %{board: board} do
      user = github_user("account-export-claim", "export-claim")
      topic = topic_fixture(board, "agent:legacy_claimed", "Legacy")
      post = post_fixture(topic, "agent:legacy_claimed", "Written under a legacy name.")

      {:ok, link} = Forum.start_actor_link(user, "agent:legacy_claimed")

      assert {:ok, pending_export} = AccountExport.build(user)
      assert pending_export["forum"]["posts"] == []

      assert [claim] = pending_export["identities"]["claims"]
      assert claim["status"] == "pending"
      refute claim["authored_posts_exported"]

      {:ok, _linked} = Forum.approve_actor_link(link)

      assert {:ok, linked_export} = AccountExport.build(user)
      assert [exported] = linked_export["forum"]["posts"]
      assert exported["id"] == post.id
      assert "agent:legacy_claimed" in linked_export["identities"]["authored_actor_refs"]
    end

    test "a rejected claim does not export", %{board: board} do
      user = github_user("account-export-rejected", "export-rejected")
      topic = topic_fixture(board, "agent:legacy_rejected", "Legacy")
      _post = post_fixture(topic, "agent:legacy_rejected", "Not this account's.")

      {:ok, link} = Forum.start_actor_link(user, "agent:legacy_rejected")
      {:ok, _rejected} = Forum.reject_actor_link(link)

      assert {:ok, export} = AccountExport.build(user)
      assert export["forum"]["posts"] == []
      assert [claim] = export["identities"]["claims"]
      assert claim["status"] == "rejected"
    end
  end

  describe "scope" do
    test "one account's export never carries another account's records", %{board: board} do
      mine = github_user("account-export-mine", "export-mine")
      theirs = github_user("account-export-theirs", "export-theirs")

      topic = topic_fixture(board, "user:" <> theirs.id, "Theirs")
      _their_post = post_fixture(topic, "user:" <> theirs.id, "Not yours.")

      Repo.insert!(%PushReceipt{
        repo: "export-theirs/work.git",
        wal_seq: 1,
        principal: "user:" <> theirs.id,
        refs: %{}
      })

      {:ok, _their_thread} = Threads.open(theirs, "Their objective.")

      Repo.insert!(%Machine{
        user_id: theirs.id,
        name: "theirs",
        token_digest: :crypto.hash(:sha256, "theirs"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      Repo.insert!(%TipDestination{
        user_id: theirs.id,
        kind: "lnurl",
        destination: "theirs@example.com",
        fingerprint: "theirs"
      })

      assert {:ok, export} = AccountExport.build(mine)

      assert export["forum"]["posts"] == []
      assert export["forum"]["topics"] == []
      assert export["forum"]["tip_destinations"] == []
      assert export["push_receipts"]["records"] == []
      assert export["threads"]["records"] == []
      assert export["computers"] == []
      assert export["account"]["id"] == mine.id
    end

    test "a claim on an actor_ref another account already linked never widens the export", %{
      board: board
    } do
      owner = github_user("account-export-owner", "export-owner")
      intruder = github_user("account-export-intruder", "export-intruder")

      topic = topic_fixture(board, "agent:legacy_contested", "Contested")
      _post = post_fixture(topic, "agent:legacy_contested", "The owner's writing.")

      {:ok, link} = Forum.start_actor_link(owner, "agent:legacy_contested")
      {:ok, _linked} = Forum.approve_actor_link(link)

      # The unique index on actor_ref refuses a second claim outright, which is
      # the point: two accounts cannot both resolve one legacy identity.
      assert {:error, %Ecto.Changeset{}} =
               Forum.start_actor_link(intruder, "agent:legacy_contested")

      assert {:ok, intruder_export} = AccountExport.build(intruder)
      assert intruder_export["forum"]["posts"] == []

      assert {:ok, owner_export} = AccountExport.build(owner)
      assert [_post] = owner_export["forum"]["posts"]
    end
  end

  describe "the route" do
    test "an account downloads its own export", %{conn: conn, board: board} do
      user = github_user("account-export-route")
      topic = topic_fixture(board, "user:" <> user.id, "Routed")
      _post = post_fixture(topic, "user:" <> user.id, "Through the route.")

      response =
        conn
        |> Plug.Test.init_test_session(%{"user_id" => user.id})
        |> get(~p"/data/export/account")

      assert response.status == 200

      assert ["attachment; filename=\"openagents-account-data.json\""] =
               Plug.Conn.get_resp_header(response, "content-disposition")

      assert ["no-store"] = Plug.Conn.get_resp_header(response, "cache-control")

      body = Jason.decode!(response.resp_body)
      assert body["schema"] == "openagents.account_export.v1"
      assert body["account"]["id"] == user.id
      assert [%{"body_text" => "Through the route."}] = body["forum"]["posts"]
    end

    test "an anonymous caller gets nothing", %{conn: conn} do
      response = get(conn, ~p"/data/export/account")
      assert response.status == 302
      refute response.resp_body =~ "openagents.account_export.v1"
    end

    test "the route reads the session, so no parameter reaches another account", %{
      conn: conn,
      board: board
    } do
      mine = github_user("account-export-session-mine", "export-session-mine")
      theirs = github_user("account-export-session-theirs", "export-session-theirs")

      topic = topic_fixture(board, "user:" <> theirs.id, "Theirs")
      _post = post_fixture(topic, "user:" <> theirs.id, "Not yours.")

      body =
        conn
        |> Plug.Test.init_test_session(%{"user_id" => mine.id})
        |> get(~p"/data/export/account?account_id=#{theirs.id}&user_id=#{theirs.id}")
        |> json_response(200)

      assert body["account"]["id"] == mine.id
      assert body["forum"]["posts"] == []
    end
  end

  describe "the document states its own bounds and gaps" do
    test "every collection cap is published and every omission is named" do
      user = github_user("account-export-bounds", "export-bounds")
      assert {:ok, export} = AccountExport.build(user)

      for key <- ~w(forum_topics forum_posts threads thread_events push_receipts box_runs) do
        assert is_integer(export["bounds"][key]) and export["bounds"][key] > 0
      end

      families = Enum.map(export["not_included"], & &1["family"])
      # `reputation` left this list when #171 gave the subject a binding.
      refute "reputation" in families
      assert "repository_content" in families
      assert "conversation" in families

      for gap <- export["not_included"] do
        assert String.length(gap["reason"]) > 20
      end
    end

    test "the identity rule the export applies is stated in the export" do
      user = github_user("account-export-rule", "export-rule")
      assert {:ok, export} = AccountExport.build(user)
      assert export["identities"]["resolution_rule"] =~ "linked"
    end
  end

  describe "an inactive account" do
    test "cannot export" do
      user = github_user("account-export-banned", "export-banned")

      banned =
        user
        |> Ecto.Changeset.change(status: "banned", banned_at: DateTime.utc_now())
        |> Repo.update!()

      assert {:error, :inactive_account} = AccountExport.build(banned)
    end
  end

  describe "repository-keyed work" do
    test "pull requests, stacks, and issue dependencies come back from every repository" do
      user = github_user("account-export-work", "export-work")
      public_repository = OpenAgents.AccountsFixtures.repository_fixture()
      private_repository = private_repository_with_member("export-work-private", user)

      public_pull_request = pull_request_fixture(public_repository, "public-branch", user)
      private_pull_request = pull_request_fixture(private_repository, "private-branch", user)

      {:ok, stack} = Stacks.create(private_repository, [private_pull_request], user)

      blocked = OpenAgents.IssuesFixtures.issue_fixture(private_repository, %{title: "Blocked"})
      blocker = OpenAgents.IssuesFixtures.issue_fixture(private_repository, %{title: "Blocker"})
      :ok = Issues.add_dependencies(blocked, [blocker.number], user)

      assert {:ok, export} = AccountExport.build(user)
      work = export["repository_work"]

      numbers = Enum.map(work["pull_requests"]["records"], & &1["id"])
      assert public_pull_request.id in numbers
      assert private_pull_request.id in numbers
      refute work["pull_requests"]["records_truncated"]

      exported_public =
        Enum.find(work["pull_requests"]["records"], &(&1["id"] == public_pull_request.id))

      assert exported_public["repository"] ==
               public_repository.owner <> "/" <> public_repository.name

      assert exported_public["head_ref"] == "public-branch"
      assert exported_public["opened_by_account"]
      refute exported_public["merged_by_account"]

      assert [exported_stack] = work["stacks"]["records"]
      assert exported_stack["id"] == stack.id
      assert exported_stack["number"] == stack.number
      assert exported_stack["trunk_ref"] == "main"

      assert [entry] = exported_stack["entries"]
      assert entry["position"] == 1
      assert entry["pull_request_number"] == private_pull_request.issue_id |> issue_number()
      assert entry["boundary_oid"] == private_pull_request.base_sha
      assert entry["observed_head_oid"] == private_pull_request.head_sha

      assert [dependency] = work["issue_dependencies"]["records"]
      assert dependency["issue_number"] == blocked.number
      assert dependency["blocked_by_issue_number"] == blocker.number
      assert dependency["blocked_by_issue_state"] == "open"
    end

    # The authoring column alone would return this record. It is the
    # readable_by join that withholds it, so removing that join turns this red
    # while every other assertion in this file still passes.
    test "a record the account authored in a repository it cannot read stays behind" do
      user = github_user("account-export-revoked", "export-revoked")
      other = github_user("account-export-revoked-owner", "export-revoked-owner")
      repository = private_repository_with_member("export-revoked-private", other)

      pull_request = pull_request_fixture(repository, "revoked-branch", user)
      {:ok, _stack} = Stacks.create(repository, [pull_request], user)

      blocked = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Blocked"})
      blocker = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Blocker"})
      :ok = Issues.add_dependencies(blocked, [blocker.number], user)

      refute Repositories.member?(repository, user)

      assert {:ok, export} = AccountExport.build(user)
      work = export["repository_work"]

      assert work["pull_requests"]["records"] == []
      assert work["stacks"]["records"] == []
      assert work["issue_dependencies"]["records"] == []
    end

    test "another account's records in a readable repository never come back" do
      user = github_user("account-export-work-mine", "export-work-mine")
      other = github_user("account-export-work-theirs", "export-work-theirs")
      repository = OpenAgents.AccountsFixtures.repository_fixture()

      theirs = pull_request_fixture(repository, "their-branch", other)
      {:ok, _stack} = Stacks.create(repository, [theirs], other)

      blocked = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Theirs blocked"})
      blocker = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Theirs blocker"})
      :ok = Issues.add_dependencies(blocked, [blocker.number], other)

      assert {:ok, export} = AccountExport.build(user)
      work = export["repository_work"]

      assert work["pull_requests"]["records"] == []
      assert work["stacks"]["records"] == []
      assert work["issue_dependencies"]["records"] == []
    end

    test "a merge the account performed on another account's pull request comes back" do
      user = github_user("account-export-merger", "export-merger")
      author = github_user("account-export-authored", "export-authored")
      repository = OpenAgents.AccountsFixtures.repository_fixture()

      pull_request =
        repository
        |> pull_request_fixture("merged-branch", author)
        |> Ecto.Changeset.change(
          state: "closed",
          merged_by_user_id: user.id,
          merged_at: DateTime.utc_now(),
          merge_commit_sha: String.duplicate("a", 40)
        )
        |> Repo.update!()

      assert {:ok, export} = AccountExport.build(user)
      assert [exported] = export["repository_work"]["pull_requests"]["records"]
      assert exported["id"] == pull_request.id
      refute exported["opened_by_account"]
      assert exported["merged_by_account"]
      assert exported["merge_commit_sha"] == String.duplicate("a", 40)
    end

    test "the document says the read is gated on the repository predicate" do
      user = github_user("account-export-gate", "export-gate")
      assert {:ok, export} = AccountExport.build(user)

      assert export["repository_work"]["authorization"] =~ "readable_by/2"

      for key <- ~w(pull_requests stacks stack_entries issue_dependencies) do
        assert is_integer(export["bounds"][key]) and export["bounds"][key] > 0
      end
    end
  end

  # A restore rehearsal on a clean environment can only work if the document
  # answers on its own. Every record that names another object names it by
  # something a person can read — a repository path, a topic and board slug, an
  # issue number, an agent handle — rather than only by a UUID this forge would
  # have to resolve. Replacing any of those with an id alone turns this red.
  describe "a reputation attestation's subject" do
    test "an attestation naming a subject this account established comes back" do
      user = github_user("account-export-attest", "export-attest")
      repository = private_repository_with_member("export-attest-private", user)
      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Attested"})

      link_subject!(user, "user:" <> user.id)
      attestation = attest!(repository, issue, "user:" <> user.id, "repository")

      assert {:ok, export} = AccountExport.build(user)
      work = export["repository_work"]

      assert [record] = work["attestations"]["records"]
      assert record["id"] == attestation.id
      assert record["subject_id"] == "user:" <> user.id
      assert record["repository"] == repository.owner <> "/" <> repository.name
      assert record["issue_number"] == issue.number
      assert record["transparency_tier"] == "repository"
      refute work["attestations"]["records_truncated"]

      # The signed claim travels verbatim, so the recipient checks it offline.
      assert record["claim"]["subject"]["actor_id"] == "user:" <> user.id
      assert record["claim_digest"] == attestation.claim_digest

      assert OpenAgents.Reputation.Claim.valid_signature?(
               record["claim"],
               record["signature"],
               issuer_public_key(attestation)
             )

      assert work["attestations"]["established_subjects"] == ["user:" <> user.id]
      assert work["attestations"]["subject_resolution_rule"] =~ "linked"
    end

    # Without the linked-claim filter this attestation would come back to
    # whoever asked. Dropping `Reputation.linked_subject_ids/1` from
    # `attestations_export/2` turns this red.
    test "an attestation whose subject the account has not established stays behind" do
      user = github_user("account-export-attest-none", "export-attest-none")
      repository = private_repository_with_member("export-attest-none-private", user)
      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Not mine"})

      _attestation = attest!(repository, issue, "actor:someone-else", "repository")

      assert {:ok, export} = AccountExport.build(user)
      assert export["repository_work"]["attestations"]["records"] == []
      assert export["repository_work"]["attestations"]["established_subjects"] == []
    end

    test "a pending claim resolves nothing, and only the operator's decision does" do
      user = github_user("account-export-attest-pending", "export-attest-pending")
      repository = private_repository_with_member("export-attest-pending-private", user)
      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Pending"})

      {:ok, claim} =
        Reputation.claim_subject(user, %{
          subject_kind: "account",
          subject_id: "user:" <> user.id
        })

      _attestation = attest!(repository, issue, "user:" <> user.id, "repository")

      assert {:ok, pending_export} = AccountExport.build(user)
      assert pending_export["repository_work"]["attestations"]["records"] == []

      {:ok, _linked} = Reputation.approve_subject_claim(claim)

      assert {:ok, export} = AccountExport.build(user)
      assert [_record] = export["repository_work"]["attestations"]["records"]

      assert [projected] = export["identities"]["reputation_subject_claims"]
      assert projected["status"] == "linked"
      assert projected["subject_kind"] == "account"
    end

    # Disclosure does not widen. `readable_by/2` admits a public repository to
    # a non-member, and the controller shows such a reader `public` only.
    # Dropping the membership test from `attestations_export/2` turns this red.
    test "a repository or private tier attestation stays behind for a non-member" do
      user = github_user("account-export-attest-tier", "export-attest-tier")
      public_repository = OpenAgents.AccountsFixtures.repository_fixture()
      issue = OpenAgents.IssuesFixtures.issue_fixture(public_repository, %{title: "Tiered"})
      other = OpenAgents.IssuesFixtures.issue_fixture(public_repository, %{title: "Open"})

      link_subject!(user, "user:" <> user.id)
      refute Repositories.member?(public_repository, user)

      withheld = attest!(public_repository, issue, "user:" <> user.id, "repository")
      disclosed = attest!(public_repository, other, "user:" <> user.id, "public")

      assert {:ok, export} = AccountExport.build(user)
      ids = Enum.map(export["repository_work"]["attestations"]["records"], & &1["id"])

      assert disclosed.id in ids
      refute withheld.id in ids
    end

    # A public-tier attestation in a repository that went private afterwards is
    # the one case the tier test admits and `readable_by/2` does not, so this is
    # what isolates the join: replacing `subquery(readable)` with `Repository`
    # in `attestations_export/2` turns this red and nothing else in this file.
    test "a public tier attestation in a repository the account cannot read stays behind" do
      user = github_user("account-export-attest-shut", "export-attest-shut")
      other = github_user("account-export-attest-shut-owner", "export-attest-shut-owner")
      repository = OpenAgents.AccountsFixtures.repository_fixture()
      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Was public"})

      link_subject!(user, "user:" <> user.id)
      attestation = attest!(repository, issue, "user:" <> user.id, "public")

      assert {:ok, before} = AccountExport.build(user)
      assert [%{"id" => id}] = before["repository_work"]["attestations"]["records"]
      assert id == attestation.id

      # The repository closes. The attestation's tier still says `public`, so
      # only the repository visibility predicate withholds it now.
      repository
      |> Ecto.Changeset.change(visibility: "private")
      |> Repo.update!()

      {:ok, _membership} = Repositories.add_member(repository, other, "owner")
      refute Repositories.member?(repository, user)

      assert {:ok, export} = AccountExport.build(user)
      assert export["repository_work"]["attestations"]["records"] == []
    end

    # Both gates withhold this one, and that is the honest description: for a
    # private repository at the `repository` tier the membership test and
    # `readable_by/2` coincide, so this asserts the outcome rather than
    # isolating one join. The test above isolates it.
    test "an attestation in a private repository the account cannot read stays behind" do
      user = github_user("account-export-attest-closed", "export-attest-closed")
      other = github_user("account-export-attest-owner", "export-attest-owner")
      repository = private_repository_with_member("export-attest-closed-private", other)
      issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Closed"})

      link_subject!(user, "user:" <> user.id)
      _attestation = attest!(repository, issue, "user:" <> user.id, "repository")

      refute Repositories.member?(repository, user)

      assert {:ok, export} = AccountExport.build(user)
      assert export["repository_work"]["attestations"]["records"] == []
    end
  end

  describe "the document resolves without the forge" do
    test "every record names its context in readable terms", %{board: board} do
      user = github_user("account-export-standalone", "export-standalone")
      repository = OpenAgents.AccountsFixtures.repository_fixture()
      path = repository.owner <> "/" <> repository.name

      topic = topic_fixture(board, "user:" <> user.id, "Standalone")
      _post = post_fixture(topic, "user:" <> user.id, "Readable on its own.")

      pull_request = pull_request_fixture(repository, "standalone-branch", user)
      {:ok, _stack} = Stacks.create(repository, [pull_request], user)

      blocked =
        OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Standalone blocked"})

      blocker =
        OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "Standalone blocker"})

      :ok = Issues.add_dependencies(blocked, [blocker.number], user)

      Repo.insert!(%PushReceipt{
        repo: repository.storage_key,
        wal_seq: 3,
        principal: "user:" <> user.id,
        refs: %{"refs/heads/main" => String.duplicate("0", 40)}
      })

      assert {:ok, export} = AccountExport.build(user)

      assert [exported_post] = export["forum"]["posts"]
      assert exported_post["topic_slug"] == topic.slug
      assert exported_post["board_slug"] == "account-export"

      work = export["repository_work"]
      assert [exported_pull_request] = work["pull_requests"]["records"]
      assert exported_pull_request["repository"] == path
      assert is_integer(exported_pull_request["number"])

      assert [exported_stack] = work["stacks"]["records"]
      assert exported_stack["repository"] == path
      assert [entry] = exported_stack["entries"]
      assert is_integer(entry["pull_request_number"])

      assert [dependency] = work["issue_dependencies"]["records"]
      assert dependency["repository"] == path
      assert dependency["issue_title"] == "Standalone blocked"
      assert dependency["blocked_by_issue_title"] == "Standalone blocker"

      assert [receipt] = export["push_receipts"]["records"]
      assert receipt["repository"] == path
      assert receipt["wal_seq"] == 3
    end
  end

  ## ── fixtures ───────────────────────────────────────────────────────────

  defp topic_fixture(board, actor_ref, title) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    unique = Integer.to_string(System.unique_integer([:positive]))

    Repo.insert!(%Topic{
      forum_id: board.id,
      idempotency_key: "account-export-topic-" <> unique,
      slug: slug <> "-" <> unique,
      title: title,
      actor_ref: actor_ref,
      actor_display_name: actor_ref,
      post_count: 1
    })
  end

  defp post_fixture(topic, actor_ref, body) do
    number =
      Repo.one(from post in Post, where: post.topic_id == ^topic.id, select: count(post.id)) + 1

    Repo.insert!(%Post{
      topic_id: topic.id,
      idempotency_key:
        "account-export-post-" <> Integer.to_string(System.unique_integer([:positive])),
      post_number: number,
      body_text: body,
      actor_ref: actor_ref,
      actor_display_name: actor_ref
    })
  end

  defp link_subject!(user, subject_id) do
    {:ok, claim} =
      Reputation.claim_subject(user, %{subject_kind: "account", subject_id: subject_id})

    {:ok, linked} = Reputation.approve_subject_claim(claim)
    linked
  end

  defp attest!(repository, issue, subject_id, tier) do
    policy =
      case Reputation.admit_policy(reputation_operator()) do
        {:ok, policy} -> policy
        {:error, _already_admitted} -> List.last(Reputation.policies())
      end

    keypair = OpenAgents.Reputation.Claim.generate_keypair()

    {:ok, key} =
      Reputation.admit_key(%{public_key: keypair.public_key, issuer: "account-export"})

    decision = OpenAgents.CompensationFixtures.outcome_decision_fixture()

    {:ok, attestation} =
      Reputation.issue(policy, %{key_id: key.key_id, private_key: keypair.private_key}, %{
        event_type: "completion",
        subject_id: subject_id,
        outcome: %{kind: "compensation_outcome_decision", ref: decision.decision_receipt_ref},
        repository: repository,
        issue_number: issue.number,
        revision: String.duplicate("a", 40),
        artifact_digest: String.duplicate("1", 64),
        confidence_ppm: 900_000,
        transparency_tier: tier,
        evidence: [
          %{
            kind: "outcome",
            ref: decision.decision_receipt_ref,
            digest: decision.outcome_digest,
            observed_at: DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      })

    attestation
  end

  defp issuer_public_key(attestation) do
    Reputation.keys()
    |> Enum.find(&(&1.key_id == attestation.issuer_key_id))
    |> Map.fetch!(:public_key)
  end

  defp reputation_operator do
    %{
      authenticated: true,
      actor_id: "operator:account-export",
      auth_method: "test_session",
      approval_receipt_ref: "account-export:#{System.unique_integer([:positive])}"
    }
  end

  # Membership is what `readable_by/2` reads for a private repository, so the
  # row goes rather than the repository: the account really did the work and
  # really cannot read where it landed.
  defp drop_membership!(repository, user) do
    {1, nil} =
      Repo.delete_all(
        from membership in Membership,
          where: membership.repository_id == ^repository.id and membership.user_id == ^user.id
      )

    :ok
  end

  defp private_repository_with_member(name, user) do
    repository =
      OpenAgents.AccountsFixtures.repository_fixture(%{name: name, visibility: "private"})

    {:ok, _membership} = Repositories.add_member(repository, user, "owner")
    repository
  end

  defp pull_request_fixture(repository, head_ref, user) do
    issue = OpenAgents.IssuesFixtures.issue_fixture(repository, %{title: "PR " <> head_ref})

    {:ok, pull_request} =
      %PullRequest{}
      |> PullRequest.changeset(%{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: repository.id,
        opened_by_user_id: user.id,
        head_ref: head_ref,
        head_sha: sha_for(head_ref),
        base_ref: "main",
        base_sha: sha_for("main"),
        state: "open"
      })
      |> Repo.insert()

    pull_request
  end

  defp sha_for(ref), do: :sha |> :crypto.hash(ref) |> Base.encode16(case: :lower)

  defp issue_number(issue_id) do
    Repo.one!(
      from issue in OpenAgents.Issues.Issue, where: issue.id == ^issue_id, select: issue.number
    )
  end
end
