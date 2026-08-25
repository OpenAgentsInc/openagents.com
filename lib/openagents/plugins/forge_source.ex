defmodule OpenAgents.Plugins.ForgeSource do
  @moduledoc """
  Adapts the plugin index over forge repository data.

  The forge already stores repository identity and git objects. This source is
  the smallest discoverable-release adapter: it walks the public, ready
  repositories and reads `manifest.json` from the default branch. A missing
  manifest is not an error; a plugin registry entry only appears when a
  repository publishes a valid typed manifest.

  The artifact digest is the manifest's declared `artifact.digest`; this layer
  does not fetch or verify the artifact bytes. That remains the runtime's job
  when a caller selects a plugin by exact name and installs it.
  """

  import Ecto.Query, warn: false

  alias OpenAgents.Plugins.Index

  @doc "Return index entries for every public, ready repository that has a manifest.json on its default branch."
  @spec entries() :: [Index.Entry.t()]
  def entries do
    OpenAgents.Repositories.Repository
    |> from(where: [visibility: "public", lifecycle_state: "ready"])
    |> OpenAgents.Repo.all()
    |> Enum.flat_map(&entries_for_repository/1)
  end

  defp entries_for_repository(
         %{
           owner: owner,
           name: name,
           storage_key: storage_key,
           default_branch: branch
         } = repository
       )
       when is_binary(owner) and is_binary(name) and is_binary(storage_key) and is_binary(branch) do
    path = bare_path(repository)
    release = default_release(repository)

    case read_manifest_at_head(path, repository) do
      {:ok, manifest} ->
        [
          %Index.Entry{
            repository: display_path(repository),
            release: release,
            manifest: manifest
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp entries_for_repository(_), do: []

  defp read_manifest_at_head(path, repository) do
    with refs when is_map(refs) <- OpenAgents.Forge.Repos.refs_at(path),
         sha when is_binary(sha) <- Map.get(refs, "refs/heads/#{repository.default_branch}") do
      read_manifest(path, sha)
    else
      _ ->
        {:error, :no_head}
    end
  end

  defp read_manifest(path, sha) do
    case OpenAgents.Forge.Repos.git(path, ["show", "#{sha}:manifest.json"]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, manifest} when is_map(manifest) ->
            {:ok, manifest}

          {:error, %Jason.DecodeError{}} ->
            {:error, :invalid_json}
        end

      _error ->
        {:error, :manifest_not_found}
    end
  end

  defp display_path(%{owner: owner, name: name}), do: "#{owner}/#{name}"

  defp bare_path(%{storage_key: storage_key}), do: OpenAgents.Forge.Repos.bare_path(storage_key)

  defp default_release(%{default_branch: branch}), do: branch
end
