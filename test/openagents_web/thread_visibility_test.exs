defmodule OpenAgentsWeb.ThreadVisibilityTest do
  @moduledoc """
  THREAD-002 at the two doors a thread is read through: the API and the web
  transcript viewer.

  Both doors answer the same three questions the same way — an owner reads
  their own thread, a reader admitted by the thread's tier reads it without the
  owner's budget, and a stranger at an owner-only thread gets the plain 404
  that never confirms the thread exists.
  """
  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Threads

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  describe "POST /api/v1/threads" do
    test "a thread opens owner-only when the caller names no tier", %{conn: conn} do
      thread =
        conn
        |> put_chat_api_token("visibility-default")
        |> post(~p"/api/v1/threads", %{"objective" => "Keep it to myself."})
        |> json_response(201)
        |> Map.fetch!("thread")

      assert thread["visibility"] == "dark"
    end

    test "an explicit tier is accepted and published", %{conn: conn} do
      thread =
        conn
        |> put_chat_api_token("visibility-explicit")
        |> post(~p"/api/v1/threads", %{
          "objective" => "Share the transcript.",
          "visibility" => "ledger"
        })
        |> json_response(201)
        |> Map.fetch!("thread")

      assert thread["visibility"] == "ledger"
      assert thread["event_count"] == 2
    end

    test "an unknown tier is refused with its own code, not a bare 422", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("visibility-unknown")
        |> post(~p"/api/v1/threads", %{
          "objective" => "Widen me.",
          "visibility" => "public"
        })
        |> assert_api_error(422, nil)

      assert body["code"] == "thread_visibility_unsupported"
      assert body["message"] =~ "\"public\" is not an admitted thread visibility"
      assert body["message"] =~ "Admitted: dark, ledger"
      assert body["errors"]["visibility"] != nil
    end

    test "a tier this surface cannot enforce is refused the same way", %{conn: conn} do
      for tier <- ~w(pulse glass) do
        body =
          conn
          |> put_chat_api_token("visibility-unenforceable-" <> tier)
          |> post(~p"/api/v1/threads", %{"objective" => "Widen me.", "visibility" => tier})
          |> assert_api_error(422, nil)

        assert body["code"] == "thread_visibility_unsupported"
      end
    end

    test "a non-string tier is refused as a field error", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("visibility-nonstring")
        |> post(~p"/api/v1/threads", %{"objective" => "Widen me.", "visibility" => 3})
        |> assert_api_error(422, nil)

      assert body["code"] == "validation_failed"
      assert body["errors"]["visibility"] != nil
    end
  end

  describe "GET /api/v1/threads/{thread_id}" do
    test "a reader admitted by the tier reads the thread without the owner's grant", %{conn: conn} do
      {:ok, thread} =
        Threads.open(github_user("api-wide-owner"), "Shared work", visibility: "ledger")

      body =
        conn
        |> put_chat_api_token("api-wide-reader")
        |> get(~p"/api/v1/threads/#{thread.id}")
        |> json_response(200)

      assert body["thread"]["id"] == thread.id
      assert body["thread"]["visibility"] == "ledger"
      # The tier discloses the transcript. It does not disclose what the
      # owner's account is spending.
      assert body["grant"] == nil
    end

    test "the owner still reads their own grant", %{conn: conn} do
      conn = put_chat_api_token(conn, "api-owner-grant")

      thread =
        conn
        |> post(~p"/api/v1/threads", %{
          "objective" => "Shared work.",
          "visibility" => "ledger"
        })
        |> json_response(201)
        |> Map.fetch!("thread")

      body = conn |> get(~p"/api/v1/threads/#{thread["id"]}") |> json_response(200)

      assert body["grant"]["status"] == "active"
    end

    test "a stranger at an owner-only thread gets the plain 404", %{conn: conn} do
      {:ok, thread} = Threads.open(github_user("api-dark-owner"), "Private work")

      assert conn
             |> put_chat_api_token("api-dark-stranger")
             |> get(~p"/api/v1/threads/#{thread.id}")
             |> api_error_code(404) == "not_found"
    end

    test "the transcript follows the same tier as the thread", %{conn: conn} do
      owner = github_user("api-events-owner")
      {:ok, wide} = Threads.open(owner, "Shared work", visibility: "ledger")
      {:ok, _wide} = Threads.record_event(wide, "tool.ran", %{"tool" => "bash"})
      {:ok, dark} = Threads.open(owner, "Private work")

      reader = put_chat_api_token(conn, "api-events-reader")

      body = reader |> get(~p"/api/v1/threads/#{wide.id}/events") |> json_response(200)
      assert Enum.any?(body["events"], &(&1["event_type"] == "tool.ran"))

      assert reader |> get(~p"/api/v1/threads/#{dark.id}/events") |> api_error_code(404) ==
               "not_found"
    end

    test "a wider tier widens reads only: a reader cannot write, cancel, or re-mint", %{
      conn: conn
    } do
      {:ok, thread} =
        Threads.open(github_user("api-fence-owner"), "Shared work", visibility: "ledger")

      reader = put_chat_api_token(conn, "api-fence-reader")

      assert reader
             |> post(~p"/api/v1/threads/#{thread.id}/events", %{
               "event_type" => "turn.user",
               "payload" => %{"text" => "not yours"}
             })
             |> api_error_code(404) == "not_found"

      assert reader
             |> post(~p"/api/v1/threads/#{thread.id}/grants", %{})
             |> api_error_code(404) == "not_found"

      assert reader |> delete(~p"/api/v1/threads/#{thread.id}") |> api_error_code(404) ==
               "not_found"

      assert Threads.get_for_user(github_user("api-fence-owner"), thread.id).status == "open"
    end
  end

  describe "/threads/:id" do
    test "the owner sees the tier and their own budget", %{conn: conn} do
      owner = github_user("live-owner")
      {:ok, thread} = Threads.open(owner, "Private work")
      {:ok, _thread, _grant, _token} = Threads.mint_grant(thread)

      {:ok, view, _html} = live(signed_in(conn, owner), ~p"/threads/#{thread.id}")

      assert view |> element("#thread-visibility") |> render() =~ "dark"
      assert has_element?(view, "#thread-budget")
    end

    test "a reader admitted by the tier reads the transcript without the budget", %{conn: conn} do
      owner = github_user("live-wide-owner")
      {:ok, thread} = Threads.open(owner, "Shared work", visibility: "ledger")
      {:ok, thread} = Threads.record_event(thread, "turn.user", %{"text" => "Fix the parser"})
      {:ok, _thread, _grant, _token} = Threads.mint_grant(thread)

      reader = github_user("live-wide-reader")
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/threads/#{thread.id}")

      assert render(view) =~ "Fix the parser"
      assert view |> element("#thread-visibility") |> render() =~ "ledger"
      refute has_element?(view, "#thread-budget")
    end

    test "a stranger at an owner-only thread gets the same 404 as a missing one", %{conn: conn} do
      {:ok, thread} = Threads.open(github_user("live-dark-owner"), "Private work")
      stranger = signed_in(conn, github_user("live-dark-stranger"))

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(stranger, ~p"/threads/#{thread.id}")
      end

      assert_raise OpenAgentsWeb.PublicNotFoundError, fn ->
        live(stranger, ~p"/threads/#{Ecto.UUID.generate()}")
      end
    end
  end
end
