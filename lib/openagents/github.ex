defmodule OpenAgents.GitHub do
  @moduledoc "Server-side GitHub REST API access using the signed-in user's OAuth token."

  @github_api_version "2022-11-28"
  @user_agent "OpenAgents"
  @full_name_regex ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+\z/
  @object_id_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @maximum_file_bytes 65_536
  @maximum_page 1_000
  @maximum_per_page 100
  @maximum_reference_pages 20
  @maximum_tree_entries 100_000
  @maximum_attribute_files 100
  @large_blob_bytes 100_000_000

  @typedoc "A bounded page projected from a GitHub REST collection."
  @type page(item) :: %{
          required(String.t()) => [item] | pos_integer() | boolean() | nil
        }

  @typedoc "A normalized current-user identity keyed by GitHub's immutable account ID."
  @type user_identity :: %{required(String.t()) => String.t() | pos_integer()}

  @typedoc "A normalized repository used for namespace and import-source discovery."
  @type repository :: %{required(String.t()) => term()}

  @doc "Returns the immutable GitHub identity associated with a retained OAuth token."
  @spec current_user(String.t()) :: {:ok, user_identity()} | {:error, atom()}
  def current_user(token) when is_binary(token) do
    with {:ok, body} <- request(token, "/user", []),
         {:ok, identity} <- project_user(body) do
      {:ok, identity}
    end
  end

  def current_user(_token), do: {:error, :invalid_token}

  @doc "Lists a bounded page of repositories visible to the retained GitHub grant."
  @spec list_repository_page(String.t(), keyword()) ::
          {:ok, page(repository())} | {:error, atom()}
  def list_repository_page(token, options \\ []) when is_binary(token) do
    with {:ok, page, per_page} <- pagination(options),
         {:ok, raw_page} <- repository_page(token, page, per_page),
         {:ok, repositories} <- traverse(raw_page.items, &project_repository/1) do
      {:ok, page_projection(repositories, page, per_page, raw_page.has_next_page)}
    end
  end

  @doc "Lists active GitHub organization memberships and their current roles."
  @spec list_active_organization_memberships(String.t(), keyword()) ::
          {:ok, page(map())} | {:error, atom()}
  def list_active_organization_memberships(token, options \\ []) when is_binary(token) do
    with {:ok, page, per_page} <- pagination(options),
         {:ok, response} <-
           request_response(token, "/user/memberships/orgs",
             params: %{"state" => "active", "page" => page, "per_page" => per_page}
           ),
         memberships when is_list(memberships) <- response.body,
         {:ok, projected} <- traverse(memberships, &project_organization_membership/1) do
      {:ok, page_projection(projected, page, per_page, has_next_page?(response))}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  @doc "Returns normalized metadata and permissions for one GitHub repository."
  @spec get_repository(String.t(), String.t()) :: {:ok, repository()} | {:error, atom()}
  def get_repository(token, full_name) when is_binary(token) do
    with :ok <- validate_full_name(full_name),
         {:ok, body} <- request(token, "/repos/#{full_name}", []),
         {:ok, repository} <- project_repository(body) do
      {:ok, repository}
    end
  end

  @doc "Returns a repository only when the retained grant can read its Git data."
  @spec get_import_source(String.t(), String.t()) :: {:ok, repository()} | {:error, atom()}
  def get_import_source(token, full_name) when is_binary(token) do
    with {:ok, repository} <- get_repository(token, full_name),
         true <- repository["readable"] do
      {:ok, repository}
    else
      false -> {:error, :github_permission_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists a bounded page of branch names and their current commit object IDs."
  @spec list_branch_page(String.t(), String.t(), keyword()) ::
          {:ok, page(map())} | {:error, atom()}
  def list_branch_page(token, full_name, options \\ []) when is_binary(token) do
    list_named_ref_page(token, full_name, "branches", options, &project_branch/1)
  end

  @doc "Lists a bounded page of tag names and their current commit object IDs."
  @spec list_tag_page(String.t(), String.t(), keyword()) ::
          {:ok, page(map())} | {:error, atom()}
  def list_tag_page(token, full_name, options \\ []) when is_binary(token) do
    list_named_ref_page(token, full_name, "tags", options, &project_tag/1)
  end

  @doc "Returns the complete bounded branch and tag ref projection for an import snapshot."
  @spec list_references(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def list_references(token, full_name, options \\ []) when is_binary(token) do
    per_page = Keyword.get(options, :per_page, @maximum_per_page)
    max_pages = Keyword.get(options, :max_pages, 10)

    with :ok <- validate_full_name(full_name),
         :ok <- validate_reference_pagination(per_page, max_pages),
         {:ok, heads} <- collect_references(token, full_name, "heads", per_page, max_pages),
         {:ok, tags} <- collect_references(token, full_name, "tags", per_page, max_pages) do
      refs = Enum.sort_by(heads ++ tags, & &1["name"])

      {:ok,
       %{
         "count" => length(refs),
         "digest" => reference_digest(refs),
         "refs" => refs
       }}
    end
  end

  @doc "Returns conservative, bounded inputs for the one-time Git LFS import warning."
  @spec lfs_warning_inputs(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def lfs_warning_inputs(token, full_name, ref)
      when is_binary(token) and is_binary(ref) do
    with :ok <- validate_full_name(full_name),
         :ok <- validate_ref(ref),
         encoded_ref <- encode_path_segment(ref),
         {:ok, body} <-
           request(token, "/repos/#{full_name}/git/trees/#{encoded_ref}",
             params: %{"recursive" => "1"}
           ),
         {:ok, inputs} <- project_lfs_warning_inputs(body) do
      {:ok, inputs}
    end
  end

  def lfs_warning_inputs(_token, _full_name, _ref), do: {:error, :invalid_ref}

  @doc "Lists compact repository summaries for the existing signed-in GitHub tool."
  @spec list_repositories(String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_repositories(token, options \\ []) when is_binary(token) do
    first = Keyword.get(options, :first, 30)

    with true <- is_integer(first) and first in 1..50,
         {:ok, raw_page} <- repository_page(token, 1, first) do
      {:ok, Enum.map(raw_page.items, &repository_summary/1)}
    else
      false -> {:error, :invalid_pagination}
      {:error, reason} -> {:error, reason}
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

  defp repository_page(token, page, per_page) do
    with {:ok, response} <-
           request_response(token, "/user/repos",
             params: %{
               "page" => page,
               "per_page" => per_page,
               "sort" => "pushed",
               "affiliation" => "owner,collaborator,organization_member"
             }
           ),
         repositories when is_list(repositories) <- response.body do
      {:ok, %{items: repositories, has_next_page: has_next_page?(response)}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp list_named_ref_page(token, full_name, collection, options, projector) do
    with :ok <- validate_full_name(full_name),
         {:ok, page, per_page} <- pagination(options),
         {:ok, response} <-
           request_response(token, "/repos/#{full_name}/#{collection}",
             params: %{"page" => page, "per_page" => per_page}
           ),
         entries when is_list(entries) <- response.body,
         {:ok, projected} <- traverse(entries, projector) do
      {:ok, page_projection(projected, page, per_page, has_next_page?(response))}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp collect_references(token, full_name, kind, per_page, max_pages) do
    collect_references(token, full_name, kind, per_page, max_pages, 1, [])
  end

  defp collect_references(token, full_name, kind, per_page, max_pages, page, acc) do
    path = "/repos/#{full_name}/git/matching-refs/#{kind}/"

    with {:ok, response} <-
           request_response(token, path, params: %{"page" => page, "per_page" => per_page}),
         entries when is_list(entries) <- response.body,
         {:ok, projected} <- traverse(entries, &project_reference(&1, kind)) do
      next_acc = Enum.reverse(projected, acc)

      cond do
        not has_next_page?(response) ->
          {:ok, Enum.reverse(next_acc)}

        page >= max_pages ->
          {:error, :github_pagination_limit_exceeded}

        true ->
          collect_references(
            token,
            full_name,
            kind,
            per_page,
            max_pages,
            page + 1,
            next_acc
          )
      end
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :github_response_invalid}
    end
  end

  defp request(token, api_path, options) do
    with {:ok, response} <- request_response(token, api_path, options), do: {:ok, response.body}
  end

  defp request_response(token, api_path, options) do
    with :ok <- validate_token(token) do
      settings = Application.get_env(:openagents, :github_api, [])
      base_url = settings[:base_url] || "https://api.github.com"

      request_options =
        [
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
        |> Keyword.put(:auth, {:bearer, token})

      case Req.get(base_url <> api_path, request_options) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :github_token_rejected}

        {:ok, %Req.Response{status: 403}} ->
          {:error, :github_permission_denied}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :github_not_found}

        {:ok, %Req.Response{}} ->
          {:error, :github_request_failed}

        {:error, _transport_error} ->
          {:error, :github_unavailable}
      end
    end
  end

  defp project_user(
         %{
           "id" => id,
           "node_id" => node_id,
           "login" => login,
           "avatar_url" => avatar_url
         } = user
       )
       when is_integer(id) and id > 0 and is_binary(node_id) and is_binary(login) and
              is_binary(avatar_url) do
    if valid_login?(login) do
      {:ok,
       %{
         "id" => id,
         "node_id" => bounded_string(node_id, 128),
         "login" => bounded_string(login, 100),
         "name" => bounded_string(user["name"], 255),
         "avatar_url" => github_avatar_url(avatar_url),
         "type" => normalize_account_type(user["type"], "User")
       }}
    else
      {:error, :github_response_invalid}
    end
  end

  defp project_user(_body), do: {:error, :github_response_invalid}

  defp project_repository(
         %{
           "id" => id,
           "node_id" => node_id,
           "name" => name,
           "full_name" => full_name,
           "private" => private,
           "default_branch" => default_branch,
           "owner" => owner
         } = repository
       )
       when is_integer(id) and id > 0 and is_binary(node_id) and is_binary(name) and
              is_binary(full_name) and is_boolean(private) and is_binary(default_branch) and
              is_map(owner) do
    with :ok <- validate_full_name(full_name),
         {:ok, owner_projection} <- project_account(owner, "User") do
      permissions = project_permissions(repository["permissions"])
      readable = permissions["pull"] or not private

      {:ok,
       %{
         "id" => id,
         "node_id" => bounded_string(node_id, 128),
         "name" => bounded_string(name, 100),
         "full_name" => bounded_string(full_name, 140),
         "owner" => owner_projection,
         "description" => bounded_string(repository["description"], 350),
         "private" => private,
         "fork" => repository["fork"] == true,
         "archived" => repository["archived"] == true,
         "default_branch" => bounded_string(default_branch, 255),
         "language" => bounded_string(repository["language"], 60),
         "pushed_at" => bounded_string(repository["pushed_at"], 32),
         "size_kb" => bounded_size(repository["size"]),
         "permissions" => permissions,
         "readable" => readable
       }}
    end
  end

  defp project_repository(_body), do: {:error, :github_response_invalid}

  defp project_organization_membership(%{
         "state" => "active",
         "role" => role,
         "organization" => organization
       })
       when role in ["admin", "member"] and is_map(organization) do
    with {:ok, projected} <- project_account(organization, "Organization") do
      {:ok, %{"state" => "active", "role" => role, "organization" => projected}}
    end
  end

  defp project_organization_membership(_body), do: {:error, :github_response_invalid}

  defp project_account(
         %{"id" => id, "node_id" => node_id, "login" => login, "avatar_url" => avatar_url} =
           account,
         default_type
       )
       when is_integer(id) and id > 0 and is_binary(node_id) and is_binary(login) and
              is_binary(avatar_url) do
    if valid_login?(login) do
      {:ok,
       %{
         "id" => id,
         "node_id" => bounded_string(node_id, 128),
         "login" => bounded_string(login, 100),
         "avatar_url" => github_avatar_url(avatar_url),
         "type" => normalize_account_type(account["type"], default_type)
       }}
    else
      {:error, :github_response_invalid}
    end
  end

  defp project_account(_account, _default_type), do: {:error, :github_response_invalid}

  defp project_branch(%{"name" => name, "commit" => %{"sha" => sha}} = branch)
       when is_binary(name) and is_binary(sha) do
    if valid_object_id?(sha) do
      {:ok,
       %{
         "name" => bounded_string(name, 255),
         "sha" => sha,
         "protected" => branch["protected"] == true
       }}
    else
      {:error, :github_response_invalid}
    end
  end

  defp project_branch(_body), do: {:error, :github_response_invalid}

  defp project_tag(%{"name" => name, "commit" => %{"sha" => sha}})
       when is_binary(name) and is_binary(sha) do
    if valid_object_id?(sha),
      do: {:ok, %{"name" => bounded_string(name, 255), "sha" => sha}},
      else: {:error, :github_response_invalid}
  end

  defp project_tag(_body), do: {:error, :github_response_invalid}

  defp project_reference(
         %{"ref" => name, "object" => %{"type" => object_type, "sha" => sha}},
         kind
       )
       when is_binary(name) and is_binary(object_type) and is_binary(sha) do
    expected_prefix = "refs/#{kind}/"

    if String.starts_with?(name, expected_prefix) and byte_size(name) <= 512 and
         object_type in ["blob", "commit", "tag", "tree"] and valid_object_id?(sha) do
      {:ok, %{"name" => name, "object_type" => object_type, "sha" => sha}}
    else
      {:error, :github_response_invalid}
    end
  end

  defp project_reference(_body, _kind), do: {:error, :github_response_invalid}

  defp project_lfs_warning_inputs(%{"tree" => tree} = body) when is_list(tree) do
    entries = Enum.take(tree, @maximum_tree_entries)

    attributes_files =
      entries
      |> Enum.filter(fn entry ->
        is_map(entry) and entry["type"] == "blob" and is_binary(entry["path"]) and
          Path.basename(entry["path"]) == ".gitattributes"
      end)
      |> Enum.map(&bounded_string(&1["path"], 500))
      |> Enum.sort()
      |> Enum.take(@maximum_attribute_files)

    lfs_config_present =
      Enum.any?(entries, fn entry ->
        is_map(entry) and entry["type"] == "blob" and entry["path"] == ".lfsconfig"
      end)

    large_blob_count =
      Enum.count(entries, fn entry ->
        is_map(entry) and entry["type"] == "blob" and is_integer(entry["size"]) and
          entry["size"] >= @large_blob_bytes
      end)

    tree_truncated = body["truncated"] == true or length(tree) > @maximum_tree_entries

    {:ok,
     %{
       "attributes_files" => attributes_files,
       "large_blob_count" => large_blob_count,
       "lfs_config_present" => lfs_config_present,
       "tree_truncated" => tree_truncated,
       "warning_recommended" =>
         attributes_files != [] or lfs_config_present or large_blob_count > 0 or tree_truncated
     }}
  end

  defp project_lfs_warning_inputs(_body), do: {:error, :github_response_invalid}

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

  defp project_permissions(permissions) when is_map(permissions) do
    %{
      "admin" => permissions["admin"] == true,
      "maintain" => permissions["maintain"] == true,
      "pull" => permissions["pull"] == true,
      "push" => permissions["push"] == true,
      "triage" => permissions["triage"] == true
    }
  end

  defp project_permissions(_permissions) do
    %{"admin" => false, "maintain" => false, "pull" => false, "push" => false, "triage" => false}
  end

  defp page_projection(items, page, per_page, has_next_page) do
    %{
      "items" => items,
      "page" => page,
      "per_page" => per_page,
      "has_next_page" => has_next_page,
      "next_page" => if(has_next_page, do: page + 1, else: nil)
    }
  end

  defp pagination(options) when is_list(options) do
    page = Keyword.get(options, :page, 1)
    per_page = Keyword.get(options, :per_page, @maximum_per_page)

    if is_integer(page) and page in 1..@maximum_page and is_integer(per_page) and
         per_page in 1..@maximum_per_page do
      {:ok, page, per_page}
    else
      {:error, :invalid_pagination}
    end
  end

  defp pagination(_options), do: {:error, :invalid_pagination}

  defp validate_reference_pagination(per_page, max_pages)
       when is_integer(per_page) and per_page in 1..@maximum_per_page and
              is_integer(max_pages) and max_pages in 1..@maximum_reference_pages,
       do: :ok

  defp validate_reference_pagination(_per_page, _max_pages),
    do: {:error, :invalid_pagination}

  defp has_next_page?(response) do
    response
    |> Req.Response.get_header("link")
    |> Enum.any?(&Regex.match?(~r/<[^>]+>;\s*rel="next"/, &1))
  end

  defp reference_digest(refs) do
    refs
    |> Enum.map_join("\n", fn ref ->
      Enum.join([ref["name"], ref["object_type"], ref["sha"]], "\0")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp traverse(entries, projector) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case projector.(entry) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
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

  defp validate_token(token) when is_binary(token) and byte_size(token) in 1..512, do: :ok
  defp validate_token(_token), do: {:error, :invalid_token}

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

  defp validate_ref(ref) when is_binary(ref) and byte_size(ref) in 1..255 do
    if String.valid?(ref) and not String.contains?(ref, ["\0", ".."]),
      do: :ok,
      else: {:error, :invalid_ref}
  end

  defp validate_ref(_ref), do: {:error, :invalid_ref}

  defp valid_login?(login) do
    is_binary(login) and byte_size(login) in 1..100 and
      Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?\z/, login)
  end

  defp valid_object_id?(sha), do: is_binary(sha) and Regex.match?(@object_id_regex, sha)

  defp normalize_account_type(type, _default) when type in ["User", "Organization"], do: type
  defp normalize_account_type(_type, default), do: default

  defp github_avatar_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "avatars.githubusercontent.com"}} ->
        bounded_string(value, 500)

      _invalid ->
        ""
    end
  end

  defp encode_path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp bounded_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded_string(_value, _maximum), do: ""
end
