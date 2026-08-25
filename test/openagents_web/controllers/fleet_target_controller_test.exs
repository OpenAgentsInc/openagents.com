defmodule OpenAgentsWeb.FleetTargetControllerTest do
  @moduledoc """
  The operator-only fleet promotion API.

  Two conditions authorize every request and neither substitutes for the
  other: the exact `deployments:promote` scope, and live operator standing.
  A tenant credential — including one holding every other scope in the
  system — never reaches this surface.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import OpenAgents.ForgePromotionFixtures

  alias OpenAgents.ApiTokens
  alias OpenAgents.Forge.{Target, Targets}
  alias OpenAgents.Repo
  alias OpenAgentsWeb.ApiError

  @repo "openagents.com"
  @create "/api/v1/admin/forge/targets"

  setup do
    isolate_forge_storage!()
    :ok
  end

  defp body(sha, overrides \\ %{}) do
    Map.merge(
      %{
        "environment" => "production",
        "idempotency_key" => "key-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        "repo" => @repo,
        "sha" => sha
      },
      overrides
    )
  end

  defp operator_conn(conn, key) do
    operator = operator_fixture(key)
    {put_promotion_api_token(conn, operator), operator}
  end

  test "an operator promotes an exact pushed SHA and gets a status URL back", %{conn: conn} do
    {conn, operator} = operator_conn(conn, "api-promote-operator")
    sha = seeded_commit(@repo)

    conn = post(conn, @create, body(sha))
    response = json_response(conn, 202)

    assert response["sha"] == sha
    assert response["repo"] == @repo
    assert response["status"] == "promoted"
    assert response["environment"] == "production"
    assert response["source"] == "api"
    assert response["promoted_by"] == "operator:#{operator.github_id}"
    assert response["replayed"] == false
    assert response["terminal"] == false
    assert is_binary(response["request_id"])
    assert response["status_url"] =~ "/api/v1/admin/forge/targets/#{response["id"]}"

    assert Targets.current(@repo).id == response["id"]
  end

  test "the promoted target is readable and listable through the same credential", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-read")
    sha = seeded_commit(@repo)

    created = conn |> post(@create, body(sha)) |> json_response(202)

    shown = conn |> get("#{@create}/#{created["id"]}") |> json_response(200)
    assert shown["id"] == created["id"]
    assert shown["sha"] == sha

    listed = conn |> get(@create) |> json_response(200)
    assert listed["repo"] == @repo
    assert Enum.map(listed["targets"], & &1["id"]) == [created["id"]]
  end

  test "a status response names no node, path, or credential", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-bounded")
    sha = seeded_commit(@repo)

    created = conn |> post(@create, body(sha)) |> json_response(202)

    # A real target carries the rolling authority RELEASE-006 publishes, which
    # names every expected node. The status projection must show the lifecycle
    # without disclosing the fleet.
    {:ok, _advanced} =
      Targets.advance(created["id"], "failed", %{
        "error_code" => "build_failed",
        "rolling_authority" => %{
          "schema" => "openagents.forge.rolling-authority.v1",
          "expected_nodes" => ["openagents@10.0.0.4"]
        },
        "workspace_path" => "/var/lib/openagents/builds/17"
      })

    shown = conn |> get("#{@create}/#{created["id"]}") |> json_response(200)

    assert shown["status"] == "failed"
    assert shown["terminal"] == true
    assert shown["error_code"] == "build_failed"
    refute Jason.encode!(shown) =~ "10.0.0.4"
    refute Jason.encode!(shown) =~ "/var/lib/openagents"
    refute Jason.encode!(shown) =~ "rolling_authority"
  end

  test "an anonymous caller is refused before the controller runs", %{conn: conn} do
    sha = seeded_commit(@repo)

    refused = conn |> post(@create, body(sha)) |> json_response(401)

    assert Enum.sort(Map.keys(refused) -- ["error"]) == Enum.sort(ApiError.envelope_keys())
    assert code(refused) == "unauthenticated"
    assert refused["status"] == 401
    assert refused["error"] == "invalid_api_token"

    assert conn |> get(@create) |> json_response(401)
    assert Repo.aggregate(Target, :count) == 0
  end

  test "a token holding every other scope cannot promote", %{conn: conn} do
    user = promotion_user_fixture("api-promote-every-other-scope")
    sha = seeded_commit(@repo)

    conn = put_unprivileged_api_token(conn, user)

    assert conn |> post(@create, body(sha)) |> json_response(401)
    assert Repo.aggregate(Target, :count) == 0
  end

  test "a forge:write token cannot promote", %{conn: conn} do
    sha = seeded_commit(@repo)
    conn = put_forge_api_token(conn, "api-promote-forge-write")

    assert conn |> post(@create, body(sha)) |> json_response(401)
    assert Repo.aggregate(Target, :count) == 0
  end

  test "a deployments:write token cannot promote", %{conn: conn} do
    user = promotion_user_fixture("api-promote-deployments-write")
    sha = seeded_commit(@repo)
    conn = put_deployments_api_token(conn, user)

    assert conn |> post(@create, body(sha)) |> json_response(401)
    assert Repo.aggregate(Target, :count) == 0
  end

  test "an ordinary account cannot be issued the promotion scope at all" do
    user = promotion_user_fixture("api-promote-issuance")

    assert {:error, :invalid_api_token} =
             ApiTokens.create(user, %{
               name: "release",
               scopes: ["deployments:promote"],
               lifetime_days: 1
             })
  end

  test "a privileged credential has a shorter maximum lifetime than forge:write" do
    operator = operator_fixture("api-promote-lifetime")

    assert {:error, :invalid_api_token} =
             ApiTokens.create(operator, %{
               name: "too long",
               scopes: ["deployments:promote"],
               lifetime_days: 30
             })

    assert {:ok, _credential, _plaintext} =
             ApiTokens.create(operator, %{
               name: "release",
               scopes: ["deployments:promote"],
               lifetime_days: 7
             })

    assert {:ok, _credential, _plaintext} =
             ApiTokens.create(operator, %{
               name: "ordinary",
               scopes: ["forge:write"],
               lifetime_days: 90
             })
  end

  test "removing the operator invalidates an existing privileged token", %{conn: conn} do
    {conn, operator} = operator_conn(conn, "api-promote-revoked")
    first = seeded_commit(@repo, "first")
    second = seeded_commit(@repo, "second")

    assert conn |> post(@create, body(first)) |> json_response(202)

    revoke_operator(operator)

    refused = conn |> post(@create, body(second)) |> json_response(403)
    assert code(refused) == "not_operator"
    assert refused["status"] == 403
    assert conn |> get(@create) |> json_response(403)
    assert Repo.aggregate(Target, :count) == 1
  end

  test "a revoked credential is refused", %{conn: conn} do
    operator = operator_fixture("api-promote-revoked-token")
    sha = seeded_commit(@repo)

    {:ok, credential, plaintext} =
      ApiTokens.create(operator, %{
        name: "release",
        scopes: ["deployments:promote"],
        lifetime_days: 1
      })

    {:ok, _revoked} = ApiTokens.revoke(operator, credential.id)

    conn = put_req_header(conn, "authorization", "Bearer " <> plaintext)

    assert conn |> post(@create, body(sha)) |> json_response(401)
  end

  test "a malformed credential is refused", %{conn: conn} do
    sha = seeded_commit(@repo)
    conn = put_req_header(conn, "authorization", "Bearer oa_pat_not-a-real-token")

    assert conn |> post(@create, body(sha)) |> json_response(401)
  end

  test "branches, abbreviations, unknown commits, and foreign repositories are refused", %{
    conn: conn
  } do
    {conn, _operator} = operator_conn(conn, "api-promote-exactness")
    sha = seeded_commit(@repo)

    branch = conn |> post(@create, body("main")) |> json_response(422)
    assert code(branch) == "validation_failed"
    assert branch["errors"]["sha"] == ["must be one full 40-character commit SHA"]

    assert conn |> post(@create, body(String.slice(sha, 0, 12))) |> json_response(422) |> code() ==
             "validation_failed"

    assert conn
           |> post(@create, body(String.duplicate("b", 40)))
           |> json_response(422)
           |> code() == "unknown_commit"

    foreign =
      conn |> post(@create, body(sha, %{"repo" => "someone-elses-repo"})) |> json_response(422)

    assert code(foreign) == "validation_failed"
    assert foreign["errors"]["repo"] == ["has no fleet to promote to"]

    preview =
      conn |> post(@create, body(sha, %{"environment" => "preview"})) |> json_response(422)

    assert code(preview) == "validation_failed"
    assert preview["errors"]["environment"] == ["must be production"]

    assert Repo.aggregate(Target, :count) == 0
  end

  test "an idempotent retry returns one target and a conflicting retry is a 409", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-idempotent")
    sha = seeded_commit(@repo, "one")
    other = seeded_commit(@repo, "two")
    request = body(sha, %{"idempotency_key" => "release-2026-08-23-0007"})

    created = conn |> post(@create, request) |> json_response(202)
    replayed = conn |> post(@create, request) |> json_response(200)

    assert replayed["id"] == created["id"]
    assert replayed["replayed"] == true

    conflict = conn |> post(@create, %{request | "sha" => other}) |> json_response(409)
    assert code(conflict) == "idempotency_conflict"
    assert Repo.aggregate(Target, :count) == 1
  end

  test "a missing idempotency key is refused", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-missing-key")
    sha = seeded_commit(@repo)

    refused =
      conn |> post(@create, Map.delete(body(sha), "idempotency_key")) |> json_response(422)

    assert code(refused) == "validation_failed"

    assert refused["errors"] == %{
             "idempotency_key" => ["must be 8 to 255 characters, generated by the caller"]
           }

    assert Repo.aggregate(Target, :count) == 0
  end

  test "an expected-current-target precondition returns 409 once it is stale", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-precondition")
    first = seeded_commit(@repo, "first")
    second = seeded_commit(@repo, "second")
    third = seeded_commit(@repo, "third")

    original = conn |> post(@create, body(first)) |> json_response(202)

    assert conn
           |> post(@create, body(second, %{"expected_current_target_id" => original["id"]}))
           |> json_response(202)

    stale =
      conn
      |> post(@create, body(third, %{"expected_current_target_id" => original["id"]}))
      |> json_response(409)

    assert code(stale) == "precondition_failed"
    assert Repo.aggregate(Target, :count) == 2
  end

  test "an unknown target ID is a bounded 404", %{conn: conn} do
    {conn, _operator} = operator_conn(conn, "api-promote-missing-target")

    missing =
      conn
      |> get("#{@create}/00000000-0000-4000-8000-000000000001")
      |> json_response(404)

    assert code(missing) == "not_found"
    assert conn |> get("#{@create}/not-a-uuid") |> json_response(404) |> code() == "not_found"
  end

  defp code(response), do: response["code"]
end
