defmodule OpenAgents.Forge.IndependenceTest do
  @moduledoc """
  EXIT-002, EXIT-003, and EXIT-004: what a user can check, recover, and leave
  with when they do not take the operator's word for anything.

  Every test drives the real git client over real HTTP, so the WAL entries
  under examination are genuine `receive-pack` requests and the clones are
  genuine clones. A verifier that only ever saw synthetic entries would prove
  nothing about the forge people actually push to.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.{
    Anchor,
    Independence,
    PushReceipt,
    Pushes,
    Repos,
    Sync,
    Verification,
    WAL
  }

  alias OpenAgents.Repo

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base =
      Path.join(System.tmp_dir!(), "forge-independence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_mirrors = Application.get_env(:openagents, :forge_mirror_urls)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    OpenAgents.Forge.CacheReadiness.reset()

    user = OpenAgents.AccountsFixtures.repository_user_fixture("exit-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(user, %{name: "demo"}, "exit-demo")

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> OpenAgents.Repo.update!()

    {:ok, _api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "forge independence test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)

      if previous_mirrors do
        Application.put_env(:openagents, :forge_mirror_urls, previous_mirrors)
      else
        Application.delete_env(:openagents, :forge_mirror_urls)
      end

      OpenAgents.Forge.CacheReadiness.reset()
      File.rm_rf(base)
    end)

    %{
      base: base,
      repo: repository.storage_key,
      repository: repository,
      url: "http://x:#{plaintext}@127.0.0.1:#{port}/exit-owner/demo.git"
    }
  end

  ## ── EXIT-002: independent verification ─────────────────────────────────

  describe "independent verification" do
    test "an untampered forge verifies clean", context do
      seed_history!(context)

      assert {:ok, %{findings: []} = report} = Verification.verify(context.repo)
      assert report.entries >= 2
      assert report.repo == context.repo
    end

    test "a ref moved without a push is reported", context do
      seed_history!(context)
      path = Repos.bare_path(context.repo)

      {parent, 0} = Repos.git(path, ["rev-parse", "refs/heads/main^"])

      {_output, 0} =
        Repos.git(path, ["update-ref", "refs/heads/main", String.trim(parent)])

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"ref" => "refs/heads/main"} = detail(findings, "served_refs_diverged")
    end

    test "a ref added without a push is reported", context do
      seed_history!(context)
      path = Repos.bare_path(context.repo)
      {head, 0} = Repos.git(path, ["rev-parse", "refs/heads/main"])

      {_output, 0} =
        Repos.git(path, ["update-ref", "refs/heads/smuggled", String.trim(head)])

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)

      assert %{"ref" => "refs/heads/smuggled", "recorded" => nil} =
               detail(findings, "served_refs_diverged")
    end

    test "a rewritten entry no longer matches the key the index recorded", context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      [entry | _rest] = WAL.entries(index)

      # The key is a digest of the payload, so replacing the payload leaves the
      # index naming a key its own contents no longer produce.
      overwrite_entry!(context, entry["object"], "tampered")

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"seq" => 0} = detail(findings, "entry_digest_mismatch")
    end

    test "a removed entry breaks the recorded sequence", context do
      seed_history!(context)
      {:ok, generation, index} = WAL.read_index(context.repo)
      [_dropped | kept] = WAL.entries(index)

      {:ok, _generation} =
        WAL.cas_index(context.repo, generation, Map.put(index, "entries", kept))

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert detail(findings, "entry_sequence_broken") != nil
    end

    test "an entry object the store cannot produce is reported", context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      [entry | _rest] = WAL.entries(index)

      File.rm!(wal_object_path(context, entry["object"]))

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"seq" => 0} = detail(findings, "entry_object_missing")
    end

    test "a lost cache is reported as diverged refs and missing objects", context do
      seed_history!(context)
      File.rm_rf!(Repos.bare_path(context.repo))

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert detail(findings, "served_refs_diverged") != nil
      assert detail(findings, "object_missing") != nil
    end

    test "verification reaches no database", _context do
      # Independence is structural, not a promise: a verifier that queried
      # PostgreSQL would be asking the operator to confirm the operator.
      for module <- external_calls(Verification) do
        refute module == OpenAgents.Repo
        refute match?("Ecto." <> _rest, inspect(module))
        refute match?("Postgrex" <> _rest, inspect(module))
      end
    end

    test "an owner/name path resolves to the same report as its storage key", context do
      seed_history!(context)

      assert {:ok, by_key} = Verification.verify(context.repo)
      assert {:ok, by_name} = Verification.verify("exit-owner/demo")

      assert by_name.repo == "exit-owner/demo"
      assert by_name.storage_key == context.repo
      assert by_key.entries == by_name.entries
      assert by_key.head == by_name.head
      assert by_key.findings == []
      assert by_name.findings == []
    end

    test "an unknown owner/name returns a repository_not_found finding", _context do
      {:error, result} = Verification.verify("exit-owner/no-such-repo")

      assert result.repo == "exit-owner/no-such-repo"
      assert result.storage_key == nil
      assert result.entries == 0

      assert [%{code: "repository_not_found", detail: %{"repo" => "exit-owner/no-such-repo"}}] =
               result.findings
    end
  end

  ## ── EXIT-005: each entry commits to the entry before it ────────────────

  describe "chained entries" do
    test "every accepted push links to the push before it", context do
      seed_history!(context)

      assert {:ok, report} = Verification.verify(context.repo)
      assert report.chained_from == 0
      assert %{seq: seq, link: link} = report.head
      assert seq == report.entries - 1
      assert link =~ ~r/^[0-9a-f]{64}$/

      {:ok, _generation, index} = WAL.read_index(context.repo)

      index
      |> WAL.entries()
      |> Enum.reduce("", fn entry, previous ->
        assert {:ok, derived} = WAL.chain_link(previous, Map.delete(entry, "link"))
        assert derived == WAL.entry_link(entry)
        derived
      end)
    end

    test "a rewritten entry that leaves the chain alone is reported", context do
      seed_history!(context)
      {:ok, generation, index} = WAL.read_index(context.repo)
      [first | rest] = WAL.entries(index)

      File.rm!(wal_object_path(context, first["object"]))
      {:ok, key} = WAL.put_entry(context.repo, 0, "a payload the pusher never sent")

      {:ok, _generation} =
        WAL.cas_index(
          context.repo,
          generation,
          Map.put(index, "entries", [%{first | "object" => key} | rest])
        )

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"seq" => 0} = detail(findings, "chain_link_mismatch")
    end

    test "a link removed from the middle of the log is reported", context do
      seed_history!(context)
      {:ok, generation, index} = WAL.read_index(context.repo)
      [first | rest] = WAL.entries(index)

      {:ok, _generation} =
        WAL.cas_index(
          context.repo,
          generation,
          Map.put(index, "entries", [first | Enum.map(rest, &Map.delete(&1, "link"))])
        )

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"seq" => 1} = detail(findings, "chain_link_missing")
    end

    test "entries written before the chain are a boundary, not a finding", context do
      seed_history!(context)
      {:ok, generation, index} = WAL.read_index(context.repo)
      entries = WAL.entries(index)

      # The production shape on the day this ships: every entry already in the
      # log carries no link, and the first push after it binds to the chain
      # start because there is no predecessor link to name.
      {legacy, [newest]} = Enum.split(entries, length(entries) - 1)
      {:ok, link} = WAL.chain_link("", Map.delete(newest, "link"))

      relinked = Enum.map(legacy, &Map.delete(&1, "link")) ++ [Map.put(newest, "link", link)]

      {:ok, _generation} =
        WAL.cas_index(context.repo, generation, Map.put(index, "entries", relinked))

      assert {:ok, report} = Verification.verify(context.repo)
      assert report.findings == []
      assert report.chained_from == newest["seq"]
    end

    test "a push that changes no ref appends nothing and leaves the chain alone", context do
      seed_history!(context)
      assert {:ok, %{head: head, entries: count}} = Verification.verify(context.repo)

      sh!(work_dir(context), "git", ["push", "origin", "HEAD:main"])

      assert {:ok, %{head: ^head, entries: ^count}} = Verification.verify(context.repo)
    end

    test "a consistent rewrite verifies clean, and only an anchor reports it", context do
      seed_history!(context)
      assert {:ok, %{findings: [], head: head}} = Verification.verify(context.repo)

      rewrite_first_entry_consistently!(context, "a payload the pusher never sent")

      # This is the limit, stated as a test rather than as a caveat: an
      # operator who rewrites the entry, its content-addressed key, the index,
      # and every link after it leaves nothing inside their own storage that
      # disagrees with anything else inside it.
      assert {:ok, %{findings: []}} = Verification.verify(context.repo)

      # A link remembered before the rewrite is outside that storage, and it
      # disagrees. One remembered link covers the whole prefix, because the
      # chain makes a rewrite non-local.
      assert {:error, %{findings: findings}} = Verification.verify(context.repo, anchor: head)
      assert %{"seq" => _seq} = detail(findings, "anchor_mismatch")
    end

    test "an anchor for a sequence the log does not have is reported", context do
      seed_history!(context)

      anchor = %{seq: 99, link: String.duplicate("a", 64)}

      assert {:error, %{findings: findings}} = Verification.verify(context.repo, anchor: anchor)
      assert %{"seq" => 99} = detail(findings, "anchor_unreachable")
    end

    test "an unreadable anchor is ignored rather than failing verification", context do
      seed_history!(context)

      assert {:ok, %{findings: []}} = Verification.verify(context.repo, anchor: "nonsense")
      assert {:ok, %{findings: []}} = Verification.verify(context.repo, anchor: nil)
    end
  end

  ## ── EXIT-005: the receipt returned to the pusher ───────────────────────

  describe "the link git push hands back" do
    test "a push prints the sequence and link it produced", context do
      seed_history!(context)
      output = commit_and_push!(work_dir(context), "three.txt", "three\n", "three")

      # What a person sees, verbatim: git prefixes a side-band band-2 message
      # with `remote: `, so the receipt arrives in the push's own output.
      assert output =~ ~r/remote: *openagents wal-receipt seq=\d+ link=[0-9a-f]{64}/

      {seq, link} = wal_receipt!(output)

      {:ok, _generation, index} = WAL.read_index(context.repo)
      head = List.last(WAL.entries(index))

      assert seq == head["seq"]
      assert link == WAL.entry_link(head)

      # And where to read it again, so the line is self-describing.
      assert output =~ "/api/v3/repos/exit-owner/demo/pushes/#{seq}"
    end

    test "the link the pusher kept reports a rewrite the log agrees with", context do
      seed_history!(context)
      output = commit_and_push!(work_dir(context), "four.txt", "four\n", "four")
      {seq, link} = wal_receipt!(output)

      rewrite_first_entry_consistently!(context, "a payload the pusher never sent")

      # Nothing inside the operator's storage disagrees with anything else in
      # it, and the value the pusher wrote down does.
      assert {:ok, %{findings: []}} = Verification.verify(context.repo)

      assert {:error, %{findings: findings}} =
               Verification.verify(context.repo, anchor: %{seq: seq, link: link})

      assert %{"seq" => ^seq} = detail(findings, "anchor_mismatch")
    end

    test "a rejected push stays a rejected push and carries no receipt", context do
      seed_history!(context)
      work = work_dir(context)

      # Rewrite history behind the remote, so `receive-pack` refuses the
      # update. The report-status the client parses has to survive whatever
      # this change does to the stream, and there is no accepted entry to
      # hand back.
      sh!(work, "git", ["reset", "--hard", "HEAD~1"])
      File.write!(Path.join(work, "divergent.txt"), "divergent\n")
      sh!(work, "git", ["add", "."])
      sh!(work, "git", ["commit", "-m", "divergent"])

      {output, status} =
        System.cmd("git", ["-c", "credential.helper=", "push", "origin", "HEAD:main"],
          cd: work,
          stderr_to_stdout: true
        )

      assert status != 0, "the non-fast-forward push was accepted:\n#{output}"
      assert output =~ "rejected"
      refute output =~ "wal-receipt"
    end
  end

  ## ── EXIT-005: the anchor published to a stranger ───────────────────────

  describe "the anchor published at a well-known path" do
    test "a stranger who kept the document reports a consistent rewrite", context do
      publish_repository!(context)
      seed_history!(context)

      {:ok, published} = Anchor.publish()

      # The anchor a stranger holds is the bytes they fetched, so the head
      # comes out of the served document and not out of the log it commits to.
      head = document_head!(published, context)

      rewrite_first_entry_consistently!(context, "a payload the pusher never sent")

      # Nothing inside the operator's storage disagrees with anything else in
      # it. This is the case `EXIT-002` cannot catch, and #167's receipt only
      # catches for the one person who pushed.
      assert {:ok, %{findings: []}} = Verification.verify(context.repo)

      assert {:error, %{findings: findings}} = Verification.verify(context.repo, anchor: head)
      assert %{"seq" => _seq} = detail(findings, "anchor_mismatch")
    end

    test "the served bytes are what the digest and the next anchor name", context do
      publish_repository!(context)
      seed_history!(context)

      {:ok, first} = Anchor.publish()
      {:ok, second} = Anchor.publish()

      # A reader hashes the file they fetched, so the stored digest has to be
      # a digest of the stored bytes and nothing re-rendered from columns.
      assert Anchor.digest(first.body) == first.digest
      assert Anchor.digest(second.body) == second.digest

      # The published sequence is itself a chain: one archived anchor pins
      # every anchor before it, the way an entry link pins every entry.
      assert first.anchor_seq == 0
      assert first.previous_digest == nil
      assert second.anchor_seq == 1
      assert second.previous_digest == first.digest
    end

    test "a private repository is anchored for nobody", context do
      seed_history!(context)

      # The repository is private in this setup, and the anchor is anonymous.
      # Naming it here would publish its existence and its push count on a
      # surface `TRANSPARENCY-001` keeps a dark repository off entirely.
      {:ok, private_anchor} = Anchor.publish()
      assert repository_section(private_anchor, context) == nil

      publish_repository!(context)
      {:ok, public_anchor} = Anchor.publish()
      assert %{"entries" => entries} = repository_section(public_anchor, context)
      assert entries > 0
    end

    test "the document states that nobody witnesses it", context do
      publish_repository!(context)
      seed_history!(context)

      {:ok, published} = Anchor.publish()
      document = Jason.decode!(published.body)

      # ADR 0008: the operator serves this, so it proves nothing on its own.
      # The claim has to travel with the artifact, not only with the docs.
      refute document["witnessed"]
      refute document["signed"]
      assert document["trust"] =~ "witnessed by nobody"
      assert document["decision"] =~ "0008"
    end

    test "each axis of the disclosure decides degraded on its own", _context do
      clean_export = %{"gaps" => []}

      # #178 split the private-data axis in two: an export encrypted to a
      # recipient-held key, and a store that is still plaintext. Both have to
      # be clean before the axis is, so the "private" side of this table
      # varies each of them.
      private_clean = %{
        "export_recipient_encryption" => true,
        "encrypted_at_rest" => true
      }

      unencrypted_export = %{private_clean | "export_recipient_encryption" => false}
      plaintext_store = %{private_clean | "encrypted_at_rest" => false}
      published_unwitnessed = %{"anchor_published" => true, "anchor_witnessed" => false}
      witnessed = %{"anchor_published" => true, "anchor_witnessed" => true}
      unpublished = %{"anchor_published" => false, "anchor_witnessed" => false}

      # Publishing the anchor is not witnessing it, and the disclosure has to
      # keep reporting degraded on the second. Every other axis is clean here,
      # so this asserts the witness disjunct rather than riding on a constant.
      assert Independence.degraded?(clean_export, published_unwitnessed, private_clean)
      assert Independence.degraded?(clean_export, unpublished, private_clean)
      assert Independence.degraded?(clean_export, witnessed, unencrypted_export)
      assert Independence.degraded?(clean_export, witnessed, plaintext_store)
      assert Independence.degraded?(%{"gaps" => [%{}]}, witnessed, private_clean)
      refute Independence.degraded?(clean_export, witnessed, private_clean)
    end
  end

  ## ── EXIT-003: recovery from the WAL, never from the mirror ─────────────

  describe "recovery" do
    test "the WAL rebuilds the repository and re-derives receipts the database lost", context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      expected_refs = WAL.refs(index)
      entries = WAL.entries(index)

      Repo.delete_all(PushReceipt)
      File.rm_rf!(Repos.bare_path(context.repo))

      assert :ok = Sync.ensure_fresh(context.repo, "main")
      assert Repos.refs(context.repo) == expected_refs
      assert {:ok, %{findings: []}} = Verification.verify(context.repo)

      assert Pushes.reconcile_receipts(context.repo) == length(entries)

      recovered =
        PushReceipt
        |> Repo.all()
        |> Enum.sort_by(& &1.wal_seq)

      assert Enum.map(recovered, & &1.wal_seq) == Enum.map(entries, & &1["seq"])
      assert Enum.map(recovered, & &1.principal) == Enum.map(entries, & &1["principal"])

      # The chain link comes back with the row, taken from the entry it
      # derives from rather than from anything the emptied table held.
      links = Enum.map(entries, &WAL.entry_link/1)
      refute Enum.any?(links, &is_nil/1)
      assert Enum.map(recovered, & &1.link) == links
    end

    test "the mirror restores source and cannot restore the push record", context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      exportable = Verification.exportable_refs(WAL.refs(index))

      mirror = Path.join(context.base, "mirror.git")
      sh!(context.base, "git", ["init", "--bare", "--initial-branch=main", mirror])
      Application.put_env(:openagents, :forge_mirror_urls, %{context.repo => mirror})

      assert :ok = Pushes.mirror_now(context.repo)
      assert Repos.refs_at(mirror) == exportable

      # Now lose the forge: the WAL is gone and the derived receipts with it.
      # The mirror still holds every commit, and that is all it holds.
      File.rm_rf!(Application.get_env(:openagents, :forge_wal_dir))
      File.rm_rf!(Repos.bare_path(context.repo))
      Repo.delete_all(PushReceipt)

      assert {:error, :not_found} = WAL.read_index(context.repo)
      assert Pushes.reconcile_receipts(context.repo) == 0
      assert Repo.aggregate(PushReceipt, :count) == 0

      restored = Path.join(context.base, "restored.git")
      sh!(context.base, "git", ["clone", "--mirror", mirror, restored])
      assert Repos.refs_at(restored) == exportable

      # Source recovered, evidence not: no sequence, no principal, no push time
      # survives a mirror, because a mirror is a ref map and a pack.
      assert Repos.applied_seq_at(restored) == -1

      mirror_bytes =
        mirror
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map_join("\n", &File.read!/1)

      for entry <- WAL.entries(index) do
        refute String.contains?(mirror_bytes, entry["principal"]),
               "the mirror carries the push principal #{entry["principal"]}"

        refute String.contains?(mirror_bytes, entry["pushed_at"])
      end
    end

    test "the rebuild path never reads the mirror", _context do
      # GitHub is a mirror and never authority. That direction holds only while
      # nothing on the recovery path can consult it.
      for module <- [Sync, Repos] do
        for {called, function, _arity} <- external_calls_with_functions(module) do
          refute called == OpenAgents.Forge.MirrorWatch,
                 "#{inspect(module)} reaches the mirror watcher"

          refute called == Pushes and function in [:mirror_url, :mirror_now, :mirror_storage_key],
                 "#{inspect(module)} reads the mirror through #{function}"
        end
      end
    end
  end

  ## ── EXIT-003: the receipt carries the link and decides nothing ─────────

  describe "the derived receipt's chain link" do
    test "every receipt carries the link of the entry it derives from", context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)

      expected =
        index
        |> WAL.entries()
        |> Map.new(fn entry -> {entry["seq"], WAL.entry_link(entry)} end)

      refute expected == %{}
      refute Enum.any?(expected, fn {_seq, link} -> is_nil(link) end)

      recorded =
        PushReceipt
        |> Repo.all()
        |> Map.new(fn receipt -> {receipt.wal_seq, receipt.link} end)

      assert recorded == expected
    end

    test "a rewritten receipt link decides nothing, because the verifier reads the WAL",
         context do
      seed_history!(context)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      head = List.last(WAL.entries(index))

      # The receipt is a projection. Edit every stored link to a value the log
      # never produced: verification is unmoved, because it recomputes the
      # chain from the WAL and never asks PostgreSQL what the chain is.
      {3, _returning} = Repo.update_all(PushReceipt, set: [link: String.duplicate("0", 64)])

      assert {:ok, report} = Verification.verify(context.repo)
      assert report.findings == []
      assert report.head == %{seq: head["seq"], link: WAL.entry_link(head)}

      assert {:ok, %{findings: []}} =
               Verification.verify(context.repo,
                 anchor: %{seq: head["seq"], link: WAL.entry_link(head)}
               )
    end
  end

  ## ── EXIT-004: a clone is complete and self-hosting ─────────────────────

  describe "clone completeness" do
    test "a clone carries every advertised ref and every object behind it", context do
      seed_history!(context)
      sh!(context.base, "git", ["-C", work_dir(context), "tag", "v1"])
      sh!(work_dir(context), "git", ["push", "origin", "v1"])

      {:ok, _generation, index} = WAL.read_index(context.repo)
      exportable = Verification.exportable_refs(WAL.refs(index))
      assert Map.has_key?(exportable, "refs/tags/v1")
      assert Map.has_key?(exportable, "refs/heads/feature")

      clone = Path.join(context.base, "exit.git")
      sh!(context.base, "git", ["clone", "--mirror", context.url, clone])

      assert Repos.refs_at(clone) == exportable

      for {_name, sha} <- exportable do
        assert {_output, 0} = Repos.git(clone, ["cat-file", "-e", sha])
      end

      assert {_output, 0} = Repos.git(clone, ["fsck", "--no-progress"])
    end

    test "the clone re-serves the same history with the forge gone", context do
      seed_history!(context)
      clone = Path.join(context.base, "self-hosted.git")
      sh!(context.base, "git", ["clone", "--mirror", context.url, clone])

      # Stop trusting the forge entirely: delete its cache and its WAL, then
      # clone from the copy the user took.
      File.rm_rf!(Repos.bare_path(context.repo))
      File.rm_rf!(Application.get_env(:openagents, :forge_wal_dir))

      elsewhere = Path.join(context.base, "elsewhere")
      sh!(context.base, "git", ["clone", clone, elsewhere])

      assert File.read!(Path.join(elsewhere, "one.txt")) == "one\n"
      assert File.read!(Path.join(elsewhere, "two.txt")) == "two\n"

      sh!(elsewhere, "git", ["checkout", "feature"])
      assert File.read!(Path.join(elsewhere, "feature.txt")) == "feature\n"
    end

    test "only the internal bookkeeping namespace is withheld", context do
      seed_history!(context)
      path = Repos.bare_path(context.repo)

      assert {"refs/internal/\n", 0} = Repos.git(path, ["config", "--get", "transfer.hideRefs"])

      # Through the git plane, so the ref is recorded in the WAL and survives
      # the convergence a clone triggers.
      {:ok, head} = OpenAgents.Forge.GitPlane.resolve_commit(context.repo, "refs/heads/main")

      {:ok, _result} =
        OpenAgents.Forge.GitPlane.batch_update_refs(
          context.repo,
          [%{ref: "refs/internal/boundary", expected_old: :absent, new: head}],
          "exit-test"
        )

      clone = Path.join(context.base, "hidden.git")
      sh!(context.base, "git", ["clone", "--mirror", context.url, clone])

      refute Map.has_key?(Repos.refs_at(clone), "refs/internal/boundary")

      served = Repos.refs(context.repo)
      assert Map.has_key?(served, "refs/internal/boundary")
      assert Repos.refs_at(clone) == Verification.exportable_refs(served)
    end

    test "a repository seeded from a shallow fetch still serves a full clone", context do
      # The shape this forge's own repository is in, and the one #179 named:
      # seq 0 is a bundle from a `--depth=1` fetch, written before WAL entries
      # carried a `shallow` key, so the log states no boundary and the
      # projection holds a commit whose parent it does not have. Every ref tip
      # resolves, so every tip-shaped check passes; a clone still aborts.
      seed_unrecorded_shallow_import!(context)
      :ok = Sync.ensure_fresh(context.repo)

      # A real push on top, so what is cloned is the production shape rather
      # than a bare seed: pushes layered over an unrecorded shallow boundary.
      work = Path.join(context.base, "shallow-work")
      sh!(context.base, "git", ["clone", "--depth=1", context.url, work])
      sh!(work, "git", ["config", "user.email", "test@example.com"])
      sh!(work, "git", ["config", "user.name", "Forge Test"])
      commit_and_push!(work, "after.txt", "after\n", "after")

      clone = Path.join(context.base, "seeded")
      sh!(context.base, "git", ["clone", context.url, clone])

      assert File.read!(Path.join(clone, "after.txt")) == "after\n"
      assert File.read!(Path.join(clone, "history-3.txt")) == "history 3\n"
      sh!(clone, "git", ["fsck", "--no-progress"])
      assert {:ok, %{findings: []}} = Verification.verify(context.repo)
    end

    test "a history a clone cannot walk is reported even when every tip resolves", context do
      seed_unrecorded_shallow_import!(context)
      :ok = Sync.ensure_fresh(context.repo)

      path = Repos.bare_path(context.repo)
      {:ok, _generation, index} = WAL.read_index(context.repo)
      head = index |> WAL.refs() |> Map.fetch!("refs/heads/main")

      # Every tip is present, which is all `object_missing` asks.
      assert {_output, 0} = Repos.git(path, ["cat-file", "-e", head])

      # Ungraft the projection the way a replay written before `REPOSITORY-003`
      # did, without touching a single object.
      File.rm(Path.join(path, "shallow"))

      assert {:error, %{findings: findings}} = Verification.verify(context.repo)
      assert %{"object" => object} = detail(findings, "object_unreachable")
      assert object =~ ~r/^[0-9a-f]{40,64}$/
      refute Enum.any?(findings, &(&1.code == "object_missing"))
    end
  end

  ## ── helpers ────────────────────────────────────────────────────────────

  # The one line a pusher keeps. Parsed the way a pusher would grep for it.
  defp wal_receipt!(output) do
    case Regex.run(~r/openagents wal-receipt seq=(\d+) link=([0-9a-f]{64})/, output) do
      [_line, seq, link] -> {String.to_integer(seq), link}
      nil -> flunk("git push printed no WAL receipt line:\n#{output}")
    end
  end

  defp detail(findings, code) do
    Enum.find_value(findings, fn
      %{code: ^code, detail: detail} -> detail
      _other -> nil
    end)
  end

  defp external_calls(module) do
    module |> external_calls_with_functions() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  defp external_calls_with_functions(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp wal_object_path(context, object_key) do
    Path.join([Application.get_env(:openagents, :forge_wal_dir), context.repo, object_key])
  end

  defp overwrite_entry!(context, object_key, contents) do
    File.write!(wal_object_path(context, object_key), contents)
  end

  defp work_dir(context), do: Path.join(context.base, "work")

  # The setup's repository is private, which is what a repository is by
  # default. The anchor's population is what an anonymous reader can already
  # see, so a test about publication has to publish first.
  defp publish_repository!(context) do
    context.repository
    |> Ecto.Changeset.change(visibility: "public")
    |> Repo.update!()
  end

  defp repository_section(anchor, context) do
    path = "#{context.repository.owner}/#{context.repository.name}"

    anchor.body
    |> Jason.decode!()
    |> Map.fetch!("repositories")
    |> Enum.find(&(&1["repo"] == path))
  end

  defp document_head!(anchor, context) do
    case repository_section(anchor, context) do
      %{"head_seq" => seq, "head_link" => link} when is_integer(seq) and is_binary(link) ->
        %{seq: seq, link: link}

      other ->
        flunk("the published anchor carried no head for the repository: #{inspect(other)}")
    end
  end

  # What an operator with write access to their own object storage can do:
  # replace an accepted entry, re-derive its content-addressed key, and
  # recompute every link after it so the log agrees with itself.
  defp rewrite_first_entry_consistently!(context, replacement) do
    {:ok, generation, index} = WAL.read_index(context.repo)
    [first | rest] = WAL.entries(index)

    File.rm!(wal_object_path(context, first["object"]))
    {:ok, key} = WAL.put_entry(context.repo, first["seq"], replacement)

    entries =
      [%{first | "object" => key} | rest]
      |> Enum.map_reduce("", fn entry, previous ->
        {:ok, link} = WAL.chain_link(previous, Map.delete(entry, "link"))
        {Map.put(entry, "link", link), link}
      end)
      |> elem(0)

    {:ok, _generation} =
      WAL.cas_index(context.repo, generation, Map.put(index, "entries", entries))

    :ok
  end

  # Two commits on main and one on a branch, all through the real push path,
  # so the WAL holds three genuine `receive-pack` entries.
  defp seed_history!(context) do
    work = work_dir(context)

    unless File.exists?(work) do
      sh!(context.base, "git", ["clone", context.url, work])
      sh!(work, "git", ["config", "user.email", "test@example.com"])
      sh!(work, "git", ["config", "user.name", "Forge Test"])
      commit_and_push!(work, "one.txt", "one\n", "one")
      commit_and_push!(work, "two.txt", "two\n", "two")
      sh!(work, "git", ["checkout", "-b", "feature"])
      commit_and_push!(work, "feature.txt", "feature\n", "feature", "feature")
      sh!(work, "git", ["checkout", "main"])
    end

    :ok
  end

  # A `--depth=1` fetch bundled with `--all` and recorded as the seq 0 entry
  # *without* a `shallow` key, which is what every entry written before that
  # key existed looks like. `OpenAgents.Repositories.Importer` records the key
  # now, and nothing backfills a log that predates it, so this is not a
  # hypothetical shape.
  defp seed_unrecorded_shallow_import!(context) do
    source = Path.join(context.base, "seed-source")
    File.mkdir_p!(source)
    sh!(source, "git", ["init", "--initial-branch=main", "."])
    sh!(source, "git", ["config", "user.email", "test@example.com"])
    sh!(source, "git", ["config", "user.name", "Forge Test"])

    Enum.each(1..3, fn n ->
      File.write!(Path.join(source, "history-#{n}.txt"), "history #{n}\n")
      sh!(source, "git", ["add", "."])
      sh!(source, "git", ["commit", "-m", "history #{n}"])
    end)

    snapshot = Path.join(context.base, "seed-snapshot.git")
    sh!(context.base, "git", ["init", "--bare", "--initial-branch=main", snapshot])

    sh!(context.base, "git", [
      "--git-dir",
      snapshot,
      "fetch",
      "--depth=1",
      source,
      "refs/heads/main:refs/heads/main"
    ])

    bundle = Path.join(context.base, "seed-snapshot.bundle")
    sh!(context.base, "git", ["--git-dir", snapshot, "bundle", "create", bundle, "--all"])

    head =
      context.base
      |> sh!("git", ["--git-dir", snapshot, "rev-parse", "refs/heads/main"])
      |> String.trim()

    {expected, index} =
      case WAL.read_index(context.repo) do
        {:ok, generation, index} -> {generation, index}
        {:error, :not_found} -> {:none, WAL.new_index()}
      end

    seq = WAL.next_seq(index)
    {:ok, object} = WAL.put_entry_file(context.repo, seq, bundle)

    entry = %{
      "seq" => seq,
      "object" => object,
      "format" => "git_bundle",
      "refs" => %{"refs/heads/main" => head},
      "principal" => "bootstrap:test",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} = WAL.cas_index(context.repo, expected, WAL.append_entry(index, entry))

    :ok
  end

  defp commit_and_push!(work, filename, contents, message, branch \\ "main") do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:#{branch}"])
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end
end
