defmodule OpenAgentsWeb.RepositoryControllerTest do
  use OpenAgentsWeb.ConnCase, async: true

  alias OpenAgents.ApiTokens
  alias OpenAgents.Repositories

  test "POST /api/v3/user/repos creates in the authenticated GitHub namespace", %{conn: conn} do
    user = github_user("repository-api-create", "octavia")

    response =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "repo-create-1")
      |> post(~p"/api/v3/user/repos", %{
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

    assert String.ends_with?(clone_url, "/git/octavia/my-project.git")
    assert String.ends_with?(html_url, "/octavia/my-project")
    assert Repositories.get_by_path!("octavia", "my-project").id == id
  end

  test "create requires a bounded idempotency key and rejects conflicting replay", %{conn: conn} do
    user = github_user("repository-api-idempotency")

    assert %{"code" => "invalid_idempotency_key"} =
             conn
             |> authorize(user)
             |> post(~p"/api/v3/user/repos", %{name: "missing-key"})
             |> json_response(400)

    first =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "same-key")
      |> post(~p"/api/v3/user/repos", %{name: "same-request"})

    replayed =
      conn
      |> authorize(user)
      |> put_req_header("idempotency-key", "same-key")
      |> post(~p"/api/v3/user/repos", %{name: "same-request"})

    assert json_response(first, 202)["id"] == json_response(replayed, 202)["id"]

    assert %{"code" => "idempotency_conflict"} =
             conn
             |> authorize(user)
             |> put_req_header("idempotency-key", "same-key")
             |> post(~p"/api/v3/user/repos", %{name: "different-request"})
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
             |> get(~p"/api/v3/repos/visible-owner/public-repo")
             |> json_response(200)

    assert public_id == public_repository.id

    assert conn
           |> get(~p"/api/v3/repos/visible-owner/private-repo")
           |> json_response(404)

    assert conn
           |> authorize(viewer)
           |> get(~p"/api/v3/repos/visible-owner/private-repo")
           |> json_response(404)

    {:ok, _membership} = Repositories.add_member(private_repository, viewer, "viewer")

    assert %{"id" => private_id, "permissions" => %{"pull" => true, "push" => false}} =
             conn
             |> authorize(viewer)
             |> get(~p"/api/v3/repos/visible-owner/private-repo")
             |> json_response(200)

    assert private_id == private_repository.id
  end

  test "GET /api/v3/user/repos returns a bounded visible list", %{conn: conn} do
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
      |> get(~p"/api/v3/user/repos?per_page=2")
      |> json_response(200)

    assert length(first["repositories"]) == 2
    assert is_binary(first["next_cursor"])

    second =
      conn
      |> authorize(user)
      |> get(~p"/api/v3/user/repos?per_page=2&after=#{first["next_cursor"]}")
      |> json_response(200)

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(first["repositories"], & &1["id"])),
             MapSet.new(Enum.map(second["repositories"], & &1["id"]))
           )
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
end
