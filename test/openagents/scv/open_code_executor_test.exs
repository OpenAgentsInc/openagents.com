defmodule OpenAgents.SCV.OpenCodeExecutorTest do
  use ExUnit.Case, async: false

  alias OpenAgents.SCV.Executor.OpenCode

  setup do
    root = Path.join(System.tmp_dir!(), "scv-opencode-#{System.unique_integer([:positive])}")
    repository = Path.join(root, "repository")
    output = Path.join(root, "runs")
    executable = Path.join(root, "fake-opencode")
    File.mkdir_p!(repository)
    File.write!(Path.join(repository, "README.md"), "fixture repository")
    File.write!(executable, fake_executable())
    File.chmod!(executable, 0o700)

    previous_probe = System.get_env("SCV_PRIVATE_PROBE")
    System.put_env("SCV_PRIVATE_PROBE", "must-not-leak")

    on_exit(fn ->
      restore_env("SCV_PRIVATE_PROBE", previous_probe)
      File.rm_rf(root)
    end)

    %{executable: executable, output: output, repository: repository}
  end

  test "runs OpenCode with isolated state and writes redacted evidence", context do
    test_pid = self()

    sample_fun = fn os_pid ->
      assert is_integer(os_pid) and os_pid > 0
      {:ok, %{rss_bytes: 12_345, cpu_percent: 4.5}}
    end

    assert {:ok, result} =
             OpenCode.run(
               context.repository,
               "READ_ONLY",
               shared_options(context) ++
                 [
                   sample_interval_ms: 10,
                   sample_fun: sample_fun,
                   event_sink: fn event -> send(test_pid, {:scv_event, event}) end
                 ]
             )

    assert result.status == "succeeded"
    assert result.exit_status == 0
    assert result.runtime.permission_profile == "read_only"
    assert result.events.event_count == 4
    assert result.events.diagnostic_line_count == 0
    assert result.events.invalid_event_count == 0
    assert result.events.session_ids == ["ses_fixture"]
    assert result.events.tool_calls == %{"read" => 1}
    assert result.events.tool_outcomes == %{"read:completed" => 1}
    assert result.events.text_event_count == 1

    assert result.report == %{
             schema: "openagents.scv.report.v1",
             text: "done [REDACTED]",
             bytes: 15,
             truncated: false
           }

    assert result.events.usage == %{
             input_tokens: 13,
             output_tokens: 8,
             reasoning_tokens: 2,
             cache_read_tokens: 3,
             cache_write_tokens: 1,
             cost_usd: 0.00125
           }

    assert result.resources.sample_count > 0
    assert result.resources.peak_rss_bytes == 12_345
    assert result.resources.maximum_cpu_percent == 4.5
    assert File.exists?(result.artifacts.events_path)
    assert File.exists?(result.summary_path)
    refute File.read!(result.artifacts.events_path) =~ "fixture-secret-key"
    assert File.read!(result.artifacts.events_path) =~ "[REDACTED]"
    refute File.read!(result.summary_path) =~ "READ_ONLY"
    refute File.read!(result.summary_path) =~ "fixture-secret-key"
    refute File.exists?(Path.join([Path.dirname(result.summary_path), "scratch"]))

    assert {:ok, %{mode: event_mode}} = File.stat(result.artifacts.events_path)
    assert {:ok, %{mode: summary_mode}} = File.stat(result.summary_path)
    assert Bitwise.band(event_mode, 0o777) == 0o600
    assert Bitwise.band(summary_mode, 0o777) == 0o600

    assert_receive {:scv_event, %{type: "run_preparing"}}
    assert_receive {:scv_event, %{type: "process_starting"}}
    assert_receive {:scv_event, %{type: "process_started", os_pid: os_pid}}
    assert is_integer(os_pid) and os_pid > 0

    for event_type <- ["step_start", "tool_use", "step_finish", "text"] do
      assert_receive {:scv_event,
                      %{
                        type: "opencode_event",
                        event_type: ^event_type,
                        session_id: "ses_fixture"
                      }}
    end

    assert_receive {:scv_event, %{type: "process_finished", status: "succeeded"}}
    assert_receive {:scv_event, %{type: "run_finished", status: "succeeded"}}
  end

  test "fails closed at the wall-clock limit", context do
    assert {:ok, result} =
             OpenCode.run(
               context.repository,
               "TIMEOUT",
               context
               |> shared_options()
               |> Keyword.put(:timeout_ms, 500)
               |> Keyword.put(:sample_interval_ms, 10)
             )

    assert result.status == "timeout"
    assert result.error_code == "command_timeout"
    assert result.exit_status == nil
    assert result.duration_ms < 1_500

    timeout_pid = context.repository |> Path.join("timeout.pid") |> File.read!() |> String.trim()
    {_output, status} = System.cmd("kill", ["-0", timeout_pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "stops capture at the output bound", context do
    assert {:ok, result} =
             OpenCode.run(
               context.repository,
               "OUTPUT_LIMIT",
               shared_options(context) ++ [maximum_output_bytes: 64]
             )

    assert result.status == "output_limit"
    assert result.error_code == "output_limit"
    assert result.resources.captured_output_bytes == 64
    assert result.resources.output_truncated
    assert File.stat!(result.artifacts.events_path).size <= 64
  end

  test "validates authority and execution bounds before creating a run", context do
    assert {:error, :repository_not_absolute} =
             OpenCode.run("relative", "prompt", shared_options(context))

    assert {:error, :permissions_invalid} =
             OpenCode.run(
               context.repository,
               "prompt",
               shared_options(context) ++ [permissions: :unbounded]
             )

    assert {:error, :openai_api_key_missing} =
             OpenCode.run(
               context.repository,
               "prompt",
               Keyword.put(shared_options(context), :api_key, nil)
             )
  end

  defp shared_options(context) do
    [
      api_key: "fixture-secret-key",
      executable: context.executable,
      model: "openai/test-model",
      output_root: context.output,
      timeout_ms: 1_000
    ]
  end

  defp fake_executable do
    """
    #!/bin/sh
    if [ "${OPENAI_API_KEY:-}" != "fixture-secret-key" ]; then exit 21; fi
    if [ "${OPENCODE_DISABLE_PROJECT_CONFIG:-}" != "1" ]; then exit 22; fi
    if [ "${OPENCODE_DISABLE_LSP_DOWNLOAD:-}" != "1" ]; then exit 23; fi
    if [ "${OPENCODE_PURE:-}" != "1" ]; then exit 24; fi
    if [ "${OPENCODE_DISABLE_SHARE:-}" != "1" ]; then exit 29; fi
    if [ "${SCV_PRIVATE_PROBE+x}" = "x" ]; then exit 25; fi
    prompt=$(cat)
    if [ -z "$prompt" ]; then exit 30; fi
    if [ "$1" != "run" ]; then exit 26; fi
    case " $* " in *" --auto "*) exit 27;; esac
    case " $* " in *" $prompt "*) exit 31;; esac
    if [ "${OPENCODE_CONFIG_DIR:-}" != "${XDG_CONFIG_HOME:-}/opencode" ]; then exit 28; fi

    case "$prompt" in
      *TIMEOUT*) echo $$ > "$PWD/timeout.pid"; while :; do :; done;;
      *OUTPUT_LIMIT*) printf '%0200d' 0; exit 0;;
    esac

    printf '%s\n' '{"type":"step_start","timestamp":1,"sessionID":"ses_fixture","part":{"type":"step-start"}}'
    printf '%s\n' '{"type":"tool_use","timestamp":2,"sessionID":"ses_fixture","part":{"tool":"read","state":{"status":"completed","output":"fixture-secret-key"}}}'
    printf '%s\n' '{"type":"step_finish","timestamp":3,"sessionID":"ses_fixture","part":{"type":"step-finish","cost":0.00125,"tokens":{"input":13,"output":8,"reasoning":2,"cache":{"read":3,"write":1}}}}'
    printf '%s\n' '{"type":"text","timestamp":4,"sessionID":"ses_fixture","part":{"type":"text","text":"done fixture-secret-key"}}'
    sleep 0.05
    """
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
