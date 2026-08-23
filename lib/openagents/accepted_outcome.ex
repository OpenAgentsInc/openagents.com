defmodule OpenAgents.AcceptedOutcome do
  @moduledoc """
  Evaluates agent-authored completion claims against the accepted-outcome
  contract (`priv/api-contracts/accepted-outcome-v1.json`).

  The contract connects the requested outcome (a scoped issue), execution
  authority (a bound attempt), the exact change (a revision), independent
  verification (an admitted verifier with a recorded falsifier), and terminal
  evidence (per-criterion receipts). The issue stays the canonical work
  record; this module only grades a claim about it.

  A claim that cannot satisfy the contract produces a typed non-accepted
  result — `:incomplete`, `:unauthorized`, or `:failed` — with the exact
  reasons, so every green result could have been red. Human-only work and
  repositories with agents disabled are outside the contract and return
  `:not_applicable`.
  """

  @contract_path "priv/api-contracts/accepted-outcome-v1.json"

  @required_issue_sections ~w(problem scope acceptance_criteria success_metrics)a
  @required_attempt_fields ~w(issue_number repository authority budget revision)a
  @terminal_results ~w(passed failed)a
  @false_green_classes ~w(
    false_green_fixture_assert
    false_green_api_mirror
    false_green_mocked_seam
    false_green_coverage_theater
    false_green_round_up
  )
  @non_accepted_types ~w(incomplete unauthorized failed)a
  @exemptions ~w(human_only_work agents_disabled_repository)a

  @doc "The decoded and validated public contract."
  def load do
    with {:ok, bytes} <- File.read(contract_file()),
         {:ok, contract} <- Jason.decode(bytes),
         :ok <- validate(contract) do
      {:ok, contract}
    end
  end

  @doc "The issue-template sections a scoped implementation issue must carry."
  def required_issue_sections, do: @required_issue_sections

  @doc "The fields that bind one execution attempt to its authorized change."
  def required_attempt_fields, do: @required_attempt_fields

  @doc "The five named false-green classes from episode 252."
  def false_green_classes, do: @false_green_classes

  @doc "The typed non-accepted result types."
  def non_accepted_types, do: @non_accepted_types

  @doc "Validates the committed contract document."
  def validate(%{
        "contract" => "openagents.accepted-outcome.v1",
        "version" => 1,
        "issue_template" => %{"required_sections" => sections},
        "attempt_binding" => %{"required_fields" => fields},
        "verification" => %{"terminal_results" => terminal_results},
        "false_green_classes" => false_greens,
        "result_states" => %{
          "non_accepted" => non_accepted,
          "not_applicable" => not_applicable
        },
        "visibility" => %{"public_projection_excludes" => excludes}
      }) do
    committed = [
      {sections, Enum.map(@required_issue_sections, &Atom.to_string/1)},
      {fields, Enum.map(@required_attempt_fields, &Atom.to_string/1)},
      {terminal_results, Enum.map(@terminal_results, &Atom.to_string/1)},
      {false_greens, @false_green_classes},
      {non_accepted, Enum.map(@non_accepted_types, &Atom.to_string/1)},
      {not_applicable, Enum.map(@exemptions, &Atom.to_string/1)}
    ]

    if Enum.all?(committed, fn {document, code} -> document == code end) and
         is_list(excludes) and excludes != [] do
      :ok
    else
      {:error, :contract_divergence}
    end
  end

  def validate(_contract), do: {:error, :invalid_contract}

  @doc """
  Evaluates one completion claim.

  Returns one of:

    * `{:not_applicable, exemption}` — human-only work or a repository with
      agents disabled; the contract does not gate it.
    * `{:accepted, outcome}` — every acceptance criterion names its evidence,
      the attempt binds the exact revision, and an admitted verifier passed
      against a recorded falsifier. `outcome.criteria` explains which evidence
      satisfied each criterion.
    * `{:not_accepted, type, reasons}` — a typed refusal: `:incomplete` for a
      structurally incomplete claim, `:unauthorized` for a claim outside its
      granted authority or verifier admission, `:failed` for a failed verifier
      result or a named false-green class.
  """
  def evaluate(claim) when is_map(claim) do
    with :applicable <- applicability(claim),
         [] <- incomplete_reasons(claim),
         [] <- unauthorized_reasons(claim),
         [] <- failed_reasons(claim) do
      {:accepted, outcome(claim)}
    else
      {:not_applicable, exemption} -> {:not_applicable, exemption}
      [{type, _detail} | _rest] = reasons -> {:not_accepted, type, Keyword.values(reasons)}
    end
  end

  @doc """
  The bounded public projection of an evaluation result.

  The projection carries only result state, typed reasons, criterion names,
  and receipt references whose visibility is `:public`. It never carries
  prompts, logs, private repository names, or private receipt references, so
  a public issue page can explain the result without leaking evidence.
  """
  def public_projection({:not_applicable, exemption}) do
    %{state: :not_applicable, exemption: exemption}
  end

  def public_projection({:not_accepted, type, reasons}) do
    %{state: :not_accepted, type: type, reasons: reasons}
  end

  def public_projection({:accepted, outcome}) do
    %{
      state: :accepted,
      issue_number: outcome.issue_number,
      revision: outcome.revision,
      criteria:
        Enum.map(outcome.criteria, fn item ->
          case item.visibility do
            :public -> %{criterion: item.criterion, evidence: item.receipt}
            _restricted -> %{criterion: item.criterion, evidence: :private}
          end
        end)
    }
  end

  defp applicability(claim) do
    cond do
      claim[:actor] != :agent -> {:not_applicable, :human_only_work}
      claim[:agents_enabled] != true -> {:not_applicable, :agents_disabled_repository}
      true -> :applicable
    end
  end

  defp incomplete_reasons(claim) do
    issue = claim[:issue] || %{}
    attempt = claim[:attempt] || %{}
    verification = claim[:verification] || %{}

    missing_sections =
      for section <- @required_issue_sections,
          blank?(get_in(issue, [:sections, section])),
          do: {:incomplete, {:missing_issue_section, section}}

    missing_fields =
      for field <- @required_attempt_fields,
          blank?(attempt[field]),
          do: {:incomplete, {:missing_attempt_field, field}}

    missing_records =
      [
        {blank?(verification[:verifier]), :missing_verifier},
        {blank?(verification[:falsifier]), :missing_falsifier},
        {verification[:terminal_result] not in @terminal_results, :missing_terminal_result}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(fn {_missing, reason} -> {:incomplete, reason} end)

    unevidenced =
      for criterion <- acceptance_criteria(issue),
          not Enum.any?(
            evidence(claim),
            &(&1[:criterion] == criterion and present?(&1[:receipt]))
          ),
          do: {:incomplete, {:unevidenced_criterion, criterion}}

    missing_sections ++ missing_fields ++ missing_records ++ unevidenced
  end

  defp unauthorized_reasons(claim) do
    issue = claim[:issue] || %{}
    attempt = claim[:attempt] || %{}
    verification = claim[:verification] || %{}
    verifier = verification[:verifier] || %{}

    [
      {attempt[:issue_number] != issue[:number] or attempt[:repository] != issue[:repository],
       :attempt_not_bound_to_issue},
      {verifier[:admitted] != true, :verifier_not_admitted},
      {verification[:separation_required] == true and
         verifier[:independent_of_producer] != true, :verifier_not_independent}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {_failed, reason} -> {:unauthorized, reason} end)
  end

  defp failed_reasons(claim) do
    verification = claim[:verification] || %{}
    named_classes = Enum.filter(List.wrap(verification[:false_green_classes]), &present?/1)

    [
      {verification[:terminal_result] == :failed, :verifier_failed},
      {named_classes != [], {:false_green, named_classes}}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {_failed, reason} -> {:failed, reason} end)
  end

  defp outcome(claim) do
    issue = claim[:issue]
    verification = claim[:verification]

    %{
      issue_number: issue[:number],
      repository: issue[:repository],
      revision: claim[:attempt][:revision],
      verifier: verification[:verifier][:id],
      falsifier: verification[:falsifier],
      criteria:
        for criterion <- acceptance_criteria(issue) do
          item = Enum.find(evidence(claim), &(&1[:criterion] == criterion))
          %{criterion: criterion, receipt: item[:receipt], visibility: item[:visibility]}
        end
    }
  end

  defp acceptance_criteria(issue), do: List.wrap(get_in(issue, [:sections, :acceptance_criteria]))

  defp evidence(claim), do: List.wrap(claim[:evidence])

  defp blank?(value), do: not present?(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)

  defp contract_file, do: Application.app_dir(:openagents, @contract_path)
end
