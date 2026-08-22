defmodule OpenAgents.Chat.Tools.RepositoryFile do
  @moduledoc false

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.Browse
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @read_tool_name "read_repository_file"
  @list_tool_name "list_repository_directory"

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        "type" => "function",
        "name" => @read_tool_name,
        "description" =>
          "Read a text file from a repository the signed-in user can access in OpenAgents. The repository can be an owner/name path or an unambiguous repository name. If the user asks for a README without naming a path, set path to null and the tool reads README.md or README from the default branch.",
        "strict" => true,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "repository" => %{
              "type" => "string",
              "description" =>
                "Repository path such as OpenAgentsInc/openagents.com, or an unambiguous name such as openagents.com."
            },
            "path" => %{
              "type" => ["string", "null"],
              "description" =>
                "Repository-relative file path. Use null to read the repository README."
            },
            "ref" => %{
              "type" => ["string", "null"],
              "description" =>
                "Branch, tag, or commit. Use null for the repository default branch."
            }
          },
          "required" => ["repository", "path", "ref"],
          "additionalProperties" => false
        }
      },
      %{
        "type" => "function",
        "name" => @list_tool_name,
        "description" =>
          "List the files and directories at one repository path. Use this tool before guessing a file path. Set path to null to list the repository root, then list child directories as needed before reading a file.",
        "strict" => true,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "repository" => %{
              "type" => "string",
              "description" =>
                "Repository path such as OpenAgentsInc/openagents.com, or an unambiguous name such as openagents.com."
            },
            "path" => %{
              "type" => ["string", "null"],
              "description" =>
                "Repository-relative directory path. Use null to list the repository root."
            },
            "ref" => %{
              "type" => ["string", "null"],
              "description" =>
                "Branch, tag, or commit. Use null for the repository default branch."
            }
          },
          "required" => ["repository", "path", "ref"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @spec execute(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute(@read_tool_name, arguments, %{user: %User{} = user}) when is_binary(arguments) do
    with {:ok, params} <- decode_arguments(arguments),
         {:ok, repository} <- resolve_repository(params["repository"], user),
         {:ok, path, blob} <- read_blob(repository, params["ref"], params["path"]) do
      if blob.binary do
        {:error, "The requested repository file is binary and cannot be read as text."}
      else
        {:ok,
         %{
           "repository" => repository.owner <> "/" <> repository.name,
           "ref" => params["ref"] || repository.default_branch,
           "path" => path,
           "content" => blob.content,
           "size_bytes" => blob.size,
           "truncated" => blob.truncated
         }}
      end
    end
  end

  def execute(@list_tool_name, arguments, %{user: %User{} = user}) when is_binary(arguments) do
    with {:ok, params} <- decode_arguments(arguments),
         {:ok, repository} <- resolve_repository(params["repository"], user),
         {:ok, path, entries} <- list_directory(repository, params["ref"], params["path"]) do
      {:ok,
       %{
         "repository" => repository.owner <> "/" <> repository.name,
         "ref" => params["ref"] || repository.default_branch,
         "path" => path,
         "entries" => Enum.map(entries, &directory_entry(path, &1)),
         "count" => length(entries)
       }}
    end
  end

  def execute(name, _arguments, _context) when name in [@read_tool_name, @list_tool_name],
    do: {:error, "You must sign in before reading a connected repository."}

  def execute(_name, _arguments, _context), do: {:error, "This tool is not available."}

  defp decode_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{"repository" => repository} = params} when is_binary(repository) ->
        {:ok,
         params
         |> Map.update("path", nil, &normalize_optional_argument/1)
         |> Map.update("ref", nil, &normalize_optional_argument/1)}

      {:ok, _arguments} ->
        {:error, "Tool arguments must include a repository string."}

      {:error, _reason} ->
        {:error, "Tool arguments must be a JSON object."}
    end
  end

  defp normalize_optional_argument(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.downcase(trimmed) in ["", "null"], do: nil, else: trimmed
  end

  defp normalize_optional_argument(value), do: value

  defp resolve_repository(repository_path, user) do
    case String.split(repository_path, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" ->
        get_visible_repository(owner, name, user)

      [name] when name != "" ->
        matches =
          user
          |> Repositories.list_visible_repositories()
          |> Enum.filter(&(String.downcase(&1.name) == String.downcase(name)))

        case matches do
          [repository] ->
            {:ok, repository}

          [] ->
            {:error, "No accessible repository matches #{name}."}

          _matches ->
            {:error, "More than one accessible repository matches #{name}. Use owner/name."}
        end

      _invalid ->
        {:error, "Repository must be an owner/name path or repository name."}
    end
  end

  defp get_visible_repository(owner, name, user) do
    {:ok, Repositories.get_visible_by_path!(owner, name, user)}
  rescue
    Ecto.NoResultsError -> {:error, "The repository does not exist or you cannot access it."}
  end

  defp read_blob(%Repository{} = repository, requested_ref, requested_path) do
    ref = requested_ref || repository.default_branch

    case requested_path do
      nil ->
        case Browse.readme(repository, ref) do
          {:ok, path, blob} -> {:ok, path, blob}
          {:error, :not_found} -> {:error, "The repository does not have a README at that ref."}
        end

      path when is_binary(path) ->
        case Browse.blob(repository, ref, path) do
          {:ok, blob} ->
            {:ok, path, blob}

          {:error, :not_found} ->
            {:error,
             "The requested file or ref does not exist. List the parent directory before trying another path."}
        end

      _invalid ->
        {:error, "Path must be a repository-relative string or null."}
    end
  end

  defp list_directory(%Repository{} = repository, requested_ref, requested_path) do
    ref = requested_ref || repository.default_branch
    path = requested_path || ""

    case Browse.tree(repository, ref, path) do
      {:ok, entries} -> {:ok, path, entries}
      {:error, :not_found} -> {:error, "The requested directory or ref does not exist."}
    end
  end

  defp directory_entry(parent_path, entry) do
    path = if parent_path == "", do: entry.name, else: parent_path <> "/" <> entry.name

    %{
      "name" => entry.name,
      "path" => path,
      "type" => if(entry.kind == "tree", do: "directory", else: "file"),
      "size_bytes" => entry.size
    }
  end
end
