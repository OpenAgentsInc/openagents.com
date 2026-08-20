defmodule OpenAgents.StagingRegressionContractTest do
  use ExUnit.Case, async: false

  @scripts_root Path.expand("ops/staging")

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "openagents-staging-regression-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)

    %{test_root: test_root}
  end

  test "the matrix has one unique result contract for every Gate 14 case" do
    matrix =
      @scripts_root |> Path.join("regression-matrix.json") |> File.read!() |> Jason.decode!()

    cases = Enum.flat_map(matrix["groups"], & &1["cases"])

    assert matrix["schema"] == "openagents.staging-regression-matrix.v1"
    assert matrix["revision"] == 1
    assert length(matrix["groups"]) == 10
    assert length(cases) == 69
    assert Enum.uniq_by(cases, & &1["id"]) == cases
    assert Enum.all?(cases, &(&1["execution"] in ["automated", "hybrid", "manual"]))
  end

  test "the harness dry run is local, fail-closed, and network-free" do
    {output, 0} = command("regression.sh", ["check"])

    assert output =~ "69 cases"
    assert output =~ "no network requests sent"
  end

  test "a report preserves failed attempts and binds copied evidence", %{test_root: test_root} do
    report = Path.join(test_root, "report.json")
    evidence = Path.join(test_root, "evidence.json")
    reason = Path.join(test_root, "reason.txt")

    assert {_, 0} = command("new-report.sh", ["--dry-run", report])
    assert {_, 0} = command("validate-report.sh", ["--draft", report])

    File.write!(evidence, Jason.encode!(%{"schema" => "openagents.test-receipt.v1"}))
    File.chmod!(evidence, 0o600)
    File.write!(reason, "The initial bounded probe observed an unavailable dependency.")
    File.chmod!(reason, 0o600)

    assert {_, 0} =
             command("record-result.sh", [
               report,
               "public-001",
               "failed",
               "public-smoke",
               evidence,
               reason
             ])

    assert {_, 0} =
             command("record-result.sh", [
               report,
               "public-001",
               "passed",
               "public-smoke",
               evidence
             ])

    assert {_, 0} = command("validate-report.sh", ["--draft", report])
    assert {output, 1} = command("finalize-report.sh", ["--regression", report])
    assert output =~ "report remains unchanged"

    decoded = report |> File.read!() |> Jason.decode!()
    result = hd(decoded["results"])

    assert decoded["state"] == "draft"
    assert result["status"] == "passed"
    assert Enum.map(result["attempts"], & &1["outcome"]) == ["failed", "passed"]
    assert Enum.map(result["attempts"], & &1["ordinal"]) == [1, 2]
    assert length(result["evidence"]) == 2
    assert Enum.all?(result["evidence"], &String.match?(&1["sha256"], ~r/^[0-9a-f]{64}$/))

    for reference <- result["evidence"] do
      assert File.exists?(Path.join(test_root, reference["path"]))
    end
  end

  test "the scanner refuses a credential shape without echoing its value", %{test_root: test_root} do
    unsafe = Path.join(test_root, "unsafe.txt")
    credential = "Bearer " <> String.duplicate("0", 24)
    File.write!(unsafe, credential)
    File.chmod!(unsafe, 0o600)

    {output, 1} = command("scan-evidence.sh", [unsafe])

    assert output =~ "bearer credential"
    refute output =~ credential
  end

  test "regression passes with common evidence but final requires a resilience report", %{
    test_root: test_root
  } do
    report = Path.join(test_root, "report.json")
    evidence_dir = Path.join(test_root, "evidence")
    evidence = Path.join(evidence_dir, "bounded-receipt.json")

    assert {_, 0} = command("new-report.sh", ["--dry-run", report])
    File.mkdir_p!(evidence_dir)
    File.write!(evidence, Jason.encode!(%{"schema" => "openagents.bounded-receipt.v1"}))
    File.chmod!(evidence, 0o600)

    evidence_sha256 =
      evidence |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    reference = %{
      "path" => "evidence/bounded-receipt.json",
      "sha256" => evidence_sha256,
      "kind" => "bounded-contract-proof"
    }

    decoded = report |> File.read!() |> Jason.decode!()
    image_digest = decoded["candidate"]["application_manifest_digest"]

    complete_common_evidence = %{
      "migration" => %{
        "classification" => "empty_current",
        "snapshot_receipt" => reference,
        "rehearsal_receipt" => reference,
        "migration_versions_receipt" => reference,
        "rollback_compatibility_receipt" => reference
      },
      "configuration_readiness_receipt" => reference,
      "local_gate" => %{
        "default_test_count" => 1,
        "cluster_test_count" => 1,
        "javascript_test_count" => 1,
        "coverage_summary_receipt" => reference
      },
      "deployment" => %{
        "web_revision" => "openagents-staging-contract-proof",
        "web_image_digest" => image_digest,
        "distributed_node_release_receipt" => reference
      },
      "forge" => %{
        "build_receipt" => reference,
        "deployment_receipt" => reference,
        "rollback_receipt" => reference,
        "relup_receipt" => reference,
        "rolling_replacement_receipt" => reference
      },
      "sanitized_artifacts" => [reference],
      "failure_injection_timeline" => [],
      "soak_receipt" => nil,
      "known_issues" => []
    }

    complete_results =
      Enum.map(decoded["results"], fn result ->
        result
        |> Map.put("status", "not_applicable")
        |> Map.put("reason", "Not applicable in the synthetic contract proof.")
      end)

    decoded =
      decoded
      |> Map.put("synthetic", false)
      |> Map.put("results", complete_results)
      |> Map.put("staging_evidence", complete_common_evidence)

    File.write!(report, Jason.encode!(decoded))
    File.chmod!(report, 0o600)

    assert {_, 0} = command("finalize-report.sh", ["--regression", report])
    assert Jason.decode!(File.read!(report))["state"] == "regression_passed"

    assert {output, 1} = command("finalize-report.sh", ["--final", report])
    assert output =~ "report remains unchanged"
    assert Jason.decode!(File.read!(report))["state"] == "regression_passed"

    [checksum, "report.json"] =
      test_root |> Path.join("report.sha256") |> File.read!() |> String.split()

    actual_checksum =
      report |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert checksum == actual_checksum
  end

  test "the public smoke retains hashes and metrics but no response content" do
    smoke = File.read!(Path.join(@scripts_root, "run-public-smoke.sh"))

    assert smoke =~ "https://staging.openagents.com"
    assert smoke =~ "content_retained: false"
    assert smoke =~ "body_sha256"
    assert smoke =~ "response_headers_sha256"
    assert smoke =~ "response_nonce_bound_to_theme_bootstrap"
    refute smoke =~ "stage.openagents.com"
    refute smoke =~ "--cookie"
    refute smoke =~ "--netrc"
  end

  defp command(script, arguments) do
    System.cmd(Path.join(@scripts_root, script), arguments, stderr_to_stdout: true)
  end
end
