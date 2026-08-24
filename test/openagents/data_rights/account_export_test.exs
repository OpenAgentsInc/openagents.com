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
  alias OpenAgents.Forum
  alias OpenAgents.Forum.{Post, TipDestination, Topic}
  alias OpenAgents.Forum.Forum, as: Board
  alias OpenAgents.Forge.PushReceipt
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
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
      assert "pull_request" in families
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
end
