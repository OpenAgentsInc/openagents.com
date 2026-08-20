defmodule OpenAgents.Voice.EvaluationTest do
  use ExUnit.Case, async: true
  @moduletag :skip

  alias OpenAgents.Voice.Evaluation.{ContractGate, Corpus}

  test "committed corpus covers every governed voice risk and has stable expected findings" do
    corpus = Corpus.load!()

    assert is_binary(corpus["digest"])
    assert byte_size(corpus["digest"]) == 64

    for regression_case <- corpus["cases"] do
      assert {:ok, result} = ContractGate.evaluate(regression_case["trace"])
      assert result["violations"] == regression_case["expected_violations"]
      assert result["passed"] == (regression_case["expected_violations"] == [])
    end
  end

  test "corpus validation rejects missing risk coverage" do
    corpus = Corpus.load!()

    reduced =
      Map.update!(corpus, "cases", &Enum.reject(&1, fn item -> item["risk"] == "tool_bypass" end))

    assert {:error, {:missing_required_risk, "tool_bypass"}} = Corpus.validate(reduced)
  end

  test "gate fails closed when admitted identity evidence is incomplete" do
    assert {:ok, result} = ContractGate.evaluate(%{})
    assert "identity_drift" in result["violations"]
    refute result["passed"]
  end
end
