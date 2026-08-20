defmodule OpenAgents.Forge.MirrorWatchTest do
  @moduledoc """
  Mirror drift detection (#127): current/lagging/off states, the immediate
  retry that heals ordinary lag, the one-incident-per-episode bound, and
  the unreachable-mirror posture (forge unaffected, nothing reported).
  """

  use OpenAgents.DataCase, async: false
  import Ecto.Query

  alias OpenAgents.Forge.{MirrorWatch, Repos}
  alias OpenAgents.Repo

  setup do
    base = Path.join(System.tmp_dir!(), "mirror-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    previous =
      for key <- [:forge_data_dir, :forge_wal_dir, :forge_mirror_urls] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    # A local bare repo stands in for GitHub.
    mirror = Path.join(base, "github-mirror.git")
    {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", mirror])
    Application.put_env(:openagents, :forge_mirror_urls, %{"openagents.com" => mirror})

    # Seed the forge repo with one commit on main.
    path = Repos.ensure_repo!("openagents.com")
    seed_commit!(path, "one")

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:openagents, key, value),
          else: Application.delete_env(:openagents, key)
      end

      File.rm_rf(base)
      :persistent_term.erase({MirrorWatch, :state})
    end)

    %{mirror: mirror, path: path}
  end

  defp seed_commit!(path, marker) do
    {blob, 0} = plumb(path, ["hash-object", "-w", "--stdin"], marker <> "\n")
    {tree, 0} = plumb(path, ["mktree"], "100644 blob #{String.trim(blob)}\tf.txt\n")

    parent =
      case Repos.git(path, ["rev-parse", "refs/heads/main"]) do
        {sha, 0} -> ["-p", String.trim(sha)]
        _none -> []
      end

    {commit, 0} =
      plumb(path, ["commit-tree", String.trim(tree), "-m", marker] ++ parent, "",
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", String.trim(commit)])
    :ok
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

  defp fresh_state, do: %{lagging_since: %{}, incident_reported: MapSet.new()}

  test "a behind mirror is retried immediately and becomes current", %{path: path, mirror: mirror} do
    # Forge has a commit the mirror lacks → behind → check retries → healed.
    state = MirrorWatch.check_all(fresh_state())
    assert MirrorWatch.state()["state"] == "current"

    {forge_main, 0} = Repos.git(path, ["rev-parse", "refs/heads/main"])
    {mirror_main, 0} = System.cmd("git", ["--git-dir", mirror, "rev-parse", "refs/heads/main"])
    assert String.trim(forge_main) == String.trim(mirror_main)

    # A later forge commit → behind on the next check → healed again.
    seed_commit!(path, "two")
    _state = MirrorWatch.check_all(state)
    assert MirrorWatch.state()["state"] == "current"
  end

  test "sustained lag records ONE degraded incident per episode" do
    # Make the mirror un-pushable but still readable: replace it with a
    # bare repo whose receive hook rejects everything.
    mirror = Application.fetch_env!(:openagents, :forge_mirror_urls)["openagents.com"]
    hook = Path.join(mirror, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    # Diverge the forge past the mirror.
    seed_commit!(Repos.bare_path("openagents.com"), "diverge")

    now = System.monotonic_time(:millisecond)
    state = MirrorWatch.check_all(fresh_state(), now)
    assert MirrorWatch.state()["state"] == "lagging"
    # Under the 15m threshold: no incident yet.
    assert incident_count() == 0

    # 20 minutes later, still lagging: exactly one incident.
    state = MirrorWatch.check_all(state, now + 20 * 60_000)
    assert incident_count() == 1

    # Still lagging on the next tick: no second incident (per-episode).
    _state = MirrorWatch.check_all(state, now + 25 * 60_000)
    assert incident_count() == 1
  end

  test "no configured mirror publishes off; unreachable mirror stays quiet" do
    Application.put_env(:openagents, :forge_mirror_urls, %{})
    _state = MirrorWatch.check_all(fresh_state())
    assert MirrorWatch.state()["state"] == "off"

    Application.put_env(:openagents, :forge_mirror_urls, %{
      "openagents.com" => "/nonexistent/mirror.git"
    })

    _state = MirrorWatch.check_all(fresh_state())
    assert incident_count() == 0
  end

  test "credential-bearing and scp-style mirror remotes fail closed" do
    for url <- [
          "https://operator:secret@mirror.example/openagents.com.git",
          "ssh://operator:secret@mirror.example/openagents.com.git",
          "operator:secret@mirror.example:openagents.com.git"
        ] do
      Application.put_env(:openagents, :forge_mirror_urls, %{"openagents.com" => url})
      assert OpenAgents.Forge.Pushes.mirror_url("openagents.com") == nil
    end
  end

  defp incident_count do
    Repo.aggregate(
      from(i in OpenAgents.Incidents.Incident, where: i.code == "forge_mirror_lagging"),
      :count
    )
  end
end
