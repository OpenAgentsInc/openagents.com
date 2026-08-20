defmodule OpenAgents.SCV.CodexCredentialStore do
  @moduledoc "Stores managed Codex authentication homes outside SCV metadata records."

  alias OpenAgents.SCV.DriverAccount

  @callback put(DriverAccount.t(), binary()) :: {:ok, pos_integer()} | {:error, atom()}
  @callback fetch(DriverAccount.t()) :: {:ok, binary()} | {:error, atom()}

  @spec put(DriverAccount.t(), binary()) :: {:ok, pos_integer()} | {:error, atom()}
  def put(%DriverAccount{} = account, auth_json) when is_binary(auth_json) do
    implementation().put(account, auth_json)
  end

  @spec fetch(DriverAccount.t()) :: {:ok, binary()} | {:error, atom()}
  def fetch(%DriverAccount{} = account), do: implementation().fetch(account)

  defp implementation do
    config()
    |> Keyword.fetch!(:credential_store)
  end

  defp config, do: Application.fetch_env!(:openagents, :scv_codex)
end
