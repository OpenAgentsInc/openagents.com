defmodule OpenAgents.Tools.WorkspaceBashTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Tools.{ExecutionContext, Registry, Runner, WorkspaceBash}

  setup do
    base = Path.join(System.tmp_dir!(), "workspace-bash-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspace")
    snapshots = Path.join(base, "snapshots")
    File.mkdir_p!(root)
    previous = Application.get_env(:openagents, :workspace_snapshot_dir)
    Application.put_env(:openagents, :workspace_snapshot_dir, snapshots)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:openagents, :workspace_snapshot_dir, previous),
        else: Application.delete_env(:openagents, :workspace_snapshot_dir)

      File.rm_rf(base)
    end)

    context = %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: "conversation:test",
      authorities: MapSet.new(["command.execute"]),
      workspace: %{
        "type" => "repository_workspace",
        "root" => root,
        "canonical" => false,
        "read_only" => false,
        "workspace_ref" => "workspace:test"
      }
    }

    %{context: context, root: root, snapshots: snapshots}
  end

  test "runs a command in the workspace and returns exit status and receipts", %{
    context: context,
    root: root
  } do
    assert {:ok, result} =
             WorkspaceBash.execute(%{"command" => "pwd && printf hello"}, context)

    assert result.status == "succeeded"
    assert result.result["status"] == "exited"
    assert result.result["exit_code"] == 0
    assert result.result["signal"] == nil
    assert result.result["timed_out"] == false
    assert result.result["truncated"] == false
    assert result.result["artifact_ref"] == nil
    assert result.result["output"] == "#{root}\nhello"
    assert result.result["workspace_ref"] == "workspace:test"
    assert is_integer(result.result["duration_ms"])
    assert [receipt] = result.target_receipt_refs
    assert String.starts_with?(receipt, "workspace-command:")
    assert result.result["effect_receipt"] == receipt
  end

  test "interleaves stderr with stdout in order", %{context: context} do
    assert {:ok, result} =
             WorkspaceBash.execute(
               %{"command" => "echo one && echo two 1>&2 && echo three"},
               context
             )

    assert result.result["output"] == "one\ntwo\nthree\n"
  end

  test "reports a nonzero exit as an executed outcome", %{context: context} do
    assert {:ok, result} = WorkspaceBash.execute(%{"command" => "printf oops; exit 3"}, context)

    assert result.status == "succeeded"
    assert result.result["status"] == "exited"
    assert result.result["exit_code"] == 3
    assert result.result["output"] == "oops"
  end

  test "distinguishes command-not-found", %{context: context} do
    assert {:ok, result} =
             WorkspaceBash.execute(%{"command" => "definitely-not-a-command-123"}, context)

    assert result.result["status"] == "command_not_found"
    assert result.result["exit_code"] == 127
  end

  test "distinguishes a signal-terminated command", %{context: context} do
    assert {:ok, result} = WorkspaceBash.execute(%{"command" => "kill -TERM $$"}, context)

    assert result.result["status"] == "signaled"
    assert result.result["signal"] == 15
  end

  test "times out, kills the whole process tree, and keeps captured output", %{
    context: context,
    root: root
  } do
    command = "echo before; sleep 30 & echo $! > child.pid; sleep 30"

    assert {:ok, result} =
             WorkspaceBash.execute(
               %{"command" => command, "timeout_seconds" => 1},
               context
             )

    assert result.status == "failed"
    assert result.error["code"] == "command_timed_out"
    assert result.result["status"] == "timed_out"
    assert result.result["timed_out"] == true
    assert result.result["exit_code"] == nil
    assert result.result["output"] =~ "before"
    assert result.result["duration_ms"] >= 1_000

    child_pid = root |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert wait_until(fn -> not os_process_alive?(child_pid) end)
  end

  test "cleans up the process tree when the tool task is killed mid-command", %{
    context: context,
    root: root
  } do
    start_supervised!({Task.Supervisor, name: __MODULE__.CancelSupervisor})

    task =
      Task.Supervisor.async_nolink(__MODULE__.CancelSupervisor, fn ->
        WorkspaceBash.execute(%{"command" => "echo $$ > shell.pid; sleep 30"}, context)
      end)

    pid_file = Path.join(root, "shell.pid")
    assert wait_until(fn -> File.exists?(pid_file) end)
    shell_pid = pid_file |> File.read!() |> String.trim()
    assert os_process_alive?(shell_pid)

    _shutdown = Task.shutdown(task, :brutal_kill)
    assert wait_until(fn -> not os_process_alive?(shell_pid) end)
  end

  test "bounds the preview to the last lines and stores the full output artifact", %{
    context: context,
    snapshots: snapshots
  } do
    assert {:ok, result} = WorkspaceBash.execute(%{"command" => "seq 1 3000"}, context)

    assert result.result["truncated"] == true
    preview_lines = String.split(result.result["output"], "\n", trim: true)
    assert length(preview_lines) <= 2_000
    assert List.last(preview_lines) == "3000"
    refute result.result["output"] =~ ~r/^1\n/

    artifact_ref = result.result["artifact_ref"]
    assert String.starts_with?(artifact_ref, "workspace-artifact:")
    assert artifact_ref in result.target_receipt_refs

    artifact_id = String.replace_prefix(artifact_ref, "workspace-artifact:", "")
    full_output = File.read!(Path.join([snapshots, artifact_id, "output"]))
    assert String.starts_with?(full_output, "1\n2\n")
    assert full_output =~ "\n3000\n"

    {:ok, expires_at, _offset} = DateTime.from_iso8601(result.result["artifact_expires_at"])
    assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  test "expired output artifacts are purged and write snapshots are kept", %{
    snapshots: snapshots
  } do
    expired = Path.join(snapshots, "expired-artifact")
    File.mkdir_p!(expired)

    File.write!(
      Path.join(expired, "manifest.json"),
      Jason.encode!(%{
        "kind" => "command_output",
        "expires_at" => "2020-01-01T00:00:00Z",
        "bytes" => 1
      })
    )

    write_snapshot = Path.join(snapshots, "write-snapshot")
    File.mkdir_p!(write_snapshot)
    File.write!(Path.join(write_snapshot, "manifest.json"), Jason.encode!(%{"existed" => true}))

    assert :ok = WorkspaceBash.purge_expired_artifacts()
    refute File.exists?(expired)
    assert File.exists?(write_snapshot)
  end

  test "redacts credential-shaped output and starts from an emptied environment", %{
    context: context
  } do
    secret = "sk-or-v1-abcdefghijklmnopqrstuvwxyz012345"
    System.put_env("WORKSPACE_BASH_TEST_SECRET", secret)
    on_exit(fn -> System.delete_env("WORKSPACE_BASH_TEST_SECRET") end)

    assert {:ok, environment} = WorkspaceBash.execute(%{"command" => "env"}, context)
    refute environment.result["output"] =~ "WORKSPACE_BASH_TEST_SECRET"
    refute environment.result["output"] =~ secret

    assert {:ok, echoed} =
             WorkspaceBash.execute(%{"command" => "echo token=#{secret}"}, context)

    refute echoed.result["output"] =~ secret
    assert echoed.result["output"] =~ "[REDACTED]"
    refute echoed.result["command"] =~ secret
  end

  test "denies network access when the host supports network namespaces", %{context: context} do
    assert {:ok, probe} = WorkspaceBash.execute(%{"command" => "true"}, context)

    case probe.result["network"] do
      "denied" ->
        assert {:ok, interfaces} =
                 WorkspaceBash.execute(%{"command" => "cat /proc/net/dev"}, context)

        names =
          interfaces.result["output"]
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, _stats] -> [String.trim(name)]
              _header -> []
            end
          end)

        assert names in [["lo"], []]

      "unrestricted" ->
        :ok
    end
  end

  test "refuses canonical, connected, read-only, and missing workspaces", %{
    context: context,
    root: root
  } do
    canonical = put_in(context.workspace["canonical"], true)

    assert {:error, :canonical_workspace_refused} =
             WorkspaceBash.execute(%{"command" => "true"}, canonical)

    connected = %{context | workspace: %{"type" => "connected_forge_repository", "root" => root}}

    assert {:error, :workspace_required} =
             WorkspaceBash.execute(%{"command" => "true"}, connected)

    read_only = put_in(context.workspace["read_only"], true)

    assert {:error, :workspace_read_only} =
             WorkspaceBash.execute(%{"command" => "true"}, read_only)

    assert {:error, :workspace_required} =
             WorkspaceBash.execute(%{"command" => "true"}, %{context | workspace: nil})
  end

  test "refuses the canonical application checkout as a command workspace", %{context: context} do
    hosted = put_in(context.workspace["root"], OpenAgents.Tools.Repository.source_dir())

    assert {:error, :canonical_workspace_refused} =
             WorkspaceBash.execute(%{"command" => "true"}, hosted)
  end

  test "rejects invalid commands and timeouts", %{context: context} do
    assert {:error, :invalid_command} = WorkspaceBash.execute(%{"command" => "   "}, context)
    assert {:error, :invalid_command} = WorkspaceBash.execute(%{"command" => "a\0b"}, context)

    assert {:error, :invalid_command_timeout} =
             WorkspaceBash.execute(%{"command" => "true", "timeout_seconds" => 0}, context)

    assert {:error, :invalid_command_timeout} =
             WorkspaceBash.execute(%{"command" => "true", "timeout_seconds" => 500}, context)
  end

  test "refuses a second concurrent command in the same workspace", %{
    context: context,
    root: root
  } do
    ready = Path.join(root, "ready.fifo")
    release = Path.join(root, "release.fifo")
    {_output, 0} = System.cmd("mkfifo", [ready, release])

    start_supervised!({Task.Supervisor, name: __MODULE__.ConcurrencySupervisor})

    first =
      Task.Supervisor.async(__MODULE__.ConcurrencySupervisor, fn ->
        WorkspaceBash.execute(%{"command" => "echo go > ready.fifo && cat release.fifo"}, context)
      end)

    {"go\n", 0} = System.cmd("cat", [ready])

    assert {:error, :command_concurrency_limit} =
             WorkspaceBash.execute(%{"command" => "true"}, context)

    {_output, 0} = System.cmd("sh", ["-c", "echo done > #{release}"])
    assert {:ok, result} = Task.await(first)
    assert result.result["exit_code"] == 0
  end

  test "runner requires command.execute authority and an exact approval receipt", %{
    context: context
  } do
    assert {:ok, snapshot} = Registry.build([WorkspaceBash])

    call = %{
      call_id: "call-workspace-bash",
      name: "bash",
      version: 1,
      raw_arguments: Jason.encode!(%{"command" => "printf approved"})
    }

    assert {:ok, refused_approval} = Runner.run(snapshot, call, context)
    assert refused_approval["error"]["code"] == "module_approval_required"

    receipt = %{
      "schema" => "sarah.module_approval.v1",
      "approval_class" => "exact_current_user_consent",
      "module_id" => WorkspaceBash.specification().module_id,
      "version" => 1,
      "scope_ref" => context.scope_ref,
      "explicit" => true,
      "actor_type" => "person",
      "receipt_ref" => "approval:workspace-bash"
    }

    assert {:ok, refused_authority} =
             Runner.run(snapshot, call, %{
               context
               | authorities: MapSet.new(),
                 approval_receipts: [receipt]
             })

    assert refused_authority["error"]["code"] == "authority_refused"

    assert {:ok, approved} =
             Runner.run(snapshot, call, %{context | approval_receipts: [receipt]})

    assert approved["status"] == "succeeded"
    assert approved["result"]["output"] == "approved"
    assert approved["result"]["exit_code"] == 0
  end

  defp wait_until(check, attempts \\ 200)
  defp wait_until(_check, 0), do: false

  defp wait_until(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(25)
      wait_until(check, attempts - 1)
    end
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _nonzero} -> false
    end
  end
end
