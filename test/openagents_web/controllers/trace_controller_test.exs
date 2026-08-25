defmodule OpenAgentsWeb.TraceControllerTest do
  @moduledoc """
  Accept ATIF v1 trace uploads at `POST /api/v3/traces`.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Repo
  alias OpenAgents.Traces.Trace

  describe "POST /api/v3/traces" do
    test "returns the trace id and url for a valid ATIF v1.7 document", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("trace-valid")
        |> post(~p"/api/v3/traces", %{
          "schema_version" => "ATIF/1.7",
          "trace" => %{"events" => [%{"type" => "step"}]}
        })
        |> json_response(201)

      assert %{"id" => id, "url" => url} = body
      assert is_binary(id)
      assert url =~ "/api/v3/traces/#{id}"
      assert body["visibility"] == "dark"
      assert is_integer(body["byte_size"])
      assert is_binary(body["digest"])
      assert String.starts_with?(body["digest"], "sha256:")
    end

    test "returns the existing trace when the same owner uploads the same document again", %{
      conn: conn
    } do
      document = %{
        "schema_version" => "ATIF/1.7",
        "trace" => %{"events" => [%{"type" => "step"}]}
      }

      first =
        conn
        |> put_chat_api_token("trace-dedup")
        |> post(~p"/api/v3/traces", document)
        |> json_response(201)

      second =
        conn
        |> put_chat_api_token("trace-dedup")
        |> post(~p"/api/v3/traces", document)
        |> json_response(200)

      assert second["id"] == first["id"]
      assert second["digest"] == first["digest"]
      assert second["byte_size"] == first["byte_size"]
      assert Repo.aggregate(Trace, :count) == 1
    end

    test "refuses a body that exceeds the size ceiling", %{conn: conn} do
      big = String.duplicate("x", 10_485_761)

      body =
        conn
        |> put_chat_api_token("trace-oversize")
        |> post(~p"/api/v3/traces", %{
          "schema_version" => "ATIF/1.7",
          "data" => big
        })
        |> json_response(413)

      assert body["code"] == "trace_body_too_large"
    end

    test "rejects an unauthenticated call", %{conn: conn} do
      conn
      |> post(~p"/api/v3/traces", %{"schema_version" => "ATIF/1.7"})
      |> assert_api_error(401, "unauthenticated")
    end

    test "rejects an invalid ATIF schema_version", %{conn: conn} do
      conn =
        conn
        |> put_chat_api_token("trace-invalid")
        |> post(~p"/api/v3/traces", %{"schema_version" => "ATIF/2.0"})

      assert_api_error(conn, 422, "validation_failed",
        errors: %{"document" => ["The document is not a valid ATIF v1 object."]}
      )
    end

    test "rejects a document with no schema_version", %{conn: conn} do
      conn =
        conn
        |> put_chat_api_token("trace-no-version")
        |> post(~p"/api/v3/traces", %{"trace" => %{}})

      assert_api_error(conn, 422, "validation_failed")
    end

    test "uses dark visibility by default and allows an explicit tier", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("trace-visibility")
        |> post("/api/v3/traces?visibility=ledger", %{
          "schema_version" => "ATIF/1.7",
          "trace" => %{}
        })
        |> json_response(201)

      assert body["visibility"] == "ledger"
    end

    test "different owners uploading the same document get separate traces", %{conn: conn} do
      document = %{
        "schema_version" => "ATIF/1.7",
        "trace" => %{"events" => [%{"type" => "step"}]}
      }

      first =
        conn
        |> put_chat_api_token("trace-owner-one")
        |> post(~p"/api/v3/traces", document)
        |> json_response(201)

      second =
        conn
        |> put_chat_api_token("trace-owner-two")
        |> post(~p"/api/v3/traces", document)
        |> json_response(201)

      refute first["id"] == second["id"]
    end
  end
end
