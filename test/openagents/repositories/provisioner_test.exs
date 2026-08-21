defmodule OpenAgents.Repositories.ProvisionerTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.AuditEvent
  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.{Importer, Provisioner, ProvisioningOutbox, Repository}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "repository-provisioner-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.get_env(:openagents, :forge_wal_adapter)

    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(root, "wal"))
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      restore_env(:forge_wal_adapter, previous_adapter)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "drain provisions an empty repository once and restores its symbolic default branch" do
    user = repository_user_fixture("provisioner-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "durable-empty", default_branch: "trunk"},
               "provision-empty"
             )

    provisioner = start_supervised!({Provisioner, name: nil, poll_interval_ms: 60_000})
    assert {:ok, 1} = Provisioner.drain(provisioner)
    assert {:ok, 0} = Provisioner.drain(provisioner)

    ready = OpenAgents.Repo.get!(Repository, repository.id)
    outbox = OpenAgents.Repo.get_by!(ProvisioningOutbox, repository_id: repository.id)

    assert ready.lifecycle_state == "ready"
    assert ready.ready_at
    assert outbox.state == "completed"
    assert outbox.attempt_count == 1

    assert audit_types(repository.id) ==
             MapSet.new([
               "repository.created",
               "repository.membership.created",
               "repository.provisioning.completed",
               "repository.provisioning.pending",
               "repository.provisioning.running"
             ])

    assert {:ok, _generation, %{"entries" => [], "refs" => %{}}} =
             WAL.read_index(repository.storage_key)

    assert String.trim(bare_git!(repository.storage_key, ["symbolic-ref", "HEAD"])) ==
             "refs/heads/trunk"

    File.rm_rf!(Repos.bare_path(repository.storage_key))
    assert :ok = OpenAgents.Forge.Sync.ensure_fresh(repository.storage_key, "trunk")

    assert String.trim(bare_git!(repository.storage_key, ["symbolic-ref", "HEAD"])) ==
             "refs/heads/trunk"
  end

  test "each provisioning transition is announced on the repository's own topic" do
    user = repository_user_fixture("provisioner-announce-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(user, %{name: "announced"}, "announce-key")

    :ok = Repositories.subscribe_provisioning(repository.id)
    other = Ecto.UUID.generate()
    :ok = Repositories.subscribe_provisioning(other)

    provisioner = start_supervised!({Provisioner, name: nil, poll_interval_ms: 60_000})
    assert {:ok, 1} = Provisioner.drain(provisioner)

    # The claim and the completion, in that order: a browser sees "queued"
    # become "running" and then "ready" without asking.
    assert_receive {:repository_provisioning, id}, 1_000
    assert id == repository.id
    assert_receive {:repository_provisioning, id}, 1_000
    assert id == repository.id
    refute_received {:repository_provisioning, ^other}

    assert OpenAgents.Repo.get!(Repository, repository.id).lifecycle_state == "ready"
  end

  test "a failing repository announces its failure too" do
    user = repository_user_fixture("provisioner-announce-failure")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(user, %{name: "announced-failure"}, "announce-2")

    :ok = Repositories.subscribe_provisioning(repository.id)

    assert :processed = Provisioner.run_once(fn _work -> {:error, :fixture_failure} end)

    assert_receive {:repository_provisioning, id}, 1_000
    assert id == repository.id
    assert_receive {:repository_provisioning, id}, 1_000
    assert id == repository.id

    assert OpenAgents.Repo.get!(Repository, repository.id).lifecycle_state == "failed"
  end

  test "a stale running lease is reclaimed and an injected failure stays bounded" do
    user = repository_user_fixture("provisioner-recovery-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(user, %{name: "recover-me"}, "recover-key")

    stale_claim = DateTime.add(DateTime.utc_now(), -600, :second)

    OpenAgents.Repo.get_by!(ProvisioningOutbox, repository_id: repository.id)
    |> Ecto.Changeset.change(state: "running", claimed_at: stale_claim, attempt_count: 1)
    |> OpenAgents.Repo.update!()

    assert :processed = Provisioner.run_once(fn _work -> {:error, :fixture_secret_failure} end)

    failed_outbox = OpenAgents.Repo.get_by!(ProvisioningOutbox, repository_id: repository.id)
    failed_repository = OpenAgents.Repo.get!(Repository, repository.id)

    assert failed_outbox.state == "failed"
    assert failed_outbox.attempt_count == 2
    assert failed_outbox.error_code == "provisioning_failed"
    assert failed_repository.lifecycle_state == "failed"
    assert failed_repository.provision_error_code == "provisioning_failed"
    refute inspect(failed_outbox) =~ "fixture_secret_failure"
    assert "repository.provisioning.failed" in audit_types(repository.id)
  end

  test "a one-time import persists a bundle that reconstructs after cache loss", %{test: _test} do
    root = Application.fetch_env!(:openagents, :forge_data_dir) |> Path.dirname()
    source = Path.join(root, "github-source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Import test"])
    File.write!(Path.join(source, "README.md"), "accepted snapshot\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Accepted snapshot"])
    git!(source, ["branch", "release"])
    git!(source, ["tag", "v1"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()

    refs = %{
      "refs/heads/main" => sha,
      "refs/heads/release" => sha,
      "refs/tags/v1" => sha
    }

    user = repository_user_fixture("import-provisioner-owner")

    source_record = %{
      source_repository_id: 501,
      source_owner_id: user.github_id,
      source_full_name: "import-provisioner-owner/source",
      source_default_branch: "main",
      source_ref_digest: ref_digest(source, refs),
      source_head_sha: sha,
      source_refs: refs,
      source_uses_lfs: false
    }

    assert {:ok, repository, repository_import, :created} =
             Repositories.create_user_import(
               user,
               source_record,
               %{name: "imported-repository", default_branch: "main"},
               "import-provision-key"
             )

    :ok = Repositories.subscribe_provisioning(repository.id)

    assert :processed =
             Provisioner.run_once(fn work ->
               Importer.import(work.repository, source_url: source)
             end)

    # The outbox claim, the import going running, the import completing, and
    # the provisioning completing. Each is a durable transition, and each is
    # what a watching browser renders as the next stage.
    assert_announcements(repository.id, 4)

    completed_import =
      OpenAgents.Repo.get!(OpenAgents.Repositories.RepositoryImport, repository_import.id)

    assert completed_import.state == "completed"
    assert completed_import.completed_at
    assert "repository.import.completed" in audit_types(repository.id)
    assert "repository.import.created" in audit_types(repository.id)
    assert "repository.import.running" in audit_types(repository.id)
    assert {:ok, _generation, index} = WAL.read_index(repository.storage_key)
    assert [%{"format" => "git_bundle", "import_id" => import_id}] = WAL.entries(index)
    assert import_id == repository_import.id
    assert WAL.refs(index) == refs

    File.rm_rf!(Repos.bare_path(repository.storage_key))
    assert :ok = OpenAgents.Forge.Sync.ensure_fresh(repository.storage_key, "main")
    assert Repos.refs(repository.storage_key) == refs

    assert String.trim(bare_git!(repository.storage_key, ["show", "main:README.md"])) ==
             "accepted snapshot"

    File.write!(Path.join(source, "README.md"), "later source change\n")
    git!(source, ["commit", "-am", "Later source change"])
    assert :ok = OpenAgents.Forge.Sync.ensure_fresh(repository.storage_key, "main")

    assert String.trim(bare_git!(repository.storage_key, ["show", "main:README.md"])) ==
             "accepted snapshot"
  end

  test "a credential-backed import keeps the askpass helper available during fetch" do
    root = Application.fetch_env!(:openagents, :forge_data_dir) |> Path.dirname()
    source = Path.join(root, "credential-source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Import test"])
    File.write!(Path.join(source, "README.md"), "credential boundary\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Credential boundary"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    refs = %{"refs/heads/main" => sha}
    user = repository_user_fixture("credential-import-owner")

    source_record = %{
      source_repository_id: 502,
      source_owner_id: user.github_id,
      source_full_name: "credential-import-owner/source",
      source_default_branch: "main",
      source_ref_digest: ref_digest(source, refs),
      source_head_sha: sha,
      source_refs: refs,
      source_uses_lfs: false
    }

    assert {:ok, repository, _repository_import, :created} =
             Repositories.create_user_import(
               user,
               source_record,
               %{name: "credential-import", default_branch: "main"},
               "credential-import-key"
             )

    test_process = self()

    git_runner = fn git_directory, arguments, options ->
      environment = Keyword.fetch!(options, :env)
      askpass = List.keyfind!(environment, "GIT_ASKPASS", 0) |> elem(1)
      token_file = List.keyfind!(environment, "OPENAGENTS_GITHUB_TOKEN_FILE", 0) |> elem(1)

      {username, 0} =
        System.cmd(askpass, ["Username for 'https://github.com':"],
          env: environment,
          stderr_to_stdout: true
        )

      {password, 0} =
        System.cmd(askpass, ["Password for 'https://github.com':"],
          env: environment,
          stderr_to_stdout: true
        )

      send(test_process, {
        :credential_fetch,
        arguments,
        String.trim(username) == "x-access-token",
        password == "fixture-credential",
        File.stat!(token_file).mode |> Bitwise.band(0o777)
      })

      Repos.git(git_directory, arguments, options)
    end

    assert :ok =
             Importer.import(repository,
               source_url: source,
               source_credential: "fixture-credential",
               git_runner: git_runner
             )

    assert_receive {:credential_fetch, arguments, true, true, 0o600}
    refute "credential.interactive=never" in arguments
    assert "credential.helper=" in arguments
    assert "fetch" in arguments
  end

  test "an import over the configured bundle limit fails without entering the WAL" do
    root = Application.fetch_env!(:openagents, :forge_data_dir) |> Path.dirname()
    source = Path.join(root, "oversized-source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Import test"])
    File.write!(Path.join(source, "README.md"), "larger than one byte\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "Oversized fixture"])

    sha = source |> git!(["rev-parse", "HEAD"]) |> String.trim()
    refs = %{"refs/heads/main" => sha}
    user = repository_user_fixture("oversized-import-owner")

    source_record = %{
      source_repository_id: 503,
      source_owner_id: user.github_id,
      source_full_name: "oversized-import-owner/source",
      source_default_branch: "main",
      source_ref_digest: ref_digest(source, refs),
      source_head_sha: sha,
      source_refs: refs,
      source_uses_lfs: false
    }

    assert {:ok, repository, repository_import, :created} =
             Repositories.create_user_import(
               user,
               source_record,
               %{name: "oversized-import", default_branch: "main"},
               "oversized-import-key"
             )

    previous_limit = Application.get_env(:openagents, :repository_import_max_bundle_bytes)
    Application.put_env(:openagents, :repository_import_max_bundle_bytes, 1)

    on_exit(fn ->
      restore_env(:repository_import_max_bundle_bytes, previous_limit)
    end)

    assert {:error, :import_too_large} = Importer.import(repository, source_url: source)
    failed = OpenAgents.Repo.get!(OpenAgents.Repositories.RepositoryImport, repository_import.id)
    assert failed.state == "failed"
    assert failed.error_code == "import_too_large"
    assert {:error, :not_found} = WAL.read_index(repository.storage_key)
  end

  defp bare_git!(storage_key, args) do
    {output, 0} = Repos.git(Repos.bare_path(storage_key), args)
    output
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    output
  end

  defp ref_digest(source, refs) do
    refs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {name, sha} ->
      object_type = source |> git!(["cat-file", "-t", sha]) |> String.trim()
      Enum.join([name, object_type, sha], "\0")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  # Waits for exactly `expected` announcements about one repository, and for no
  # more than that.
  defp assert_announcements(repository_id, expected) do
    Enum.each(1..expected, fn _ ->
      assert_receive {:repository_provisioning, ^repository_id}, 1_000
    end)

    refute_receive {:repository_provisioning, ^repository_id}, 50
  end

  defp audit_types(repository_id) do
    AuditEvent
    |> where([event], event.repository_id == ^repository_id)
    |> select([event], event.event_type)
    |> OpenAgents.Repo.all()
    |> MapSet.new()
  end
end
