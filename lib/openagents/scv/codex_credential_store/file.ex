defmodule OpenAgents.SCV.CodexCredentialStore.File do
  @moduledoc "Private file credential store for local development and protocol tests."

  @behaviour OpenAgents.SCV.CodexCredentialStore

  alias OpenAgents.SCV.DriverAccount

  @impl true
  def put(%DriverAccount{} = account, auth_json) when is_binary(auth_json) do
    with {:ok, path} <- path(account),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- atomic_write(path, auth_json) do
      {:ok, System.system_time(:millisecond)}
    else
      _error -> {:error, :credential_store_failed}
    end
  end

  @impl true
  def fetch(%DriverAccount{} = account) do
    with {:ok, path} <- path(account),
         {:ok, auth_json} <- File.read(path) do
      {:ok, auth_json}
    else
      _error -> {:error, :credential_not_found}
    end
  end

  defp path(%DriverAccount{secret_ref: "file:" <> slot}) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]{1,80}\z/, slot) do
      {:ok, Path.join(root(), slot <> ".json")}
    else
      {:error, :credential_reference_invalid}
    end
  end

  defp path(%DriverAccount{}), do: {:error, :credential_reference_invalid}

  defp atomic_write(path, contents) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temporary, contents, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        _ = File.rm(temporary)
        error
    end
  end

  defp root do
    :openagents
    |> Application.fetch_env!(:scv_codex)
    |> Keyword.fetch!(:file_root)
  end
end
