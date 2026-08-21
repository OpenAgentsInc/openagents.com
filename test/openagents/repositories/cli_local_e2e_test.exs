defmodule OpenAgents.Repositories.CliLocalE2ETest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.{Accounts, ApiTokens, Repositories}
  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repositories.{Importer, Provisioner}

  @moduletag :cross_repo

  setup do
    cli_entry = System.fetch_env!("OPENAGENTS_CLI_ENTRY")

    node =
      System.find_executable("node") || raise "node is required for the CLI cross-repository test"

    true = Path.type(cli_entry) == :absolute
    true = File.regular?(cli_entry)

    root =
      Path.join(
        System.tmp_dir!(),
        "openagents-cli-local-e2e-#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(root)
    previous = save_environment([:forge_data_dir, :forge_wal_dir, :github_api])
    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "forge"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(root, "wal"))

    user = repository_user_fixture("cli-e2e-owner")
    {:ok, user} = Accounts.store_github_token(user, "github-cli-e2e-token")

    {:ok, _api_token, plaintext} =
      ApiTokens.create(user, %{name: "CLI local E2E", scopes: ["forge:write"], lifetime_days: 1})

    source = fixture_repository!(root)
    refs = refs(source)

    github_port = free_port()
    endpoint_port = System.get_env("OPENAGENTS_E2E_PORT", "4000") |> String.to_integer()
    api_origin = "http://localhost:#{endpoint_port}"

    github_options = [
      source_full_name: "#{user.github_login}/source-project",
      repository_id: 9_001,
      owner_id: user.github_id,
      default_branch: "main",
      refs:
        Map.new(refs, fn {name, sha} ->
          {type, 0} = System.cmd("git", ["-C", source, "cat-file", "-t", sha])
          {name, %{sha: sha, type: String.trim(type)}}
        end)
    ]

    start_supervised!(
      Supervisor.child_spec(
        {Bandit,
         plug: {OpenAgents.Test.RepositoryCliGitHubFake, github_options},
         port: github_port,
         ip: {127, 0, 0, 1}},
        id: :repository_cli_github_fake
      )
    )

    Application.put_env(:openagents, :github_api,
      base_url: "http://127.0.0.1:#{github_port}",
      request_options: []
    )

    start_supervised!(
      Supervisor.child_spec(
        {Bandit, plug: OpenAgentsWeb.Endpoint, port: endpoint_port, ip: {127, 0, 0, 1}},
        id: :repository_cli_local_endpoint
      )
    )

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "openagents")

    File.write!(
      wrapper,
      "#!/bin/sh\nexec node \"$OPENAGENTS_CLI_ENTRY\" \"$@\"\n",
      [:exclusive]
    )

    File.chmod!(wrapper, 0o700)

    on_exit(fn ->
      restore_environment(previous)
      File.rm_rf!(root)
    end)

    %{
      cli_entry: cli_entry,
      node: node,
      environment: [
        {"OPENAGENTS_API_URL", api_origin},
        {"OPENAGENTS_TOKEN", plaintext},
        {"OPENAGENTS_CLI_ENTRY", cli_entry},
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
        {"NO_COLOR", "1"}
      ],
      api_origin: api_origin,
      root: root,
      secret: plaintext,
      source: source,
      source_refs: refs,
      user: user
    }
  end

  test "CLI creates, pushes, clones, reconstructs, and imports once", context do
    checkout = local_checkout!(context.root, "created-source")

    create_task =
      cli_task(context, checkout, [
        "--json",
        "repo",
        "create",
        "created-project",
        "--public",
        "--source",
        checkout,
        "--wait-timeout",
        "20"
      ])

    assert :processed = await_outbox(&Provisioner.run_once/0)
    create_output = await_cli!(create_task, context.secret)
    assert create_output =~ "\"full_name\":\"#{context.user.github_login}/created-project\""

    setup_git_output =
      cli!(context, checkout, ["--json", "auth", "setup-git", "--local"])

    refute setup_git_output =~ context.secret
    git!(checkout, ["push", "-u", "origin", "HEAD:main"], context.environment)
    expected_sha = git!(checkout, ["rev-parse", "HEAD"], context.environment) |> String.trim()

    clone = Path.join(context.root, "cli-clone")

    clone_output =
      cli!(context, context.root, [
        "--json",
        "repo",
        "clone",
        "#{context.user.github_login}/created-project",
        clone
      ])

    refute clone_output =~ context.secret

    assert git!(clone, ["rev-parse", "HEAD"], context.environment) |> String.trim() ==
             expected_sha

    repository = Repositories.get_by_path!(context.user.github_login, "created-project")
    File.rm_rf!(Repos.bare_path(repository.storage_key))

    reconstructed = Path.join(context.root, "reconstructed-clone")

    _output =
      cli!(context, context.root, [
        "--json",
        "repo",
        "clone",
        "#{context.user.github_login}/created-project",
        reconstructed
      ])

    assert git!(reconstructed, ["rev-parse", "HEAD"], context.environment) |> String.trim() ==
             expected_sha

    anonymous = Path.join(context.root, "anonymous-clone")

    git!(
      context.root,
      [
        "-c",
        "credential.helper=",
        "clone",
        "#{context.api_origin}/#{context.user.github_login}/created-project.git",
        anonymous
      ],
      [{"GIT_TERMINAL_PROMPT", "0"}]
    )

    assert git!(anonymous, ["rev-parse", "HEAD"], []) |> String.trim() == expected_sha

    private_task =
      cli_task(context, context.root, [
        "--json",
        "repo",
        "create",
        "private-project",
        "--wait-timeout",
        "20"
      ])

    assert :processed = await_outbox(&Provisioner.run_once/0)
    _private_output = await_cli!(private_task, context.secret)
    private_repository = Repositories.get_by_path!(context.user.github_login, "private-project")

    private_url =
      "#{context.api_origin}/#{context.user.github_login}/private-project.git"

    {anonymous_private_output, anonymous_private_status} =
      git_raw(
        context.root,
        ["-c", "credential.helper=", "clone", private_url, Path.join(context.root, "concealed")],
        [{"GIT_TERMINAL_PROMPT", "0"}]
      )

    assert anonymous_private_status != 0
    refute anonymous_private_output =~ context.secret

    viewer = repository_user_fixture("cli-e2e-viewer")
    {:ok, _membership} = Repositories.add_member(private_repository, viewer, "viewer")

    {:ok, _viewer_token, viewer_plaintext} =
      ApiTokens.create(viewer, %{
        name: "CLI E2E viewer",
        scopes: ["forge:write"],
        lifetime_days: 1
      })

    viewer_context = %{
      context
      | secret: viewer_plaintext,
        environment:
          replace_environment(context.environment, "OPENAGENTS_TOKEN", viewer_plaintext)
    }

    viewer_clone = Path.join(context.root, "viewer-clone")

    _viewer_output =
      cli!(viewer_context, context.root, [
        "--json",
        "repo",
        "clone",
        "#{context.user.github_login}/private-project",
        viewer_clone
      ])

    cli!(viewer_context, viewer_clone, ["--json", "auth", "setup-git", "--local"])
    git!(viewer_clone, ["config", "user.email", "viewer@example.com"], [])
    git!(viewer_clone, ["config", "user.name", "Read-only viewer"], [])
    File.write!(Path.join(viewer_clone, "refused.txt"), "must not land\n")
    git!(viewer_clone, ["add", "refused.txt"], [])
    git!(viewer_clone, ["commit", "-m", "Refused viewer push"], [])

    {viewer_push_output, viewer_push_status} =
      git_raw(viewer_clone, ["push", "origin", "HEAD:main"], viewer_context.environment)

    assert viewer_push_status != 0
    refute viewer_push_output =~ viewer_plaintext
    assert Repos.refs(private_repository.storage_key) == %{}

    import_task =
      cli_task(context, context.root, [
        "--json",
        "repo",
        "import",
        "#{context.user.github_login}/source-project",
        "--name",
        "imported-project",
        "--wait-timeout",
        "20"
      ])

    executor = fn work -> Importer.import(work.repository, source_url: context.source) end
    assert :processed = await_outbox(fn -> Provisioner.run_once(executor) end)
    import_output = await_cli!(import_task, context.secret)

    assert import_output =~ "This is a one-time import" or
             import_output =~ "\"state\":\"completed\""

    imported = Repositories.get_by_path!(context.user.github_login, "imported-project")
    assert {:ok, _generation, imported_index} = WAL.read_index(imported.storage_key)
    assert WAL.refs(imported_index) == context.source_refs

    File.write!(Path.join(context.source, "later.txt"), "later GitHub change\n")
    git!(context.source, ["add", "later.txt"], [])
    git!(context.source, ["commit", "-m", "Later source change"], [])
    assert WAL.refs(imported_index) == context.source_refs
    assert Repos.refs(imported.storage_key) == context.source_refs

    remote_config = git!(checkout, ["config", "--get", "remote.origin.url"], [])
    refute remote_config =~ context.secret
    refute remote_config =~ "@localhost"

    write_receipt(context, expected_sha, imported)
  end

  defp cli_task(context, directory, arguments) do
    Task.async(fn -> cli_raw(context, directory, arguments) end)
  end

  defp cli!(context, directory, arguments) do
    context
    |> cli_raw(directory, arguments)
    |> assert_cli_success!(context.secret)
  end

  defp cli_raw(context, directory, arguments) do
    System.cmd(context.node, [context.cli_entry | arguments],
      cd: directory,
      env: context.environment,
      stderr_to_stdout: true
    )
  end

  defp await_cli!(task, secret) do
    task
    |> Task.await(30_000)
    |> assert_cli_success!(secret)
  end

  defp assert_cli_success!({output, 0}, secret) do
    refute output =~ secret
    output
  end

  defp assert_cli_success!({output, status}, _secret) do
    flunk("CLI exited with #{status}:\n#{output}")
  end

  defp await_outbox(run, remaining \\ 500)
  defp await_outbox(_run, 0), do: flunk("repository outbox work was not accepted")

  defp await_outbox(run, remaining) do
    case run.() do
      :processed ->
        :processed

      :idle ->
        receive do
        after
          10 -> await_outbox(run, remaining - 1)
        end
    end
  end

  defp local_checkout!(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git!(path, ["init", "--initial-branch=main"], [])
    git!(path, ["config", "user.email", "cli-e2e@example.com"], [])
    git!(path, ["config", "user.name", "CLI E2E"], [])
    File.write!(Path.join(path, "README.md"), "CLI local E2E\n")
    git!(path, ["add", "README.md"], [])
    git!(path, ["commit", "-m", "Initial commit"], [])
    path
  end

  defp fixture_repository!(root) do
    path = local_checkout!(root, "github-source")
    git!(path, ["branch", "release"], [])
    git!(path, ["tag", "v1"], [])
    path
  end

  defp refs(path) do
    path
    |> git!(["for-each-ref", "--format=%(objectname) %(refname)"], [])
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [sha, name] = String.split(line, " ", parts: 2)
      {name, sha}
    end)
  end

  defp git!(directory, arguments, environment) do
    case git_raw(directory, arguments, environment) do
      {output, 0} -> output
      {output, status} -> flunk("git exited with #{status}:\n#{output}")
    end
  end

  defp git_raw(directory, arguments, environment) do
    System.cmd("git", arguments,
      cd: directory,
      env: environment,
      stderr_to_stdout: true
    )
  end

  defp replace_environment(environment, key, value) do
    Enum.map(environment, fn
      {^key, _old_value} -> {key, value}
      pair -> pair
    end)
  end

  defp write_receipt(context, pushed_sha, imported) do
    case System.get_env("OPENAGENTS_E2E_RECEIPT_PATH") do
      nil ->
        :ok

      path ->
        repository_import =
          imported
          |> OpenAgents.Repo.preload(:repository_import)
          |> Map.fetch!(:repository_import)

        contract_path =
          Application.app_dir(:openagents, "priv/api-contracts/repositories-v1.json")

        contract_digest =
          contract_path
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        body = %{
          "api_origin" => context.api_origin,
          "cli_revision" => System.get_env("OPENAGENTS_CLI_REVISION", "working-tree"),
          "contract_sha256" => contract_digest,
          "created_commit_sha" => pushed_sha,
          "import_ref_digest" => repository_import.source_ref_digest,
          "server_revision" => System.get_env("OPENAGENTS_SERVER_REVISION", "working-tree"),
          "secret_scan" => "passed",
          "test_count" => 1
        }

        File.write!(path, Jason.encode_to_iodata!(body, pretty: true))
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp save_environment(keys), do: Map.new(keys, &{&1, Application.get_env(:openagents, &1)})

  defp restore_environment(environment) do
    Enum.each(environment, fn
      {key, nil} -> Application.delete_env(:openagents, key)
      {key, value} -> Application.put_env(:openagents, key, value)
    end)
  end
end
