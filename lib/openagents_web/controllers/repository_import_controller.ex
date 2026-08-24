defmodule OpenAgentsWeb.RepositoryImportController do
  @moduledoc """
  Accepts and reports one-time GitHub repository copies.

  Two kinds arrive here and they are not the same claim. An **import** copies a
  repository this account owns and becomes this account's own repository. An
  **upstream mirror** (`"mirror": true`) copies a public repository this
  account does not own, names the upstream, carries its license, and refuses
  every push.

  Which one you get is never inferred. A foreign source owner without
  `"mirror": true` is still refused, and the refusal names the source owner
  and the field that would admit it, because becoming a mirror is a decision
  the caller makes rather than one this controller makes for them.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.GitHubProjection
  alias OpenAgentsWeb.{RepositoryImportJSON, RepositoryJSON}

  def create_user(conn, params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, full_name} <- source_repository(params),
         {:ok, mirror?} <- mirror_requested(params),
         {:ok, source, github_repository} <-
           GitHubProjection.import_source(conn.assigns.current_user, full_name),
         {:ok, attrs} <- import_attrs(params, github_repository),
         {:ok, repository, repository_import, replay_state} <-
           create_user_copy(
             mirror?,
             conn.assigns.current_user,
             source,
             attrs,
             idempotency_key
           ) do
      render_import(conn, repository, repository_import, replay_state)
    else
      {:error, reason} -> render_error(conn, reason, params)
    end
  end

  defp create_user_copy(true, user, source, attrs, idempotency_key),
    do: Repositories.create_user_mirror(user, source, attrs, idempotency_key)

  defp create_user_copy(false, user, source, attrs, idempotency_key),
    do: Repositories.create_user_import(user, source, attrs, idempotency_key)

  defp create_organization_copy(true, user, namespace, source, attrs, idempotency_key),
    do: Repositories.create_organization_mirror(user, namespace, source, attrs, idempotency_key)

  defp create_organization_copy(false, user, namespace, source, attrs, idempotency_key),
    do: Repositories.create_organization_import(user, namespace, source, attrs, idempotency_key)

  defp mirror_requested(%{"mirror" => mirror}) when is_boolean(mirror), do: {:ok, mirror}
  defp mirror_requested(%{"mirror" => _invalid}), do: {:error, :invalid_import}
  defp mirror_requested(_params), do: {:ok, false}

  def create_organization(conn, %{"org" => org} = params) do
    with {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, namespace} <-
           GitHubProjection.authorized_organization(conn.assigns.current_user, org),
         {:ok, full_name} <- source_repository(params),
         {:ok, mirror?} <- mirror_requested(params),
         {:ok, source, github_repository} <-
           GitHubProjection.import_source(conn.assigns.current_user, full_name),
         {:ok, attrs} <- import_attrs(params, github_repository),
         {:ok, repository, repository_import, replay_state} <-
           create_organization_copy(
             mirror?,
             conn.assigns.current_user,
             namespace,
             source,
             attrs,
             idempotency_key
           ) do
      render_import(conn, repository, repository_import, replay_state)
    else
      {:error, reason} -> render_error(conn, reason, params)
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
    Ecto.NoResultsError -> render_error(conn, :not_found, %{})
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
    private? = Map.get(params, "private", github_repository["private"])
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

  # The refusal used to say "Source namespace is not eligible", which names
  # nothing: the caller cannot tell whether the destination namespace or the
  # source owner failed, and the destination is usually their own account. The
  # source owner is what failed, so the source owner is what the message says,
  # along with the one field that admits a public repository owned by someone
  # else.
  defp render_error(conn, :source_namespace_mismatch, params) do
    error(
      conn,
      :forbidden,
      "source_namespace_mismatch",
      "The source repository #{source_name(params)} is owned by another GitHub account, " <>
        "so it cannot be imported as your own repository. " <>
        "If it is public, send \"mirror\": true to bring it in as an upstream mirror, " <>
        "which names the upstream, carries its license, and accepts no pushes.",
      %{"source" => source_name(params), "destination" => "eligible"}
    )
  end

  defp render_error(conn, :source_repository_not_public, params),
    do:
      error(
        conn,
        :forbidden,
        "source_repository_not_public",
        "The source repository #{source_name(params)} is not public, " <>
          "so it cannot be brought in as an upstream mirror.",
        %{"source" => source_name(params)}
      )

  defp render_error(conn, :not_found, _params),
    do: error(conn, :not_found, "not_found", "Repository import not found")

  defp render_error(conn, :namespace_not_allowed, _params),
    do: error(conn, :forbidden, "namespace_not_allowed", "Namespace is not eligible")

  defp render_error(conn, :github_connection_required, _params),
    do: error(conn, :forbidden, "github_connection_required", "Connect GitHub before importing")

  defp render_error(conn, :github_scope_required, _params),
    do: error(conn, :forbidden, "github_scope_required", "Reconnect GitHub with required access")

  defp render_error(conn, :source_repository_not_accessible, _params),
    do: error(conn, :forbidden, "source_repository_not_accessible", "Source is not accessible")

  defp render_error(conn, :idempotency_conflict, _params),
    do: error(conn, :conflict, "idempotency_conflict", "The idempotency key is already in use")

  defp render_error(conn, :repository_quota_exceeded, _params),
    do:
      error(
        conn,
        :unprocessable_entity,
        "repository_quota_exceeded",
        "The namespace repository quota is exhausted"
      )

  defp render_error(conn, :invalid_idempotency_key, _params),
    do: error(conn, :bad_request, "invalid_idempotency_key", "Provide one Idempotency-Key header")

  defp render_error(conn, %Ecto.Changeset{}, _params),
    do: error(conn, :unprocessable_entity, "invalid_import", "Repository import is invalid")

  defp render_error(conn, reason, _params)
       when reason in [
              :github_unavailable,
              :github_request_failed,
              :github_pagination_limit_exceeded
            ],
       do: error(conn, :service_unavailable, "github_unavailable", "GitHub is unavailable")

  defp render_error(conn, _reason, _params),
    do: error(conn, :unprocessable_entity, "invalid_import", "Repository import is invalid")

  defp source_name(%{"source" => %{"repository" => full_name}}) when is_binary(full_name),
    do: bounded_source_name(full_name)

  defp source_name(_params), do: "requested by this call"

  defp bounded_source_name(full_name) do
    full_name
    |> String.replace(~r/[^A-Za-z0-9._\/-]/, "")
    |> String.slice(0, 140)
  end

  defp error(conn, status, code, message, failed \\ nil) do
    body = %{
      "code" => code,
      "message" => message,
      "request_id" => List.first(get_resp_header(conn, "x-request-id"))
    }

    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(if failed, do: Map.put(body, "failed", failed), else: body)
  end

  defp base_url(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end
end
