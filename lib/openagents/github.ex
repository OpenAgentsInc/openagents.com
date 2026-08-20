defmodule OpenAgents.GitHub do
  @moduledoc "Server-side GitHub REST API access using the signed-in user's OAuth token."

  @github_api_version "2022-11-28"
  @user_agent "OpenAgents"
  @full_name_regex ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+\z/
  @maximum_file_bytes 65_536

  @spec list_repositories(String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_repositories(token, options \\ []) when is_binary(token) do
    first = Keyword.get(options, :first, 30)

    request(token, "/user/repos",
      params: %{
        "per_page" => first,
        "sort" => "pushed",
        "affiliation" => "owner,collaborator,organization_member"
      }
    )
    |> case do
      {:ok, repositories} when is_list(repositories) ->
        {:ok, Enum.map(repositories, &repository_summary/1)}

      {:ok, _body} ->
        {:error, :github_response_invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_path(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def read_path(token, full_name, path, ref \\ nil) when is_binary(token) do
    with :ok <- validate_full_name(full_name),
         :ok <- validate_path(path) do
      params = if is_binary(ref) and ref != "", do: %{"ref" => ref}, else: %{}
      encoded_path = path |> String.split("/") |> Enum.map_join("/", &URI.encode/1)

      case request(token, "/repos/#{full_name}/contents/#{encoded_path}", params: params) do
        {:ok, %{"type" => "file"} = body} -> file_contents(body)
        {:ok, entries} when is_list(entries) -> {:ok, directory_listing(entries)}
        {:ok, _body} -> {:error, :github_response_invalid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp request(token, api_path, options) do
    settings = Application.get_env(:openagents, :github_api, [])
    base_url = settings[:base_url] || "https://api.github.com"

    request_options =
      [
        auth: {:bearer, token},
        params: Keyword.get(options, :params, %{}),
        headers: [
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", @github_api_version},
          {"user-agent", @user_agent}
        ],
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(settings[:request_options] || [])

    case Req.get(base_url <> api_path, request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: 401}} -> {:error, :github_token_rejected}
      {:ok, %Req.Response{status: 403}} -> {:error, :github_permission_denied}
      {:ok, %Req.Response{status: 404}} -> {:error, :github_not_found}
      {:ok, %Req.Response{}} -> {:error, :github_request_failed}
      {:error, _transport_error} -> {:error, :github_unavailable}
    end
  end

  defp repository_summary(repository) when is_map(repository) do
    %{
      "full_name" => bounded_string(repository["full_name"], 140),
      "description" => bounded_string(repository["description"], 300),
      "private" => repository["private"] == true,
      "default_branch" => bounded_string(repository["default_branch"], 100),
      "language" => bounded_string(repository["language"], 60),
      "pushed_at" => bounded_string(repository["pushed_at"], 32)
    }
  end

  defp bounded_size(size) when is_integer(size) and size >= 0, do: size
  defp bounded_size(_size), do: 0

  defp file_contents(%{"encoding" => "base64", "content" => content} = body)
       when is_binary(content) do
    case Base.decode64(content, ignore: :whitespace) do
      {:ok, decoded} ->
        truncated = byte_size(decoded) > @maximum_file_bytes

        text =
          decoded
          |> binary_part(0, min(byte_size(decoded), @maximum_file_bytes))
          |> keep_valid_utf8()

        case text do
          {:ok, contents} ->
            {:ok,
             %{
               "type" => "file",
               "path" => bounded_string(body["path"], 500),
               "size" => bounded_size(body["size"]),
               "truncated" => truncated,
               "content" => contents
             }}

          :error ->
            {:error, :github_file_not_text}
        end

      :error ->
        {:error, :github_response_invalid}
    end
  end

  defp file_contents(_body), do: {:error, :github_response_invalid}

  defp directory_listing(entries) do
    %{
      "type" => "directory",
      "entries" =>
        entries
        |> Enum.take(200)
        |> Enum.map(fn entry ->
          %{
            "name" => bounded_string(entry["name"], 255),
            "path" => bounded_string(entry["path"], 500),
            "type" => bounded_string(entry["type"], 16),
            "size" => bounded_size(entry["size"])
          }
        end)
    }
  end

  defp keep_valid_utf8(binary), do: keep_valid_utf8(binary, 3)

  defp keep_valid_utf8(binary, allowed_trailing_trim) do
    cond do
      String.valid?(binary) ->
        {:ok, binary}

      allowed_trailing_trim > 0 and byte_size(binary) > 0 ->
        binary
        |> binary_part(0, byte_size(binary) - 1)
        |> keep_valid_utf8(allowed_trailing_trim - 1)

      true ->
        :error
    end
  end

  defp validate_full_name(full_name)
       when is_binary(full_name) and byte_size(full_name) in 3..140 do
    if Regex.match?(@full_name_regex, full_name), do: :ok, else: {:error, :invalid_repository}
  end

  defp validate_full_name(_full_name), do: {:error, :invalid_repository}

  defp validate_path(path) when is_binary(path) and byte_size(path) <= 500 do
    segments = String.split(path, "/")

    if path == "" or Enum.all?(segments, &(&1 not in ["", ".", ".."])),
      do: :ok,
      else: {:error, :invalid_repository_path}
  end

  defp validate_path(_path), do: {:error, :invalid_repository_path}

  defp bounded_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded_string(_value, _maximum), do: ""
end
