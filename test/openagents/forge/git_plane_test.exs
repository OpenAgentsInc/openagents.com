defmodule OpenAgents.Forge.GitPlaneTest do
  @moduledoc """
  Git primitives for the stack service (#46): ref resolution, ancestry,
  merge bases, `merge-tree --write-tree` planning, boundary-based commit
  replay, hidden retention refs, and atomic batch compare-and-swap ref
  updates persisted as one WAL entry per batch.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.Forge.{GitPlane, Repos, Sync, WAL}

  @repo "openagents.com"

  setup do
    base = Path.join(System.tmp_dir!(), "forge-plane-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.get_env(:openagents, :forge_wal_adapter)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      restore_env(:forge_wal_adapter, previous_adapter)
      File.rm_rf(base)
    end)

    seed_repo(base)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  # Commit graph, seeded via plumbing and then recorded as WAL entry 0 so the
  # bare repo is a disposable projection like it is in production:
  #
  #     base ── b1 ── b2 ── c1     (layer-1 = b2, layer-2 = c1)
  #        ├── trunk_x             (main moved past the boundary)
  #        └── conflict_k          (touches the same path as b1)
  #     root_d                     (disconnected history)
  defp seed_repo(base) do
    path = Repos.ensure_repo!(@repo)

    file_base = write_blob(path, "base\n")
    other_base = write_blob(path, "other\n")

    tree_base =
      mktree(path, "100644 blob #{file_base}\tfile.txt\n100644 blob #{other_base}\tother.txt\n")

    base_commit = commit_tree(path, tree_base, [], "Base commit\n")

    file_b1 = write_blob(path, "layer one\n")

    tree_b1 =
      mktree(path, "100644 blob #{file_b1}\tfile.txt\n100644 blob #{other_base}\tother.txt\n")

    b1 = commit_tree(path, tree_b1, ["-p", base_commit], "Layer one, first commit\n")

    b2_extra = write_blob(path, "second\n")

    tree_b2 =
      mktree(
        path,
        "100644 blob #{b2_extra}\tb2.txt\n100644 blob #{file_b1}\tfile.txt\n" <>
          "100644 blob #{other_base}\tother.txt\n"
      )

    b2 = commit_tree(path, tree_b2, ["-p", b1], "Layer one, second commit\n")

    c1_extra = write_blob(path, "layer two\n")

    tree_c1 =
      mktree(
        path,
        "100644 blob #{b2_extra}\tb2.txt\n100644 blob #{c1_extra}\tc1.txt\n" <>
          "100644 blob #{file_b1}\tfile.txt\n100644 blob #{other_base}\tother.txt\n"
      )

    c1 = commit_tree(path, tree_c1, ["-p", b2], "Layer two\n")

    other_x = write_blob(path, "trunk moved\n")

    tree_x =
      mktree(path, "100644 blob #{file_base}\tfile.txt\n100644 blob #{other_x}\tother.txt\n")

    trunk_x = commit_tree(path, tree_x, ["-p", base_commit], "Trunk advance\n")

    file_k = write_blob(path, "conflicting\n")

    tree_k =
      mktree(path, "100644 blob #{file_k}\tfile.txt\n100644 blob #{other_base}\tother.txt\n")

    conflict_k = commit_tree(path, tree_k, ["-p", base_commit], "Conflicting change\n")

    root_blob = write_blob(path, "disconnected\n")
    tree_d = mktree(path, "100644 blob #{root_blob}\td.txt\n")
    root_d = commit_tree(path, tree_d, [], "Disconnected root\n")

    refs = %{
      "refs/heads/main" => trunk_x,
      "refs/heads/layer-1" => b2,
      "refs/heads/layer-2" => c1,
      "refs/heads/boundary" => base_commit,
      "refs/heads/conflicting" => conflict_k,
      "refs/heads/disconnected" => root_d
    }

    Enum.each(refs, fn {name, sha} ->
      {_, 0} = Repos.git(path, ["update-ref", name, sha])
    end)

    bundle = Path.join(base, "seed.bundle")
    {_, 0} = Repos.git(path, ["bundle", "create", bundle, "--all"])
    {:ok, object} = WAL.put_entry_file(@repo, 0, bundle)

    entry = %{
      "seq" => 0,
      "object" => object,
      "format" => "git_bundle",
      "refs" => refs,
      "principal" => "test:seed",
      "pushed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, _generation} = WAL.cas_index(@repo, :none, WAL.append_entry(WAL.new_index(), entry))
    Repos.record_applied_seq!(@repo, 0)

    %{
      path: path,
      base_commit: base_commit,
      b1: b1,
      b2: b2,
      c1: c1,
      trunk_x: trunk_x,
      conflict_k: conflict_k,
      root_d: root_d,
      refs: refs
    }
  end

  defp write_blob(path, content) do
    {sha, 0} = git_in(path, ["hash-object", "-w", "--stdin"], content)
    String.trim(sha)
  end

  defp mktree(path, listing) do
    {sha, 0} = git_in(path, ["mktree"], listing)
    String.trim(sha)
  end

  defp commit_tree(path, tree, parent_args, message) do
    {sha, 0} =
      git_in(path, ["commit-tree", tree] ++ parent_args, message,
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
        ]
      )

    String.trim(sha)
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "plane-stdin-#{System.unique_integer([:positive])}")
    File.write!(input, stdin)

    try do
      System.cmd(
        "sh",
        ["-c", ~s(exec git --git-dir "$GD" "$@" < "$IN"), "sh"] ++ args,
        env: [{"GD", path}, {"IN", input}] ++ Keyword.get(opts, :env, [])
      )
    after
      File.rm(input)
    end
  end

  defp show(path, args) do
    {output, 0} = Repos.git(path, args)
    String.trim(output)
  end

  describe "resolve_commit/2" do
    test "resolves a branch, a full OID, and a short OID", %{b2: b2} do
      assert {:ok, ^b2} = GitPlane.resolve_commit(@repo, "layer-1")
      assert {:ok, ^b2} = GitPlane.resolve_commit(@repo, b2)
      assert {:ok, ^b2} = GitPlane.resolve_commit(@repo, String.slice(b2, 0, 10))
    end

    test "an unknown or malformed ref is :not_found" do
      assert {:error, :not_found} = GitPlane.resolve_commit(@repo, "no-such-branch")
      assert {:error, :not_found} = GitPlane.resolve_commit(@repo, "-evil")
      assert {:error, :not_found} = GitPlane.resolve_commit(@repo, "a..b")
    end
  end

  describe "ancestor?/3" do
    test "reports ancestry along and across branches", %{
      base_commit: base_commit,
      b2: b2,
      trunk_x: trunk_x
    } do
      assert {:ok, true} = GitPlane.ancestor?(@repo, base_commit, b2)
      assert {:ok, false} = GitPlane.ancestor?(@repo, b2, base_commit)
      assert {:ok, false} = GitPlane.ancestor?(@repo, b2, trunk_x)
      assert {:ok, true} = GitPlane.ancestor?(@repo, b2, b2)
    end
  end

  describe "containing/3" do
    test "answers the whole matrix in one read", %{
      base_commit: base_commit,
      b1: b1,
      b2: b2,
      c1: c1,
      trunk_x: trunk_x
    } do
      assert {:ok, matrix} = GitPlane.containing(@repo, [b1, trunk_x], [b2, c1, trunk_x])

      assert matrix[b1] == [b2, c1]
      assert matrix[trunk_x] == [trunk_x]

      assert {:ok, %{^base_commit => carried}} =
               GitPlane.containing(@repo, [base_commit], [b2, trunk_x])

      assert carried == [b2, trunk_x]
    end

    test "a revision the repository does not have contains nothing", %{b2: b2} do
      absent = String.duplicate("a", 40)

      assert {:ok, matrix} = GitPlane.containing(@repo, [absent, b2], [b2, absent])
      assert matrix[absent] == []
      assert matrix[b2] == [b2]
    end

    test "refuses a matrix past the pair bound rather than scanning it", %{b2: b2} do
      candidates = List.duplicate(b2, 65)

      assert {:error, :too_many_pairs} = GitPlane.containing(@repo, [b2], candidates)
      assert {:ok, _matrix} = GitPlane.containing(@repo, [b2], Enum.take(candidates, 64))
    end

    test "an empty ask is an empty answer", %{b2: b2} do
      assert {:ok, %{}} = GitPlane.containing(@repo, [], [b2])
      assert {:ok, %{^b2 => []}} = GitPlane.containing(@repo, [b2], [])
      assert {:error, :not_found} = GitPlane.containing(@repo, b2, [b2])
    end
  end

  describe "merge_base/3" do
    test "finds the common ancestor of diverged branches", %{base_commit: base_commit} do
      assert {:ok, ^base_commit} = GitPlane.merge_base(@repo, "layer-1", "main")
    end

    test "disconnected histories have no merge base", %{root_d: root_d, b2: b2} do
      assert {:error, :no_merge_base} = GitPlane.merge_base(@repo, root_d, b2)
    end
  end

  describe "merge_tree/4" do
    test "a clean merge returns the merged tree without touching refs", %{path: path, refs: refs} do
      assert {:ok, %{tree: tree}} = GitPlane.merge_tree(@repo, "layer-1", "main")
      assert show(path, ["cat-file", "blob", tree <> ":file.txt"]) == "layer one"
      assert show(path, ["cat-file", "blob", tree <> ":other.txt"]) == "trunk moved"
      assert Repos.refs(@repo) == refs
    end

    test "a conflict returns structured path data", %{refs: refs} do
      assert {:conflict, conflict} = GitPlane.merge_tree(@repo, "layer-1", "conflicting")
      assert conflict.paths == ["file.txt"]
      assert Enum.all?(conflict.files, &(&1.path == "file.txt"))
      assert Enum.map(conflict.files, & &1.stage) == ["1", "2", "3"]
      assert Regex.match?(~r/\A[0-9a-f]{40,64}\z/, conflict.tree)
      assert Repos.refs(@repo) == refs
    end

    test "an explicit merge base is honored", %{b1: b1, b2: b2, path: path} do
      assert {:ok, %{tree: tree}} = GitPlane.merge_tree(@repo, "main", b2, merge_base: b1)
      assert show(path, ["cat-file", "blob", tree <> ":other.txt"]) == "trunk moved"
    end
  end

  describe "replay/4" do
    test "replays only commits after the boundary onto the new parent", %{
      path: path,
      base_commit: base_commit,
      b1: b1,
      b2: b2,
      trunk_x: trunk_x
    } do
      assert {:ok, %{new_head: new_head, replayed: replayed}} =
               GitPlane.replay(@repo, base_commit, b2, trunk_x)

      assert [%{old: ^b1, new: new_b1}, %{old: ^b2, new: new_b2}] = replayed
      assert new_head == new_b2
      assert show(path, ["rev-parse", new_b1 <> "^"]) == trunk_x
      assert show(path, ["rev-parse", new_b2 <> "^"]) == new_b1
      assert show(path, ["cat-file", "blob", new_b2 <> ":file.txt"]) == "layer one"
      assert show(path, ["cat-file", "blob", new_b2 <> ":other.txt"]) == "trunk moved"

      assert show(path, ["show", "-s", "--format=%an <%ae>", new_b1]) ==
               "Test Author <author@example.test>"

      assert show(path, ["show", "-s", "--format=%cn <%ce>", new_b1]) ==
               "OpenAgents Forge <forge@openagents.com>"

      assert show(path, ["show", "-s", "--format=%s", new_b1]) == "Layer one, first commit"
    end

    test "an empty range returns the new parent unchanged", %{b2: b2, trunk_x: trunk_x} do
      assert {:ok, %{new_head: ^trunk_x, replayed: []}} =
               GitPlane.replay(@repo, b2, b2, trunk_x)
    end

    test "a conflicting commit reports the commit, paths, and completed steps", %{
      base_commit: base_commit,
      b1: b1,
      conflict_k: conflict_k
    } do
      assert {:conflict, conflict} = GitPlane.replay(@repo, base_commit, conflict_k, b1)
      assert conflict.commit == conflict_k
      assert conflict.onto == b1
      assert conflict.paths == ["file.txt"]
      assert conflict.replayed == []
    end

    test "a merge commit in the range is rejected", %{
      path: path,
      base_commit: base_commit,
      b2: b2,
      trunk_x: trunk_x
    } do
      tree = show(path, ["rev-parse", b2 <> "^{tree}"])
      merge = commit_tree(path, tree, ["-p", b2, "-p", trunk_x], "Merge\n")

      assert {:error, {:merge_commit, ^merge}} =
               GitPlane.replay(@repo, base_commit, merge, trunk_x)
    end
  end

  describe "internal_ref/1" do
    test "builds hidden retention ref names" do
      assert {:ok, "refs/internal/stacks/7/boundary"} =
               GitPlane.internal_ref(["stacks", "7", "boundary"])
    end

    test "rejects unsafe segments" do
      assert {:error, :invalid_ref} = GitPlane.internal_ref(["a/b"])
      assert {:error, :invalid_ref} = GitPlane.internal_ref(["-flag"])
      assert {:error, :invalid_ref} = GitPlane.internal_ref([""])
      assert {:error, :invalid_ref} = GitPlane.internal_ref(["x.lock"])
    end
  end

  describe "batch_update_refs/3" do
    test "applies every ref in one WAL transition and survives cache loss", %{
      b2: b2,
      base_commit: base_commit,
      refs: refs
    } do
      {:ok, retention} = GitPlane.internal_ref(["stacks", "1", "boundary"])

      updates = [
        %{ref: "refs/heads/stack-1", expected_old: :absent, new: b2},
        %{ref: retention, expected_old: :absent, new: base_commit}
      ]

      assert {:ok, %{seq: 1, refs: refs_after}} =
               GitPlane.batch_update_refs(@repo, updates, "test:batch")

      assert refs_after ==
               Map.merge(refs, %{"refs/heads/stack-1" => b2, retention => base_commit})

      {:ok, _generation, index} = WAL.read_index(@repo)
      assert [_seed, batch_entry] = WAL.entries(index)
      assert batch_entry["principal"] == "test:batch"
      assert WAL.refs(index) == refs_after

      File.rm_rf!(Repos.bare_path(@repo))
      assert :ok = Sync.ensure_fresh(@repo)
      assert Repos.refs(@repo) == refs_after
    end

    test "a mismatched expected OID rejects the whole batch", %{
      b2: b2,
      trunk_x: trunk_x,
      refs: refs
    } do
      updates = [
        %{ref: "refs/heads/stack-1", expected_old: :absent, new: b2},
        %{ref: "refs/heads/main", expected_old: b2, new: b2}
      ]

      assert {:error, {:expected_mismatch, "refs/heads/main", ^trunk_x}} =
               GitPlane.batch_update_refs(@repo, updates, "test:batch")

      assert Repos.refs(@repo) == refs
      {:ok, _generation, index} = WAL.read_index(@repo)
      assert length(WAL.entries(index)) == 1
    end

    test "a git-rejected transaction applies none of the batch", %{b2: b2, refs: refs} do
      updates = [
        %{ref: "refs/heads/stack-1", expected_old: :absent, new: b2},
        %{ref: "refs/heads/main/nested", expected_old: :absent, new: b2}
      ]

      assert {:error, :ref_update_failed} =
               GitPlane.batch_update_refs(@repo, updates, "test:batch")

      assert Repos.refs(@repo) == refs
    end

    test "deletes and moves to known OIDs persist without a bundle", %{
      b2: b2,
      c1: c1,
      base_commit: base_commit
    } do
      updates = [
        %{ref: "refs/heads/layer-2", expected_old: c1, new: :delete},
        %{ref: "refs/heads/boundary", expected_old: base_commit, new: b2}
      ]

      assert {:ok, %{seq: 1, refs: refs_after}} =
               GitPlane.batch_update_refs(@repo, updates, "test:batch")

      refute Map.has_key?(refs_after, "refs/heads/layer-2")
      assert refs_after["refs/heads/boundary"] == b2

      {:ok, _generation, index} = WAL.read_index(@repo)
      assert [_seed, batch_entry] = WAL.entries(index)
      assert batch_entry["format"] == "ref_update"

      File.rm_rf!(Repos.bare_path(@repo))
      assert :ok = Sync.ensure_fresh(@repo)
      assert Repos.refs(@repo) == refs_after
    end

    test "malformed updates never reach git", %{b2: b2} do
      assert {:error, :invalid_update} =
               GitPlane.batch_update_refs(
                 @repo,
                 [%{ref: "main", expected_old: :absent, new: b2}],
                 "t"
               )

      assert {:error, :invalid_update} =
               GitPlane.batch_update_refs(
                 @repo,
                 [%{ref: "refs/heads/x", expected_old: :absent, new: "not-an-oid"}],
                 "t"
               )

      assert {:error, :invalid_update} =
               GitPlane.batch_update_refs(
                 @repo,
                 [
                   %{ref: "refs/heads/x", expected_old: :absent, new: b2},
                   %{ref: "refs/heads/x", expected_old: :absent, new: b2}
                 ],
                 "t"
               )

      assert {:error, :invalid_update} =
               GitPlane.batch_update_refs(
                 @repo,
                 [%{ref: "refs/heads/x", expected_old: :absent, new: :delete}],
                 "t"
               )
    end

    test "hidden internal refs are not advertised to clients", %{
      path: path,
      base_commit: base_commit
    } do
      {:ok, retention} = GitPlane.internal_ref(["stacks", "1", "boundary"])

      assert {:ok, _result} =
               GitPlane.batch_update_refs(
                 @repo,
                 [%{ref: retention, expected_old: :absent, new: base_commit}],
                 "test:batch"
               )

      {advertised, 0} =
        OpenAgents.Forge.GitHTTP.run_git_service(
          "upload-pack",
          ["--advertise-refs", path],
          "",
          nil
        )

      refute advertised =~ "refs/internal/"
      assert advertised =~ "refs/heads/main"
    end

    test "concurrent writers with one expected OID produce exactly one winner", %{
      path: path,
      base_commit: base_commit,
      trunk_x: trunk_x
    } do
      tree = show(path, ["rev-parse", base_commit <> "^{tree}"])

      results =
        1..6
        |> Task.async_stream(
          fn n ->
            commit = commit_tree(path, tree, ["-p", trunk_x], "Contender #{n}\n")

            GitPlane.batch_update_refs(
              @repo,
              [%{ref: "refs/heads/main", expected_old: trunk_x, new: commit}],
              "test:writer-#{n}"
            )
          end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, {:expected_mismatch, "refs/heads/main", _}}, &1)
             ) ==
               5
    end

    test "concurrent batches never interleave: paired refs move together in every WAL entry", %{
      path: path,
      base_commit: base_commit
    } do
      tree = show(path, ["rev-parse", base_commit <> "^{tree}"])

      pair = ["refs/heads/pair-a", "refs/heads/pair-b"]

      assert {:ok, _result} =
               GitPlane.batch_update_refs(
                 @repo,
                 Enum.map(pair, &%{ref: &1, expected_old: :absent, new: base_commit}),
                 "test:pair-seed"
               )

      writers = 6

      1..writers
      |> Task.async_stream(
        fn n -> advance_pair(path, tree, pair, n, 20) end,
        timeout: :infinity
      )
      |> Enum.each(fn result -> assert {:ok, :ok} = result end)

      {:ok, _generation, index} = WAL.read_index(@repo)
      entries = WAL.entries(index)
      assert length(entries) == writers + 2

      entries
      |> Enum.drop(1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, entry] ->
        changed =
          entry["refs"]
          |> Enum.filter(fn {name, sha} -> previous["refs"][name] != sha end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        assert changed == pair,
               "WAL entry #{entry["seq"]} interleaved a batch: changed #{inspect(changed)}"
      end)
    end
  end

  # Retry loop for the interleave test: read the live pair tips, build one
  # new commit on each, and CAS both refs in one batch.
  defp advance_pair(_path, _tree, _pair, _n, 0), do: {:error, :retries_exhausted}

  defp advance_pair(path, tree, [ref_a, ref_b] = pair, n, retries) do
    refs = Repos.refs(@repo)
    old_a = Map.fetch!(refs, ref_a)
    old_b = Map.fetch!(refs, ref_b)
    new_a = commit_tree(path, tree, ["-p", old_a], "Pair A by writer #{n}\n")
    new_b = commit_tree(path, tree, ["-p", old_b], "Pair B by writer #{n}\n")

    case GitPlane.batch_update_refs(
           @repo,
           [
             %{ref: ref_a, expected_old: old_a, new: new_a},
             %{ref: ref_b, expected_old: old_b, new: new_b}
           ],
           "test:pair-#{n}"
         ) do
      {:ok, _result} ->
        :ok

      {:error, {:expected_mismatch, _ref, _actual}} ->
        advance_pair(path, tree, pair, n, retries - 1)
    end
  end
end
