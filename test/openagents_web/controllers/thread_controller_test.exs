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

    test "records the repository the opener names and returns it", %{conn: conn} do
      thread =
        conn
        |> put_chat_api_token("thread-repository")
        |> post(~p"/api/v3/threads", %{
          "objective" => "openagents coder in OpenAgentsInc/openagents.com on main",
          "repository" => "OpenAgentsInc/openagents.com"
        })
        |> json_response(201)
        |> Map.fetch!("thread")

      assert thread["repository"] == "OpenAgentsInc/openagents.com"
      # No foreign key and no format rule: a thread may concern a repository
      # the forge does not host, so the recorded string is the opener's own.
      assert Repo.get!(OpenAgents.Threads.Thread, thread["id"]).repository ==
               "OpenAgentsInc/openagents.com"
    end

    test "a thread without a repository records none and reports null", %{conn: conn} do
      thread =
        conn
        |> put_chat_api_token("thread-no-repository")
        |> post(~p"/api/v3/threads", %{"objective" => "No repository named."})
        |> json_response(201)
        |> Map.fetch!("thread")

      assert Map.fetch!(thread, "repository") == nil
    end

    test "a blank repository is refused rather than recorded as noise", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-blank-repository")
        |> post(~p"/api/v3/threads", %{"objective" => "Blank it.", "repository" => "   "})
        |> json_response(422)

      assert body["code"] == "validation_failed"
      assert Map.has_key?(body["errors"], "repository")
    end

    test "a repository over the bound is refused", %{conn: conn} do
      body =
        conn
        |> put_chat_api_token("thread-long-repository")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Bound it.",
          "repository" => String.duplicate("a", 201)
        })
        |> json_response(422)

      assert Map.has_key?(body["errors"], "repository")
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

    test "a catalog model whose provider is not configured is refused, never substituted",
         %{conn: conn} do
      previous = Application.get_env(:openagents, :openrouter_provider)

      Application.put_env(
        :openagents,
        :openrouter_provider,
        OpenAgents.Providers.UnconfiguredTestProvider
      )

      on_exit(fn -> Application.put_env(:openagents, :openrouter_provider, previous) end)

      body =
        conn
        |> put_chat_api_token("thread-unavailable-model")
        |> post(~p"/api/v3/threads", %{
          "objective" => "Ask for the unconfigured lane.",
          "model" => "ox-alpha"
        })
        |> json_response(503)

      assert body["code"] == "model_unavailable"
      assert Map.has_key?(body["errors"], "model")

      # The refusal names what is currently available. Unconfiguring this lane
      # takes every model on it, which is more than one now, so the check is
      # that each surviving model is named rather than that the default is —
      # the default may be on the lane that just went dark.
      available =
        Enum.filter(OpenAgents.Inference.Models.all(), &OpenAgents.Inference.Models.available?/1)

      assert available != []
      for model <- available, do: assert(body["message"] =~ model.id)
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
    test "reports usage, and reports no remainder where there is no ceiling", %{conn: conn} do
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
      # A thread's grant sets no call or token ceiling, so there is no
      # remainder to count down. `null` is what the client already reads as
      # "no limit"; a number here would have been invented.
      assert is_nil(Threads.ceilings().max_calls)
      assert is_nil(body["grant"]["limits"]["max_total_tokens"])
      assert is_nil(body["grant"]["remaining"]["calls"])
      assert is_nil(body["grant"]["remaining"]["total_tokens"])

      # Cost is still ceiled, at what the account's credit has left, and its
      # remainder is a real figure.
      assert body["grant"]["remaining"]["cost_microusd"] ==
               body["grant"]["limits"]["max_cost_microusd"] -
                 body["grant"]["usage"]["estimated_cost_microusd"]

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

    test "a thread's authority carries no deadline, so time alone does not end it", %{
      conn: conn
    } do
      # What this replaces: the grant expired on a wall clock, the thread was
      # closed as `authority_expired`, and a coding session that was mid-work
      # was told to start a new one because an hour had passed.
      authenticated = put_chat_api_token(conn, "thread-no-clock")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Outlive me."})
        |> json_response(201)

      body =
        authenticated
        |> get(~p"/api/v3/threads/#{created["thread"]["id"]}")
        |> json_response(200)

      assert body["grant"]["status"] == "active"
      assert body["thread"]["status"] == "open"
      assert is_nil(body["thread"]["error_code"])
      assert {:ok, _resolved} = Inference.resolve(created["grant"]["token"])
    end

    test "a thread left holding no authority reports it as spent, never as expired", %{
      conn: conn
    } do
      # The slot still has to come back — an open thread that can never work
      # again would hold the account's ceiling forever. What a reader is told
      # is that the authority was spent, which is true, rather than that it
      # expired, which is a concept this no longer has.
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
      assert body["thread"]["error_code"] == "authority_spent"
      refute body["thread"]["report"] =~ "expired"
    end

    test "the slot is released by revoking, not by waiting", %{conn: conn} do
      cap(1)
      authenticated = put_chat_api_token(conn, "thread-expiry-cap")

      first =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "First."})
        |> json_response(201)

      assert Threads.open_count(github_user("api-token-thread-expiry-cap")) == 1

      # Waiting does not free it. There is no clock to wait out.
      refused =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Second."})
        |> json_response(429)

      assert refused["code"] == "thread_quota_reached"

      # Saying so does.
      _deleted = authenticated |> delete(~p"/api/v3/threads/#{first["thread"]["id"]}")

      second =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Second."})
        |> json_response(201)

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
            "model" => created["grant"]["model"],
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

    test "returns the created event, whose id is the cursor", %{authenticated: conn, id: id} do
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "event_type" => "turn.user",
          "payload" => %{"text" => "echo me back"}
        })
        |> json_response(201)

      # A writer that never learns its event's id cannot continue from it or
      # dedup its own append against a later read, so the 201 carries the event
      # rather than only the thread it landed on.
      assert is_integer(body["event"]["id"])
      assert body["event"]["event_type"] == "turn.user"
      assert body["event"]["payload"] == %{"text" => "echo me back"}
      assert is_binary(body["event"]["inserted_at"])

      read = conn |> get(~p"/api/v3/threads/#{id}/events") |> json_response(200)
      assert List.last(read["events"])["id"] == body["event"]["id"]
    end

    test "refuses an event with no type", %{authenticated: conn, id: id} do
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{"payload" => %{"text" => "x"}})
        |> json_response(422)

      # The code is the machine's half of the refusal, symmetric with
      # `thread_terminal`: a client drops the event without parsing prose.
      assert body["code"] == "event_invalid"
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

    test "appends a batch in order and returns the created events", %{
      authenticated: conn,
      id: id
    } do
      before = conn |> get(~p"/api/v3/threads/#{id}") |> json_response(200)

      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "events" => [
            %{"event_type" => "turn.user", "payload" => %{"text" => "first"}},
            %{"event_type" => "tool.ran", "payload" => %{"tool" => "bash"}},
            %{"event_type" => "turn.assistant", "payload" => %{"text" => "third"}}
          ]
        })
        |> json_response(201)

      # A tool-heavy turn no longer costs one round trip per event, and the
      # created events come back in the order they landed so the writer learns
      # every id it just wrote.
      assert Enum.map(body["events"], & &1["event_type"]) ==
               ["turn.user", "tool.ran", "turn.assistant"]

      ids = Enum.map(body["events"], & &1["id"])
      assert ids == Enum.sort(ids)
      assert Enum.all?(body["events"], &is_binary(&1["inserted_at"]))
      assert body["thread"]["event_count"] == before["thread"]["event_count"] + 3

      read = conn |> get(~p"/api/v3/threads/#{id}/events") |> json_response(200)
      assert Enum.take(read["events"], -3) |> Enum.map(& &1["id"]) == ids
    end

    test "a batch with one invalid event records nothing", %{authenticated: conn, id: id} do
      before = conn |> get(~p"/api/v3/threads/#{id}") |> json_response(200)

      # The second entry passes the route's parse — its type is non-blank — and
      # is refused by the database's 80-character ceiling, so the refusal
      # proves the transaction rolled the first entry back with it.
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "events" => [
            %{"event_type" => "turn.user", "payload" => %{"text" => "landed?"}},
            %{"event_type" => String.duplicate("x", 81), "payload" => %{}}
          ]
        })
        |> json_response(422)

      assert body["code"] == "event_invalid"
      assert body["errors"]["events[1].event_type"] != nil

      after_refusal = conn |> get(~p"/api/v3/threads/#{id}") |> json_response(200)
      assert after_refusal["thread"]["event_count"] == before["thread"]["event_count"]
    end

    test "a batch entry with no type is refused naming its position", %{
      authenticated: conn,
      id: id
    } do
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "events" => [
            %{"event_type" => "turn.user"},
            %{"payload" => %{"text" => "no type"}}
          ]
        })
        |> json_response(422)

      assert body["code"] == "event_invalid"
      assert body["errors"]["events[1].event_type"] != nil
    end

    test "an empty batch is refused rather than answered created", %{
      authenticated: conn,
      id: id
    } do
      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{"events" => []})
        |> json_response(422)

      assert body["code"] == "event_invalid"
      assert body["errors"]["events"] != nil
    end

    test "a batch over the cap is refused with its own code", %{authenticated: conn, id: id} do
      previous = Application.get_env(:openagents, :maximum_thread_event_batch)
      Application.put_env(:openagents, :maximum_thread_event_batch, 2)

      on_exit(fn ->
        Application.put_env(:openagents, :maximum_thread_event_batch, previous)
      end)

      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "events" =>
            for index <- 1..3 do
              %{"event_type" => "turn.user", "payload" => %{"index" => index}}
            end
        })
        |> json_response(422)

      # Over the cap is not an invalid event — every entry may be well formed —
      # so it carries its own code, and the sentence names the split.
      assert body["code"] == "event_batch_too_large"
      assert body["message"] =~ "2"
      assert [sentence] = body["errors"]["events"]
      assert sentence =~ "3 events"
    end

    test "refuses a batch to a revoked thread as one refusal", %{authenticated: conn, id: id} do
      conn |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)

      body =
        conn
        |> post(~p"/api/v3/threads/#{id}/events", %{
          "events" => [
            %{"event_type" => "turn.user", "payload" => %{"text" => "late"}},
            %{"event_type" => "turn.assistant", "payload" => %{"text" => "later"}}
          ]
        })
        |> json_response(422)

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

    test "?repository= narrows the listing to that repository, exactly", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-repository-filter")

      for {objective, repository} <- [
            {"here", "OpenAgentsInc/openagents.com"},
            {"elsewhere", "OpenAgentsInc/openagents"},
            {"nowhere", nil}
          ] do
        authenticated
        |> post(
          ~p"/api/v3/threads",
          %{"objective" => objective}
          |> Map.merge(if repository, do: %{"repository" => repository}, else: %{})
        )
        |> json_response(201)
      end

      body =
        authenticated
        |> get(~p"/api/v3/threads?repository=OpenAgentsInc/openagents.com")
        |> json_response(200)

      # An exact match on the recorded field, so a resume picker filters
      # structurally instead of parsing the objective sentence back.
      assert Enum.map(body["threads"], & &1["objective"]) == ["here"]
      assert Enum.map(body["threads"], & &1["repository"]) == ["OpenAgentsInc/openagents.com"]

      unfiltered = authenticated |> get(~p"/api/v3/threads") |> json_response(200)
      assert length(unfiltered["threads"]) == 3
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

  describe "POST /api/v3/threads/:thread_id/grants" do
    test "re-mints authority on the same thread and revokes the old grant", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-remint")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Resume me."})
        |> json_response(201)

      id = created["thread"]["id"]
      old_token = created["grant"]["token"]
      assert {:ok, _usable} = Inference.resolve(old_token)

      body = authenticated |> post(~p"/api/v3/threads/#{id}/grants") |> json_response(201)

      assert body["thread"]["id"] == id
      assert body["thread"]["status"] == "open"
      new_token = body["grant"]["token"]
      assert is_binary(new_token) and new_token != old_token
      assert {:ok, _usable} = Inference.resolve(new_token)
      assert {:error, :grant_revoked} = Inference.resolve(old_token)
    end

    test "a terminal thread refuses with thread_terminal", %{conn: conn} do
      authenticated = put_chat_api_token(conn, "thread-remint-terminal")

      created =
        authenticated
        |> post(~p"/api/v3/threads", %{"objective" => "Close me first."})
        |> json_response(201)

      id = created["thread"]["id"]
      _cancelled = authenticated |> delete(~p"/api/v3/threads/#{id}") |> json_response(200)

      refused = authenticated |> post(~p"/api/v3/threads/#{id}/grants") |> json_response(422)
      assert refused["code"] == "thread_terminal"
    end

    test "another account's thread is not found", %{conn: conn} do
      owner = put_chat_api_token(conn, "thread-remint-owner")

      created =
        owner
        |> post(~p"/api/v3/threads", %{"objective" => "Mine alone."})
        |> json_response(201)

      id = created["thread"]["id"]

      stranger = put_chat_api_token(recycle(conn), "thread-remint-stranger")
      assert stranger |> post(~p"/api/v3/threads/#{id}/grants") |> json_response(404)
    end
  end
end
