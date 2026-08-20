defmodule OpenAgents.ChangelogTest do
  @moduledoc """
  The public changelog projection (#138, TRANSPARENCY-001): validated
  append-only entries, per-repo disclosure gating, the l1 embargo lane
  (shown without a sha, never silently omitted), receipt-only rows for
  deploys nobody wrote a note for, receipt joins by sha prefix, the
  schema-versioned API payload, principal roles only — and the idempotent
  backfill seed.
  """

  use OpenAgents.SarahDataCase, async: false
  alias OpenAgents.Changelog
  alias OpenAgents.Changelog.{Backfill, Entry}
  alias OpenAgents.Forge.{DeployReceipt, PushReceipt}

  setup do
    :persistent_term.erase({OpenAgents.Changelog, :cache})
    on_exit(fn -> :persistent_term.erase({OpenAgents.Changelog, :cache}) end)
    :ok
  end

  defp override_visibility(map) do
    previous = Application.get_env(:openagents, :forge_public_visibility)
    Application.put_env(:openagents, :forge_public_visibility, map)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :forge_public_visibility, previous),
        else: Application.delete_env(:openagents, :forge_public_visibility)
    end)
  end

  # A full 40-hex sha from a distinctive hex prefix.
  defp full_sha(prefix), do: String.pad_trailing(prefix, 40, "0")

  defp entry_attrs(overrides) do
    Map.merge(
      %{
        repo: "sarah",
        sha: full_sha("feed0001"),
        summary: "A test entry",
        category: "ui",
        source: "operator",
        entry_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp insert_deploy!(attrs) do
    {:ok, deploy} =
      %DeployReceipt{}
      |> DeployReceipt.changeset(
        Map.merge(
          %{
            repo: "sarah",
            target_id: Ecto.UUID.generate(),
            result: "live",
            modules: ["Elixir.OpenAgents.Something"],
            nodes: ["node-a", "node-b"]
          },
          attrs
        )
      )
      |> Repo.insert()

    deploy
  end

  describe "record/1" do
    test "validates category, source, and sha shape" do
      assert {:error, changeset} = Changelog.record(entry_attrs(%{category: "nonsense"}))
      assert "is invalid" in errors_on(changeset).category

      assert {:error, changeset} = Changelog.record(entry_attrs(%{source: "nonsense"}))
      assert "is invalid" in errors_on(changeset).source

      assert {:error, changeset} = Changelog.record(entry_attrs(%{sha: "not-a-sha"}))
      assert "has invalid format" in errors_on(changeset).sha

      assert {:error, changeset} = Changelog.record(entry_attrs(%{sha: "abc"}))
      assert "has invalid format" in errors_on(changeset).sha
    end

    test "a duplicate {repo, sha, source} insert is a no-op" do
      assert {:ok, %Entry{id: id}} = Changelog.record(entry_attrs(%{}))
      assert is_binary(id)

      assert {:ok, %Entry{}} =
               Changelog.record(entry_attrs(%{summary: "Different wording, same key"}))

      assert Repo.aggregate(Entry, :count) == 1
      assert Repo.one!(Entry).summary == "A test entry"
    end
  end

  describe "timeline/2" do
    test "a dark repo is {:error, :not_public}, indistinguishable from absent" do
      assert {:error, :not_public} = Changelog.timeline("demo")
      assert {:error, :not_public} = Changelog.timeline("no-such-repo")
    end

    test "a repo configured :l2 returns entries newest first" do
      override_visibility(%{"sarah" => :l2})

      now = DateTime.utc_now()

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0001"),
            summary: "Older entry",
            entry_at: DateTime.add(now, -3600, :second)
          })
        )

      {:ok, _} =
        Changelog.record(entry_attrs(%{sha: full_sha("feed0002"), summary: "Newer entry"}))

      assert {:ok, [newer, older]} = Changelog.timeline("sarah", refresh: true)
      assert newer.summary == "Newer entry"
      assert older.summary == "Older entry"
      assert Enum.all?([newer, older], &(&1.kind == :entry))
    end

    test "an embargoed l1 entry appears without its sha" do
      sha = full_sha("feed0003")

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: sha,
            summary: "Security fix under embargo",
            visibility: "l1",
            disclosure_after: DateTime.add(DateTime.utc_now(), 3600, :second),
            detail: %{"cve" => "CVE-0000-0000"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("sarah", refresh: true)
      assert row.summary == "Security fix under embargo"
      assert row.sha == nil
      assert row.short_sha == nil
      assert row.detail == %{}
    end

    test "an l1 entry past its disclosure_after shows its sha" do
      sha = full_sha("feed0004")

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: sha,
            summary: "Disclosed security fix",
            visibility: "l1",
            disclosure_after: DateTime.add(DateTime.utc_now(), -3600, :second)
          })
        )

      assert {:ok, [row]} = Changelog.timeline("sarah", refresh: true)
      assert row.sha == sha
      assert row.short_sha == String.slice(sha, 0, 12)
    end

    test "a receipted deploy with no authored entry appears as a bare :receipt row" do
      deploy = insert_deploy!(%{sha: full_sha("feed0005")})

      assert {:ok, [row]} = Changelog.timeline("sarah", refresh: true)
      assert row.kind == :receipt
      assert row.summary == nil
      assert row.sha == deploy.sha
      assert row.deploy.result == "live"
      assert row.receipt_ids.deploy == deploy.id
    end

    test "a deploy receipt prefix-matching an entry's short sha attaches to the entry" do
      {:ok, _} =
        Changelog.record(
          entry_attrs(%{sha: "feed0006", summary: "Short-sha entry from backfill lane"})
        )

      deploy = insert_deploy!(%{sha: full_sha("feed0006"), push_to_live_ms: 5_540})

      assert {:ok, [row]} = Changelog.timeline("sarah", refresh: true)
      assert row.kind == :entry
      assert row.summary == "Short-sha entry from backfill lane"
      assert row.deploy.push_to_live_ms == 5_540
      assert row.receipt_ids.deploy == deploy.id
    end
  end

  describe "projection/2" do
    test "publishes the schema version, receipt ids, commit_url — and only the push role" do
      sha = full_sha("feed0007")
      {:ok, _} = Changelog.record(entry_attrs(%{sha: sha, summary: "Projected entry"}))

      {:ok, push} =
        %PushReceipt{}
        |> PushReceipt.changeset(%{
          repo: "sarah",
          wal_seq: 1,
          principal: "operator:abc123",
          refs: %{"refs/heads/main" => %{"new" => sha}}
        })
        |> Repo.insert()

      assert {:ok, payload} = Changelog.projection("sarah", refresh: true)

      assert payload["schema"] == "sarah.changelog.v1"
      assert payload["repo"] == "sarah"

      assert [entry] = payload["entries"]
      assert entry["summary"] == "Projected entry"
      assert entry["receipt_ids"]["push"] == push.id
      assert entry["commit_url"] == "/OpenAgentsInc/sarah/commit/#{String.slice(sha, 0, 12)}"
      assert entry["push"]["principal_role"] == "operator"
      assert entry["push"]["wal_seq"] == 1

      # The principal's id never leaves the projection — role prefix only.
      refute Jason.encode!(payload) =~ "abc123"
    end
  end

  describe "Backfill.run/0" do
    test "seeds every curated entry and is idempotent on re-run" do
      Backfill.run()

      seeded = Repo.aggregate(Entry, :count)
      assert seeded == length(Backfill.entries())

      # Re-running inserts nothing: the {repo, sha, source} conflict target
      # makes every duplicate a DB-level no-op.
      Backfill.run()
      assert Repo.aggregate(Entry, :count) == seeded

      assert {:ok, rows} = Changelog.timeline("sarah", refresh: true)
      assert Enum.any?(rows, &(&1.source == "backfill"))
    end
  end
end
