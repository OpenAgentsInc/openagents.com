defmodule OpenAgents.Forge.GitHTTPTest do
  @moduledoc """
  End-to-end forge tests with the real git client over real HTTP: clone,
  push, WAL persistence, receipt derivation, re-materialization from the
  WAL after cache loss, and auth refusals. This is the P1 exit test from
  the roadmap, minus the fleet.
  """

  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.{AuditEvent, Forge, Machines, Repo, Repositories}
  alias OpenAgents.Forge.{Repos, WAL}

  defmodule TestPipeline do
    @moduledoc false
    use Plug.Builder

    plug OpenAgentsWeb.Plugs.ForgeGitAuth
    plug OpenAgents.Forge.GitHTTP
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "forge-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    user = repository_user_fixture("git-http-owner")

    {:ok, repository, :created} =
      OpenAgents.Repositories.create_user_repository(user, %{name: "demo"}, "git-http-demo")

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle_state: "ready", ready_at: DateTime.utc_now())
      |> OpenAgents.Repo.update!()

    {:ok, api_token, plaintext} =
      OpenAgents.ApiTokens.create(user, %{
        name: "Git HTTP test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    port = free_port()
    start_supervised!({Bandit, plug: TestPipeline, port: port, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      Application.put_env(:openagents, :forge_data_dir, previous_data)
      Application.put_env(:openagents, :forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    %{
      base: base,
      port: port,
      repository: repository,
      api_token: api_token,
      token: plaintext,
      url: "http://x:#{plaintext}@127.0.0.1:#{port}/git-http-owner/demo.git",
      user: user
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Every git call disables credential helpers so the developer keychain can
  # neither pollute these tests nor be polluted by them.
  defp sh!(dir, "git", args), do: sh_raw!(dir, "git", ["-c", "credential.helper="] ++ args)
  defp sh!(dir, command, args), do: sh_raw!(dir, command, args)

  defp sh_raw!(dir, command, args) do
    {output, status} = System.cmd(command, args, cd: dir, stderr_to_stdout: true)
    if status != 0, do: flunk("#{command} #{Enum.join(args, " ")} failed:\n#{output}")
    output
  end

  defp seed_clone!(base, url) do
    work = Path.join(base, "clone-#{System.unique_integer([:positive])}")
    sh!(base, "git", ["clone", url, work])
    sh!(work, "git", ["config", "user.email", "test@example.com"])
    sh!(work, "git", ["config", "user.name", "Forge Test"])
    work
  end

  defp commit_and_push!(work, filename, contents, message) do
    File.write!(Path.join(work, filename), contents)
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", message])
    sh!(work, "git", ["push", "origin", "HEAD:main"])
  end

  test "clone, push, WAL persist, receipt, and PubSub — the ack chain", %{
    base: base,
    repository: repository,
    url: url,
    user: user
  } do
    Phoenix.PubSub.subscribe(OpenAgents.PubSub, "forge:pushes")

    work = seed_clone!(base, url)
    commit_and_push!(work, "hello.txt", "hello forge\n", "first commit")

    # WAL is the authority: index has the entry and the ref.
    assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    assert [entry] = WAL.entries(index)
    assert entry["seq"] == 0
    assert entry["principal"] == "user:#{user.id}"
    assert %{"refs/heads/main" => sha} = WAL.refs(index)
    assert byte_size(sha) == 40

    # Derived receipt exists, idempotent by (repo, wal_seq).
    assert [receipt] = Forge.recent_pushes(repository.storage_key)
    assert receipt.wal_seq == 0
    assert receipt.refs["refs/heads/main"]["new"] == sha
    assert receipt.refs["refs/heads/main"]["old"] == nil

    # Deploy signal fired.
    assert_receive {:forge_push, %{repo: storage_key, wal_seq: 0}}, 2_000
    assert storage_key == repository.storage_key

    assert %AuditEvent{event_type: "repository.git.write", repository_id: repository_id} =
             Repo.get_by(AuditEvent,
               event_type: "repository.git.write",
               repository_id: repository.id
             )

    assert repository_id == repository.id

    # A second clone sees the commit.
    verify = seed_clone!(base, url)
    assert File.read!(Path.join(verify, "hello.txt")) == "hello forge\n"
  end

  test "a second push appends to the WAL and receipts stay ordered", %{
    base: base,
    repository: repository,
    url: url
  } do
    work = seed_clone!(base, url)
    commit_and_push!(work, "a.txt", "one\n", "one")
    commit_and_push!(work, "b.txt", "two\n", "two")

    assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    assert length(WAL.entries(index)) == 2
    assert [%{wal_seq: 1}, %{wal_seq: 0}] = Forge.recent_pushes(repository.storage_key)
  end

  test "cache loss: the bare repo re-materializes from the WAL", %{
    base: base,
    repository: repository,
    url: url
  } do
    work = seed_clone!(base, url)
    commit_and_push!(work, "keep.txt", "durable\n", "durable commit")
    refs_before = Repos.refs(repository.storage_key)

    # Kill the cache entirely.
    File.rm_rf!(Repos.bare_path(repository.storage_key))
    refute File.exists?(Repos.bare_path(repository.storage_key))

    # A fresh clone triggers materialization and sees identical state.
    verify = seed_clone!(base, url)
    assert File.read!(Path.join(verify, "keep.txt")) == "durable\n"
    assert Repos.refs(repository.storage_key) == refs_before
  end

  test "unauthenticated and wrong-token pushes are refused", %{
    base: base,
    port: port,
    repository: repository,
    url: url
  } do
    work = seed_clone!(base, url)
    File.write!(Path.join(work, "no.txt"), "no\n")
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", "unauthorized"])

    for bad_url <- [
          "http://127.0.0.1:#{port}/git-http-owner/demo.git",
          "http://x:wrong-token@127.0.0.1:#{port}/git-http-owner/demo.git"
        ] do
      {output, status} =
        System.cmd("git", ["-c", "credential.helper=", "push", bad_url, "HEAD:main"],
          cd: work,
          stderr_to_stdout: true,
          env: [{"GIT_TERMINAL_PROMPT", "0"}]
        )

      assert status != 0

      assert output =~ "401" or output =~ "Authentication" or
               output =~ "terminal prompts disabled"
    end

    # Nothing leaked into the WAL.
    case WAL.read_index(repository.storage_key) do
      {:error, :not_found} -> :ok
      {:ok, _generation, index} -> assert WAL.entries(index) == []
    end
  end

  test "unknown repositories are refused", %{port: port, token: token} do
    {output, status} =
      System.cmd(
        "git",
        [
          "-c",
          "credential.helper=",
          "clone",
          "http://x:#{token}@127.0.0.1:#{port}/git-http-owner/not-allowed.git"
        ],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "404" or output =~ "not found" or output =~ "unknown"
  end

  test "Git RPC reauthenticates a token after ref advertisement", %{
    api_token: api_token,
    token: token,
    user: user
  } do
    authorization = "Basic " <> Base.encode64("x:#{token}")

    advertised =
      :get
      |> Plug.Test.conn("/git-http-owner/demo.git/info/refs?service=git-upload-pack")
      |> Plug.Conn.put_req_header("authorization", authorization)
      |> TestPipeline.call([])

    assert advertised.status == 200
    assert {:ok, _revoked} = OpenAgents.ApiTokens.revoke(user, api_token.id)

    rpc =
      :post
      |> Plug.Test.conn("/git-http-owner/demo.git/git-upload-pack", "")
      |> Plug.Conn.put_req_header("authorization", authorization)
      |> TestPipeline.call([])

    assert rpc.status == 401
    assert Plug.Conn.get_resp_header(rpc, "www-authenticate") != []
  end

  test "public repositories clone anonymously and private repositories issue a challenge", %{
    base: base,
    port: port,
    repository: repository
  } do
    anonymous_url = "http://127.0.0.1:#{port}/git-http-owner/demo.git"

    {private_output, private_status} =
      System.cmd(
        "git",
        ["-c", "credential.helper=", "clone", anonymous_url, Path.join(base, "private")],
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    assert private_status != 0
    assert private_output =~ "Authentication" or private_output =~ "terminal prompts disabled"

    repository
    |> Ecto.Changeset.change(visibility: "public")
    |> OpenAgents.Repo.update!()

    public_clone = Path.join(base, "public")
    sh!(base, "git", ["clone", anonymous_url, public_clone])
    assert File.dir?(Path.join(public_clone, ".git"))
  end

  test "a viewer can clone a private repository but cannot push", %{
    base: base,
    port: port,
    repository: repository,
    url: owner_url
  } do
    owner_clone = seed_clone!(base, owner_url)
    commit_and_push!(owner_clone, "owner.txt", "owner\n", "Owner commit")

    viewer = repository_user_fixture("git-http-viewer")
    {:ok, _membership} = OpenAgents.Repositories.add_member(repository, viewer, "viewer")

    {:ok, _api_token, viewer_token} =
      OpenAgents.ApiTokens.create(viewer, %{
        name: "Viewer Git HTTP test",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    viewer_url =
      "http://x:#{viewer_token}@127.0.0.1:#{port}/git-http-owner/demo.git"

    viewer_clone = seed_clone!(base, viewer_url)
    File.write!(Path.join(viewer_clone, "viewer.txt"), "viewer\n")
    sh!(viewer_clone, "git", ["add", "viewer.txt"])
    sh!(viewer_clone, "git", ["commit", "-m", "Viewer commit"])

    {output, status} =
      System.cmd("git", ["-c", "credential.helper=", "push", "origin", "HEAD:main"],
        cd: viewer_clone,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "403" or output =~ "read only" or output =~ "unable to access"
  end

  test "a paired machine requires an explicit operation-scoped repository grant", %{
    base: base,
    port: port,
    repository: repository,
    user: user
  } do
    {:ok, pairing} =
      Machines.start_pairing(%{
        "name" => "git-machine",
        "tier" => "probe",
        "platform" => "linux",
        "agent_version" => "0.1.0",
        "roots" => []
      })

    assert {:ok, machine} = Machines.approve_pairing(user, pairing.code)

    assert {:ok, %{token: machine_token}} =
             Machines.claim_pairing(pairing.pairing.id, pairing.poll_secret)

    machine_url =
      "http://x:#{machine_token}@127.0.0.1:#{port}/git-http-owner/demo.git"

    {ungranted_output, ungranted_status} =
      System.cmd(
        "git",
        ["-c", "credential.helper=", "clone", machine_url, Path.join(base, "machine-ungranted")],
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    assert ungranted_status != 0
    assert ungranted_output =~ "404" or ungranted_output =~ "not found"

    assert {:ok, _grant} = Repositories.grant_machine(repository, user, machine, ["read"])
    machine_clone = seed_clone!(base, machine_url)
    File.write!(Path.join(machine_clone, "machine.txt"), "machine\n")
    sh!(machine_clone, "git", ["add", "machine.txt"])
    sh!(machine_clone, "git", ["commit", "-m", "Machine commit"])

    {_output, read_only_status} =
      System.cmd("git", ["-c", "credential.helper=", "push", "origin", "HEAD:main"],
        cd: machine_clone,
        stderr_to_stdout: true
      )

    assert read_only_status != 0

    assert {:ok, _grant} =
             Repositories.grant_machine(repository, user, machine, ["read", "write"])

    sh!(machine_clone, "git", ["push", "origin", "HEAD:main"])
  end

  test "the legacy initial repository path remains available", %{
    base: base,
    port: port,
    token: token
  } do
    legacy_url = "http://x:#{token}@127.0.0.1:#{port}/openagents.com.git"
    legacy_clone = Path.join(base, "legacy")
    sh!(base, "git", ["clone", legacy_url, legacy_clone])
    assert File.dir?(Path.join(legacy_clone, ".git"))
  end

  test "a failed WAL persist rolls refs back and the push is not acked", %{
    base: base,
    repository: repository,
    url: url
  } do
    work = seed_clone!(base, url)
    commit_and_push!(work, "ok.txt", "fine\n", "fine")
    refs_before = Repos.refs(repository.storage_key)

    # Break the WAL (unwritable dir) — the next push must not ack.
    wal_dir = Application.get_env(:openagents, :forge_wal_dir)
    File.chmod!(Path.join(wal_dir, repository.storage_key), 0o500)

    File.write!(Path.join(work, "lost.txt"), "must not land\n")
    sh!(work, "git", ["add", "."])
    sh!(work, "git", ["commit", "-m", "must not land"])

    {output, status} =
      System.cmd("git", ["-c", "credential.helper=", "push", "origin", "HEAD:main"],
        cd: work,
        stderr_to_stdout: true
      )

    File.chmod!(Path.join(wal_dir, repository.storage_key), 0o700)

    assert status != 0, "push must fail when the WAL cannot persist: #{output}"
    # Local refs rolled back — cache never ahead of authority.
    assert Repos.refs(repository.storage_key) == refs_before
    assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    assert length(WAL.entries(index)) == 1
  end
end
