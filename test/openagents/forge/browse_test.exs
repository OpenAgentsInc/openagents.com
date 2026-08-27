defmodule OpenAgents.Forge.BrowseTest do
  @moduledoc """
  Bounded git plumbing for the public forge UI (#136/#137): ref/sha
  resolution, commit metadata with provenance trailers (and no author
  emails), changed files, diffs, trees, blobs, README lookup, logs, and the
  shape gates that keep request data from ever becoming a git flag.
  """

  use OpenAgents.DataCase, async: false
  alias OpenAgents.Forge.{Browse, Repos}

  @second_message """
  Second commit

  Changelog: Moved the thing
  Changelog-Category: ui
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_test
  """

  setup do
    base = Path.join(System.tmp_dir!(), "forge-browse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      if previous_data,
        do: Application.put_env(:openagents, :forge_data_dir, previous_data),
        else: Application.delete_env(:openagents, :forge_data_dir)

      if previous_wal,
        do: Application.put_env(:openagents, :forge_wal_dir, previous_wal),
        else: Application.delete_env(:openagents, :forge_wal_dir)

      File.rm_rf(base)
    end)

    seed_repo("openagents.com")
  end

  # Two chained commits in the bare repo via plumbing (no clone, no WAL):
  # the first seeds README.md + file.txt, the second adds docs/note.md,
  # modifies file.txt, and carries the provenance/changelog trailers.
  defp seed_repo(repo) do
    path = Repos.ensure_repo!(repo)

    readme = write_blob(path, "# OpenAgents test repo\n\nFixture readme.\n")
    file_v1 = write_blob(path, "hello\n")

    tree_one =
      mktree(path, "100644 blob #{readme}\tREADME.md\n100644 blob #{file_v1}\tfile.txt\n")

    first = commit_tree(path, tree_one, [], "First commit\n")

    note = write_blob(path, "# Note\n\nBody of the note.\n")
    docs_tree = mktree(path, "100644 blob #{note}\tnote.md\n")
    file_v2 = write_blob(path, "hello world\n")

    tree_two =
      mktree(
        path,
        "100644 blob #{readme}\tREADME.md\n" <>
          "040000 tree #{docs_tree}\tdocs\n" <>
          "100644 blob #{file_v2}\tfile.txt\n"
      )

    second = commit_tree(path, tree_two, ["-p", first], @second_message)

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", second])
    %{first: first, second: second}
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
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    String.trim(sha)
  end

  defp git_in(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "browse-stdin-#{System.unique_integer([:positive])}")
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

  describe "resolve_commit/2" do
    test "resolves a branch name, a full sha, and a short sha", %{second: second} do
      assert {:ok, ^second} = Browse.resolve_commit("openagents.com", "main")
      assert {:ok, ^second} = Browse.resolve_commit("openagents.com", second)
      assert {:ok, ^second} = Browse.resolve_commit("openagents.com", String.slice(second, 0, 8))
    end

    test "an unknown ref or sha is :not_found" do
      assert {:error, :not_found} = Browse.resolve_commit("openagents.com", "no-such-branch")
      assert {:error, :not_found} = Browse.resolve_commit("openagents.com", "deadbeefdeadbeef")
    end

    test "a malformed ref never reaches git" do
      assert {:error, :not_found} = Browse.resolve_commit("openagents.com", "-evil")
      assert {:error, :not_found} = Browse.resolve_commit("openagents.com", "a..b")
    end
  end

  describe "commit/2" do
    test "returns subject, author, parents, and parsed trailers — never an email",
         %{first: first, second: second} do
      assert {:ok, commit} = Browse.commit("openagents.com", String.slice(second, 0, 8))

      assert commit.sha == second
      assert commit.subject == "Second commit"
      assert commit.author == "Test Author"
      assert commit.parents == [first]

      assert commit.trailers == [
               {"Changelog", "Moved the thing"},
               {"Changelog-Category", "ui"},
               {"Co-Authored-By", "Claude Fable 5 <noreply@anthropic.com>"},
               {"Claude-Session", "https://claude.ai/code/session_test"}
             ]

      refute Map.has_key?(commit, :email)
      refute inspect(commit) =~ "author@example.test"
    end
  end

  test "changed_files/2 lists the second commit's additions and modifications",
       %{second: second} do
    assert {:ok, files} = Browse.changed_files("openagents.com", second)

    assert %{status: "A", path: "docs/note.md"} in files
    assert %{status: "M", path: "file.txt"} in files
  end

  test "diff/2 returns the patch with an honest truncation flag", %{second: second} do
    assert {:ok, diff, false} = Browse.diff("openagents.com", second)

    assert diff =~ "docs/note.md"
    assert diff =~ "Body of the note."
  end

  describe "tree/3" do
    test "lists root entries with directories first" do
      assert {:ok, entries} = Browse.tree("openagents.com", "main")

      assert Enum.map(entries, & &1.name) == ["docs", "README.md", "file.txt"]
      assert [%{kind: "tree", size: nil} | blobs] = entries
      assert Enum.all?(blobs, &(&1.kind == "blob" and is_integer(&1.size)))
    end

    test "lists a subdirectory" do
      assert {:ok, [%{name: "note.md", kind: "blob"}]} =
               Browse.tree("openagents.com", "main", "docs")
    end
  end

  describe "blob/3" do
    test "returns bounded content with size" do
      assert {:ok, blob} = Browse.blob("openagents.com", "main", "file.txt")

      assert blob.content == "hello world\n"
      assert blob.size == byte_size("hello world\n")
      assert blob.truncated == false
      assert blob.binary == false
    end

    test "a missing path is :not_found" do
      assert {:error, :not_found} = Browse.blob("openagents.com", "main", "missing.txt")
    end

    test "an unknown repo name is :not_found before any git runs" do
      assert {:error, :not_found} = Browse.blob("nope", "main", "file.txt")
    end
  end

  test "blob_page/3 returns a resolved revision, head, and blob together", %{second: second} do
    assert {:ok, page} = Browse.blob_page("openagents.com", "main", "file.txt")

    assert page.sha == second
    assert page.head == second
    assert page.blob.content == "hello world\n"
  end

  test "readme/2 finds README.md at a ref" do
    assert {:ok, "README.md", blob} = Browse.readme("openagents.com", "main")
    assert blob.content =~ "Fixture readme."
  end

  test "log/3 returns both commits newest first", %{first: first, second: second} do
    assert {:ok, [newest, oldest]} = Browse.log("openagents.com", "main", 30)

    assert newest.sha == second
    assert newest.subject == "Second commit"
    assert oldest.sha == first
    assert oldest.subject == "First commit"
  end

  test "overview/2 returns repository-home data after one bounded read", %{second: second} do
    overview = Browse.overview("openagents.com", 1)

    assert overview.head == second
    assert overview.readme.name == "README.md"
    assert overview.readme.blob.content =~ "Fixture readme."
    assert [%{sha: ^second}] = overview.commits
    assert Enum.map(overview.entries, & &1.name) == ["docs", "README.md", "file.txt"]
    assert %{name: "main", sha: second, kind: :branch} in overview.refs
  end

  describe "shape gates" do
    test "valid_ref?/1 rejects flag-shaped, traversing, and range refs" do
      assert Browse.valid_ref?("main")
      assert Browse.valid_ref?("v1.2.3")

      refute Browse.valid_ref?("-leading")
      refute Browse.valid_ref?("a..b")
      refute Browse.valid_ref?("")
      refute Browse.valid_ref?(nil)
    end

    test "valid_path?/1 rejects absolute, traversing, and flag-shaped paths" do
      assert Browse.valid_path?("docs/note.md")
      assert Browse.valid_path?("file.txt")

      refute Browse.valid_path?("/etc/passwd")
      refute Browse.valid_path?("../secret")
      refute Browse.valid_path?("docs/../secret")
      refute Browse.valid_path?("-flag")
      refute Browse.valid_path?("")
      refute Browse.valid_path?(nil)
    end
  end
end
