defmodule OpenAgents.Deployments.Providers.Fake do
  @moduledoc """
  A provider that deploys nothing and records what it was asked to do.

  The fake provider is the first delivery phase's whole execution surface. It
  exists so the contract — admission, leases, idempotency by run id, uncertain
  results, cancellation, secret boundaries — can be proved before any real
  infrastructure is involved, and so those proofs keep running afterwards.

  It is idempotent by run id: a second `deploy/1` for a run it already deployed
  returns the original receipt instead of a second deployment. State lives in an
  ETS table owned by a supervised process, so a worker crash does not lose the
  record of what the provider already did.

  Behavior is chosen per run through `program/2`, which is how a test asks for a
  failure, a timeout, or an uncertain result without a real outage.
  """

  @behaviour OpenAgents.Deployments.Provider

  use GenServer

  alias OpenAgents.Deployments.Execution

  @table __MODULE__.Deployments
  @programs __MODULE__.Programs

  @doc "Start the fake provider's durable-enough bookkeeping."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl GenServer
  def init(_options) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@programs, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl OpenAgents.Deployments.Provider
  def deploy(%Execution{} = execution) do
    ensure_tables()

    case :ets.lookup(@table, execution.run_id) do
      [{_run_id, receipt}] ->
        {:ok, Map.put(receipt, "replayed", true)}

      [] ->
        execute(execution, program(execution.run_id))
    end
  end

  @impl OpenAgents.Deployments.Provider
  def cancel(%Execution{} = execution) do
    ensure_tables()
    :ets.insert(@programs, {execution.run_id, :cancelled})
    :ok
  end

  @impl OpenAgents.Deployments.Provider
  def required_secret_references(provider_config) when is_map(provider_config) do
    case Map.get(provider_config, "secret_reference") do
      reference when is_binary(reference) -> [reference]
      _absent -> []
    end
  end

  @doc """
  Program the outcome of one run's next deployment.

  `:succeed` is the default. `:fail` returns a definitive error, `:uncertain`
  returns an unknown outcome, and `:hang` returns an uncertain result after the
  execution deadline passes, which is how a timeout looks from here.
  """
  @spec program(String.t(), :succeed | :fail | :uncertain | :hang) :: :ok
  def program(run_id, outcome)
      when is_binary(run_id) and outcome in [:succeed, :fail, :uncertain, :hang] do
    ensure_tables()
    :ets.insert(@programs, {run_id, outcome})
    :ok
  end

  @doc "Whether this run was asked to stop."
  @spec cancelled?(String.t()) :: boolean()
  def cancelled?(run_id) when is_binary(run_id) do
    ensure_tables()
    :ets.lookup(@programs, run_id) == [{run_id, :cancelled}]
  end

  @doc "The receipt this provider already issued for a run, if any."
  @spec receipt(String.t()) :: {:ok, map()} | :error
  def receipt(run_id) when is_binary(run_id) do
    ensure_tables()

    case :ets.lookup(@table, run_id) do
      [{_run_id, receipt}] -> {:ok, receipt}
      [] -> :error
    end
  end

  @doc """
  Forget one run's recorded deployment and program.

  Bookkeeping is keyed by run id, which is unique, so nothing here clears every
  run: a concurrent test's programmed outcome must survive another test's setup.
  """
  @spec forget(String.t()) :: :ok
  def forget(run_id) when is_binary(run_id) do
    ensure_tables()
    :ets.delete(@table, run_id)
    :ets.delete(@programs, run_id)
    :ok
  end

  defp execute(%Execution{}, :fail), do: {:error, :provider_rejected}

  defp execute(%Execution{} = execution, :uncertain) do
    {:uncertain, %{"run_id" => execution.run_id, "detail" => "provider did not confirm"}}
  end

  defp execute(%Execution{} = execution, :hang) do
    {:uncertain, %{"run_id" => execution.run_id, "detail" => "provider timed out"}}
  end

  defp execute(%Execution{}, :cancelled), do: {:error, :cancelled}

  defp execute(%Execution{} = execution, :succeed) do
    receipt = %{
      "run_id" => execution.run_id,
      "commit_sha" => execution.commit_sha,
      "artifact_digest" => execution.artifact_digest,
      "environment" => execution.environment,
      "secret_references_resolved" =>
        execution.secrets |> Map.keys() |> Enum.sort() |> Enum.join(",")
    }

    :ets.insert(@table, {execution.run_id, receipt})
    {:ok, receipt}
  end

  defp program(run_id) do
    case :ets.lookup(@programs, run_id) do
      [{_run_id, outcome}] -> outcome
      [] -> :succeed
    end
  end

  # The provider is used from request-path tests and from workers, so the tables
  # are created on demand rather than requiring a supervised owner everywhere.
  defp ensure_tables do
    for table <- [@table, @programs] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
