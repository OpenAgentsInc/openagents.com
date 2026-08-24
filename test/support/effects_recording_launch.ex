defmodule OpenAgents.Effects.WorkLaunchTest.RecordingLaunch do
  @moduledoc """
  A stand-in for `OpenAgents.Effects.Handlers.WorkLaunch` that records the
  launch it was asked for instead of starting a Horde singleton (EFFECT-001).

  The real handler's decisions — whether a job still exists, whether it still
  needs a worker, which server module its payload names — are the part under
  test, so this delegates all of them and only replaces the one line that would
  reach into the cluster.
  """

  @behaviour OpenAgents.Effects.Handler

  alias OpenAgents.Effects.Effect
  alias OpenAgents.Effects.Handlers.WorkLaunch
  alias OpenAgents.Work
  alias OpenAgents.Work.Job

  @impl OpenAgents.Effects.Handler
  def run(%Effect{payload: payload}, _idempotency_key) do
    with {:ok, job_id} <- fetch(payload, "job_id"),
         {:ok, name} <- fetch(payload, "worker"),
         {:ok, server} <- WorkLaunch.worker(name) do
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
        case Application.get_env(:openagents, :effects_launch_observer) do
          pid when is_pid(pid) -> send(pid, {:launch_requested, server, job_id})
          _absent -> :ok
        end

        :ok
    end
  end

  defp fetch(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:invalid_payload, key}}
    end
  end
end
