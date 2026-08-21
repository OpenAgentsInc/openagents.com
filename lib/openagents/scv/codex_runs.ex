defmodule OpenAgents.SCV.CodexRuns do
  @moduledoc "Dispatches durable Codex-backed SCVs from an admitted operator account."

  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.SCV.CodexRun
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.Execution
  alias OpenAgents.SCV.Executions

  @spec start(Ecto.UUID.t(), Repository.t(), String.t(), String.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, atom() | Ecto.Changeset.t()}
  def start(account_id, %Repository{} = repository, revision, objective, options \\ [])
      when is_binary(account_id) and is_binary(revision) and is_binary(objective) do
    with :ok <- feature_enabled(),
         %DriverAccount{} = account <- Repo.get(DriverAccount, account_id),
         {:ok, execution} <- Executions.claim(account, revision, objective, options) do
      case DynamicSupervisor.start_child(
             OpenAgents.SCV.CodexRunSupervisor,
             {CodexRun, account: account, execution: execution, repository: repository}
           ) do
        {:ok, _pid} ->
          {:ok, execution}

        {:error, _reason} ->
          _terminal =
            Executions.finish(execution, %{
              status: "failed",
              error_code: "dispatcher_unavailable",
              report: %{text: "The SCV dispatcher could not start the admitted run."}
            })

          {:error, :dispatcher_unavailable}
      end
    else
      nil -> {:error, :account_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await(Ecto.UUID.t(), timeout()) :: {:ok, Execution.t()} | {:error, :timeout}
  def await(run_id, timeout \\ 15 * 60 * 1_000) when is_binary(run_id) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_until(run_id, deadline)
  end

  defp await_until(run_id, deadline) do
    execution = Executions.get!(run_id)

    cond do
      Execution.terminal?(execution) ->
        {:ok, execution}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        receive do
        after
          250 -> await_until(run_id, deadline)
        end
    end
  end

  defp feature_enabled do
    if Application.fetch_env!(:openagents, :scv_codex)[:enabled],
      do: :ok,
      else: {:error, :codex_scv_disabled}
  end
end
