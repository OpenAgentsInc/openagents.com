defmodule OpenAgentsWeb.RepositoryControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.ApiTokens
  alias OpenAgents.Forge.{Repos, WAL}
  alias OpenAgents.Repositories

  test "POST /api/v1/user/repos creates in the authenticated GitHub namespace", %{conn: conn} do
    user = github_user("repository-api-create", "octavia")

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "repo-create-1")
      |> post(~p"/api/v1/user/repos", %{
        name: "My-Project",
        description: "An API-created repository",
        private: true,
        default_branch: "trunk"
      })

    assert %{
             "id" => id,
             "name" => "my-project",
             "full_name" => "octavia/my-project",
             "private" => true,
             "visibility" => "private",
             "default_branch" => "trunk",
             "lifecycle_state" => "provisioning",
             "clone_url" => clone_url,
             "html_url" => html_url,
             "permissions" => %{"admin" => true, "pull" => true, "push" => true}
           } = json_response(response, 202)

    assert String.ends_with?(clone_url, "/octavia/my-project.git")
    assert String.ends_with?(html_url, "/octavia/my-project")
    assert Repositories.get_by_path!("octavia", "my-project").id == id
  end

  test "create requires a bounded idempotency key and rejects conflicting replay", %{conn: conn} do
    user = github_user("repository-api-idempotency")

    assert %{"code" => "invalid_idempotency_key"} =
             conn
             |> authorize(user)
             |> post(~p"/api/v1/user/repos", %{name: "missing-key"})
             |> json_response(400)

    first =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "same-key")
      |> post(~p"/api/v1/user/repos", %{name: "same-request"})

    replayed =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "same-key")
      |> post(~p"/api/v1/user/repos", %{name: "same-request"})

    assert json_response(first, 202)["id"] == json_response(replayed, 202)["id"]

    assert %{"code" => "idempotency_conflict"} =
             conn
             |> authorize(user)
             |> put_req_header("idempotency-key", "same-key")
             |> post(~p"/api/v1/user/repos", %{name: "different-request"})
             |> json_response(409)
  end

  test "GET repository permits public reads and conceals private repositories", %{conn: conn} do
    owner = github_user("repository-api-visibility-owner", "visible-owner")
    viewer = github_user("repository-api-visibility-viewer")

    {:ok, public_repository, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: "public-repo", visibility: "public"},
        "public-create"
      )

    {:ok, private_repository, :created} =
      Repositories.create_user_repository(
        owner,
        %{name: "private-repo", visibility: "private"},
        "private-create"
      )

    mark_ready(public_repository)
    mark_ready(private_repository)

    assert %{"id" => public_id, "permissions" => %{"pull" => true, "push" => false}} =
             conn
             |> get(~p"/api/v1/repos/visible-owner/public-repo")
             |> json_response(200)

    assert public_id == public_repository.id

    assert conn
           |> get(~p"/api/v1/repos/visible-owner/private-repo")
           |> json_response(404)

    assert conn
           |> authorize(viewer)
           |> get(~p"/api/v1/repos/visible-owner/private-repo")
           |> json_response(404)

    {:ok, _membership} = Repositories.add_member(private_repository, viewer, "viewer")

    assert %{"id" => private_id, "permissions" => %{"pull" => true, "push" => false}} =
             conn
             |> authorize(viewer)
             |> get(~p"/api/v1/repos/visible-owner/private-repo")
             |> json_response(200)

    assert private_id == private_repository.id
  end

  test "GET /api/v1/user/repos returns a bounded visible list", %{conn: conn} do
    user = github_user("repository-api-list", "repo-list-owner")

    Enum.each(1..3, fn number ->
      assert {:ok, _repository, :created} =
               Repositories.create_user_repository(
                 user,
                 %{name: "project-#{number}"},
                 "list-key-#{number}"
               )
    end)

    first =
      conn
      |> authorize(user)
      |> get(~p"/api/v1/user/repos?per_page=2")
      |> json_response(200)

    assert length(first["repositories"]) == 2
    assert is_binary(first["next_cursor"])

    second =
      conn
      |> authorize(user)
      |> get(~p"/api/v1/user/repos?per_page=2&after=#{first["next_cursor"]}")
      |> json_response(200)

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(first["repositories"], & &1["id"])),
             MapSet.new(Enum.map(second["repositories"], & &1["id"]))
           )
  end

  test "GET /api/v1/user/repos filters by GitHub namespace", %{conn: conn} do
    user = github_user("repository-api-list-namespace", "repo-list-filter")

    assert {:ok, _repository, :created} =
             Repositories.create_user_repository(
               user,
               %{name: "matching-project"},
               "list-namespace-key"
             )

    response =
      conn
      |> authorize(user)
      |> get(~p"/api/v1/user/repos?namespace=repo-list-filter&per_page=10")
      |> json_response(200)

    assert Enum.map(response["repositories"], & &1["full_name"]) == [
             "repo-list-filter/matching-project"
           ]

    assert %{"repositories" => []} =
             conn
             |> authorize(user)
             |> get(~p"/api/v1/user/repos?namespace=another-owner&per_page=10")
             |> json_response(200)
  end

  test "creation enforces the namespace repository quota", %{conn: conn} do
    previous = Application.get_env(:openagents, :repository_namespace_limit)
    Application.put_env(:openagents, :repository_namespace_limit, 1)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:openagents, :repository_namespace_limit),
        else: Application.put_env(:openagents, :repository_namespace_limit, previous)
    end)

    user = github_user("repository-api-quota", "quota-owner")

    assert conn
           |> authorize(user)
           |> put_req_header("idempotency-key", "quota-first")
           |> post(~p"/api/v1/user/repos", %{name: "first"})
           |> json_response(202)

    assert %{"code" => "repository_quota_exceeded"} =
             conn
             |> authorize(user)
             |> put_req_header("idempotency-key", "quota-second")
             |> post(~p"/api/v1/user/repos", %{name: "second"})
             |> json_response(422)
  end

  test "DELETE /api/v1/repos/:owner/:repo removes an owned repository and its storage", %{
    conn: conn
  } do
    configure_repository_storage("repository-api-delete")
    owner = github_user("repository-api-delete-owner", "delete-owner")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               owner,
               %{name: "delete-me", visibility: "private"},
               "delete-repository"
             )

    mark_ready(repository)
    assert {:ok, _generation} = WAL.cas_index(repository.storage_key, :none, WAL.new_index())
    bare_path = Repos.ensure_repo!(repository.storage_key)

    response =
      conn
      |> authorize(owner)
      |> delete("/api/v1/repos/delete-owner/delete-me")

    assert response.status == 204
    assert response.resp_body == ""

    assert_raise Ecto.NoResultsError, fn ->
      Repositories.get_by_path!("delete-owner", "delete-me")
    end

    assert {:error, :not_found} = WAL.read_index(repository.storage_key)
    refute File.exists?(bare_path)
  end

  test "DELETE /api/v1/repos/:owner/:repo permits only repository owners", %{conn: conn} do
    owner = github_user("repository-api-delete-authorization-owner", "protected-owner")
    maintainer = github_user("repository-api-delete-authorization-maintainer")

    assert {:ok, repository, :created} =
             Repositories.create_user_repository(
               owner,
               %{name: "protected-repository", visibility: "private"},
               "protected-repository"
             )

    mark_ready(repository)
    assert {:ok, _membership} = Repositories.add_member(repository, maintainer, "maintainer")

    assert %{"code" => "not_found"} =
             conn
             |> authorize(maintainer)
             |> delete("/api/v1/repos/protected-owner/protected-repository")
             |> json_response(404)

    assert Repositories.get_by_path!("protected-owner", "protected-repository").id ==
             repository.id
  end

  defp authorize(conn, user) do
    {:ok, _credential, plaintext} =
      ApiTokens.create(user, %{name: "repository API test", scopes: ["forge:write"]})

    put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end

  defp mark_ready(repository) do
    repository
    |> Ecto.Changeset.change(
      lifecycle_state: "ready",
      ready_at: DateTime.utc_now()
    )
    |> OpenAgents.Repo.update!()
  end

  defp configure_repository_storage(key) do
    root = Path.join(System.tmp_dir!(), "#{key}-#{System.unique_integer([:positive])}")
    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    previous_adapter = Application.get_env(:openagents, :forge_wal_adapter)

    Application.put_env(:openagents, :forge_data_dir, Path.join(root, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(root, "wal"))
    Application.put_env(:openagents, :forge_wal_adapter, OpenAgents.Forge.WAL.Local)

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      restore_env(:forge_wal_adapter, previous_adapter)
      File.rm_rf!(root)
    end)

    root
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
