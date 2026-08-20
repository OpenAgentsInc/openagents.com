defmodule OpenAgents.SCV.CodexLoginSupervisor do
  @moduledoc "Routes each isolated Codex device login through the cluster supervisor."

  alias OpenAgents.SCV.CodexLogin
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.DriverLoginAttempt

  @spec start_login(DriverAccount.t(), DriverLoginAttempt.t()) :: {:ok, map()} | {:error, atom()}
  def start_login(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt) do
    child = {CodexLogin, account: account, attempt: attempt}

    with {:ok, pid} <- start_child(child),
         {:ok, ceremony} <- CodexLogin.begin(pid) do
      {:ok, ceremony}
    else
      {:error, {:already_started, pid}} -> CodexLogin.snapshot(pid)
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :login_start_failed}
    end
  end

  @spec cancel(DriverLoginAttempt.t()) :: :ok | {:error, atom()}
  def cancel(%DriverLoginAttempt{id: attempt_id}) do
    case lookup(attempt_id) do
      [{pid, _value}] -> CodexLogin.cancel(pid)
      [] -> {:error, :login_not_running}
    end
  end

  @spec snapshot(DriverLoginAttempt.t()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%DriverLoginAttempt{id: attempt_id}) do
    case lookup(attempt_id) do
      [{pid, _value}] -> CodexLogin.snapshot(pid)
      [] -> {:error, :login_not_running}
    end
  end

  defp start_child(child) do
    case OpenAgents.Cluster.DynamicSupervisor.start_child(OpenAgents.HordeSupervisor, child) do
      {:ok, pid, _info} -> {:ok, pid}
      result -> result
    end
  end

  defp lookup(attempt_id) do
    Horde.Registry.lookup(OpenAgents.HordeRegistry, CodexLogin.registry_key(attempt_id))
  end
end
