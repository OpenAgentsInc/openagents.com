defmodule OpenAgentsWeb.ApiErrorTest do
  use OpenAgentsWeb.ConnCase, async: true

  alias OpenAgentsWeb.ApiError

  describe "the envelope" do
    test "carries the same six keys whatever the failure is", %{conn: conn} do
      for {code, status} <- ApiError.codes() do
        body =
          conn
          |> ApiError.refuse(code)
          |> json_response(status)

        assert Map.keys(body) |> Enum.sort() ==
                 ~w(code documentation_url errors message request_id status)

        assert body["code"] == code
        assert body["status"] == status
        assert is_binary(body["message"])
        assert is_map(body["errors"])
      end
    end

    test "maps every stable code to exactly one status" do
      codes = ApiError.codes()

      assert codes["not_found"] == 404
      assert codes["forbidden"] == 403
      assert codes["validation_failed"] == 422
      assert codes["unauthenticated"] == 401
    end

    test "reports the request ID the endpoint assigned", %{conn: conn} do
      body =
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "lane82-request")
        |> ApiError.refuse("not_found")
        |> json_response(404)

      assert body["request_id"] == "lane82-request"
    end

    test "overrides the default message without changing the code", %{conn: conn} do
      body =
        conn
        |> ApiError.refuse("not_found", message: "Label does not exist on this issue")
        |> json_response(404)

      assert body["message"] == "Label does not exist on this issue"
      assert body["code"] == "not_found"
    end

    test "carries field errors as a field-to-messages map", %{conn: conn} do
      body =
        conn
        |> ApiError.validation_failed(%{state: ["must be one of: open, closed, all"]})
        |> json_response(422)

      assert body["errors"] == %{"state" => ["must be one of: open, closed, all"]}
      assert body["code"] == "validation_failed"
      assert body["message"] == "Validation Failed"
    end

    test "translates a changeset into the same field-to-messages map", %{conn: conn} do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      body = conn |> ApiError.changeset(changeset) |> json_response(422)

      assert body["errors"] == %{"title" => ["can't be blank"]}
      assert body["code"] == "validation_failed"
    end

    test "interpolates changeset message placeholders", %{conn: conn} do
      changeset =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{title: String.duplicate("a", 5)}, [:title])
        |> Ecto.Changeset.validate_length(:title, max: 3)

      body = conn |> ApiError.changeset(changeset) |> json_response(422)

      assert body["errors"]["title"] == ["should be at most 3 character(s)"]
    end

    test "keeps a legacy key beside the envelope when a client already reads it", %{conn: conn} do
      body =
        conn
        |> ApiError.refuse("agent_participation_forbidden",
          legacy: %{"error" => %{"code" => "agent_participation_forbidden"}}
        )
        |> json_response(403)

      assert body["error"] == %{"code" => "agent_participation_forbidden"}
      assert body["code"] == "agent_participation_forbidden"
      assert body["status"] == 403
    end

    test "refuses an unknown code rather than inventing a status", %{conn: conn} do
      assert_raise ArgumentError, fn -> ApiError.refuse(conn, "no_such_code") end
    end

    test "points documentation_url at the published contract", %{conn: conn} do
      body = conn |> ApiError.refuse("not_found") |> json_response(404)

      assert body["documentation_url"] =~ "/api/v1"
    end
  end
end
