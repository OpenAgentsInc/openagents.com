defmodule OpenAgentsWeb.ContinualLearningController do
  @moduledoc """
  Operator-authenticated continual-learning jobs for the one named internal
  buyer (CONTINUAL-001).

  The endpoints are the whole lane: start a job over admitted licensed datasets,
  read it, cancel it, resume it from its surviving checkpoint, replay it as a new
  job, and export its evidence. Every refusal is a typed code, so a caller learns
  which bound it hit rather than reading a generic failure.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.ContinualLearning

  def create(conn, params) do
    case ContinualLearning.start(conn.assigns.current_user, admission(params)) do
      {:ok, job} ->
        conn
        |> put_status(:created)
        |> json(%{"job" => ContinualLearning.projection(job)})

      {:error, reason} ->
        refusal(conn, reason)
    end
  end

  def index(conn, params) do
    case ContinualLearning.list(conn.assigns.current_user, limit(params)) do
      {:ok, jobs} ->
        json(conn, %{"jobs" => Enum.map(jobs, &ContinualLearning.projection/1)})

      {:error, reason} ->
        refusal(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case ContinualLearning.get(conn.assigns.current_user, id) do
      {:ok, job} -> json(conn, %{"job" => ContinualLearning.projection(job)})
      {:error, reason} -> refusal(conn, reason)
    end
  end

  def cancel(conn, %{"id" => id}) do
    case ContinualLearning.cancel(conn.assigns.current_user, id) do
      {:ok, job} -> json(conn, %{"job" => ContinualLearning.projection(job)})
      {:error, reason} -> refusal(conn, reason)
    end
  end

  def resume(conn, %{"id" => id} = params) do
    case ContinualLearning.resume(conn.assigns.current_user, id, surface(params)) do
      {:ok, job} -> json(conn, %{"job" => ContinualLearning.projection(job)})
      {:error, reason} -> refusal(conn, reason)
    end
  end

  def replay(conn, %{"id" => id} = params) do
    case ContinualLearning.replay(conn.assigns.current_user, id, surface(params)) do
      {:ok, job} ->
        conn
        |> put_status(:created)
        |> json(%{"job" => ContinualLearning.projection(job)})

      {:error, reason} ->
        refusal(conn, reason)
    end
  end

  def evidence(conn, %{"id" => id}) do
    case ContinualLearning.export_evidence(conn.assigns.current_user, id) do
      {:ok, export} ->
        conn
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="continual-learning-evidence-#{id}.json")
        )
        |> json(export)

      {:error, reason} ->
        refusal(conn, reason)
    end
  end

  # The admission arrives as JSON with string keys. Only the admitted shape is
  # read across the boundary: nothing here turns caller text into an atom, and an
  # unexpected key is dropped rather than carried into the durable row.
  defp admission(params) do
    %{
      buyer_ref: params["buyer_ref"],
      objective: params["objective"],
      objective_version: params["objective_version"],
      base_model_ref: params["base_model_ref"],
      base_model_digest: params["base_model_digest"],
      configuration: params["configuration"] || %{},
      datasets: dataset_references(params["datasets"]),
      evaluation: evaluation(params["evaluation"] || %{}),
      budget: budget(params["budget"] || %{}),
      runtime_class: params["runtime_class"],
      stopping_policy: stopping_policy(params["stopping_policy"] || %{}),
      conversation_id: params["conversation_id"],
      owner_visitor_id: params["owner_visitor_id"]
    }
  end

  defp dataset_references(references) when is_list(references) do
    Enum.map(references, fn reference ->
      if is_map(reference),
        do: Map.take(reference, ["listing_id", "acceptance_ref"]),
        else: %{}
    end)
  end

  defp dataset_references(_references), do: []

  defp evaluation(evaluation) when is_map(evaluation) do
    %{
      corpus: dataset_references(evaluation["corpus"]),
      verifier: verifier(evaluation["verifier"] || %{}),
      separation_required: evaluation["separation_required"] == true,
      acceptance_criteria: evaluation["acceptance_criteria"],
      target_metric: evaluation["target_metric"],
      target_value: evaluation["target_value"],
      policy_version: evaluation["policy_version"] || 1
    }
  end

  defp verifier(verifier) when is_map(verifier) do
    %{
      id: verifier["id"],
      admitted: verifier["admitted"] == true,
      independent_of_producer: verifier["independent_of_producer"] == true
    }
  end

  defp budget(budget) when is_map(budget), do: %{usd_cents: budget["usd_cents"]}

  defp stopping_policy(policy) when is_map(policy) do
    %{
      maximum_rounds: policy["maximum_rounds"],
      minimum_improvement: policy["minimum_improvement"] || 0.0
    }
  end

  defp surface(params) do
    %{
      conversation_id: params["conversation_id"],
      owner_visitor_id: params["owner_visitor_id"]
    }
  end

  defp limit(params) do
    case Integer.parse(to_string(params["limit"] || "50")) do
      {value, ""} when value > 0 -> value
      _invalid -> 50
    end
  end

  defp refusal(conn, reason) do
    conn
    |> put_status(status_for(reason))
    |> json(%{"error" => code(reason)})
  end

  defp status_for(:not_found), do: :not_found
  defp status_for(:operator_required), do: :forbidden
  defp status_for(:continual_learning_disabled), do: :service_unavailable
  defp status_for(:continual_learning_at_capacity), do: :conflict
  defp status_for(:buyer_not_configured), do: :service_unavailable
  defp status_for(:buyer_not_admitted), do: :forbidden
  defp status_for(:training_code_not_pinned), do: :service_unavailable
  defp status_for(:not_cancellable), do: :conflict
  defp status_for(:not_resumable), do: :conflict
  defp status_for(:budget_exhausted), do: :conflict
  defp status_for(:checkpoint_lost), do: :conflict
  defp status_for(:checkpoint_missing), do: :conflict
  defp status_for(:stopping_policy_satisfied), do: :conflict
  defp status_for({:capacity_unavailable, _detail}), do: :service_unavailable
  defp status_for({:dataset_not_authorized, _detail}), do: :forbidden
  defp status_for({:dataset_unavailable, _detail}), do: :conflict
  defp status_for({:consent_missing, _listing_id}), do: :forbidden
  defp status_for({:use_not_licensed, _listing_id, _use}), do: :forbidden
  defp status_for({:unsupported_custody, _detail}), do: :forbidden
  defp status_for({:dataset_moved, _listing_id}), do: :conflict
  defp status_for(_reason), do: :unprocessable_entity

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp code({reason, detail}) when is_atom(reason) and (is_atom(detail) or is_binary(detail)),
    do: "#{reason}:#{detail}"

  defp code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)

  defp code({reason, detail, extra}) when is_atom(reason),
    do: "#{reason}:#{detail}:#{extra}"

  defp code(%Ecto.Changeset{}), do: "invalid_continual_learning_job"
  defp code(_reason), do: "continual_learning_failed"
end
