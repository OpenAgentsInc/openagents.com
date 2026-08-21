defmodule OpenAgents.SCV.CodexAppServerExecutorTest do
  use ExUnit.Case, async: false

  alias OpenAgents.SCV.CodexCredentialStore
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.Executor.CodexAppServer

  setup do
    original = Application.fetch_env!(:openagents, :scv_codex)

    root =
      Path.join(System.tmp_dir!(), "codex-executor-test-#{System.unique_integer([:positive])}")

    repository = Path.join(root, "repository")
    credential_root = Path.join(root, "credentials")
    temporary_root = Path.join(root, "temporary")
    File.mkdir_p!(repository)
    System.cmd("git", ["-C", repository, "init", "--initial-branch=main"])
    File.write!(Path.join(repository, "README.md"), "SCV fixture")
    System.cmd("git", ["-C", repository, "add", "README.md"])

    System.cmd("git", [
      "-C",
      repository,
      "-c",
      "user.name=SCV",
      "-c",
      "user.email=scv@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    {revision, 0} = System.cmd("git", ["-C", repository, "rev-parse", "HEAD"])
    revision = String.trim(revision)

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.merge(original,
        executable: fixture(),
        credential_store: OpenAgents.SCV.CodexCredentialStore.File,
        file_root: credential_root,
        temporary_root: temporary_root,
        client_options: [args: ["run"]]
      )
    )

    account = %DriverAccount{
      id: Ecto.UUID.generate(),
      status: "ready",
      secret_ref: "file:executor",
      credential_version: 1,
      available_models: ["gpt-5.6-luna"],
      reasoning_efforts: ["low", "none"]
    }

    auth_json =
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "fixture-secret"}
      })

    assert {:ok, _version} = CodexCredentialStore.put(account, auth_json)

    on_exit(fn ->
      Application.put_env(:openagents, :scv_codex, original)
      File.rm_rf(root)
    end)

    {:ok,
     account: account, repository: repository, revision: revision, temporary_root: temporary_root}
  end

  test "runs a read-only Codex-backed SCV and emits a bounded report", context do
    test_process = self()
    run_id = Ecto.UUID.generate()

    assert {:ok, result} =
             CodexAppServer.run(
               context.repository,
               "Inspect the fixture without changing it.",
               account: context.account,
               run_id: run_id,
               repository_revision: context.revision,
               reasoning_effort: "low",
               event_sink: fn event ->
                 send(test_process, {:scv_event, event})
                 :ok
               end,
               session_sink: fn session ->
                 send(test_process, {:scv_session, session})
                 :ok
               end,
               credential_sink: fn _auth_json -> :ok end
             )

    assert result.status == "succeeded", inspect(result)
    assert result.repository.git_sha == context.revision
    assert result.runtime.model == "gpt-5.6-luna"
    assert result.runtime.reasoning_effort == "low"
    assert result.runtime.permission_profile == "read_only"
    assert result.report.schema == "openagents.scv.report.v1"
    assert result.report.valid
    assert result.report.text =~ "SCV completed the inspection"
    assert result.report.text =~ "[REDACTED]"
    assert result.events.tool_calls == %{"commandExecution" => 1}
    assert result.events.completed_tool_calls == %{"commandExecution" => 1}
    assert result.usage.total_tokens == 21

    assert_receive {:scv_session, %{driver_thread_id: "thr_fixture"}}

    assert_receive {:scv_session,
                    %{driver_thread_id: "thr_fixture", driver_turn_id: "turn_fixture"}}

    assert_receive {:scv_event, %{type: "driver_started"}}
    assert_receive {:scv_event, %{type: "driver_session_started"}}
    assert_receive {:scv_event, %{type: "turn_started"}}
    assert_receive {:scv_event, %{type: "tool_started", activity_kind: "command"}}
    assert_receive {:scv_event, %{type: "tool_completed", status: "completed"}}
    assert_receive {:scv_event, %{type: "message_delta", text_bytes: text_bytes}}
    assert text_bytes > 0
    assert_receive {:scv_event, %{type: "usage_updated", total_tokens: 21}}
    assert_receive {:scv_event, %{type: "turn_finished", status: "succeeded"}}
    assert_receive {:scv_event, %{type: "run_finished", status: "succeeded"}}

    refute inspect(result) =~ "fixture-secret"

    refute File.exists?(
             Path.join([
               context.temporary_root,
               "openagents-scv-codex",
               "openagents-scv-codex-run-#{run_id}"
             ])
           )
  end

  test "fails a report-only run that never accesses the repository", context do
    config = Application.fetch_env!(:openagents, :scv_codex)

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.put(config, :client_options, args: ["no_tools"])
    )

    test_process = self()

    assert {:ok, result} =
             CodexAppServer.run(
               context.repository,
               "Inspect the fixture without changing it.",
               account: context.account,
               run_id: Ecto.UUID.generate(),
               repository_revision: context.revision,
               reasoning_effort: "low",
               event_sink: fn event ->
                 send(test_process, {:scv_event, event})
                 :ok
               end
             )

    assert result.status == "failed"
    assert result.error_code == "tool_activity_missing"
    assert result.report.valid
    assert result.events.tool_calls == %{}
    assert result.events.completed_tool_calls == %{}
    assert_receive {:scv_event, %{type: "turn_finished", status: "succeeded"}}

    assert_receive {:scv_event,
                    %{type: "run_finished", status: "failed", error_code: "tool_activity_missing"}}
  end

  defp fixture do
    Path.expand("../../support/fake_codex_app_server.sh", __DIR__)
  end
end
