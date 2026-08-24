defmodule OpenAgentsWeb.ThreadControllerTest do
  @moduledoc """
  The three routes that open, read, and revoke a thread.

  A thread is the unit of agent work (`docs/taxonomy.md`), and these routes are
  the only way a caller reaches one. They are also where the abuse controls
  live, so the refusals are tested as carefully as the successes.
  """
  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Inference
  alias OpenAgents.Inference.Credit
  alias OpenAgents.Inference.Grant
  alias OpenAgents.Repo
  alias OpenAgents.Threads

  describe "POST /api/v3/threads" do
    test "opens a thread and returns a grant that names it", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-open")
        |> post(~p"/api/v3/threads", %{"objective" => "Rename the fence."})
        |> json_response(201)

      assert %{"thread" => thread, "grant" => grant} = body
      assert thread["status"] == "open"
      assert thread["objective"] == "Rename the fence."
      assert thread["generation"] == 1
      assert is_binary(thread["id"])

      assert String.starts_with?(grant["token"], "sig_")
      assert grant["url"] =~ "/api/inference/proxy"
      assert grant["limits"]["max_calls"] == Threads.ceilings().max_calls
      assert grant["limits"]["max_total_tokens"] == Threads.ceilings().max_total_tokens
      # The cost ceiling is what this account has left of its credit, so
      # opening another thread does not mint another allowance.
      minted = Repo.get_by!(Grant, thread_id: thread["id"])
      assert grant["limits"]["max_cost_microusd"] == Credit.remaining(minted.owner_visitor_id)

      assert minted.conversation_id == nil
      assert minted.status == "active"
    end

    test "the thread's ceilings are its own, not the delegation ceilings", %{conn: conn} do
      grant =
        conn
        |> put_chat_api_token("thread-ceilings")
        |> post(~p"/api/v3/threads", %{"objective" => "Measure the budget."})
        |> json_response(201)
        |> Map.fetch!("grant")

      delegation = %{
        "max_calls" => Application.fetch_env!(:openagents, :inference_grant_max_calls),
        "max_total_tokens" =>
          Application.fetch_env!(:openagents, :inference_grant_max_total_tokens),
        "max_cost_microusd" =>
          Application.fetch_env!(:openagents, :inference_grant_max_cost_microusd)
      }

      refute grant["limits"] == delegation
    end

    test "a caller may narrow the admitted execution shape", %{conn: conn} do
      thread =
        conn
        |> put_chat_api_token("thread-shape")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Edit the file.",
          "reasoning" => "low",
          "permission_profile" => "workspace_write"
        })
        |> json_response(201)
        |> Map.fetch!("thread")

      assert thread["reasoning_effort"] == "low"
      assert thread["permission_profile"] == "workspace_write"
    end

    test "a caller may open a thread on another routed model", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-ox-alpha")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Delegate the edit.",
          "model" => "ox-alpha"
        })
        |> json_response(201)

      assert body["grant"]["model"] == "ox-alpha"
    end

    test "a thread names the default model when its caller names none", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-default-model")
        |> post(~p"/api/v3/threads", %{"objective" => "Take the default."})
        |> json_response(201)

      assert body["grant"]["model"] == OpenAgents.Inference.Models.default_id()
    end

    test "a model the proxy cannot route is refused, naming the field", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-bad-model")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Ask for the impossible.",
          "model" => "attacker/gpt-9-ultra"
        })
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "model")
    end

    test "an objective is required", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-no-objective")
        |> post(~p"/api/v3/threads", %{})
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "objective")
    end

    test "a reasoning effort outside the enum is refused rather than replaced", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-bad-reasoning")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Ask for the impossible.",
          "reasoning" => "not-a-legal-value"
        })
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "reasoning")
    end

    test "a permission profile outside the enum is refused", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-bad-profile")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Ask for the impossible.",
          "permission_profile" => "root"
        })
        |> json_response(422)

      assert Map.has_key?(body["errors"], "permission_profile")
    end

    test "opening more concurrent threads than the cap allows is refused", %{conn: conn} do
      limit = 2
      previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
      Application.put_env(:openagents, :maximum_open_threads_per_account, limit)

      on_exit(fn ->
        Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
      end)

      authenticated = put_chat_api_token(conn, "thread-cap")

      for index <- 1..limit do
        assert authenticated
               |> post(~p"/api/v3/threads", %{"objective" => "Concurrent #{index}."})
               |> json_response(201)
      end

      body =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "One too many."})
        |> json_response(429)

      assert body["code"] == "thread_quota_reached"
      assert body["message"] =~ "#{limit}"
      assert [message] = body["errors"]["threads"]
      assert message =~ "#{limit}"
    end

    # An account that has spent its credit has nothing to mint a grant against,
    # and a thread without authority is not a thread anyone can work, so the
    # refusal names the money rather than reading as a transient failure.
    test "an account that has spent its credit is refused with what it spent", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-credit")

      opened =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Spend it all."})
        |> json_response(201)

      grant = Repo.get_by!(Grant, thread_id: opened["thread"]["id"])
      allowance = Credit.allowance(grant.owner_visitor_id)
      price = Application.fetch_env!(:openagents, :inference_output_price_microusd_per_ktoken)

      {:ok, _metered} =
        Inference.record_usage(grant, %{"output_tokens" => div(allowance, price) * 1_000})

      assert Credit.remaining(grant.owner_visitor_id) == 0

      body =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "One more, on empty."})
        |> json_response(402)

      assert body["code"] == "credit_exhausted"
      assert body["message"] =~ "$100.00"
      assert [message] = body["errors"]["credit"]
      assert message =~ "$100.00"
    end

    test "the cap counts one account's threads, never another's", %{conn: conn} do
      previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
      Application.put_env(:openagents, :maximum_open_threads_per_account, 1)

      on_exit(fn ->
        Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
      end)

      assert conn
             |> put_chat_api_token("thread-cap-mine")
             |> post(~p"/api/v3/threads", %{"objective" => "Mine."})
             |> json_response(201)

      assert conn
             |> put_chat_api_token("thread-cap-yours")
             |> post(~p"/api/v3/threads", %{"objective" => "Yours."})
             |> json_response(201)
    end

    test "an anonymous caller is refused with the envelope", %{conn: conn} do
      body = conn |> post(~p"/api/v3/threads", %{"objective" => "No."}) |> json_response(401)

      assert body["code"] == "unauthenticated"
      assert is_map(body["errors"])
    end
  end

  describe "GET /api/v3/threads/:thread_id" do
    test "reports status and usage against the ceiling", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-read")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Report on me."})
        |> json_response(201)

      id = created["thread"]["id"]
      grant = Repo.get_by!(Grant, thread_id: id)
      {:ok, _spent} = Inference.record_usage(grant, %{"input_tokens" => 10, "output_tokens" => 5})

      body = authenticated |> get(~p"/api/v3/threads/#{id}") |> json_response(200)

      assert body["thread"]["status"] == "open"
      assert body["grant"]["status"] == "active"
      assert body["grant"]["call_count"] == 1
      assert body["grant"]["usage"]["total_tokens"] == 15
      assert body["grant"]["limits"]["max_total_tokens"] == Threads.ceilings().max_total_tokens
      assert body["grant"]["remaining"]["calls"] == Threads.ceilings().max_calls - 1

      assert body["grant"]["remaining"]["total_tokens"] ==
               Threads.ceilings().max_total_tokens - 15

      refute Map.has_key?(body["grant"], "token")
    end

    test "another account's thread is not found", %{conn: conn} do
      created =
        conn
        |> put_chat_api_token("thread-owner")
        |> post(~p"/api/v3/threads", %{"objective" => "Private work."})
        |> json_response(201)

      body =
        conn
        |> put_chat_api_token("thread-stranger")
        |> get(~p"/api/v3/threads/#{created["thread"]["id"]}")
        |> json_response(404)

      assert body["code"] == "not_found"
      assert body["message"] == "Not Found"
    end

    test "an unknown id and another account's id refuse identically", %{conn: conn} do
      created =
        conn
        |> put_chat_api_token("thread-owner-two")
        |> post(~p"/api/v3/threads", %{"objective" => "Private work."})
        |> json_response(201)

      stranger = put_chat_api_token(conn, "thread-stranger-two")

      theirs =
        stranger |> get(~p"/api/v3/threads/#{created["thread"]["id"]}") |> json_response(404)

      absent =
        stranger
        |> get(~p"/api/v3/threads/00000000-0000-4000-8000-000000000001")
        |> json_response(404)

      assert Map.drop(theirs, ["request_id"]) == Map.drop(absent, ["request_id"])
    end

    test "an expired grant is reported as expired without anyone revoking it", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-expiry-read")
      elapsed_ttl()

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Outlive me."})
        |> json_response(201)

      body =
        authenticated
        |> get(~p"/api/v3/threads/#{created["thread"]["id"]}")
        |> json_response(200)

      assert body["grant"]["status"] == "expired"
      assert body["thread"]["status"] == "failed"
      assert body["thread"]["error_code"] == "authority_expired"
      assert {:error, :grant_expired} = Inference.resolve(created["grant"]["token"])
    end

    test "an expired thread releases the slot the cap counts", %{conn: conn} do
      cap(1)
      restore_ttl = elapsed_ttl()
      authenticated = put_chat_api_token(conn, "thread-expiry-cap")

      # This thread's authority has already elapsed, but the row is open and
      # nobody has said anything about it.
      first =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "First."})
        |> json_response(201)

      assert Threads.open_count(github_user("api-token-thread-expiry-cap")) == 1

      restore_ttl.()

      second =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Second."})
        |> json_response(201)

      retired =
        authenticated
        |> get(~p"/api/v3/threads/#{first["thread"]["id"]}")
        |> json_response(200)

      assert retired["thread"]["status"] == "failed"
      assert retired["thread"]["error_code"] == "authority_expired"

      # The second thread's authority has not elapsed, so it still holds the
      # only slot and the cap still bites.
      refused =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Third."})
        |> json_response(429)

      assert refused["code"] == "thread_quota_reached"
      assert second["grant"]["token"] != first["grant"]["token"]
    end
  end

  describe "DELETE /api/v3/threads/:thread_id" do
    test "revokes the grant immediately", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-revoke")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Stop me."})
        |> json_response(201)

      id = created["thread"]["id"]
      token = created["grant"]["token"]
      assert {:ok, _usable} = Inference.resolve(token)

      body = authenticated |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)

      assert body["thread"]["status"] == "cancelled"
      assert body["grant"]["status"] == "revoked"
      assert {:error, :grant_revoked} = Inference.resolve(token)
      assert Threads.active_grants(%OpenAgents.Threads.Thread{id: id}) == []
    end

    test "revoking twice leaves the thread terminal", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-revoke-twice")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Stop me twice."})
        |> json_response(201)

      id = created["thread"]["id"]
      assert authenticated |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)
      body = authenticated |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)

      assert body["thread"]["status"] == "cancelled"
      assert body["grant"]["status"] == "revoked"
    end

    test "another account cannot revoke a thread it did not open", %{conn: conn} do
      created =
        conn
        |> put_chat_api_token("thread-revoke-owner")
        |> post(~p"/api/v3/threads", %{"objective" => "Mine alone."})
        |> json_response(201)

      body =
        conn
        |> put_chat_api_token("thread-revoke-stranger")
        |> delete(~p"/api/v3/threads/#{created["thread"]["id"]}")
        |> json_response(404)

      assert body["code"] == "not_found"
      assert {:ok, _still_usable} = Inference.resolve(created["grant"]["token"])
    end
  end

  describe "spending a thread's grant" do
    test "the grant reaches the model exactly as a conversation-fenced one does", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-spend")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Answer one question."})
        |> json_response(201)

      proxied =
        conn
        |> put_req_header("authorization", "Bearer #{created["grant"]["token"]}")
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/inference/proxy",
          Jason.encode!(%{
            "model" => "ignored-by-proxy",
            "messages" => [%{"role" => "user", "content" => "hello there"}],
            "stream" => true
          })
        )

      assert proxied.status == 200

      body = authenticated |> get(~p"/api/v3/threads/#{created["thread"]["id"]}")
      grant = json_response(body, 200)["grant"]

      assert grant["call_count"] == 1
      assert grant["usage"]["total_tokens"] > 0
    end

    test "a revoked thread's grant no longer reaches the model", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-spend-revoked")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Answer, then stop."})
        |> json_response(201)

      assert authenticated
             |> delete(~p"/api/v3/threads/#{created["thread"]["id"]}")
             |> json_response(200)

      proxied =
        conn
        |> put_req_header("authorization", "Bearer #{created["grant"]["token"]}")
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/inference/proxy",
          Jason.encode!(%{
            "messages" => [%{"role" => "user", "content" => "hello there"}]
          })
        )

      assert proxied.status == 403
    end
  end

  defp cap(limit) do
    previous = Application.get_env(:openagents, :maximum_open_threads_per_account)
    Application.put_env(:openagents, :maximum_open_threads_per_account, limit)

    on_exit(fn ->
      Application.put_env(:openagents, :maximum_open_threads_per_account, previous)
    end)
  end

  # A grant's expiry is immutable once minted, which is the point: nothing can
  # move a clock it has already committed to. So the TTL is set before the mint
  # rather than the row edited after it, and the returned function puts the
  # configured TTL back.
  defp elapsed_ttl do
    previous = Application.get_env(:openagents, :thread_grant_ttl_seconds)
    Application.put_env(:openagents, :thread_grant_ttl_seconds, -1)
    restore = fn -> Application.put_env(:openagents, :thread_grant_ttl_seconds, previous) end
    on_exit(restore)
    restore
  end

  describe "a thread's transcript" do
    setup %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-transcript")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Remember me."})
        |> json_response(201)

      %{authenticated: authenticated, id: created["thread"]["id"]}
    end

    test "records an event and advances the count", %{authenticated: conn, id: id} do
      before = conn |> get(~p"/api/v3/threads/#{id}") |> json_response(200)

      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "event_type" => "turn.user",
          "payload" => %{"text" => "list the open issues"}
        })
        |> json_response(201)

      # Opening a thread records its own lifecycle event, so the count is a
      # delta rather than a total.
      assert body["thread"]["event_count"] == before["thread"]["event_count"] + 1
    end

    test "reads the transcript back, oldest first", %{authenticated: conn, id: id} do
      for text <- ["first", "second", "third"] do
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "event_type" => "turn.user",
          "payload" => %{"text" => text}
        })
        |> json_response(201)
      end

      body = conn |> get(~p"/api/v3/threads/#{id}/events") |> json_response(200)

      # The server's copy is the only copy: a client reads this back rather than
      # keeping its own, so two machines on one thread see one transcript.
      texts =
        body["events"]
        |> Enum.filter(&(&1["event_type"] == "turn.user"))
        |> Enum.map(& &1["payload"]["text"])

      assert texts == ["first", "second", "third"]
      assert Enum.all?(body["events"], &(&1["schema"] == "openagents.thread.event.v1"))
    end

    test "continues from an event already read", %{authenticated: conn, id: id} do
      for text <- ["one", "two", "three"] do
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "event_type" => "turn.user",
          "payload" => %{"text" => text}
        })
        |> json_response(201)
      end

      first = conn |> get(~p"/api/v3/threads/#{id}/events?limit=2") |> json_response(200)
      cursor = List.last(first["events"])["id"]

      rest = conn |> get(~p"/api/v3/threads/#{id}/events?after=#{cursor}") |> json_response(200)

      # A working session records a turn and every tool it ran, which passes
      # the listing cap inside an hour. Without a cursor its history could not
      # be read back at all.
      assert length(first["events"]) == 2
      assert Enum.all?(rest["events"], &(&1["id"] > cursor))
      assert Enum.map(rest["events"], & &1["payload"]["text"]) |> List.last() == "three"
    end

    test "records a payload far larger than the old ceiling", %{authenticated: conn, id: id} do
      # A single reasoning block observed in a live session is 38,791
      # characters. Under the inherited 16 KB ceiling the only way to record one
      # was to split it and reassemble it on every read.
      reasoning = String.duplicate("thinking about the problem. ", 2_000)
      assert byte_size(reasoning) > 16_384

      conn
      |> post(~p"/api/v3/threads/#{id}/events", %{
        "event_type" => "turn.reasoning",
        "payload" => %{"text" => reasoning}
      })
      |> json_response(201)

      body = conn |> get(~p"/api/v3/threads/#{id}/events") |> json_response(200)

      stored =
        body["events"]
        |> Enum.find(&(&1["event_type"] == "turn.reasoning"))
        |> get_in(["payload", "text"])

      # Stored whole, so the transcript reproduces the session rather than a
      # summary of it.
      assert stored == reasoning
    end

    test "accepts an event whose type is the whole of it", %{authenticated: conn, id: id} do
      # Some events carry nothing but their type, and the route defaults an
      # absent payload to an empty object. The remaining floor is that the
      # column holds valid JSON, not that the JSON is interesting.
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{"event_type" => "turn.started"})
        |> json_response(201)

      assert body["thread"]["event_count"] > 0
    end

    test "refuses an event with no type", %{authenticated: conn, id: id} do
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{"payload" => %{"text" => "x"}})
        |> json_response(422)

      assert body["errors"]["event_type"] != nil
    end

    test "refuses to append to a revoked thread", %{authenticated: conn, id: id} do
      conn |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)

      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{"event_type" => "turn.user"})
        |> json_response(422)

      # A transcript that keeps growing after the report was written is not the
      # transcript the report describes.
      assert body["code"] == "thread_terminal"
    end

    test "does not read another account's transcript", %{authenticated: conn, id: id} do
      conn
      |> post(~p"/api/v3/threads/#{id}/events", %{"event_type" => "turn.user"})
      |> json_response(201)

      stranger = put_chat_api_token(build_conn(), "thread-stranger")

      assert stranger |> get(~p"/api/v3/threads/#{id}/events") |> json_response(404)
    end
  end

  describe "GET /api/v3/threads" do
    test "lists the account's threads, newest first", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-index")

      for objective <- ["older", "newer"] do
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => objective})
        |> json_response(201)
      end

      body = authenticated |> get(~p"/api/v3/threads") |> json_response(200)

      # A client that outlives its process needs a way back to the work it was
      # doing, and the account is the only place that knows.
      assert Enum.map(body["threads"], & &1["objective"]) == ["newer", "older"]
    end

    test "does not list another account's threads", %{conn: conn} do
      put_chat_api_token(conn, "thread-mine")
      |> post(~p"/api/v3/threads", %{"objective" => "mine"})
      |> json_response(201)

      body =
        build_conn()
        |> put_chat_api_token("thread-theirs")
        |> get(~p"/api/v3/threads")
        |> json_response(200)

      assert body["threads"] == []
    end
  end
end
