defmodule OpenAgentsWeb.RepositoryImportController do
  @moduledoc "Accepts and reports one-time GitHub repository imports."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.GitHubProjection
  alias OpenAgentsWeb.{RepositoryImportJSON, RepositoryJSON}

  def create_user(conn, params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, full_name} <- source_repository(params),
         {:ok, source, github_repository} <-
           GitHubProjection.import_source(conn.assigns.current_user, full_name),
         {:ok, attrs} <- import_attrs(params, github_repository),
         {:ok, repository, repository_import, replay_state} <-
           Repositories.create_user_import(
             conn.assigns.current_user,
             source,
             attrs,
             idempotency_key
           ) do
      render_import(conn, repository, repository_import, replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create_organization(conn, %{"org" => org} = params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, namespace} <-
           GitHubProjection.authorized_organization(conn.assigns.current_user, org),
         {:ok, full_name} <- source_repository(params),
         {:ok, source, github_repository} <-
           GitHubProjection.import_source(conn.assigns.current_user, full_name),
         {:ok, attrs} <- import_attrs(params, github_repository),
         {:ok, repository, repository_import, replay_state} <-
           Repositories.create_organization_import(
             conn.assigns.current_user,
             namespace,
             source,
             attrs,
             idempotency_key
           ) do
      render_import(conn, repository, repository_import, replay_state)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    repository_import = Repositories.get_import_for_user!(id, conn.assigns.current_user)
    repository = repository_import.repository
    role = Repositories.membership_role(repository, conn.assigns.current_user)

    json(conn, %{
      "repository" =>
        RepositoryJSON.repository(
          repository,
          RepositoryJSON.permissions(repository, role),
          base_url(conn)
        ),
      "import" => RepositoryImportJSON.import(repository_import)
    })
  rescue
    Ecto.NoResultsError -> render_error(conn, :not_found)
  end

  defp render_import(conn, repository, repository_import, replay_state) do
    role = Repositories.membership_role(repository, conn.assigns.current_user)
    status = if repository.lifecycle_state == "ready", do: :created, else: :accepted

    repository_body =
      RepositoryJSON.repository(
        repository,
        RepositoryJSON.permissions(repository, role),
        base_url(conn)
      )

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(
      repository_body
      |> Map.put("import", RepositoryImportJSON.import(repository_import))
      |> Map.put("replayed", replay_state == :replayed)
    )
  end

  defp source_repository(%{
         "source" => %{"provider" => "github", "repository" => full_name}
       })
       when is_binary(full_name),
       do: {:ok, full_name}

  defp source_repository(_params), do: {:error, :invalid_import}

  defp import_attrs(params, github_repository) do
    private? = Map.get(params, "private", true)
    name = params["name"] || github_repository["name"]

    if is_boolean(private?) do
      {:ok,
       %{
         name: name,
         description: github_repository["description"],
         visibility: if(private?, do: "private", else: "public"),
         default_branch: github_repository["default_branch"]
       }}
    else
      {:error, :invalid_import}
    end
  end

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

  defp render_error(conn, :not_found),
    do: error(conn, :not_found, "not_found", "Repository import not found")

  defp render_error(conn, :source_namespace_mismatch),
    do: error(conn, :forbidden, "source_namespace_mismatch", "Source namespace is not eligible")

  defp render_error(conn, :namespace_not_allowed),
    do: error(conn, :forbidden, "namespace_not_allowed", "Namespace is not eligible")

  defp render_error(conn, :github_connection_required),
    do: error(conn, :forbidden, "github_connection_required", "Connect GitHub before importing")

  defp render_error(conn, :github_scope_required),
    do: error(conn, :forbidden, "github_scope_required", "Reconnect GitHub with required access")

  defp render_error(conn, :source_repository_not_accessible),
    do: error(conn, :forbidden, "source_repository_not_accessible", "Source is not accessible")

  defp render_error(conn, :idempotency_conflict),
    do: error(conn, :conflict, "idempotency_conflict", "The idempotency key is already in use")

  defp render_error(conn, :invalid_idempotency_key),
    do: error(conn, :bad_request, "invalid_idempotency_key", "Provide one Idempotency-Key header")

  defp render_error(conn, %Ecto.Changeset{}),
    do: error(conn, :unprocessable_entity, "invalid_import", "Repository import is invalid")

  defp render_error(conn, reason)
       when reason in [
              :github_unavailable,
              :github_request_failed,
              :github_pagination_limit_exceeded
            ],
       do: error(conn, :service_unavailable, "github_unavailable", "GitHub is unavailable")

  defp render_error(conn, _reason),
    do: error(conn, :unprocessable_entity, "invalid_import", "Repository import is invalid")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      "code" => code,
      "message" => message,
      "request_id" => List.first(get_resp_header(conn, "x-request-id"))
    })
  end

  defp base_url(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end
end
