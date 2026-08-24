defmodule OpenAgents.ChangelogTest do
  @moduledoc """
  The public changelog projection (#138, TRANSPARENCY-001): validated
  append-only entries, per-repo disclosure gating, the l1 embargo lane
  (shown without a sha, never silently omitted), receipt-only rows for
  deploys nobody wrote a note for, receipt joins by sha prefix, the
  schema-versioned API payload, principal roles only — and the idempotent
  backfill seed.
  """

  use OpenAgents.DataCase, async: false
  alias OpenAgents.Changelog
  alias OpenAgents.Changelog.{Backfill, Entry}
  alias OpenAgents.Forge
  alias OpenAgents.Forge.{DeployReceipt, PushReceipt, ReceiptRepository}
  alias OpenAgents.Transparency.ArtifactLink

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
        repo: "openagents.com",
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
            repo: "openagents.com",
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

  defp insert_artifact_link!(attrs) do
    user = repository_user_fixture("test-user")
    repository = repository_fixture(%{})

    {:ok, link} =
      %ArtifactLink{}
      |> ArtifactLink.changeset(
        Map.merge(
          %{
            account_id: user.id,
            repository_id: repository.id,
            artifact_type: "changelog",
            artifact_ref: "sha",
            tier: "dark"
          },
          attrs
        )
      )
      |> Repo.insert()

    link
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
      override_visibility(%{"openagents.com" => :l2})

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

      assert {:ok, [newer, older]} = Changelog.timeline("openagents.com", refresh: true)
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

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
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

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.sha == sha
      assert row.short_sha == String.slice(sha, 0, 12)
    end

    test "a receipted deploy with no authored entry appears as a bare :receipt row" do
      deploy = insert_deploy!(%{sha: full_sha("feed0005")})

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
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

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.kind == :entry
      assert row.summary == "Short-sha entry from backfill lane"
      assert row.deploy.push_to_live_ms == 5_540
      assert row.receipt_ids.deploy == deploy.id
    end
  end

  describe "which repository a receipt belongs to" do
    # `forge_builds.repo` and `forge_deploys.repo` hold a repository *name*, and
    # `Targets.promote/4` admits both the bare name and the `owner/name` path.
    # Before #181 the changelog matched the string exactly, so a receipt written
    # under one form was invisible to a projection asking for the other, even
    # though both settle to the same repository. The key settles it.
    test "a receipt written under the owner/name path reaches the bare-name projection" do
      sha = full_sha("feed0181")
      {:ok, _entry} = Changelog.record(entry_attrs(%{sha: sha, summary: "Keyed receipt"}))

      repository = ReceiptRepository.resolve("openagents.com")
      assert repository.id == "00000000-0000-4000-8000-000000000001"

      deploy =
        insert_deploy!(%{
          repo: "OpenAgentsInc/openagents.com",
          repository_id: repository.id,
          sha: sha
        })

      assert {:ok, payload} = Changelog.projection("openagents.com", refresh: true)
      assert [entry] = payload["entries"]
      assert entry["receipt_ids"]["deploy"] == deploy.id

      # `OpenAgents.Forge.receipts_for/2` reads the same way.
      assert Enum.any?(Forge.receipts_for("openagents.com", sha), fn
               {:deploys, deploys} -> Enum.any?(deploys, &(&1.id == deploy.id))
               _other -> false
             end)
    end

    # A receipt whose name the backfill could not settle still reads. It keeps
    # a null key, and the string is what finds it.
    test "a receipt with no key still reaches the projection by its string" do
      sha = full_sha("feed0182")
      {:ok, _entry} = Changelog.record(entry_attrs(%{sha: sha, summary: "Unkeyed receipt"}))

      deploy = insert_deploy!(%{repo: "openagents.com", repository_id: nil, sha: sha})

      assert {:ok, payload} = Changelog.projection("openagents.com", refresh: true)
      assert [entry] = payload["entries"]
      assert entry["receipt_ids"]["deploy"] == deploy.id
    end
  end

  describe "projection/2" do
    test "publishes the schema version, receipt ids, commit_url — and only the push role" do
      sha = full_sha("feed0007")
      {:ok, _} = Changelog.record(entry_attrs(%{sha: sha, summary: "Projected entry"}))

      {:ok, push} =
        %PushReceipt{}
        |> PushReceipt.changeset(%{
          repo: "openagents.com",
          wal_seq: 1,
          principal: "operator:abc123",
          refs: %{"refs/heads/main" => %{"new" => sha}}
        })
        |> Repo.insert()

      assert {:ok, payload} = Changelog.projection("openagents.com", refresh: true)

      assert payload["schema"] == "openagents.changelog.v1"
      assert payload["repo"] == "openagents.com"

      assert [entry] = payload["entries"]
      assert entry["summary"] == "Projected entry"
      assert entry["receipt_ids"]["push"] == push.id

      assert entry["commit_url"] ==
               "/OpenAgentsInc/openagents.com/commit/#{String.slice(sha, 0, 12)}"

      assert entry["push"]["principal_role"] == "operator"
      assert entry["push"]["wal_seq"] == 1

      # The principal's id never leaves the projection — role prefix only.
      refute Jason.encode!(payload) =~ "abc123"
    end
  end

  describe "timeline/2 redaction" do
    test "a ledger tier exposes trace_ref, trace_digest, and detail" do
      override_visibility(%{"openagents.com" => :l2})

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0101"),
            summary: "Ledger trace",
            transparency_tier: "ledger",
            trace_ref: "trace:v1:ledger",
            trace_digest: "sha256:ledger",
            detail: %{"note" => "visible"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.trace_ref == "trace:v1:ledger"
      assert row.trace_digest == "sha256:ledger"
      assert row.detail == %{"note" => "visible"}
    end

    test "a pulse tier exposes metadata but hides detail" do
      override_visibility(%{"openagents.com" => :l2})

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0102"),
            summary: "Pulse trace",
            transparency_tier: "pulse",
            trace_ref: "trace:v1:pulse",
            trace_digest: "sha256:pulse",
            detail: %{"note" => "hidden"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.trace_ref == "trace:v1:pulse"
      assert row.trace_digest == "sha256:pulse"
      assert row.detail == %{}
    end

    test "a dark tier hides trace_ref, trace_digest, and detail" do
      override_visibility(%{"openagents.com" => :l2})

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0103"),
            summary: "Dark trace",
            transparency_tier: "dark",
            trace_ref: "trace:v1:dark",
            trace_digest: "sha256:dark",
            detail: %{"note" => "hidden"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.trace_ref == nil
      assert row.trace_digest == nil
      assert row.detail == %{}
    end

    test "an artifact_link overrides the entry transparency_tier" do
      override_visibility(%{"openagents.com" => :l2})

      link = insert_artifact_link!(%{tier: "pulse"})

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0104"),
            summary: "Link-tier trace",
            transparency_tier: "ledger",
            artifact_link_id: link.id,
            trace_ref: "trace:v1:link",
            trace_digest: "sha256:link",
            detail: %{"note" => "hidden"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.trace_ref == "trace:v1:link"
      assert row.trace_digest == "sha256:link"
      assert row.detail == %{}
    end

    test "a revoked artifact_link hides all trace and detail" do
      override_visibility(%{"openagents.com" => :l2})

      link = insert_artifact_link!(%{tier: "glass"})

      link
      |> OpenAgents.Transparency.revoke("test", Ecto.UUID.generate())
      |> Repo.update!()

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0105"),
            summary: "Revoked trace",
            artifact_link_id: link.id,
            trace_ref: "trace:v1:revoked",
            trace_digest: "sha256:revoked",
            detail: %{"note" => "hidden"}
          })
        )

      assert {:ok, [row]} = Changelog.timeline("openagents.com", refresh: true)
      assert row.trace_ref == nil
      assert row.trace_digest == nil
      assert row.detail == %{}
    end
  end

  describe "projection/2 redaction" do
    test "the API payload reflects redacted trace and detail" do
      override_visibility(%{"openagents.com" => :l2})

      {:ok, _} =
        Changelog.record(
          entry_attrs(%{
            sha: full_sha("feed0106"),
            summary: "Projected redaction",
            transparency_tier: "pulse",
            trace_ref: "trace:v1:projected",
            trace_digest: "sha256:projected",
            detail: %{"note" => "hidden"}
          })
        )

      assert {:ok, payload} = Changelog.projection("openagents.com", refresh: true)

      assert [entry] = payload["entries"]
      assert entry["trace_ref"] == "trace:v1:projected"
      assert entry["trace_digest"] == "sha256:projected"
      assert entry["detail"] == %{}
    end
  end

  describe "Backfill.run/0" do
    test "seeds what it can prove and is idempotent on re-run" do
      Backfill.run()

      seeded = Repo.aggregate(Entry, :count)
      assert seeded == length(Backfill.seeded_entries())

      # Re-running inserts nothing: the {repo, sha, source} conflict target
      # makes every duplicate a DB-level no-op.
      Backfill.run()
      assert Repo.aggregate(Entry, :count) == seeded

      assert {:ok, rows} = Changelog.timeline("openagents.com", refresh: true)
      assert Enum.any?(rows, &(&1.source == "backfill"))
    end

    test "the launch entry is the release, and its commit is in this history" do
      # The page tells a reader that every entry links to its commit and that
      # the diff is readable from there. An entry anchored to a commit this
      # repository does not contain is a link to nothing, so the seed may only
      # publish entries whose sha is really here.
      assert [launch] = Backfill.seeded_entries()
      assert launch.summary =~ "v0.0.1"

      for %{sha: sha} <- Backfill.seeded_entries() do
        assert {_output, 0} = System.cmd("git", ["cat-file", "-e", sha <> "^{commit}"]),
               "seeded entry #{sha} is not a commit in this repository"
      end
    end

    test "the curated pre-public entries are retained but not published" do
      # They are anchored to the history that preceded this repository's
      # clean-room rewrite. Kept so they can be restored if that history is
      # ever grafted in; not seeded, because today they would be dead links.
      refute Enum.empty?(Backfill.pre_public_entries())

      seeded = MapSet.new(Backfill.seeded_entries(), & &1.sha)

      for %{sha: sha} <- Backfill.pre_public_entries() do
        refute MapSet.member?(seeded, sha)
      end
    end

    test "a summary the column cannot hold is a changeset error, not a crash" do
      # `changelog_entries.summary` is varchar(255) and the validation allowed
      # 500, so anything between the two raised from Postgres instead.
      attrs = %{
        repo: "openagents.com",
        sha: "abcdef1",
        summary: String.duplicate("x", 256),
        category: "feature",
        source: "backfill",
        entry_at: DateTime.utc_now()
      }

      assert {:error, changeset} = Changelog.record(attrs)
      assert %{summary: [_message]} = errors_on(changeset)
    end
  end

  describe "announcements" do
    test "an appended entry announces itself and drops the cached projection" do
      # Warm the cache, so the assertion below is about invalidation rather
      # than about a cache that was never populated.
      assert {:ok, []} = Changelog.timeline("openagents.com")
      assert {"openagents.com", _at, []} = :persistent_term.get({Changelog, :cache})

      :ok = Changelog.subscribe()

      {:ok, _entry} =
        Changelog.record(entry_attrs(%{sha: full_sha("aced0001"), summary: "Landed just now"}))

      assert_receive {:changelog_entry, "openagents.com"}

      # The cache is what a reconnecting client reads on its next mount, so a
      # subscriber is not the only thing that has to learn.
      assert :persistent_term.get({Changelog, :cache}, :absent) == :absent
      assert {:ok, [row]} = Changelog.timeline("openagents.com")
      assert row.summary == "Landed just now"
    end

    test "a rejected entry announces nothing" do
      :ok = Changelog.subscribe()

      assert {:error, _changeset} = Changelog.record(entry_attrs(%{category: "nonsense"}))
      refute_receive {:changelog_entry, _repo}, 20
    end

    test "the ledger's events are named once, for every subscriber" do
      assert Changelog.ledger_event?({:changelog_entry, "openagents.com"})
      assert Changelog.ledger_event?({:forge_deploy, %{sha: "abc"}})
      assert Changelog.ledger_event?({:forge_build_ready, %{}})
      refute Changelog.ledger_event?({:issues_changed, "some-id"})
      refute Changelog.ledger_event?(:refresh_dashboard)
    end
  end
end
