defmodule OpenAgentsWeb.PullRequestControllerTest do
  use OpenAgentsWeb.ConnCase

  alias OpenAgents.Forge.Repos
  alias OpenAgents.Repositories

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "pull-request-controller-#{System.unique_integer([:positive])}"
      )

    previous_data = Application.get_env(:openagents, :forge_data_dir)
    previous_wal = Application.get_env(:openagents, :forge_wal_dir)
    Application.put_env(:openagents, :forge_data_dir, Path.join(base, "data"))
    Application.put_env(:openagents, :forge_wal_dir, Path.join(base, "wal"))

    on_exit(fn ->
      restore_env(:forge_data_dir, previous_data)
      restore_env(:forge_wal_dir, previous_wal)
      File.rm_rf(base)
    end)

    :ok
  end

  test "POST, GET, and PATCH /api/v1/repos/:owner/:repo/pulls manage a pull request", %{
    conn: conn
  } do
    target = repository_fixture()
    source = repository_fixture()
    seed_repository(target)
    seed_repository(source)

    user = github_user("api-token-pull-request-lifecycle")
    {:ok, _membership} = Repositories.add_member(source, user, "owner")
    conn = put_forge_api_token(conn, "pull-request-lifecycle", target)

    create_conn =
      post(conn, "/api/v1/repos/#{target.owner}/#{target.name}/pulls", %{
        title: "Add pull request support",
        body: "Issue-backed pull request",
        head_repository: "#{source.owner}/#{source.name}",
        head: "main",
        base: "main"
      })

    assert %{
             "number" => number,
             "title" => "Add pull request support",
             "state" => "open",
             "draft" => true,
             "head" => %{"ref" => "main"},
             "base" => %{"ref" => "main"}
           } = json_response(create_conn, 201)

    show_conn = get(conn, "/api/v1/repos/#{target.owner}/#{target.name}/pulls/#{number}")

    assert %{"number" => ^number, "title" => "Add pull request support"} =
             json_response(show_conn, 200)

    update_conn =
      patch(conn, "/api/v1/repos/#{target.owner}/#{target.name}/pulls/#{number}", %{
        title: "Ship pull request support",
        state: "closed",
        draft: false
      })

    assert %{
             "number" => ^number,
             "title" => "Ship pull request support",
             "state" => "closed",
             "draft" => false
           } = json_response(update_conn, 200)
  end

  test "POST /api/v1/repos/:owner/:repo/pulls rejects a disabled repository", %{conn: conn} do
    target = repository_fixture(%{pull_requests_enabled: false})
    conn = put_forge_api_token(conn, "pull-request-disabled", target)

    conn =
      post(conn, "/api/v1/repos/#{target.owner}/#{target.name}/pulls", %{
        title: "Cannot open",
        head_repository: "#{target.owner}/#{target.name}",
        head: "main"
      })

    assert %{"message" => "Pull requests are disabled for this repository."} =
             json_response(conn, 409)
  end

  test "POST /api/v1/repos/:owner/:repo/pulls requires a bearer token", %{conn: conn} do
    repository = repository_fixture()

    conn =
      post(conn, "/api/v1/repos/#{repository.owner}/#{repository.name}/pulls", %{
        title: "Unauthenticated pull request"
      })

    assert %{"error" => "invalid_api_token"} = json_response(conn, 401)
  end

  test "GET /api/v1/repos/:owner/:repo/pulls lists pull requests", %{conn: conn} do
    repository = repository_fixture()

    conn =
      get(conn, "/api/v1/repos/#{repository.owner}/#{repository.name}/pulls")

    assert [] == json_response(conn, 200)
  end

  test "PATCH /api/v1/repos/:owner/:repo updates the owner pull request setting", %{conn: conn} do
    repository = repository_fixture()
    conn = put_forge_api_token(conn, "pull-request-settings", repository)

    conn =
      patch(conn, "/api/v1/repos/#{repository.owner}/#{repository.name}", %{
        pull_requests_enabled: false
      })

    assert %{"pull_requests_enabled" => false} = json_response(conn, 200)
  end

  test "PATCH /api/v1/repos/:owner/:repo requires an owner", %{conn: conn} do
    repository = repository_fixture()
    conn = put_forge_api_token(conn, "pull-request-nonowner")

    conn =
      patch(conn, "/api/v1/repos/#{repository.owner}/#{repository.name}", %{
        pull_requests_enabled: false
      })

    assert %{"code" => "forbidden"} = json_response(conn, 403)
  end

  defp seed_repository(repository) do
    path = Repos.ensure_repo!(repository.storage_key, repository.default_branch)
    blob = git!(path, ["hash-object", "-w", "--stdin"], "fixture\n")
    tree = git!(path, ["mktree"], "100644 blob #{blob}\tREADME.md\n")

    commit =
      git!(path, ["commit-tree", tree, "-m", "Seed repository"], "",
        env: [
          {"GIT_AUTHOR_NAME", "Test Author"},
          {"GIT_AUTHOR_EMAIL", "author@example.test"},
          {"GIT_COMMITTER_NAME", "Test Author"},
          {"GIT_COMMITTER_EMAIL", "author@example.test"}
        ]
      )

    {_, 0} = Repos.git(path, ["update-ref", "refs/heads/main", commit])
    :ok
  end

  defp git!(git_dir, args, input, options \\ []) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "pull-request-controller-input-#{System.unique_integer([:positive])}"
      )

    File.write!(input_path, input)

    try do
      {output, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(exec git --git-dir "$GIT_DIR" "$@" < "$INPUT"), "sh"] ++ args,
          env: [{"GIT_DIR", git_dir}, {"INPUT", input_path}] ++ Keyword.get(options, :env, [])
        )

      String.trim(output)
    after
      File.rm(input_path)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)
end
