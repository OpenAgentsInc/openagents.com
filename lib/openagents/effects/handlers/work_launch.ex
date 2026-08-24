defmodule OpenAgents.Effects.Handlers.WorkLaunch do
  @moduledoc """
  Starts the worker a committed `work_jobs` row is owed (EFFECT-001).

  `OpenAgents.Work.start_job/1` and its siblings commit the job row and the
  effect that asks for its worker in one transaction, then try the launch
  inline. This handler is what runs when that inline attempt did not happen or
  did not succeed: the node died in the gap, Horde refused, the cluster was
  mid-relocation.

  Redelivery is safe three times over. The worker is a Horde cluster singleton,
  so a second `start_child` for a job already running returns
  `{:already_started, pid}`, which `OpenAgents.Work.ensure_worker/2` reports as
  success. A job that reached a terminal status needs no worker and the effect
  completes without one. A job that no longer exists — the conversation was
  deleted under DATA-004 — is likewise nothing owed, not a failure to retry.
  """

  @behaviour OpenAgents.Effects.Handler

  alias OpenAgents.Effects.Effect
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  # The payload names its worker by a bounded string this module admits.
  # Nothing turns a payload value into a module or an atom at runtime.
  @workers %{
    "job" => OpenAgents.Work.JobServer,
    "delegation" => OpenAgents.Work.DelegationServer,
    "scv" => OpenAgents.Work.ScvServer,
    "continual_learning" => OpenAgents.Work.ContinualLearningServer
  }

  @doc "The worker names an effect payload may carry."
  @spec worker_names() :: [String.t()]
  def worker_names, do: @workers |> Map.keys() |> Enum.sort()

  @doc "Resolve a payload's worker name to its server module."
  @spec worker(String.t()) :: {:ok, module()} | {:error, :unknown_worker}
  def worker(name) when is_binary(name) do
    case Map.fetch(@workers, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_worker}
    end
  end

  @impl OpenAgents.Effects.Handler
  def run(%Effect{payload: payload}, _idempotency_key) do
    with {:ok, job_id} <- fetch(payload, "job_id"),
         {:ok, name} <- fetch(payload, "worker"),
         {:ok, server} <- worker(name) do
      launch(server, job_id)
    end
  end

  defp launch(server, job_id) do
    case Work.get_job(job_id) do
      nil ->
        :ok

      %Job{status: status} when status not in ~w(queued running) ->
        :ok

      %Job{} ->
        case Work.ensure_worker(server, job_id) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:invalid_payload, key}}
    end
  end
end
