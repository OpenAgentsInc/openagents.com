defmodule OpenAgentsWeb.ContinualLearningControllerTest do
  @moduledoc """
  The operator API of the continual-learning lane (CONTINUAL-001).

  The route is the only way into the lane, so it has to refuse before it
  admits: an anonymous caller, a signed-in caller who is not an operator, and a
  buyer the lane never admitted all get a typed refusal. One admitted job then
  walks the whole surface — create, list, read, cancel, replay, and evidence.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ContinualLearning
  alias OpenAgents.ContinualLearningFixtures, as: Fixtures
  alias OpenAgents.Conversations

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenAgents.Repo, {:shared, self()})
    previous_capacity = Application.get_env(:openagents, OpenAgents.Capacity, [])
    previous_evidence = Application.get_env(:openagents, :capacity_test_evidence)

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

      if is_nil(previous_evidence),
        do: Application.delete_env(:openagents, :capacity_test_evidence),
        else: Application.put_env(:openagents, :capacity_test_evidence, previous_evidence)
    end)

    :ok
  end

  test "the lane refuses an anonymous caller and a signed-in non-operator", %{conn: conn} do
    anonymous = post(conn, ~p"/api/operator/continual-learning/jobs", %{})
    assert json_response(anonymous, 401)

    user = github_user("continual-learning-regular")
    signed_in = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    refused = post(signed_in, ~p"/api/operator/continual-learning/jobs", %{})
    assert json_response(refused, 403) == %{"error" => "operator_required"}
  end

  test "an operator starts, reads, cancels, replays, and exports one job" do
    user = github_user("continual-learning-operator")
    grant_operator(user)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    created =
      operator_conn(user)
      |> post(~p"/api/operator/continual-learning/jobs", payload(conversation))

    assert %{"job" => %{"id" => id, "status" => "queued", "admission_digest" => digest}} =
             json_response(created, 201)

    assert digest =~ ~r/\A[0-9a-f]{64}\z/

    listed = get(operator_conn(user), ~p"/api/operator/continual-learning/jobs")
    assert %{"jobs" => jobs} = json_response(listed, 200)
    assert id in Enum.map(jobs, & &1["id"])

    shown = get(operator_conn(user), ~p"/api/operator/continual-learning/jobs/#{id}")
    assert %{"job" => %{"id" => ^id, "buyer_ref" => buyer_ref}} = json_response(shown, 200)
    assert buyer_ref == Fixtures.buyer_ref()

    completed = Fixtures.await_terminal!(id)
    assert completed.status == "completed"

    evidence = get(operator_conn(user), ~p"/api/operator/continual-learning/jobs/#{id}/evidence")
    assert %{"artifact" => artifact, "checkpoints" => checkpoints} = json_response(evidence, 200)
    assert artifact["artifact_digest"]
    assert length(checkpoints) == 2

    assert ["attachment; filename=\"continual-learning-evidence-" <> _rest] =
             get_resp_header(evidence, "content-disposition")

    # A terminal job cannot be cancelled or resumed, but it can be replayed.
    cancelled =
      post(operator_conn(user), ~p"/api/operator/continual-learning/jobs/#{id}/cancellation", %{})

    assert json_response(cancelled, 409) == %{"error" => "not_cancellable"}

    resumed =
      post(operator_conn(user), ~p"/api/operator/continual-learning/jobs/#{id}/resumptions", %{})

    assert json_response(resumed, 409) == %{"error" => "not_resumable"}

    replayed =
      post(operator_conn(user), ~p"/api/operator/continual-learning/jobs/#{id}/replays", %{})

    assert %{"job" => %{"id" => replay_id, "replay_of_id" => ^id}} = json_response(replayed, 201)
    assert Fixtures.await_terminal!(replay_id).status == "completed"
  end

  test "a buyer the lane never admitted is refused with its own code", %{conn: conn} do
    user = github_user("continual-learning-wrong-buyer")
    grant_operator(user)
    {:ok, conversation} = Conversations.ensure_conversation(user)

    refused =
      post(
        operator_conn(user),
        ~p"/api/operator/continual-learning/jobs",
        conversation |> payload() |> Map.put("buyer_ref", "buyer:someone-else")
      )

    assert json_response(refused, 403) == %{"error" => "buyer_not_admitted"}
    assert ContinualLearning.active_count() == 0

    _ = conn
  end

  defp operator_conn(user) do
    Plug.Test.init_test_session(build_conn(), %{"user_id" => user.id})
  end

  defp payload(conversation) do
    training = Fixtures.licensed_dataset!()
    evaluation = Fixtures.licensed_dataset!()

    %{
      "buyer_ref" => Fixtures.buyer_ref(),
      "objective" => "Improve tool selection on consented support traces.",
      "objective_version" => 1,
      "base_model_ref" => Fixtures.base_model_ref(),
      "base_model_digest" => Fixtures.base_model_digest(),
      "configuration" => %{"learning_rate" => "3e-4"},
      "runtime_class" => "standard",
      "conversation_id" => conversation.id,
      "owner_visitor_id" => conversation.visitor_id,
      "datasets" => [dataset(training)],
      "evaluation" => %{
        "corpus" => [dataset(evaluation)],
        "verifier" => %{
          "id" => "verifier:openagents-eval-1",
          "admitted" => true,
          "independent_of_producer" => true
        },
        "separation_required" => true,
        "acceptance_criteria" => ["tool-selection score reaches the admitted target"],
        "target_metric" => "score",
        "target_value" => 0.6,
        "policy_version" => 1
      },
      "budget" => %{"usd_cents" => 100},
      "stopping_policy" => %{"maximum_rounds" => 2, "minimum_improvement" => 0.0}
    }
  end

  defp dataset(%{listing: listing, acceptance_ref: acceptance_ref}) do
    %{"listing_id" => listing.id, "acceptance_ref" => acceptance_ref}
  end
end
