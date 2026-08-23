defmodule OpenAgents.ForgePromotionFixtures do
  @moduledoc """
  A real bare forge repository with one real commit.

  Promotion's precondition is that the SHA is already in the WAL-backed
  repository, and `OpenAgents.Forge.Targets` deliberately runs that check in
  every environment including test. A fixture that stubbed it would prove
  nothing, so this one writes an actual commit object with Git plumbing.
  """

  alias OpenAgents.Accounts
  alias OpenAgents.Forge.Repos

  @doc "An account that is a current operator for the duration of the test."
  def operator_fixture(key) do
    user = promotion_user_fixture(key)
    grant_operator(user)
    user
  end

  @doc "An ordinary active account that is never an operator."
  def promotion_user_fixture(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()
    suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 12)

    {:ok, user} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "promotion-#{suffix}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    user
  end

  # The operator allowlist is one application-wide value shared by every
  # concurrently running test, so a grant adds only its own id and its cleanup
  # removes only that id.
  @doc "Add one account to the operator allowlist until the test ends."
  def grant_operator(%{github_id: github_id}) do
    update_operator_ids(&[github_id | &1])
    ExUnit.Callbacks.on_exit(fn -> update_operator_ids(&List.delete(&1, github_id)) end)
    :ok
  end

  @doc "Remove one account from the operator allowlist immediately."
  def revoke_operator(%{github_id: github_id}) do
    update_operator_ids(&List.delete(&1, github_id))
  end

  defp update_operator_ids(fun) do
    :global.trans({{:openagents, :admin_github_ids}, self()}, fn ->
      ids = Application.get_env(:openagents, :admin_github_ids, [])
      Application.put_env(:openagents, :admin_github_ids, fun.(ids))
    end)

    :ok
  end

  @doc "Point the forge data and WAL directories at a private temporary tree."
  def isolate_forge_storage! do
    base = Path.join(System.tmp_dir!(), "forge-promotion-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    :ok
  end

  @doc "Create one commit in `repo`'s bare forge repository and return its SHA."
  def seeded_commit(repo, message \\ "seed") do
    path = Repos.ensure_repo!(repo)
    {blob, 0} = plumb(path, ["hash-object", "-w", "--stdin"], "content #{message}\n")
    {tree, 0} = plumb(path, ["mktree"], "100644 blob #{String.trim(blob)}\tf.txt\n")

    {commit, 0} =
      plumb(path, ["commit-tree", String.trim(tree), "-m", message], "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    sha = String.trim(commit)
    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", sha])
    sha
  end

  defp plumb(path, args, stdin, opts \\ []) do
    input = Path.join(System.tmp_dir!(), "plumb-#{System.unique_integer([:positive])}")
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
end
