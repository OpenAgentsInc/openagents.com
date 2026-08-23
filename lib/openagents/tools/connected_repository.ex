defmodule OpenAgents.Tools.ConnectedRepository do
  @moduledoc false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Tools.ExecutionContext

  @maximum_content_bytes 180_000
  @sensitive_names MapSet.new([
                     ".env",
                     ".git",
                     ".netrc",
                     "credentials",
                     "credentials.json",
                     "id_dsa",
                     "id_ed25519",
                     "id_rsa"
                   ])

  @spec resolve(ExecutionContext.t(), String.t()) ::
          {:ok, Repository.t()} | {:error, atom()}
  def resolve(%ExecutionContext{owner_user_id: user_id}, repository)
      when is_binary(user_id) and is_binary(repository) do
    with %User{} = user <- Repo.get(User, user_id),
         {:ok, parsed} <- parse_repository(repository) do
      resolve_visible(parsed, user)
    else
      nil -> {:error, :repository_authentication_required}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(%ExecutionContext{}, _repository), do: {:error, :repository_authentication_required}

  @spec read(Repository.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(%Repository{} = repository, path, ref)
      when is_binary(path) and is_binary(ref) do
    with {:ok, ref} <- normalize_ref(ref, repository),
         {:ok, path, blob} <- read_blob(repository, ref, normalize_optional(path)),
         :ok <- ensure_text_blob(blob) do
      {content, locally_truncated?} = truncate_content(blob.content)

      {:ok,
       %{
         "schema" => "openagents.connected_repository_file.v1",
         "repository" => repository.owner <> "/" <> repository.name,
         "ref" => ref,
         "path" => path,
         "content" => content,
         "size_bytes" => blob.size,
         "truncated" => blob.truncated or locally_truncated?
       }}
    end
  end

  @spec list(Repository.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def list(%Repository{} = repository, path, ref)
      when is_binary(path) and is_binary(ref) do
    path = normalize_optional(path) || ""

    with {:ok, ref} <- normalize_ref(ref, repository),
         :ok <- validate_directory_path(path),
         {:ok, entries} <- map_browse_error(Browse.tree(repository, ref, path), :directory) do
      entries = Enum.map(entries, &directory_entry(path, &1))

      {:ok,
       %{
         "schema" => "openagents.connected_repository_directory.v1",
         "repository" => repository.owner <> "/" <> repository.name,
         "ref" => ref,
         "path" => path,
         "entries" => entries,
         "count" => length(entries)
       }}
    end
  end

  defp parse_repository(repository) do
    repository = String.trim(repository)

    case String.split(repository, "/", trim: true) do
      [name] when byte_size(name) in 1..100 ->
        {:ok, {:name, String.downcase(name)}}

      [owner, name] when byte_size(owner) in 1..100 and byte_size(name) in 1..100 ->
        {:ok, {:path, owner, name}}

      _invalid ->
        {:error, :invalid_repository}
    end
  end

  defp resolve_visible({:path, owner, name}, user) do
    {:ok, Repositories.get_visible_by_path!(owner, name, user)}
  rescue
    Ecto.NoResultsError -> {:error, :repository_not_found}
  end

  defp resolve_visible({:name, name_key}, user) do
    matches =
      user
      |> Repositories.list_visible_repositories()
      |> Enum.filter(&(&1.name_key == name_key))

    case matches do
      [repository] -> {:ok, repository}
      [] -> {:error, :repository_not_found}
      _many -> {:error, :ambiguous_repository_name}
    end
  end

  defp normalize_ref(ref, repository) do
    ref = normalize_optional(ref) || repository.default_branch
    if Browse.valid_ref?(ref), do: {:ok, ref}, else: {:error, :invalid_repository_ref}
  end

  defp read_blob(repository, ref, nil) do
    case Browse.readme(repository, ref) do
      {:ok, path, blob} -> {:ok, path, blob}
      {:error, :not_found} -> {:error, :repository_readme_not_found}
    end
  end

  defp read_blob(repository, ref, path) do
    with :ok <- validate_file_path(path),
         {:ok, blob} <- map_browse_error(Browse.blob(repository, ref, path), :file) do
      {:ok, path, blob}
    end
  end

  defp validate_file_path(path) do
    cond do
      not Browse.valid_path?(path) -> {:error, :invalid_repository_path}
      sensitive_path?(path) -> {:error, :sensitive_repository_path}
      true -> :ok
    end
  end

  defp validate_directory_path(""), do: :ok
  defp validate_directory_path(path), do: validate_file_path(path)

  defp map_browse_error({:ok, value}, _kind), do: {:ok, value}

  defp map_browse_error({:error, :not_found}, :file),
    do: {:error, :repository_ref_or_file_not_found}

  defp map_browse_error({:error, :not_found}, :directory),
    do: {:error, :repository_ref_or_directory_not_found}

  defp ensure_text_blob(%{binary: true}), do: {:error, :repository_binary_file}
  defp ensure_text_blob(%{binary: false}), do: :ok

  defp directory_entry(parent, entry) do
    %{
      "name" => entry.name,
      "path" => if(parent == "", do: entry.name, else: parent <> "/" <> entry.name),
      "type" => if(entry.kind == "tree", do: "directory", else: "file"),
      "size_bytes" => entry.size || 0
    }
  end

  defp normalize_optional(value) when value in ["", "null"], do: nil
  defp normalize_optional(value), do: value

  defp sensitive_path?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(fn segment ->
      normalized = String.downcase(segment)

      MapSet.member?(@sensitive_names, normalized) or String.starts_with?(normalized, ".env.") or
        String.ends_with?(normalized, [".pem", ".key", ".p12", ".pfx"])
    end)
  end

  defp truncate_content(content) when byte_size(content) <= @maximum_content_bytes,
    do: {content, false}

  defp truncate_content(content) do
    truncated = binary_part(content, 0, @maximum_content_bytes)
    {trim_invalid_suffix(truncated), true}
  end

  defp trim_invalid_suffix(content) do
    if String.valid?(content) do
      content
    else
      trim_invalid_suffix(binary_part(content, 0, byte_size(content) - 1))
    end
  end
end
