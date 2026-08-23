defmodule OpenAgents.AcceptedOutcomeTest do
  use ExUnit.Case, async: true

  alias OpenAgents.AcceptedOutcome

  @criteria [
    "The command exits zero on the fixture repository.",
    "An unauthorized caller receives a typed refusal."
  ]

  defp claim(overrides \\ %{}) do
    Map.merge(
      %{
        actor: :agent,
        agents_enabled: true,
        issue: %{
          number: 66,
          repository: "OpenAgentsInc/openagents.com",
          sections: %{
            problem: "Agent reports can sound complete without proof.",
            scope: "Grade completion claims; keep the issue canonical.",
            acceptance_criteria: @criteria,
            success_metrics: ["Zero false-completion incidents."]
          }
        },
        attempt: %{
          issue_number: 66,
          repository: "OpenAgentsInc/openagents.com",
          authority: %{token_scope: "forge:write"},
          budget: %{tool_calls: 32},
          revision: "8c4f2b1a9d3e"
        },
        verification: %{
          verifier: %{id: "ci-gate", admitted: true, independent_of_producer: true},
          separation_required: true,
          falsifier: "The fixture run fails when the fix is reverted.",
          terminal_result: :passed,
          false_green_classes: []
        },
        evidence: [
          %{criterion: Enum.at(@criteria, 0), receipt: "receipt:gate:41", visibility: :public},
          %{criterion: Enum.at(@criteria, 1), receipt: "receipt:test:87", visibility: :private}
        ]
      },
      overrides
    )
  end

  test "the committed contract is valid and matches the code" do
    assert {:ok, contract} = AcceptedOutcome.load()

    assert contract["false_green_classes"] == AcceptedOutcome.false_green_classes()

    divergent = put_in(contract, ["result_states", "non_accepted"], ["failed"])
    assert {:error, :contract_divergence} = AcceptedOutcome.validate(divergent)

    assert {:error, :invalid_contract} = AcceptedOutcome.validate(%{"contract" => "other"})
  end

  test "a complete, bound, verified claim is accepted and explains each criterion" do
    assert {:accepted, outcome} = AcceptedOutcome.evaluate(claim())

    assert outcome.issue_number == 66
    assert outcome.revision == "8c4f2b1a9d3e"
    assert outcome.verifier == "ci-gate"
    assert outcome.falsifier =~ "reverted"

    assert Enum.map(outcome.criteria, & &1.criterion) == @criteria
    assert Enum.all?(outcome.criteria, &(&1.receipt != nil))
  end

  test "a failed verifier result produces a typed failed result" do
    failed = claim(%{verification: %{claim().verification | terminal_result: :failed}})

    assert {:not_accepted, :failed, [:verifier_failed]} = AcceptedOutcome.evaluate(failed)
  end

  test "a named false-green class fails even when the verifier reported green" do
    verification = %{claim().verification | false_green_classes: ["false_green_mocked_seam"]}

    assert {:not_accepted, :failed, [{:false_green, ["false_green_mocked_seam"]}]} =
             AcceptedOutcome.evaluate(claim(%{verification: verification}))
  end

  test "a structurally incomplete claim produces a typed incomplete result" do
    base = claim()

    unscoped =
      claim(%{issue: put_in(base.issue, [:sections, :success_metrics], [])})

    assert {:not_accepted, :incomplete, [{:missing_issue_section, :success_metrics}]} =
             AcceptedOutcome.evaluate(unscoped)

    no_revision = claim(%{attempt: %{base.attempt | revision: nil}})

    assert {:not_accepted, :incomplete, [{:missing_attempt_field, :revision}]} =
             AcceptedOutcome.evaluate(no_revision)

    no_falsifier = claim(%{verification: %{base.verification | falsifier: "  "}})

    assert {:not_accepted, :incomplete, [:missing_falsifier]} =
             AcceptedOutcome.evaluate(no_falsifier)

    unevidenced = claim(%{evidence: [hd(base.evidence)]})

    assert {:not_accepted, :incomplete, [{:unevidenced_criterion, criterion}]} =
             AcceptedOutcome.evaluate(unevidenced)

    assert criterion == Enum.at(@criteria, 1)
  end

  test "an unbound or unadmitted attempt produces a typed unauthorized result" do
    base = claim()

    unbound = claim(%{attempt: %{base.attempt | issue_number: 67}})

    assert {:not_accepted, :unauthorized, [:attempt_not_bound_to_issue]} =
             AcceptedOutcome.evaluate(unbound)

    verifier = %{base.verification.verifier | admitted: false}

    assert {:not_accepted, :unauthorized, [:verifier_not_admitted]} =
             AcceptedOutcome.evaluate(
               claim(%{verification: %{base.verification | verifier: verifier}})
             )

    dependent = %{base.verification.verifier | independent_of_producer: false}

    assert {:not_accepted, :unauthorized, [:verifier_not_independent]} =
             AcceptedOutcome.evaluate(
               claim(%{verification: %{base.verification | verifier: dependent}})
             )
  end

  test "producer-verifier separation is required only when policy requires it" do
    base = claim()
    dependent = %{base.verification.verifier | independent_of_producer: false}

    verification = %{base.verification | verifier: dependent, separation_required: false}

    assert {:accepted, _outcome} = AcceptedOutcome.evaluate(claim(%{verification: verification}))
  end

  test "the public projection never carries private evidence" do
    projection = AcceptedOutcome.public_projection(AcceptedOutcome.evaluate(claim()))

    assert projection.state == :accepted

    assert [
             %{evidence: "receipt:gate:41"},
             %{evidence: :private}
           ] = projection.criteria

    refute inspect(projection) =~ "receipt:test:87"

    refusal =
      AcceptedOutcome.evaluate(
        claim(%{verification: %{claim().verification | terminal_result: :failed}})
      )

    assert %{state: :not_accepted, type: :failed, reasons: [:verifier_failed]} =
             AcceptedOutcome.public_projection(refusal)
  end

  test "human-only work and agents-disabled repositories stay outside the contract" do
    assert {:not_applicable, :human_only_work} =
             AcceptedOutcome.evaluate(claim(%{actor: :human}))

    assert {:not_applicable, :agents_disabled_repository} =
             AcceptedOutcome.evaluate(claim(%{agents_enabled: false}))
  end
end
