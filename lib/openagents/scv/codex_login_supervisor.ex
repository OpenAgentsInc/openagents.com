defmodule OpenAgents.SCV.CodexLoginSupervisor do
  @moduledoc "Supervises one isolated Codex app-server process per pending account login."

  use DynamicSupervisor

  alias OpenAgents.SCV.CodexLogin
  alias OpenAgents.SCV.DriverAccount
  alias OpenAgents.SCV.DriverLoginAttempt

  def start_link(options) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_login(DriverAccount.t(), DriverLoginAttempt.t()) :: {:ok, map()} | {:error, atom()}
  def start_login(%DriverAccount{} = account, %DriverLoginAttempt{} = attempt) do
    child = {CodexLogin, account: account, attempt: attempt}

    with {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__, child),
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
    case Registry.lookup(OpenAgents.SCV.CodexLoginRegistry, attempt_id) do
      [{pid, _value}] -> CodexLogin.cancel(pid)
      [] -> {:error, :login_not_running}
    end
  end
end
