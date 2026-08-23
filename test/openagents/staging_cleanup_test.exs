defmodule OpenAgents.StagingCleanupTest do
  use OpenAgents.DataCase, async: false

  import OpenAgents.AccountsFixtures

  alias OpenAgents.Conversations
  alias OpenAgents.Machines.Machine
  alias OpenAgents.ProjectFields.ProjectField
  alias OpenAgents.Projects
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Staging.DisposableResource
  alias OpenAgents.StagingCleanup
  alias OpenAgents.Voice
  alias OpenAgents.Voice.{Config, Recording, Recordings}
  alias OpenAgents.Work.Job

  @run_id "gate14-cleanup-0001"

  setup do
    original_enabled = Application.get_env(:openagents, :staging_cleanup_enabled)
    original_environment = Application.get_env(:openagents, :runtime_environment)
    original_gate = Application.get_env(:openagents, :staging_gate)

    Application.put_env(:openagents, :staging_cleanup_enabled, true)
    Application.put_env(:openagents, :runtime_environment, :test)
    Application.put_env(:openagents, :staging_gate, 0)

    on_exit(fn ->
      restore_env(:staging_cleanup_enabled, original_enabled)
      restore_env(:runtime_environment, original_environment)
      restore_env(:staging_gate, original_gate)
    end)

    :ok
  end

  test "one run removes only its registered accounts, repositories, recordings, and machines" do
    user = repository_user_fixture("cleanup-target")
    unrelated_user = repository_user_fixture("cleanup-unrelated")
    repository = cleanup_repository_fixture(user)
    project = project_fixture(repository, user)
    field = project_field_fixture(project)
    machine = machine_fixture(user)
    recording = recording_fixture(user)

    for {kind, resource_id} <- [
          {:account, user.id},
          {:repository, repository.id},
          {:machine, machine.id},
          {:recording, recording.id}
        ] do
      assert {:ok, %DisposableResource{}} = StagingCleanup.register(@run_id, kind, resource_id)
    end

    assert {:ok,
            %{
              registered: %{
                "account" => 1,
                "machine" => 1,
                "recording" => 1,
                "repository" => 1
              }
            }} = StagingCleanup.preview(@run_id)

    checked = @run_id |> StagingCleanup.command!("check") |> Jason.decode!()
    assert checked["schema"] == "openagents.staging_cleanup.v1"
    assert checked["status"] == "checked"
    assert checked["deleted"] == nil

    assert {:ok, result} = StagingCleanup.cleanup(@run_id)
    assert result.registered == result.deleted

    assert Repo.get(OpenAgents.Accounts.User, user.id) == nil
    assert Repo.get(Repository, repository.id) == nil
    assert Repo.get(Machine, machine.id) == nil
    assert Repo.get(Recording, recording.id) == nil
    assert Repo.get(ProjectField, field.id) == nil
    assert Repo.get(OpenAgents.Accounts.User, unrelated_user.id)
    assert Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    assert Repo.aggregate(DisposableResource, :count) == 0

    assert {:ok, %{registered: empty}} = StagingCleanup.preview(@run_id)
    assert Enum.all?(empty, fn {_kind, count} -> count == 0 end)
  end

  test "registration refuses the canonical repository and administrator accounts" do
    assert {:error, :canonical_repository_forbidden} =
             StagingCleanup.register(
               @run_id,
               :repository,
               Repositories.get_by_path!("OpenAgentsInc", "openagents.com").id
             )

    user = repository_user_fixture("cleanup-admin")
    original_ids = Application.get_env(:openagents, :admin_github_ids)
    Application.put_env(:openagents, :admin_github_ids, [user.github_id])
    on_exit(fn -> restore_env(:admin_github_ids, original_ids) end)

    assert {:error, :administrator_account_forbidden} =
             StagingCleanup.register(@run_id, :account, user.id)
  end

  test "cleanup refuses an account that owns a project outside the registered repositories" do
    user = repository_user_fixture("cleanup-project-owner")
    repository = Repositories.get_by_path!("OpenAgentsInc", "openagents.com")
    {:ok, _membership} = Repositories.add_member(repository, user, "owner")
    project = project_fixture(repository, user)
    assert {:ok, _registration} = StagingCleanup.register(@run_id, :account, user.id)

    assert {:error, :account_owns_unregistered_project} = StagingCleanup.cleanup(@run_id)
    assert Repo.get(OpenAgents.Accounts.User, user.id)
    assert Repo.get(OpenAgents.Projects.Project, project.id)
    assert Repo.get_by(DisposableResource, run_id: @run_id)
  end

  test "cleanup refuses an account that owns an unregistered machine" do
    user = repository_user_fixture("cleanup-machine-owner")
    machine = machine_fixture(user)
    assert {:ok, _registration} = StagingCleanup.register(@run_id, :account, user.id)

    assert {:error, :account_owns_unregistered_machine} = StagingCleanup.cleanup(@run_id)
    assert Repo.get(OpenAgents.Accounts.User, user.id)
    assert Repo.get(Machine, machine.id)
  end

  test "cleanup refuses an account that owns an unregistered recording" do
    user = repository_user_fixture("cleanup-recording-owner")
    recording = recording_fixture(user)
    assert {:ok, _registration} = StagingCleanup.register(@run_id, :account, user.id)

    assert {:error, :account_owns_unregistered_recording} = StagingCleanup.cleanup(@run_id)
    assert Repo.get(OpenAgents.Accounts.User, user.id)
    assert Repo.get(Recording, recording.id)
  end

  test "cleanup refuses an online machine" do
    user = repository_user_fixture("cleanup-online-machine")
    machine = machine_fixture(user)
    assert {:ok, _registration} = StagingCleanup.register(@run_id, :machine, machine.id)
    assert {:ok, _pid} = OpenAgents.Computer.register(machine.id)
    on_exit(fn -> OpenAgents.Computer.unregister(machine.id) end)

    assert {:error, :machine_online} = StagingCleanup.cleanup(@run_id)
    assert Repo.get(Machine, machine.id)
  end

  test "cleanup refuses a machine with queued work" do
    user = repository_user_fixture("cleanup-active-work")
    machine = machine_fixture(user)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    owner = Conversations.get_conversation_owner!(conversation)

    job =
      %Job{}
      |> Job.create_changeset(%{
        conversation_id: conversation.id,
        owner_visitor_id: owner.id,
        machine_id: machine.id,
        surface: "text",
        goal: "Keep this staging machine busy"
      })
      |> Repo.insert!()

    assert {:ok, _registration} = StagingCleanup.register(@run_id, :machine, machine.id)
    assert {:error, :machine_has_active_work} = StagingCleanup.cleanup(@run_id)
    assert Repo.get(Machine, machine.id)
    assert Repo.get(Job, job.id)
  end

  test "cleanup refuses account data with an active voice session" do
    user = repository_user_fixture("cleanup-active-voice")
    {:ok, conversation} = Conversations.ensure_conversation(user)
    {:ok, _session} = Voice.admit_session(conversation, enabled_voice_config())
    assert {:ok, _registration} = StagingCleanup.register(@run_id, :account, user.id)

    assert {:error, {:account_data_cleanup_failed, :voice_session_in_progress}} =
             StagingCleanup.cleanup(@run_id)

    assert Repo.get(OpenAgents.Accounts.User, user.id)
  end

  test "cleanup is unavailable unless the staging-only feature is admitted" do
    user = repository_user_fixture("cleanup-disabled")
    Application.put_env(:openagents, :staging_cleanup_enabled, false)

    assert {:error, :staging_cleanup_not_admitted} =
             StagingCleanup.register(@run_id, :account, user.id)

    Application.put_env(:openagents, :staging_cleanup_enabled, true)
    Application.put_env(:openagents, :runtime_environment, :production)

    assert {:error, :staging_cleanup_not_admitted} = StagingCleanup.preview(@run_id)
  end

  defp cleanup_repository_fixture(user) do
    {:ok, repository} =
      Repositories.create_repository(%{
        owner: "OpenAgentsStaging",
        name: "cleanup-#{System.unique_integer([:positive])}",
        visibility: "private",
        default_branch: "main"
      })

    {:ok, _membership} = Repositories.add_member(repository, user, "owner")
    repository
  end

  defp project_fixture(repository, user) do
    {:ok, project} =
      Projects.create_project(
        repository,
        %{title: "Disposable cleanup project", owner: user.github_login},
        user
      )

    project
  end

  defp project_field_fixture(project) do
    {:ok, field} =
      Projects.create_project_field(%{
        name: "Status",
        data_type: "single_select",
        options: %{"values" => ["Todo", "Done"]},
        project_id: project.id
      })

    field
  end

  defp machine_fixture(user) do
    %Machine{user_id: user.id}
    |> Machine.create_changeset(%{name: "Disposable machine", tier: "probe", roots: []})
    |> Ecto.Changeset.change(
      token_digest: :crypto.hash(:sha256, "disposable-machine-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    )
    |> Repo.insert!()
  end

  defp recording_fixture(user) do
    {:ok, conversation} = Conversations.ensure_conversation(user)
    {:ok, session} = Voice.admit_session(conversation, enabled_voice_config())

    {:ok, _recording} =
      Recordings.append_chunk(session, session.generation, 1, "audio", "audio/webm")

    {:ok, recording} = Recordings.finalize(session, session.generation, "complete", 500)
    {:ok, _session} = Voice.end_session(session, session.generation, "user_ended")
    recording
  end

  defp enabled_voice_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
