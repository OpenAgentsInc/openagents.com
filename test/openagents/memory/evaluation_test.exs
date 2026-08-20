defmodule OpenAgents.Memory.EvaluationTest do
  use OpenAgents.SarahDataCase

  alias OpenAgents.Memory.Evaluation.{Corpus, ReleaseGate, Report, Runner}

  test "committed PostgreSQL corpus produces the exact blocking baseline" do
    corpus = Corpus.load!()
    assert {:ok, report} = Runner.run()
    assert report["passed"]
    assert :ok = ReleaseGate.validate(corpus, report)

    baseline_path =
      :openagents
      |> :code.priv_dir()
      |> List.to_string()
      |> Path.join("sarah/evals/recall/baseline.v1.json")

    assert {:ok, baseline} = baseline_path |> File.read!() |> Jason.decode()
    assert report == baseline

    assert report["metrics"] == %{
             "precision_at_3" => 1.0,
             "precision_at_10" => 1.0,
             "grounded_answer_rate" => 1.0,
             "unsupported_memory_claims" => 0,
             "correction_recognition" => 1.0,
             "no_result_honesty" => 1.0,
             "cross_scope_leakage" => 0,
             "degradation_honesty" => 1.0
           }
  end

  test "altered, incomplete, and below-threshold evidence cannot pass the release gate" do
    corpus = Corpus.load!()
    assert {:ok, report} = Runner.run()

    [first | rest] = report["results"]
    leaking_result = %{first | "foreign_ref_count" => 1, "case_passed" => false}
    leaking = Report.build(corpus, [leaking_result | rest])
    refute leaking["passed"]
    assert leaking["metrics"]["cross_scope_leakage"] == 1
    assert {:error, :recall_release_evidence_rejected} = ReleaseGate.validate(corpus, leaking)

    incomplete = Report.build(corpus, tl(report["results"]))
    refute incomplete["passed"]
    assert {:error, :recall_release_evidence_rejected} = ReleaseGate.validate(corpus, incomplete)
  end
end
