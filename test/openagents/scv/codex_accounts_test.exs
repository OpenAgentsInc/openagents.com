defmodule OpenAgents.SCV.CodexAccountsTest do
  use OpenAgents.DataCase, async: false

  alias OpenAgents.Accounts
  alias OpenAgents.Repo
  alias OpenAgents.SCV.CodexAccounts
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.DriverLoginAttempt

  setup do
    original = Application.fetch_env!(:openagents, :scv_codex)
    original_admin_ids = Application.get_env(:openagents, :admin_github_ids, [])

    root =
      Path.join(System.tmp_dir!(), "codex-account-test-#{System.unique_integer([:positive])}")

    refs = ["file:slot-#{System.unique_integer([:positive])}"]

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.merge(original, file_root: root, credential_refs: refs)
    )

    on_exit(fn ->
      Application.put_env(:openagents, :scv_codex, original)
      Application.put_env(:openagents, :admin_github_ids, original_admin_ids)
      File.rm_rf(root)
    end)

    {:ok, credential_ref: hd(refs), root: root}
  end

  test "connects an individual operator account and persists only a credential reference", %{
    root: root
  } do
    telemetry_id = "codex-account-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:openagents, :scv, :codex_account, :event],
        fn _event, _measurements, metadata, test_process ->
          send(test_process, {:codex_account_event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    operator = operator("codex-operator")
    :ok = CodexAccounts.subscribe()

    assert {:ok, account, attempt, ceremony} =
             CodexAccounts.start_device_login(operator, %{"label" => "Primary Codex"})

    assert ceremony.verification_url == "https://auth.openai.com/codex/device"
    assert ceremony.user_code == "TEST-CODE"
    assert ceremony.account_id == account.id
    assert ceremony.attempt_id == attempt.id

    assert_receive {:codex_account_event,
                    %{
                      schema: "openagents.scv.codex_account.event.v1",
                      type: "device_login_waiting",
                      account_id: account_id,
                      attempt_id: attempt_id
                    }},
                   5_000

    assert account_id == account.id
    assert attempt_id == attempt.id

    assert_receive {:scv_codex_accounts, {:account_ready, account_id}}, 5_000
    assert account_id == account.id

    assert_receive {:codex_account_event,
                    %{
                      type: "account_ready",
                      account_id: ready_account_id,
                      attempt_id: ready_attempt_id,
                      credential_version: credential_version
                    }},
                   5_000

    assert ready_account_id == account.id
    assert ready_attempt_id == attempt.id
    assert is_integer(credential_version)

    connected = Repo.get!(DriverAccount, account.id)
    completed = Repo.get!(DriverLoginAttempt, attempt.id)

    assert connected.status == "ready"
    assert connected.driver == "codex_app_server"
    assert connected.credential_kind == "managed_chatgpt"
    assert connected.account_email == "operator@example.test"
    assert connected.plan_type == "plus"
    assert "gpt-5.6-luna" in connected.available_models
    assert Enum.sort(connected.reasoning_efforts) == ["low", "none"]
    assert is_integer(connected.credential_version)
    assert completed.status == "succeeded"
    assert is_binary(completed.user_code_digest)

    credential_slot = String.replace_prefix(connected.secret_ref, "file:", "")
    credential_file = Path.join(root, credential_slot <> ".json")
    assert {:ok, stored} = File.read(credential_file)
    assert is_map(Jason.decode!(stored))

    inspected = inspect(connected)
    refute inspected =~ stored
    refute inspected =~ "test-only"
  end

  test "refuses ordinary users and fails closed when configured account slots are occupied" do
    ordinary = user("codex-ordinary")
    assert {:error, :not_authorized} = CodexAccounts.start_device_login(ordinary, %{})

    first_operator = operator("codex-first")
    second_operator = operator("codex-second")
    :ok = CodexAccounts.subscribe()

    assert {:ok, account, _attempt, _ceremony} =
             CodexAccounts.start_device_login(first_operator, %{})

    assert {:error, :account_capacity_reached} =
             CodexAccounts.start_device_login(second_operator, %{})

    assert_receive {:scv_codex_accounts, {:account_ready, account_id}}, 5_000
    assert account_id == account.id
  end

  test "reuses a failed account slot for a new device login", %{credential_ref: credential_ref} do
    operator = operator("codex-retry")
    :ok = CodexAccounts.subscribe()

    failed_account =
      %DriverAccount{}
      |> DriverAccount.create_changeset(%{
        operator_id: operator.id,
        label: "Failed Codex",
        secret_ref: credential_ref
      })
      |> Repo.insert!()
      |> DriverAccount.failed_changeset("account_not_ready")
      |> Repo.update!()

    assert {:ok, retried_account, _attempt, _ceremony} =
             CodexAccounts.start_device_login(operator, %{"label" => "Retried Codex"})

    assert retried_account.id == failed_account.id
    assert retried_account.status == "pending"
    assert retried_account.label == "Retried Codex"
    assert retried_account.last_error_code == nil

    assert_receive {:scv_codex_accounts, {:account_ready, account_id}}, 5_000
    assert account_id == failed_account.id
  end

  test "recovers an active device ceremony through the cluster registry" do
    operator = operator("codex-recover")
    configure_held_login()

    assert {:ok, account, attempt, ceremony} =
             CodexAccounts.start_device_login(operator, %{"label" => "Recoverable Codex"})

    assert {:ok, recovered} = CodexAccounts.recover_device_login(operator)
    assert recovered == ceremony

    assert [{pid, _value}] =
             Horde.Registry.lookup(
               OpenAgents.HordeRegistry,
               {:scv_codex_login, attempt.id}
             )

    assert node(pid) == node()
    assert :ok = CodexAccounts.cancel_device_login(operator, attempt.id)

    assert Repo.get!(DriverAccount, account.id).status == "failed"
    assert Repo.get!(DriverLoginAttempt, attempt.id).status == "cancelled"
  end

  test "surfaces and clears a device ceremony interrupted by process loss" do
    operator = operator("codex-interrupted")
    configure_held_login()

    assert {:ok, account, attempt, _ceremony} =
             CodexAccounts.start_device_login(operator, %{"label" => "Interrupted Codex"})

    assert [{pid, _value}] =
             Horde.Registry.lookup(
               OpenAgents.HordeRegistry,
               {:scv_codex_login, attempt.id}
             )

    monitor = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert {:error, :login_not_running, attempt_id} =
             CodexAccounts.recover_device_login(operator)

    assert attempt_id == attempt.id
    assert :ok = CodexAccounts.cancel_device_login(operator, attempt.id)
    assert Repo.get!(DriverAccount, account.id).status == "failed"
    assert Repo.get!(DriverLoginAttempt, attempt.id).status == "cancelled"
  end

  defp configure_held_login do
    config = Application.fetch_env!(:openagents, :scv_codex)

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.put(config, :client_options, args: ["hold"])
    )
  end

  defp operator(key) do
    account = user(key)

    Application.put_env(
      :openagents,
      :admin_github_ids,
      [account.github_id | Application.get_env(:openagents, :admin_github_ids, [])]
    )

    account
  end

  defp user(key) do
    digest = :crypto.hash(:sha256, key)
    github_id = digest |> binary_part(0, 7) |> :binary.decode_unsigned()

    {:ok, account} =
      Accounts.upsert_github_user(%{
        github_id: github_id,
        github_login: "test-#{String.slice(key, 0, 20)}",
        github_avatar_url: "https://avatars.githubusercontent.com/u/#{github_id}?v=4"
      })

    account
  end
end
