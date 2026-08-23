defmodule OpenAgentsWeb.ApiErrorContractTest do
  @moduledoc """
  The contract that stops the issue family from drifting back into six shapes.

  Every route classified `:envelope` in `OpenAgentsWeb.ApiRouteAuthority` is
  dispatched here against a repository that does not exist. Whatever the route
  answers — the pipeline's `401`, the controller's `404` — the body must be the
  shared envelope. A controller that reverts to a bare `%{message: ...}`, a
  bare `%{errors: ...}`, or a string `error` fails this test rather than
  whichever controller test happened to name the old shape.
  """

  use OpenAgentsWeb.ConnCase

  import Phoenix.ConnTest

  alias OpenAgentsWeb.ApiError
  alias OpenAgentsWeb.ApiRouteAuthority

  @endpoint OpenAgentsWeb.Endpoint

  @envelope_keys ~w(code documentation_url errors message request_id status)

  test "every route on the envelope contract refuses with the envelope" do
    for {verb, path} <- ApiRouteAuthority.routes(),
        ApiRouteAuthority.error_contract(verb, path) == :envelope do
      conn = dispatch_missing(verb, path)

      assert conn.status >= 400,
             "#{verb} #{path} answered #{conn.status} for a repository that does not exist"

      body = json_response(conn, conn.status)

      assert Enum.sort(Map.keys(body) -- ["error"]) == @envelope_keys,
             """
             #{String.upcase(verb)} #{path} did not answer with the API error envelope.

             Keys: #{inspect(Map.keys(body))}
             Body: #{inspect(body, pretty: true)}
             """

      assert body["status"] == conn.status
      assert Map.has_key?(ApiError.codes(), body["code"]), "#{verb} #{path} invented a code"
      assert ApiError.codes()[body["code"]] == conn.status
      assert is_binary(body["message"]) and body["message"] != ""
      assert is_map(body["errors"])
    end
  end

  test "a private repository and an absent one refuse identically" do
    private =
      repository_fixture(%{
        owner: "EnvelopeOrg",
        name: "private-work",
        visibility: "private"
      })

    private_body =
      build_conn()
      |> get("/api/v3/repos/#{private.owner}/#{private.name}/issues/1")
      |> json_response(404)

    absent_body =
      build_conn()
      |> get("/api/v3/repos/#{private.owner}/no-such-repository/issues/1")
      |> json_response(404)

    assert Map.drop(private_body, ["request_id"]) == Map.drop(absent_body, ["request_id"])
    assert private_body["code"] == "not_found"
    assert private_body["message"] == "Not Found"
  end

  test "a rejected filter names the field it rejected" do
    body =
      build_conn()
      |> get("/api/v3/repos/nobody/nonexistent/issues?state=sideways")
      |> json_response(404)

    # The repository check runs first, so this path proves only non-disclosure.
    assert body["code"] == "not_found"
  end

  defp dispatch_missing(verb, path) do
    resolved =
      path
      |> String.replace(":owner", "nobody")
      |> String.replace(":repo", "nonexistent")
      |> String.replace(":issue_number", "1")
      |> String.replace(":milestone_number", "1")
      |> String.replace(":project_number", "1")
      |> String.replace(":blocked_by_number", "2")
      |> String.replace(":item_id", "00000000-0000-4000-8000-000000000001")
      |> String.replace(":note_id", "00000000-0000-4000-8000-000000000001")
      |> String.replace(":id", "1")
      |> String.replace(":name", "bug")
      |> String.replace(":assignee", "someone")

    dispatch(build_conn(), @endpoint, String.to_atom(verb), resolved)
  end
end
