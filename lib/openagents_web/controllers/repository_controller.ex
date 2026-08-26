defmodule OpenAgentsWeb.RepositoryController do
  @moduledoc "Creates and reads hosted repositories."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.GitHubProjection
  alias OpenAgentsWeb.RepositoryJSON

  @doc """
  Creates a repository under a named owner of either kind.

  `POST /api/v1/user/repos` and `POST /api/v1/orgs/{org}/repos` make the caller
  choose a route by the kind of owner, and a caller handed `OWNER/NAME` knows
  only that an owner was named. Guessing the kind from the shape of the
  argument sends a personal namespace to the organization route. This route
  takes the owner as a parameter and resolves the kind here, so no client has
  to guess.

  `owner` defaults to the authenticated login. Everything else — the
  idempotency key, the attributes, the response — matches the two routes it
  stands in for.
  """
  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, attrs} <- repository_attrs(params),
         {:ok, owner} <- requested_owner(params, user),
         {:ok, namespace} <- GitHubProjection.authorized_namespace(user, owner),
         {:ok, repository, replay_state} <-
           Repositories.create_namespace_repository(user, namespace, attrs, idempotency_key) do
      render_repository(conn, repository, user, replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create_user(conn, params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, attrs} <- repository_attrs(params),
         {:ok, repository, replay_state} <-
           Repositories.create_user_repository(conn.assigns.current_user, attrs, idempotency_key) do
      render_repository(conn, repository, conn.assigns.current_user, replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create_organization(conn, %{"org" => org} = params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, attrs} <- repository_attrs(params),
         {:ok, namespace} <-
           GitHubProjection.authorized_organization(conn.assigns.current_user, org),
         {:ok, repository, replay_state} <-
           Repositories.create_organization_repository(
             conn.assigns.current_user,
             namespace,
             attrs,
             idempotency_key
           ) do
      render_repository(conn, repository, conn.assigns.current_user, replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def index(conn, params) do
    with {:ok, per_page} <- per_page(params),
         {:ok, after_cursor} <- decode_cursor(params["after"]),
         {:ok, namespace_key} <- namespace_key(params["namespace"]) do
      {repositories, more?} =
        Repositories.list_visible_repositories_page(
          conn.assigns.current_user,
          per_page,
          after_cursor,
          namespace_key
        )

      next_cursor = if more?, do: encode_cursor(List.last(repositories)), else: nil

      json(conn, %{
        "repositories" =>
          Enum.map(repositories, &projection(&1, conn.assigns.current_user, base_url(conn))),
        "next_cursor" => next_cursor
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def show(conn, %{"owner" => owner, "repo" => name}) do
    repository = Repositories.get_visible_by_path!(owner, name, conn.assigns.current_user)
    json(conn, projection(repository, conn.assigns.current_user, base_url(conn)))
  rescue
    Ecto.NoResultsError -> render_error(conn, :not_found)
  end

  def update(conn, %{
        "owner" => owner,
        "repo" => name,
        "pull_requests_enabled" => enabled
      }) do
    case Repositories.update_pull_request_setting(
           owner,
           name,
           conn.assigns.current_user,
           enabled
         ) do
      {:ok, repository} ->
        json(conn, projection(repository, conn.assigns.current_user, base_url(conn)))

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def update(conn, _params), do: render_error(conn, :invalid_pull_request_setting)

  def delete(conn, %{"owner" => owner, "repo" => name}) do
    case Repositories.delete_owned_repository(owner, name, conn.assigns.current_user,
           surface: "api"
         ) do
      {:ok, _repository} -> send_resp(conn, :no_content, "")
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_repository(conn, repository, user, replay_state) do
    status = if repository.lifecycle_state == "ready", do: :created, else: :accepted

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(
      projection(repository, user, base_url(conn))
      |> Map.put("replayed", replay_state == :replayed)
    )
  end

  defp projection(repository, user, base_url) do
    role = Repositories.membership_role(repository, user)

    RepositoryJSON.repository(repository, RepositoryJSON.permissions(repository, role), base_url)
  end

  defp repository_attrs(params) do
    private? = Map.get(params, "private", true)

    if is_boolean(private?) do
      {:ok,
       %{
         name: params["name"],
         description: params["description"],
         visibility: if(private?, do: "private", else: "public"),
         default_branch: params["default_branch"] || "main"
       }}
    else
      {:error, :invalid_repository}
    end
  end

  defp requested_owner(%{"owner" => owner}, _user) when is_binary(owner) do
    case namespace_key(owner) do
      {:ok, _key} -> {:ok, owner}
      {:error, _reason} -> {:error, :invalid_repository}
    end
  end

  defp requested_owner(%{"owner" => _owner}, _user), do: {:error, :invalid_repository}

  defp requested_owner(_params, %{github_login: login}) when is_binary(login),
    do: {:ok, login}

  defp requested_owner(_params, _user), do: {:error, :namespace_not_allowed}

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..200 ->
        if String.contains?(key, ["\r", "\n", "\0"]),
          do: {:error, :invalid_idempotency_key},
          else: {:ok, key}

      _invalid ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp per_page(%{"per_page" => value}) do
    case Integer.parse(value) do
      {number, ""} when number in 1..100 -> {:ok, number}
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp per_page(_params), do: {:ok, 30}

  defp namespace_key(nil), do: {:ok, nil}

  defp namespace_key(namespace) when is_binary(namespace) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9-]{0,38}\z/, namespace),
      do: {:ok, String.downcase(namespace)},
      else: {:error, :invalid_pagination}
  end

  defp namespace_key(_namespace), do: {:error, :invalid_pagination}

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, [owner_key, name_key, id]} <- Jason.decode(encoded),
         true <- Enum.all?([owner_key, name_key, id], &is_binary/1),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {owner_key, name_key, id}}
    else
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp encode_cursor(repository) do
    Jason.encode!([
      repository.namespace.slug_key,
      repository.name_key,
      repository.id
    ])
    |> Base.url_encode64(padding: false)
  end

  defp render_error(conn, %Ecto.Changeset{} = changeset) do
    conflict? =
      Enum.any?(changeset.errors, fn
        {:name_key, {_message, options}} -> options[:constraint] == :unique
        {:storage_key, {_message, options}} -> options[:constraint] == :unique
        _error -> false
      end)

    if conflict?,
      do: render_error(conn, :repository_name_conflict),
      else: render_error(conn, :invalid_repository)
  end

  defp render_error(conn, :invalid_idempotency_key),
    do: error(conn, :bad_request, "invalid_idempotency_key", "Provide one Idempotency-Key header")

  defp render_error(conn, :idempotency_conflict),
    do: error(conn, :conflict, "idempotency_conflict", "The idempotency key is already in use")

  defp render_error(conn, :repository_name_conflict),
    do:
      error(conn, :conflict, "repository_name_conflict", "Repository name is unavailable", "name")

  defp render_error(conn, :repository_busy),
    do:
      error(
        conn,
        :conflict,
        "repository_busy",
        "Repository provisioning is still running. Try again after it finishes"
      )

  defp render_error(conn, {:storage_cleanup_failed, _reason}),
    do:
      error(
        conn,
        :service_unavailable,
        "repository_delete_failed",
        "Repository storage could not be deleted"
      )

  defp render_error(conn, :repository_quota_exceeded),
    do:
      error(
        conn,
        :unprocessable_entity,
        "repository_quota_exceeded",
        "The namespace repository quota is exhausted"
      )

  defp render_error(conn, :not_found),
    do: error(conn, :not_found, "not_found", "Repository not found")

  defp render_error(conn, :forbidden),
    do: error(conn, :forbidden, "forbidden", "Only a repository owner can update settings")

  defp render_error(conn, :invalid_pull_request_setting),
    do:
      error(
        conn,
        :unprocessable_entity,
        "invalid_pull_request_setting",
        "pull_requests_enabled must be a boolean"
      )

  defp render_error(conn, :invalid_pagination),
    do: error(conn, :unprocessable_entity, "invalid_pagination", "Pagination input is invalid")

  defp render_error(conn, :namespace_not_allowed),
    do: error(conn, :forbidden, "namespace_not_allowed", "Namespace is not eligible")

  defp render_error(conn, :github_scope_required),
    do: error(conn, :forbidden, "github_scope_required", "Reconnect GitHub with required access")

  defp render_error(conn, _reason),
    do: error(conn, :unprocessable_entity, "invalid_repository", "Repository input is invalid")

  defp error(conn, status, code, message, field \\ nil) do
    body = %{
      "code" => code,
      "message" => message,
      "request_id" => List.first(get_resp_header(conn, "x-request-id"))
    }

    body = if field, do: Map.put(body, "field", field), else: body

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(body)
  end

  defp base_url(conn),
    do: URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
end
