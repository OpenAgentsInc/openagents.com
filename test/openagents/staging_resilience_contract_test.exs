defmodule OpenAgents.StagingResilienceContractTest do
  use ExUnit.Case, async: false

  @scripts_root Path.expand("ops/staging")

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "openagents-staging-resilience-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)

    %{test_root: test_root}
  end

  test "the resilience matrix covers every failure and soak canary" do
    matrix =
      @scripts_root |> Path.join("resilience-matrix.json") |> File.read!() |> Jason.decode!()

    assert matrix["schema"] == "openagents.staging-resilience-matrix.v1"
    assert length(matrix["failure_injections"]) == 11

    assert Enum.uniq_by(matrix["failure_injections"], & &1["id"]) ==
             matrix["failure_injections"]

    assert matrix["revision"] == 2
    assert matrix["soak"]["required_duration_seconds"] == 15 * 60
    assert matrix["soak"]["minimum_metric_samples"] == 15

    assert matrix["soak"]["canaries"] |> Enum.map(& &1["id"]) |> Enum.sort() ==
             ~w(git memory status tracker typed voice)

    report =
      Path.join(
        System.tmp_dir!(),
        "openagents-resilience-target-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(report) end)
    assert {_, 0} = command("new-resilience-report.sh", ["--dry-run", report])
    target = report |> File.read!() |> Jason.decode!() |> Map.fetch!("target")
    assert target["track"] == "release-candidate"
    assert target["service"] == "openagents-staging-release"
  end

  test "the resilience dry run is local and fail-closed" do
    {output, 0} = command("resilience.sh", ["check"])

    assert output =~ "11 failures"
    assert output =~ "15-minute soak"
    assert output =~ "no network requests sent"
  end

  test "evidence permission checks support GNU and BSD stat" do
    validator = File.read!(Path.join(@scripts_root, "validate-resilience-report.sh"))

    assert validator =~ "stat -c '%a'"
    assert validator =~ "stat -f '%Lp'"
    assert validator =~ "report_dir=$(realpath"
  end

  test "finalization requires every recovery, 15 measured minutes, canaries, and zero unexplained harm",
       %{test_root: test_root} do
    report = Path.join(test_root, "report.json")
    evidence = Path.join(test_root, "recovery.json")

    assert {_, 0} = command("new-resilience-report.sh", ["--dry-run", report])
    File.write!(evidence, Jason.encode!(%{"schema" => "openagents.recovery-proof.v1"}))
    File.chmod!(evidence, 0o600)

    for ordinal <- 1..11 do
      case_id = "failure-#{String.pad_leading(Integer.to_string(ordinal), 3, "0")}"

      assert {_, 0} =
               command("record-result.sh", [report, case_id, "passed", "recovery-proof", evidence])
    end

    decoded = report |> File.read!() |> Jason.decode!()
    [reference | _] = hd(decoded["failure_injections"])["evidence"]
    completed_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    started_at = DateTime.add(completed_at, -(15 * 60), :second)

    soak = decoded["soak"]

    canaries =
      Enum.map(soak["canaries"], fn canary ->
        canary
        |> Map.put("completed_count", canary["minimum_passes"])
        |> Map.put("passed_count", canary["minimum_passes"])
        |> Map.put("receipt", reference)
      end)

    soak =
      soak
      |> Map.put("started_at", DateTime.to_iso8601(started_at))
      |> Map.put("completed_at", DateTime.to_iso8601(completed_at))
      |> Map.put("candidate_identity_stable", true)
      |> Map.put("redeploy_count", 0)
      |> Map.put("metric_sample_count", 15)
      |> Map.put("timeline_receipt", reference)
      |> Map.put("metrics_receipt", reference)
      |> Map.put("canaries", canaries)
      |> Map.put("post_soak_smoke_receipt", reference)
      |> Map.put("unexplained_error_count", 0)
      |> Map.put("data_loss_count", 0)
      |> Map.put("authority_expansion_count", 0)
      |> Map.put("fleet_divergence_count", 0)
      |> Map.put("secret_leak_count", 0)
      |> Map.put("unexplained_restart_count", 0)

    decoded =
      decoded
      |> Map.put("synthetic", false)
      |> Map.put("soak", soak)

    File.write!(report, Jason.encode!(decoded))
    File.chmod!(report, 0o600)

    assert {_, 0} = command("finalize-report.sh", ["--final", report])

    completed = report |> File.read!() |> Jason.decode!()
    assert completed["state"] == "complete"
    assert Enum.all?(completed["failure_injections"], &(&1["status"] == "passed"))
    assert completed["soak"]["redeploy_count"] == 0

    main_dir = Path.join(test_root, "main")
    nested_dir = Path.join([main_dir, "evidence", "gate15"])
    main_report = Path.join(main_dir, "report.json")
    File.mkdir_p!(nested_dir)
    File.cp!(report, Path.join(nested_dir, "report.json"))
    File.cp!(Path.join(test_root, "report.sha256"), Path.join(nested_dir, "report.sha256"))
    File.cp_r!(Path.join(test_root, "evidence"), Path.join(nested_dir, "evidence"))

    assert {_, 0} = command("new-report.sh", ["--dry-run", main_report])
    main = main_report |> File.read!() |> Jason.decode!()

    resilience_reference = %{
      "path" => "evidence/gate15/report.json",
      "sha256" => sha256(Path.join(nested_dir, "report.json")),
      "kind" => "resilience-report"
    }

    main_results =
      Enum.map(main["results"], fn result ->
        result
        |> Map.put("status", "not_applicable")
        |> Map.put("reason", "Not applicable in the synthetic nested-report proof.")
      end)

    staging_evidence = %{
      "migration" => %{
        "classification" => "empty_current",
        "snapshot_receipt" => resilience_reference,
        "rehearsal_receipt" => resilience_reference,
        "migration_versions_receipt" => resilience_reference,
        "rollback_compatibility_receipt" => resilience_reference
      },
      "configuration_readiness_receipt" => resilience_reference,
      "local_gate" => %{
        "default_test_count" => 1,
        "cluster_test_count" => 1,
        "javascript_test_count" => 1,
        "coverage_summary_receipt" => resilience_reference
      },
      "deployment" => %{
        "web_revision" => "openagents-staging-resilience-proof",
        "web_image_digest" => main["candidate"]["application_manifest_digest"],
        "distributed_node_release_receipt" => resilience_reference
      },
      "forge" => %{
        "build_receipt" => resilience_reference,
        "deployment_receipt" => resilience_reference,
        "rollback_receipt" => resilience_reference,
        "relup_receipt" => resilience_reference,
        "rolling_replacement_receipt" => resilience_reference
      },
      "sanitized_artifacts" => [resilience_reference],
      "failure_injection_timeline" => [resilience_reference],
      "soak_receipt" => resilience_reference,
      "known_issues" => []
    }

    main =
      main
      |> Map.put("synthetic", false)
      |> Map.put("results", main_results)
      |> Map.put("staging_evidence", staging_evidence)

    File.write!(main_report, Jason.encode!(main))
    File.chmod!(main_report, 0o600)

    assert {_, 0} = command("finalize-report.sh", ["--final", main_report])
    assert Jason.decode!(File.read!(main_report))["state"] == "complete"
  end

  defp command(script, arguments) do
    System.cmd(Path.join(@scripts_root, script), arguments, stderr_to_stdout: true)
  end

  defp sha256(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
