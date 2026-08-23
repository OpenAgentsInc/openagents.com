defmodule OpenAgents.ContinualLearningFixtures do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.ArtifactCatalogFixtures
  alias OpenAgents.ContinualLearning
  alias OpenAgents.Provenance.Canonical

  @buyer_ref "buyer:openagents-training"
  @base_model "openagents/base-1"

  def buyer_ref, do: @buyer_ref
  def base_model_ref, do: @base_model
  def base_model_digest, do: Canonical.sha256("base-model-1")
  def training_code_digest, do: Canonical.sha256("training-code-1")

  @doc "The continual-learning settings one admitted canary run needs."
  def settings(overrides \\ []) do
    Keyword.merge(
      [
        enabled: true,
        buyer_ref: @buyer_ref,
        buyer_class: "openagents_training",
        runtime_classes: ["standard", "strong"],
        admitted_base_models: %{@base_model => base_model_digest()},
        admitted_custody: ["openagents_managed"],
        maximum_rounds: 8,
        maximum_datasets: 4,
        wall_clock_ms: 900_000,
        maximum_state_bytes: 65_536,
        concurrency_limit: 1,
        training_code_digest: training_code_digest(),
        trainer: OpenAgents.ContinualLearning.Trainer.Reference,
        evaluator: OpenAgents.ContinualLearning.Evaluator.Reference,
        class_watts: %{"standard" => 350, "strong" => 700, "batch" => 250},
        round_cost_usd_cents: %{"standard" => 2, "strong" => 4, "batch" => 1},
        settlement_unit: "usd_cents",
        outcome_repository: "OpenAgentsInc/openagents.com",
        outcome_issue_number: 86
      ],
      overrides
    )
  end

  @doc "Capacity evidence one fresh standard class admits a job against."
  def capacity_evidence do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok,
     %{
       "classes" => [
         %{
           "id" => "standard",
           "logical" => 30,
           "active_reservations" => 4,
           "observed_limit" => 24,
           "reported_free" => 8,
           "queued" => 0,
           "observed_at" => DateTime.to_iso8601(now)
         }
       ]
     }}
  end

  @doc """
  Publishes one licensed dataset listing and walks it to an admitted acceptance
  receipt, which is what the buyer must already hold before a job can bind it.
  """
  def licensed_dataset!(overrides \\ %{}) do
    listing = ArtifactCatalogFixtures.publish_listing!(overrides)

    {:ok, offer} =
      ArtifactCatalog.record_transaction(
        listing.id,
        "offer",
        ArtifactCatalogFixtures.transaction_attributes(
          listing,
          listing.publication_receipt_ref,
          %{
            buyer_ref: @buyer_ref
          }
        )
      )

    {:ok, acceptance} =
      ArtifactCatalog.record_transaction(
        listing.id,
        "acceptance",
        ArtifactCatalogFixtures.transaction_attributes(listing, offer.receipt_ref, %{
          buyer_ref: @buyer_ref
        })
      )

    %{listing: listing, acceptance_ref: acceptance.receipt_ref}
  end

  @doc "Moves one listing's license window into the past, as an expiry does."
  def expire_license!(%{listing: listing}) do
    now = DateTime.utc_now()

    {1, _returned} =
      OpenAgents.Repo.update_all(
        from(l in OpenAgents.ArtifactCatalog.Listing, where: l.id == ^listing.id),
        set: [
          license_effective_at: DateTime.add(now, -7_200, :second),
          license_expires_at: DateTime.add(now, -60, :second)
        ]
      )

    :ok
  end

  @doc "One admitted dataset reference for `ContinualLearning.start/2`."
  def dataset_reference(%{listing: listing, acceptance_ref: acceptance_ref}) do
    %{listing_id: listing.id, acceptance_ref: acceptance_ref}
  end

  @doc "The admission attributes of one bounded canary job."
  def admission(conversation, training, evaluation, overrides \\ %{}) do
    Map.merge(
      %{
        buyer_ref: @buyer_ref,
        objective: "Improve tool selection on consented support traces.",
        objective_version: 1,
        base_model_ref: @base_model,
        base_model_digest: base_model_digest(),
        configuration: %{"learning_rate" => "3e-4"},
        runtime_class: "standard",
        conversation_id: conversation.id,
        owner_visitor_id: conversation.visitor_id,
        datasets: [dataset_reference(training)],
        evaluation: %{
          corpus: [dataset_reference(evaluation)],
          verifier: %{
            id: "verifier:openagents-eval-1",
            admitted: true,
            independent_of_producer: true
          },
          separation_required: true,
          acceptance_criteria: ["tool-selection score reaches the admitted target"],
          target_metric: "score",
          target_value: 0.6,
          policy_version: 1
        },
        budget: %{usd_cents: 100},
        stopping_policy: %{maximum_rounds: 2, minimum_improvement: 0.0}
      },
      overrides
    )
  end

  @doc "Waits for one continual-learning job to reach a terminal status."
  def await_terminal!(job_id, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _attempt, _accumulator ->
      {:ok, job} = ContinualLearning.fetch(job_id)

      if OpenAgents.ContinualLearning.Job.terminal?(job) do
        {:halt, job}
      else
        Process.sleep(25)
        {:cont, job}
      end
    end)
  end
end
