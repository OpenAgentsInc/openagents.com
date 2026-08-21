defmodule OpenAgents.SCV.Workspace do
  @moduledoc "Creates and verifies one disposable exact-revision SCV workspace."

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Repositories.Repository

  @spec prepare(Repository.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, Path.t()} | {:error, atom()}
  def prepare(%Repository{} = repository, revision, run_id) do
    root = workspace_root()
    path = Path.join(root, run_id)
    source = Repos.bare_path(repository.storage_key)

    with true <- Repos.valid_storage_key?(repository.storage_key),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
         true <- File.dir?(source),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         false <- File.exists?(path),
         {_, 0} <-
           git([
             "-c",
             "core.hooksPath=/dev/null",
             "clone",
             "--no-local",
             "--no-checkout",
             "--",
             source,
             path
           ]),
         {_, 0} <- git(["-C", path, "checkout", "--detach", revision]),
         {head, 0} <- git(["-C", path, "rev-parse", "HEAD"]),
         ^revision <- String.trim(head),
         {_, 0} <- git(["-C", path, "diff", "--quiet"]),
         {_, 0} <- git(["-C", path, "diff", "--cached", "--quiet"]) do
      {:ok, path}
    else
      _error ->
        File.rm_rf(path)
        {:error, :workspace_preparation_failed}
    end
  end

  @spec destroy(Path.t()) :: :ok
  def destroy(path) when is_binary(path) do
    root = workspace_root()
    expanded = Path.expand(path)

    if Path.dirname(expanded) == root do
      File.rm_rf(expanded)
      :ok
    else
      :ok
    end
  end

  defp git(arguments), do: System.cmd("git", arguments, stderr_to_stdout: true)

  defp workspace_root do
    :openagents
    |> Application.fetch_env!(:scv_codex)
    |> Keyword.get(:temporary_root, System.tmp_dir!())
    |> Path.expand()
    |> Path.join("openagents-scv-workspaces")
  end
end
