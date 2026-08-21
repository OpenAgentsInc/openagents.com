defmodule OpenAgents.SCV.ExecutionsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Repo
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.ExecutionEvent
  alias OpenAgents.SCV.Executions

  setup do
    {:ok, operator} =
      Accounts.upsert_github_user(%{
        github_id: System.unique_integer([:positive]),
        github_login: "scv-execution-#{System.unique_integer([:positive])}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
      })

    account =
      %DriverAccount{}
      |> DriverAccount.create_changeset(%{
        operator_id: operator.id,
        label: "Execution account",
        secret_ref: "file:execution-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()
      |> DriverAccount.ready_changeset(%{
        credential_version: 1,
        plan_type: "pro",
        available_models: ["gpt-5.6-luna"],
        reasoning_efforts: ["low", "none"],
        last_verified_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {:ok, account: account, revision: String.duplicate("a", 40)}
  end

  test "fences one active SCV per account and persists a terminal receipt", context do
    assert {:ok, execution} =
             Executions.claim(context.account, context.revision, "Inspect the release.")

    assert execution.status == "running"
    assert execution.driver == "codex_app_server"
    assert execution.model == "gpt-5.6-luna"
    assert execution.reasoning_effort == "low"
    assert execution.principal == "scv:codex_app_server:#{context.account.id}"

    assert {:error, :account_capacity_unavailable} =
             Executions.claim(context.account, context.revision, "Competing inspection.")

    assert :ok =
             Executions.record_event(execution, %{
               schema: "openagents.scv.event.v1",
               run_id: execution.id,
               type: "tool_started",
               emitted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
               activity_kind: "command",
               tool: "commandExecution",
               command: "must not persist",
               output: "must not persist"
             })

    assert [public] = Executions.public_projection()
    assert public["id"] =~ ~r/\Ascv-[0-9a-f]{8}\z/
    assert public["text"] == "Running a read-only repository command"
    refute inspect(public) =~ execution.id
    refute inspect(public) =~ "must not persist"

    [event] = Repo.all(ExecutionEvent)
    assert event.event_type == "tool_started"
    assert event.payload["activity_kind"] == "command"
    refute Map.has_key?(event.payload, "command")
    refute Map.has_key?(event.payload, "output")

    assert {:ok, updated} =
             Executions.record_session(execution, %{
               driver_thread_id: "thr_fixture",
               driver_turn_id: "turn_fixture"
             })

    assert updated.driver_thread_id == "thr_fixture"
    assert updated.driver_turn_id == "turn_fixture"

    report = "{\"summary\":\"bounded\"}"

    assert {:ok, completed} =
             Executions.finish(execution, %{
               status: "succeeded",
               report: %{text: report},
               usage: %{total_tokens: 21},
               resources: %{wall_time_ms: 50}
             })

    assert completed.status == "succeeded"
    assert completed.report == report
    assert completed.report_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert completed.event_count == 1
    assert completed.completed_at

    assert {:error, :stale_execution_generation} =
             Executions.record_event(execution, %{
               schema: "openagents.scv.event.v1",
               run_id: execution.id,
               type: "heartbeat"
             })
  end

  test "refuses an account without the admitted model or reasoning effort", context do
    unavailable =
      context.account
      |> Ecto.Changeset.change(available_models: [], reasoning_efforts: [])
      |> Repo.update!()

    assert {:error, :required_model_unavailable} =
             Executions.claim(unavailable, context.revision, "Inspect the release.")
  end

  test "expires a stale lease and releases the account slot", context do
    assert {:ok, execution} =
             Executions.claim(context.account, context.revision, "Inspect the release.")

    execution
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert Executions.expire_stale() == 1
    assert Executions.get!(execution.id).status == "uncertain"
    assert Executions.public_projection() == []

    assert {:ok, replacement} =
             Executions.claim(context.account, context.revision, "Inspect it again.")

    assert replacement.generation == execution.generation + 1
  end
end
