defmodule OpenAgents.SCV.RunTest do
  use ExUnit.Case, async: false

  alias OpenAgents.SCV
  alias OpenAgents.SCV.Run
  alias OpenAgents.SCV.Worker

  setup do
    root = Path.join(System.tmp_dir!(), "scv-run-#{System.unique_integer([:positive])}")
    repository = Path.join(root, "repository")
    output = Path.join(root, "runs")
    executable = Path.join(root, "fake-opencode")

    File.mkdir_p!(repository)
    File.write!(Path.join(repository, "README.md"), "SCV fixture")
    File.write!(executable, fake_executable())
    File.chmod!(executable, 0o700)

    on_exit(fn -> File.rm_rf(root) end)

    %{executable: executable, output: output, repository: repository}
  end

  test "runs OpenCode as an SCV driver inside an admitted environment", context do
    test_pid = self()
    revision = String.duplicate("a", 40)

    assert {:ok, result} =
             SCV.run(context.repository, "Inspect the fixture.",
               driver: :opencode,
               environment: :opencode_core,
               repository_revision: revision,
               driver_options: [
                 api_key: "fixture-secret-key",
                 executable: context.executable,
                 model: "openai/test-model",
                 output_root: context.output,
                 timeout_ms: 5_000,
                 event_sink: fn event -> send(test_pid, {:event, event}) end
               ]
             )

    assert result.status == "succeeded"
    assert result.repository.git_sha == revision

    assert result.scv == %{
             driver: "opencode",
             environment: "opencode-core",
             runner: "local",
             capabilities: [
               "model_inference",
               "network_egress",
               "process_execute",
               "workspace_read"
             ]
           }

    assert_receive {:event,
                    %{
                      schema: "openagents.scv.event.v1",
                      driver: "opencode",
                      environment: "opencode-core",
                      runner: "local",
                      type: "run_preparing"
                    }},
                   5_000
  end

  test "keeps objectives and driver credentials out of inspected run values", context do
    assert {:ok, run} =
             Run.new(context.repository, "sensitive objective",
               driver_options: [api_key: "sensitive credential"]
             )

    inspected = inspect(run)
    refute inspected =~ "sensitive objective"
    refute inspected =~ "sensitive credential"
  end

  test "rejects unadmitted drivers, environments, and repository revisions", context do
    assert {:error, :driver_not_admitted} =
             Run.new(context.repository, "objective", driver: :unknown)

    assert {:error, :environment_not_admitted} =
             Run.new(context.repository, "objective", environment: :unknown)

    assert {:error, :repository_revision_invalid} =
             Run.new(context.repository, "objective", repository_revision: "main")
  end

  test "starts the read-only staging worker from bounded environment values", context do
    test_pid = self()

    environment = %{
      "SCV_REPOSITORY" => context.repository,
      "SCV_REPOSITORY_REVISION" => String.duplicate("b", 40),
      "SCV_OBJECTIVE" => "Inspect the fixture.",
      "SCV_DRIVER" => "opencode",
      "SCV_ENVIRONMENT" => "opencode-core",
      "SCV_PERMISSION_PROFILE" => "read_only",
      "SCV_MODEL" => "openai/test-model",
      "SCV_REASONING_EFFORT" => "none",
      "SCV_OUTPUT_ROOT" => context.output,
      "OPENAI_API_KEY" => "fixture-secret-key"
    }

    assert {:ok, result} =
             Worker.run(environment,
               event_sink: fn event -> send(test_pid, {:worker_event, event}) end,
               driver_options: [executable: context.executable, timeout_ms: 5_000]
             )

    assert result.status == "succeeded"
    assert result.runtime.permission_profile == "read_only"
    assert result.runtime.reasoning_effort == "none"
    assert_receive {:worker_event, %{type: "process_started", driver: "opencode"}}, 5_000

    assert {:error, {:environment_value_not_admitted, "SCV_PERMISSION_PROFILE"}} =
             Worker.run(Map.put(environment, "SCV_PERMISSION_PROFILE", "workspace_write"))

    assert {:error, {:environment_missing, "OPENAI_API_KEY"}} =
             Worker.run(Map.delete(environment, "OPENAI_API_KEY"))

    assert {:error, {:environment_value_not_admitted, "SCV_REASONING_EFFORT"}} =
             Worker.run(Map.put(environment, "SCV_REASONING_EFFORT", "medium"))
  end

  test "emits bounded structured report chunks before the terminal result" do
    text = String.duplicate("SCV finding 🚀 ", 500)
    digest = "sha256:" <> (:crypto.hash(:sha256, text) |> Base.encode16(case: :lower))

    result = %{
      run_id: Ecto.UUID.generate(),
      status: "succeeded",
      duration_ms: 100,
      repository: %{git_sha: String.duplicate("a", 40)},
      scv: %{driver: "opencode", environment: "opencode-core"},
      runtime: %{model: "openai/gpt-5.6-luna", reasoning_effort: "low"},
      events: %{event_count: 2, tool_calls: %{}, usage: %{}},
      resources: %{},
      artifacts: %{events_digest: String.duplicate("b", 64)},
      report: %{
        schema: "openagents.scv.report.v1",
        text: text,
        bytes: byte_size(text),
        truncated: false
      }
    }

    events = Worker.terminal_events(result)
    terminal = List.last(events)
    chunks = Enum.drop(events, -1)

    assert terminal.type == "worker_finished"
    assert terminal.model == "openai/gpt-5.6-luna"
    assert terminal.reasoning_effort == "low"
    assert terminal.report.digest == digest
    assert terminal.report.chunk_count == length(chunks)
    refute Map.has_key?(terminal.report, :text)

    assert Enum.map(chunks, & &1.sequence) == Enum.to_list(1..length(chunks))
    assert Enum.all?(chunks, &(&1.type == "report_chunk"))
    assert Enum.all?(chunks, &(&1.report_digest == digest))
    assert Enum.all?(chunks, &(byte_size(Jason.encode!(&1)) < 4_096))
    assert chunks |> Enum.map(& &1.text) |> Enum.join() == text

    encoded = chunks |> hd() |> Worker.encode_event()
    assert encoded =~ "\\uD83D\\uDE80"
    refute encoded =~ "🚀"
    assert {:ok, %{"text" => decoded}} = Jason.decode(encoded)
    assert decoded == hd(chunks).text
  end

  defp fake_executable do
    """
    #!/bin/sh
    if [ "${OPENAI_API_KEY:-}" != "fixture-secret-key" ]; then exit 21; fi
    prompt=$(cat)
    if [ -z "$prompt" ]; then exit 22; fi
    case " $* " in *" --variant low "*|*" --variant none "*) :;; *) exit 23;; esac
    printf '%s\n' '{"type":"step_start","timestamp":1,"sessionID":"ses_scv","part":{"type":"step-start"}}'
    printf '%s\n' '{"type":"step_finish","timestamp":2,"sessionID":"ses_scv","part":{"type":"step-finish","cost":0.001,"tokens":{"input":4,"output":2,"reasoning":1,"cache":{"read":0,"write":0}}}}'
    """
  end
end
