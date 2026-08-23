defmodule OpenAgents.ContinualLearningTest do
  @moduledoc """
  CONTINUAL-001: the lane that trains on verified licensed datasets.

  The refusals come first — a disabled lane, a signed-in non-operator, a buyer
  the lane never admitted, a base-model digest that does not match, a license
  that does not admit training, a removed listing, an evaluator that is not
  independent when separation is required, an unavailable fleet — because a
  lane that cannot refuse cannot be trusted with licensed data. The canary run
  then goes end to end and proves the artifact binds the exact datasets,
  licenses, code, configuration, checkpoints, and evaluation it claims.
  """

  use OpenAgents.DataCase, async: false

  alias OpenAgents.AccountsFixtures
  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.Conversations
  alias OpenAgents.ContinualLearning
  alias OpenAgents.ContinualLearning.Checkpoint
  alias OpenAgents.ContinualLearningFixtures, as: Fixtures
  alias OpenAgents.ContinualLearningStubs
  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})

    previous_capacity = Application.get_env(:openagents, OpenAgents.Capacity, [])

    previous =
      for key <- [:admin_github_ids, :capacity_test_evidence] do
        {key, Application.get_env(:openagents, key)}
      end

    Application.put_env(:openagents, OpenAgents.ContinualLearning, Fixtures.settings())

    Application.put_env(
      :openagents,
      OpenAgents.Capacity,
      Keyword.merge(previous_capacity, evidence_source: OpenAgents.CapacityEvidenceStub)
    )

    Application.put_env(:openagents, :capacity_test_evidence, Fixtures.capacity_evidence())

    on_exit(fn ->
      Application.put_env(:openagents, OpenAgents.Capacity, previous_capacity)
      Application.delete_env(:openagents, OpenAgents.ContinualLearning)
      ContinualLearningStubs.Observer.forget()

      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:openagents, key),
          else: Application.put_env(:openagents, key, value)
      end
    end)

    :ok
  end

  describe "admission" do
    test "a disabled lane refuses before authority is considered" do
      %{operator: operator, conversation: conversation} = account("cl-disabled")
      configure(enabled: false)

      assert {:error, :continual_learning_disabled} =
               ContinualLearning.start(operator, admission(conversation))
    end

    test "a signed-in non-operator cannot start, read, cancel, or export a job" do
      %{conversation: conversation} = account("cl-operator")
      user = AccountsFixtures.repository_user_fixture("cl-non-operator")

      assert {:error, :operator_required} =
               ContinualLearning.start(user, admission(conversation))

      assert {:error, :operator_required} = ContinualLearning.get(user, Ecto.UUID.generate())
      assert {:error, :operator_required} = ContinualLearning.list(user)
      assert {:error, :operator_required} = ContinualLearning.cancel(user, Ecto.UUID.generate())

      assert {:error, :operator_required} =
               ContinualLearning.export_evidence(user, Ecto.UUID.generate())
    end

    test "only the named buyer the lane admits may start a job" do
      %{operator: operator, conversation: conversation} = account("cl-buyer")

      assert {:error, :buyer_not_admitted} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{buyer_ref: "buyer:someone-else"})
               )

      configure(buyer_ref: nil)

      assert {:error, :buyer_not_configured} =
               ContinualLearning.start(operator, admission(conversation))
    end

    test "the base model, its digest, and the training code are all pinned" do
      %{operator: operator, conversation: conversation} = account("cl-model")

      assert {:error, :base_model_not_admitted} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{base_model_ref: "someone/else-1"})
               )

      assert {:error, :base_model_digest_mismatch} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{base_model_digest: Canonical.sha256("other")})
               )

      configure(training_code_digest: nil)

      assert {:error, :training_code_not_pinned} =
               ContinualLearning.start(operator, admission(conversation))
    end

    test "the runtime class, budget, and stopping policy stay inside their bounds" do
      %{operator: operator, conversation: conversation} = account("cl-bounds")

      assert {:error, :runtime_class_not_admitted} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{runtime_class: "gigantic"})
               )

      assert {:error, :budget_invalid} =
               ContinualLearning.start(operator, admission(conversation, %{budget: %{}}))

      assert {:error, :stopping_policy_exceeds_bound} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{stopping_policy: %{maximum_rounds: 9}})
               )

      assert {:error, :stopping_policy_required} =
               ContinualLearning.start(operator, admission(conversation, %{stopping_policy: %{}}))
    end

    test "an unlicensed use, a withdrawn consent, and a removed listing all refuse" do
      %{operator: operator, conversation: conversation} = account("cl-license")

      evaluation_only =
        Fixtures.licensed_dataset!(%{
          license_terms: %{
            "opt_in" => true,
            "allowed_uses" => ["evaluation"],
            "redistribution" => "prohibited"
          }
        })

      assert {:error, {:use_not_licensed, _id, "training"}} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{
                   datasets: [Fixtures.dataset_reference(evaluation_only)]
                 })
               )

      expired = Fixtures.licensed_dataset!()
      Fixtures.expire_license!(expired)

      assert {:error, {:dataset_unavailable, :stale_license}} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{datasets: [Fixtures.dataset_reference(expired)]})
               )

      removed = Fixtures.licensed_dataset!()

      {:ok, _receipt} =
        ArtifactCatalog.remove_listing(removed.listing.id, %{
          reason: "the contributor withdrew consent",
          receipt_ref: "artifact-removal:#{System.unique_integer([:positive])}",
          actor_ref: "operator:test"
        })

      assert {:error, {:dataset_unavailable, :listing_removed}} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{datasets: [Fixtures.dataset_reference(removed)]})
               )
    end

    test "a dataset the buyer never accepted is refused before any capacity is spent" do
      %{operator: operator, conversation: conversation} = account("cl-acceptance")
      unaccepted = Fixtures.licensed_dataset!()

      assert {:error, {:dataset_not_authorized, :not_authorized}} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{
                   datasets: [
                     %{
                       listing_id: unaccepted.listing.id,
                       acceptance_ref: "artifact-transaction:never-issued"
                     }
                   ]
                 })
               )

      assert ContinualLearning.active_count() == 0
    end

    test "an unadmitted or non-independent evaluator cannot grade the run" do
      %{operator: operator, conversation: conversation} = account("cl-evaluator")

      assert {:error, :evaluator_not_admitted} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{
                   evaluation:
                     evaluation(conversation, %{
                       verifier: %{
                         id: "verifier:x",
                         admitted: false,
                         independent_of_producer: true
                       }
                     })
                 })
               )

      assert {:error, :evaluator_not_independent} =
               ContinualLearning.start(
                 operator,
                 admission(conversation, %{
                   evaluation:
                     evaluation(conversation, %{
                       verifier: %{
                         id: "verifier:x",
                         admitted: true,
                         independent_of_producer: false
                       }
                     })
                 })
               )
    end

    test "an unavailable fleet class refuses instead of queueing" do
      %{operator: operator, conversation: conversation} = account("cl-capacity")
      Application.put_env(:openagents, :capacity_test_evidence, {:error, :unavailable})

      assert {:error, {:capacity_unavailable, _detail}} =
               ContinualLearning.start(operator, admission(conversation))
    end

    test "the concurrency ceiling refuses a second concurrent job" do
      %{operator: operator, conversation: conversation} = account("cl-concurrency")
      ContinualLearningStubs.Observer.watch(self())
      configure(trainer: ContinualLearningStubs.GatedTrainer)

      assert {:ok, job} = ContinualLearning.start(operator, admission(conversation))
      assert_receive {:round_started, 1, trainer}, 5_000

      assert {:error, :continual_learning_at_capacity} =
               ContinualLearning.start(operator, admission(conversation))

      Process.exit(trainer, :kill)
      assert Fixtures.await_terminal!(job.id).status == "interrupted"
    end
  end

  describe "the canary run" do
    test "one admitted job trains, evaluates, and binds a reproducible artifact" do
      %{operator: operator, conversation: conversation} = account("cl-run")

      assert {:ok, started} = ContinualLearning.start(operator, admission(conversation))
      assert started.status == "queued"
      assert started.admission_digest =~ ~r/\A[0-9a-f]{64}\z/
      assert started.work_job_id

      job = Fixtures.await_terminal!(started.id)
      assert job.status == "completed"
      assert job.rounds_completed == 2

      # Every round committed a checkpoint, chained to its parent.
      checkpoints = ContinualLearning.checkpoints(job)
      assert Enum.map(checkpoints, & &1.round) == [1, 2]
      assert Enum.at(checkpoints, 1).parent_digest == Enum.at(checkpoints, 0).state_digest

      for checkpoint <- checkpoints do
        assert Canonical.digest!(checkpoint.state) == checkpoint.state_digest
        assert checkpoint.energy["joules"] > 0
        assert checkpoint.usage["cost_usd_cents"] == 2
      end

      # The artifact binds the exact inputs the admission authorized.
      artifact = ContinualLearning.artifact(job)
      assert artifact.base_model_digest == Fixtures.base_model_digest()
      assert artifact.training_code_digest == Fixtures.training_code_digest()
      assert artifact.configuration_digest == job.configuration_digest
      assert artifact.checkpoint_digests == Enum.map(checkpoints, & &1.state_digest)
      assert [binding] = artifact.dataset_bindings
      assert binding["license_digest"] == List.first(job.datasets)["license_digest"]
      assert artifact.accepted_outcome["state"] == "accepted"
      assert artifact.accepted_outcome["revision"] == job.admission_digest
      assert artifact.accepted_outcome["issue_number"] == 86
      assert artifact.evaluation_result["terminal_result"] == "passed"
      assert artifact.evaluation_result["corpus_digest"] == job.evaluation["corpus_digest"]

      # Settlement-ready evidence names the buyer and the policy, and states
      # that no custody moved here.
      assert artifact.settlement["buyer_ref"] == Fixtures.buyer_ref()
      assert artifact.settlement["unit"] == "usd_cents"
      assert artifact.settlement["amount"] == 4
      assert artifact.settlement["transferred"] == false

      # The receipt chain explains the whole run, in order, append-only.
      kinds = job |> ContinualLearning.receipts() |> Enum.map(& &1.kind)
      assert List.first(kinds) == "admission"

      for kind <- ~w(usage energy training evaluation artifact settlement) do
        assert kind in kinds
      end

      # The licensed side of the trade reconciles into the catalog's own chain.
      listing_id = List.first(job.datasets)["listing_id"]
      {:ok, history} = ArtifactCatalog.export_listing_history(listing_id)
      actions = Enum.map(history["receipts"], & &1["action"])
      assert "delivery" in actions
      assert "verification" in actions
      assert "settlement" in actions
    end

    test "a replay is a new job from round zero that reproduces the artifact digest" do
      %{operator: operator, conversation: conversation} = account("cl-replay")

      {:ok, first} = ContinualLearning.start(operator, admission(conversation))
      first = Fixtures.await_terminal!(first.id)
      assert first.status == "completed"

      assert {:ok, replay} =
               ContinualLearning.replay(operator, first.id, %{
                 conversation_id: conversation.id,
                 owner_visitor_id: conversation.visitor_id
               })

      assert replay.id != first.id
      assert replay.replay_of_id == first.id
      assert replay.rounds_completed == 0
      assert replay.admission_digest == first.admission_digest

      replay = Fixtures.await_terminal!(replay.id)
      assert replay.status == "completed"

      # Reproducibility is the claim the digests have to carry.
      assert ContinualLearning.artifact(replay).artifact_digest ==
               ContinualLearning.artifact(first).artifact_digest

      # The replay trained its own checkpoints rather than reusing any.
      assert Enum.map(ContinualLearning.checkpoints(replay), & &1.round) == [1, 2]
    end

    test "a trainer failure and an unverifiable evaluation both refuse the artifact" do
      %{operator: operator, conversation: conversation} = account("cl-trainer-failure")
      configure(trainer: ContinualLearningStubs.FailingTrainer)

      {:ok, job} = ContinualLearning.start(operator, admission(conversation))
      job = Fixtures.await_terminal!(job.id)
      assert job.status == "failed"
      assert job.error_code == "trainer_unavailable"
      assert ContinualLearning.artifact(job) == nil
      assert ContinualLearning.checkpoints(job) == []

      configure(evaluator: ContinualLearningStubs.FailingEvaluator)
      %{conversation: other} = account("cl-evaluator-failure")
      {:ok, unverifiable} = ContinualLearning.start(operator, admission(other))
      unverifiable = Fixtures.await_terminal!(unverifiable.id)
      assert unverifiable.status == "failed"
      assert unverifiable.error_code == "evaluator_unavailable"
      assert ContinualLearning.artifact(unverifiable) == nil
    end

    test "a failed grade and a foreign evaluator identity both refuse the artifact" do
      %{operator: operator, conversation: conversation} = account("cl-grade")
      configure(evaluator: ContinualLearningStubs.FailingGradeEvaluator)

      {:ok, refused} = ContinualLearning.start(operator, admission(conversation))
      refused = Fixtures.await_terminal!(refused.id)
      assert refused.status == "failed"
      assert refused.error_code == "evaluation_failed"
      assert ContinualLearning.artifact(refused) == nil

      configure(evaluator: ContinualLearningStubs.ForeignEvaluator)
      %{conversation: other} = account("cl-foreign-evaluator")
      {:ok, foreign} = ContinualLearning.start(operator, admission(other))
      foreign = Fixtures.await_terminal!(foreign.id)
      assert foreign.status == "failed"
      assert foreign.error_code == "evaluator_identity_mismatch"
      assert ContinualLearning.artifact(foreign) == nil
    end

    test "an exhausted budget stops the run at a checkpoint the buyer can resume" do
      %{operator: operator, conversation: conversation} = account("cl-budget")

      {:ok, job} =
        ContinualLearning.start(
          operator,
          admission(conversation, %{
            budget: %{usd_cents: 2},
            stopping_policy: %{maximum_rounds: 3}
          })
        )

      job = Fixtures.await_terminal!(job.id)
      assert job.status == "budget_exhausted"
      assert job.rounds_completed == 1
      assert ContinualLearning.artifact(job) == nil

      # The surviving checkpoint records the round the money bought, and the
      # spent budget refuses a resume that could not pay for another round.
      assert %{round: 1} = ContinualLearning.latest_checkpoint(job)
      assert {:error, :budget_exhausted} = ContinualLearning.resume(operator, job.id)
    end

    test "cancellation stops the round loop and keeps the committed evidence" do
      %{operator: operator, conversation: conversation} = account("cl-cancel")
      ContinualLearningStubs.Observer.watch(self())
      configure(trainer: ContinualLearningStubs.GatedTrainer)

      {:ok, job} =
        ContinualLearning.start(
          operator,
          admission(conversation, %{
            stopping_policy: %{maximum_rounds: 4},
            evaluation: evaluation(conversation, %{target_value: 0.95})
          })
        )

      assert_receive {:round_started, 1, trainer}, 5_000
      send(trainer, :proceed)
      assert_receive {:round_started, 2, next}, 5_000

      assert {:ok, cancelled} = ContinualLearning.cancel(operator, job.id)
      assert cancelled.status == "cancelled"
      send(next, :proceed)

      terminal = Fixtures.await_terminal!(job.id)
      assert terminal.status == "cancelled"
      assert terminal.rounds_completed < 4
      assert ContinualLearning.artifact(terminal) == nil
      assert ContinualLearning.checkpoints(terminal) != []
    end
  end

  describe "resume" do
    test "a resume continues the surviving chain under the same admission" do
      %{operator: operator, conversation: conversation} = account("cl-resume")
      interrupted = interrupt_after_first_round!(operator, conversation)
      assert interrupted.status == "interrupted"
      assert interrupted.rounds_completed == 1

      configure(trainer: OpenAgents.ContinualLearning.Trainer.Reference)

      assert {:ok, resumed} = ContinualLearning.resume(operator, interrupted.id)
      assert resumed.id == interrupted.id
      assert resumed.resume_count == 1
      assert resumed.admission_digest == interrupted.admission_digest
      assert resumed.rounds_completed == 1

      terminal = Fixtures.await_terminal!(resumed.id)
      assert terminal.status == "completed"
      assert terminal.rounds_completed == 2

      # The resume continued the surviving chain instead of retraining round one.
      checkpoints = ContinualLearning.checkpoints(terminal)
      assert Enum.map(checkpoints, & &1.round) == [1, 2]
      assert Enum.at(checkpoints, 1).parent_digest == Enum.at(checkpoints, 0).state_digest

      # The resume is an authorized act with its own receipt.
      resume_receipts =
        terminal |> ContinualLearning.receipts() |> Enum.filter(&(&1.kind == "resume"))

      assert [receipt] = resume_receipts
      assert receipt.payload["from_round"] == 1
      assert receipt.payload["admission_digest"] == terminal.admission_digest
    end

    test "a lost checkpoint refuses the resume instead of retraining silently" do
      %{operator: operator, conversation: conversation} = account("cl-checkpoint-loss")
      interrupted = interrupt_after_first_round!(operator, conversation)

      {:ok, _lost} =
        interrupted
        |> ContinualLearning.latest_checkpoint()
        |> Checkpoint.loss_changeset()
        |> Repo.update()

      assert {:error, :checkpoint_lost} = ContinualLearning.resume(operator, interrupted.id)
      assert {:ok, reloaded} = ContinualLearning.fetch(interrupted.id)
      assert reloaded.rounds_completed == 1
    end

    test "a completed job is not resumable and a satisfied policy stops the resume" do
      %{operator: operator, conversation: conversation} = account("cl-not-resumable")

      {:ok, job} = ContinualLearning.start(operator, admission(conversation))
      completed = Fixtures.await_terminal!(job.id)
      assert completed.status == "completed"

      assert {:error, :not_resumable} = ContinualLearning.resume(operator, completed.id)
    end
  end

  describe "evidence" do
    test "the export carries the admission, the chain, the receipts, and the artifact" do
      %{operator: operator, conversation: conversation} = account("cl-evidence")

      {:ok, job} = ContinualLearning.start(operator, admission(conversation))
      job = Fixtures.await_terminal!(job.id)

      assert {:ok, evidence} = ContinualLearning.export_evidence(operator, job.id)
      assert evidence["schema"] == "openagents.continual_learning_evidence.v1"
      assert evidence["job"]["admission_digest"] == job.admission_digest
      assert length(evidence["checkpoints"]) == 2
      assert evidence["artifact"]["artifact_digest"]

      # The projection never carries the licensed source location, only its
      # digest, so evidence cannot become an access path.
      serialized = Jason.encode!(evidence)
      refute serialized =~ "vault://"

      assert {:ok, jobs} = ContinualLearning.list(operator)
      assert job.id in Enum.map(jobs, & &1.id)
    end
  end

  # Kills the worker between the first and the second round, which is the fault
  # a resume exists for: one committed checkpoint, no terminal artifact.
  defp interrupt_after_first_round!(operator, conversation) do
    ContinualLearningStubs.Observer.watch(self())
    configure(trainer: ContinualLearningStubs.GatedTrainer)

    {:ok, job} = ContinualLearning.start(operator, admission(conversation))
    assert_receive {:round_started, 1, first}, 5_000
    send(first, :proceed)
    assert_receive {:round_started, 2, second}, 5_000
    Process.exit(second, :kill)

    Fixtures.await_terminal!(job.id)
  end

  defp configure(overrides) do
    Application.put_env(
      :openagents,
      OpenAgents.ContinualLearning,
      Fixtures.settings(overrides)
    )
  end

  defp admission(conversation, overrides \\ %{}) do
    training = Fixtures.licensed_dataset!()
    evaluation = Fixtures.licensed_dataset!()
    Fixtures.admission(conversation, training, evaluation, overrides)
  end

  defp evaluation(conversation, overrides) do
    conversation
    |> admission()
    |> Map.fetch!(:evaluation)
    |> Map.merge(overrides)
  end

  defp account(login) do
    user = AccountsFixtures.repository_user_fixture(login)
    {:ok, conversation} = Conversations.ensure_conversation(user)
    configured = Application.get_env(:openagents, :admin_github_ids, [])
    Application.put_env(:openagents, :admin_github_ids, [user.github_id | configured])
    %{operator: user, conversation: conversation}
  end
end
