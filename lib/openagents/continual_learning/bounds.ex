defmodule OpenAgents.ContinualLearning.Bounds do
  @moduledoc """
  The bounds one continual-learning job is admitted under.

  Every limit a run can spend — rounds, wall clock, checkpoint size, budget,
  runtime classes, admitted base models, admitted custody — is read here and
  snapshotted onto the job row at admission, so a configuration change cannot
  widen a run that is already admitted.
  """

  @kind "continual_learning"

  @doc "The `work_jobs` kind a continual-learning run uses."
  def kind, do: @kind

  @doc "The configured continual-learning settings."
  def settings, do: Application.get_env(:openagents, OpenAgents.ContinualLearning, [])

  @doc "Whether the continual-learning lane is admitted in this runtime."
  def enabled?, do: Keyword.get(settings(), :enabled) == true

  @doc "The one named buyer this lane serves, or `nil` when no buyer is named."
  def buyer_ref, do: Keyword.get(settings(), :buyer_ref)

  @doc "The buyer class every consumed listing must be licensed to."
  def buyer_class, do: Keyword.get(settings(), :buyer_class)

  @doc "The runtime classes a job may request, as capacity class identifiers."
  def runtime_classes, do: Keyword.get(settings(), :runtime_classes, [])

  @doc "The admitted base models as `%{model_ref => digest}`."
  def admitted_base_models, do: Keyword.get(settings(), :admitted_base_models, %{})

  @doc "The custody classes, as capacity data locations, the lane may train in."
  def admitted_custody, do: Keyword.get(settings(), :admitted_custody, [])

  @doc "The largest number of training rounds one job may run."
  def maximum_rounds, do: Keyword.get(settings(), :maximum_rounds, 8)

  @doc "The largest number of licensed datasets one job may admit."
  def maximum_datasets, do: Keyword.get(settings(), :maximum_datasets, 4)

  @doc "The wall clock one job is admitted for, in milliseconds."
  def wall_clock_ms, do: Keyword.get(settings(), :wall_clock_ms, 900_000)

  @doc "The largest checkpoint state one round may durably store, in bytes."
  def maximum_state_bytes, do: Keyword.get(settings(), :maximum_state_bytes, 65_536)

  @doc "How many continual-learning jobs may run at once."
  def concurrency_limit, do: Keyword.get(settings(), :concurrency_limit, 1)

  @doc "The exact training code the lane runs, as a digest."
  def training_code_digest, do: Keyword.get(settings(), :training_code_digest)

  @doc "The trainer implementation."
  def trainer,
    do: Keyword.get(settings(), :trainer, OpenAgents.ContinualLearning.Trainer.Reference)

  @doc "The evaluator implementation."
  def evaluator,
    do: Keyword.get(settings(), :evaluator, OpenAgents.ContinualLearning.Evaluator.Reference)

  @doc "The average power draw of one runtime class, in watts."
  def class_watts, do: Keyword.get(settings(), :class_watts, %{})

  @doc "The settlement unit every settlement-ready receipt is denominated in."
  def settlement_unit, do: Keyword.get(settings(), :settlement_unit, "usd_cents")

  @doc "The cost one round of a runtime class meters, in US cents."
  def round_cost_usd_cents(runtime_class) when is_binary(runtime_class) do
    settings()
    |> Keyword.get(:round_cost_usd_cents, %{})
    |> Map.get(runtime_class, 1)
  end

  @doc "The forge issue every accepted outcome of this lane is graded against."
  def outcome_issue do
    %{
      repository: Keyword.get(settings(), :outcome_repository),
      issue_number: Keyword.get(settings(), :outcome_issue_number)
    }
  end

  @doc """
  The immutable bounds snapshot recorded on the job row at admission.
  """
  def snapshot(runtime_class) when is_binary(runtime_class) do
    %{
      "maximum_rounds" => maximum_rounds(),
      "wall_clock_ms" => wall_clock_ms(),
      "maximum_state_bytes" => maximum_state_bytes(),
      "runtime_class" => runtime_class,
      "watts" => Map.get(class_watts(), runtime_class, 0),
      "training_code_digest" => training_code_digest()
    }
  end
end
