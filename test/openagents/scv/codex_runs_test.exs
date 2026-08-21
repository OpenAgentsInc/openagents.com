defmodule OpenAgents.SCV.CodexRunsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Forge.Repos, as: ForgeRepos
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.SCV.CodexCredentialStore
  alias OpenAgents.SCV.CodexRuns
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.ExecutionEvent

  setup do
    original_codex = Application.fetch_env!(:openagents, :scv_codex)
    original_forge_data = Application.get_env(:openagents, :forge_data_dir)
    root = Path.join(System.tmp_dir!(), "codex-runs-test-#{System.unique_integer([:positive])}")
    forge_data = Path.join(root, "forge")
    credential_root = Path.join(root, "credentials")
    temporary_root = Path.join(root, "temporary")

    Application.put_env(:openagents, :forge_data_dir, forge_data)

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.merge(original_codex,
        executable: fixture(),
        credential_store: OpenAgents.SCV.CodexCredentialStore.File,
        file_root: credential_root,
        temporary_root: temporary_root,
        client_options: [args: ["run"]]
      )
    )

    repository = Repositories.initial_repository!()
    bare = ForgeRepos.ensure_repo!(repository.storage_key, repository.default_branch)
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["-C", source, "init", "--initial-branch=main"])
    File.write!(Path.join(source, "README.md"), "Durable SCV fixture")
    System.cmd("git", ["-C", source, "add", "README.md"])

    System.cmd("git", [
      "-C",
      source,
      "-c",
      "user.name=SCV",
      "-c",
      "user.email=scv@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    {revision, 0} = System.cmd("git", ["-C", source, "rev-parse", "HEAD"])
    revision = String.trim(revision)
    {_, 0} = System.cmd("git", ["-C", source, "push", bare, "HEAD:refs/heads/main"])

    {:ok, operator} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "codex-run-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/2?v=4"
      })

    pending =
      %DriverAccount{}
      |> DriverAccount.create_changeset(%{
        operator_id: operator.id,
        label: "Durable run account",
        secret_ref: "file:durable-run"
      })
      |> Repo.insert!()

    auth_json =
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "fixture-secret"}
      })

    {:ok, credential_version} = CodexCredentialStore.put(pending, auth_json)

    account =
      pending
      |> DriverAccount.ready_changeset(%{
        credential_version: credential_version,
        plan_type: "pro",
        available_models: ["gpt-5.6-luna"],
        reasoning_efforts: ["low", "none"],
        last_verified_at: DateTime.utc_now()
      })
      |> Repo.update!()

    on_exit(fn ->
      Application.put_env(:openagents, :scv_codex, original_codex)

      if is_nil(original_forge_data) do
        Application.delete_env(:openagents, :forge_data_dir)
      else
        Application.put_env(:openagents, :forge_data_dir, original_forge_data)
      end

      File.rm_rf(root)
    end)

    {:ok,
     account: account, repository: repository, revision: revision, temporary_root: temporary_root}
  end

  test "dispatches an SCV and persists its events and report", context do
    assert {:ok, claimed} =
             CodexRuns.start(
               context.account.id,
               context.repository,
               context.revision,
               "Inspect the fixture and report production risks."
             )

    assert claimed.status == "running"
    assert {:ok, completed} = CodexRuns.await(claimed.id, 5_000)
    assert completed.status == "succeeded"
    assert completed.report =~ "SCV completed the inspection"
    assert completed.event_count >= 9
    assert completed.driver_thread_id == "thr_fixture"
    assert completed.driver_turn_id == "turn_fixture"
    assert completed.usage["total_tokens"] == 21

    events = Repo.all(from event in ExecutionEvent, where: event.run_id == ^claimed.id)
    event_types = MapSet.new(events, & &1.event_type)

    assert MapSet.subset?(
             MapSet.new(~w(driver_started turn_started tool_started run_finished)),
             event_types
           )

    workspace = Path.join([context.temporary_root, "openagents-scv-workspaces", claimed.id])
    refute File.exists?(workspace)
    refute inspect(completed) =~ "fixture-secret"
  end

  test "refuses dispatch while the Codex SCV feature is disabled", context do
    config = Application.fetch_env!(:openagents, :scv_codex)
    Application.put_env(:openagents, :scv_codex, Keyword.put(config, :enabled, false))

    assert {:error, :codex_scv_disabled} =
             CodexRuns.start(
               context.account.id,
               context.repository,
               context.revision,
               "Inspect the fixture."
             )
  end

  defp fixture do
    Path.expand("../../support/fake_codex_app_server.sh", __DIR__)
  end
end
