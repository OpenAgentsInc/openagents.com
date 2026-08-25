defmodule OpenAgents.BoxTest do
  use OpenAgents.DataCase

  alias OpenAgents.Box
  alias OpenAgents.Box.Client
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.Conversations
  alias OpenAgents.Repo

  @api_key "box_test_0000000000000000000000000000000000000000000000000000000000000"
  @box_id "bx_8bhkse3n"

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_api = Application.get_env(:openagents, :box_api)
    original_key = Application.get_env(:openagents, :box_api_key)

    Application.put_env(:openagents, :box_api,
      base_url: "https://box-api.internal",
      poll_interval_ms: 0,
      poll_attempts: 3,
      request_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0]
    )

    Application.put_env(:openagents, :box_api_key, @api_key)

    on_exit(fn ->
      restore_env(:box_api, original_api)
      restore_env(:box_api_key, original_key)
    end)

    {:ok, conversation} = Conversations.ensure_conversation("box-pool-test")
    %{conversation_id: conversation.id}
  end

  defp restore_env(key, nil), do: Application.delete_env(:openagents, key)
  defp restore_env(key, value), do: Application.put_env(:openagents, key, value)

  # The setup script is private, and the provider payload is where it becomes
  # observable, so read it back the way the provider does.
  defp captured_setup_script(conversation_id) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(raw) do
        {:ok, %{"setupScript" => script}} -> send(owner, {:setup_script, script})
        _other -> :ok
      end

      Req.Test.json(conn, box_body())
    end)

    assert {:ok, _record} = Box.create_box(conversation_id)
    assert_received {:setup_script, script}
    script
  end

  defp index_of(haystack, needle) do
    assert [index | _rest] = :binary.match(haystack, needle) |> Tuple.to_list()
    index
  end

  defp box_body(overrides \\ %{}) do
    %{
      "box" =>
        Map.merge(
          %{
            "id" => @box_id,
            "state" => "ready",
            "setupStatus" => "done",
            "name" => Box.provider_ownership_marker()
          },
          overrides
        )
    }
  end

  describe "create_box/1" do
    test "provisions, records ownership, and polls to runnable", %{conversation_id: cid} do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/boxes"
        assert ["Bearer " <> _key] = Plug.Conn.get_req_header(conn, "authorization")
        assert [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        assert byte_size(idempotency_key) > 0

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(raw)
        assert payload["noEnv"] == true
        assert payload["setupScript"] =~ "openrouter/stealth/ox-alpha"

        Req.Test.json(conn, box_body(%{"state" => "provisioning", "setupStatus" => "pending"}))
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/boxes/#{@box_id}"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["name"] == Box.provider_ownership_marker()
        Req.Test.json(conn, box_body(%{"state" => "provisioning", "setupStatus" => "pending"}))
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/boxes/#{@box_id}"
        Req.Test.json(conn, box_body())
      end)

      assert {:ok, record} = Box.create_box(cid)
      assert record.box_id == @box_id
      assert record.conversation_id == cid
      assert record.state == "ready"
      assert record.setup_status == "done"
      assert record.stopped_at == nil
    end

    test "writes the OpenCode configuration before installing", %{conversation_id: cid} do
      script = captured_setup_script(cid)

      configuration_at = index_of(script, "opencode.json")
      install_at = index_of(script, "releases/download")

      assert configuration_at < install_at,
             "the configuration write must precede the install so a failed fetch cannot cost both"
    end

    test "installs a pinned release without the unauthenticated GitHub API", %{
      conversation_id: cid
    } do
      script = captured_setup_script(cid)

      assert script =~
               ~r{https://github\.com/anomalyco/opencode/releases/download/v\d+\.\d+\.\d+/}

      refute script =~ "api.github.com"
      refute script =~ "opencode.ai/install"
      refute script =~ "releases/latest"
    end

    test "links the binary onto the PATH a non-interactive run gets", %{conversation_id: cid} do
      script = captured_setup_script(cid)

      assert script =~ ~s(ln -sf "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode")
    end

    test "retries a transient fetch a bounded number of times", %{conversation_id: cid} do
      script = captured_setup_script(cid)

      assert script =~ "until curl"
      assert script =~ ~r/if \[ "\$opencode_attempt" -ge \d+ \]/
      assert script =~ "exit 1"
    end

    test "injects the OpenRouter key through the box environment only", %{conversation_id: cid} do
      original = Application.get_env(:openagents, :openrouter_api_key)
      Application.put_env(:openagents, :openrouter_api_key, "sk-or-v1-test0000000000000000")
      on_exit(fn -> restore_env(:openrouter_api_key, original) end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(raw)
        assert payload["env"] == %{"OPENROUTER_API_KEY" => "sk-or-v1-test0000000000000000"}
        refute payload["setupScript"] =~ "sk-or-v1"
        Req.Test.json(conn, box_body())
      end)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, box_body()) end)

      assert {:ok, record} = Box.create_box(cid)
      assert record.setup_status == "done"
    end

    test "surfaces a failed setup honestly", %{conversation_id: cid} do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, box_body(%{"setupStatus" => "pending"}))
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PATCH"
        Req.Test.json(conn, box_body(%{"setupStatus" => "pending"}))
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, box_body(%{"setupStatus" => "failed"}))
      end)

      assert {:ok, record} = Box.create_box(cid)
      assert record.setup_status == "failed"
    end

    test "refuses past the per-conversation cap without a remote call", %{conversation_id: cid} do
      for index <- 1..Box.maximum_active_boxes() do
        insert_box(cid, "bx_aaaaaaa#{Enum.at(~w(2 3 4 5 6 7 8 9 a b), index - 1)}")
      end

      assert {:error, :box_quota_reached} = Box.create_box(cid)
    end

    test "a stopped box frees its quota slot", %{conversation_id: cid} do
      for index <- 1..Box.maximum_active_boxes() do
        insert_box(cid, "bx_aaaaaaa#{Enum.at(~w(2 3 4 5 6 7 8 9 a b), index - 1)}")
      end

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/boxes/bx_aaaaaaa2/stop"
        Req.Test.json(conn, box_body(%{"id" => "bx_aaaaaaa2", "state" => "archiving"}))
      end)

      assert {:ok, stopped} = Box.stop_box(cid, "bx_aaaaaaa2")
      assert %DateTime{} = stopped.stopped_at
      assert stopped.state == "archiving"

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/boxes"
        Req.Test.json(conn, box_body())
      end)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, box_body()) end)

      assert {:ok, _record} = Box.create_box(cid)
    end

    test "another conversation's boxes do not count against this quota", %{conversation_id: cid} do
      {:ok, other} = Conversations.ensure_conversation("box-pool-other")

      for index <- 1..Box.maximum_active_boxes() do
        insert_box(other.id, "bx_aaaaaaa#{Enum.at(~w(2 3 4 5 6 7 8 9 a b), index - 1)}")
      end

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, box_body())
      end)

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, box_body()) end)

      assert {:ok, _record} = Box.create_box(cid)
    end

    test "a provider refusal rolls back and stores nothing", %{conversation_id: cid} do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"code" => "rate_limited"})
      end)

      assert {:error, :box_rate_limited} = Box.create_box(cid)
      assert Repo.aggregate(ConversationBox, :count) == 0
    end
  end

  describe "run_command/4" do
    test "runs a command on an owned box", %{conversation_id: cid} do
      insert_box(cid, @box_id)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/boxes/#{@box_id}/commands"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"command" => "echo hi", "timeoutSeconds" => 60} = Jason.decode!(raw)

        Req.Test.json(conn, %{
          "exitCode" => 0,
          "stdout" => "hi\n",
          "stderr" => "",
          "success" => true,
          "timedOut" => false
        })
      end)

      assert {:ok, body} = Box.run_command(cid, @box_id, "echo hi", 60)
      assert body["exitCode"] == 0
    end

    test "refuses a box owned by another conversation", %{conversation_id: cid} do
      {:ok, other} = Conversations.ensure_conversation("box-owner-other")
      insert_box(other.id, @box_id)

      assert {:error, :box_not_owned} = Box.run_command(cid, @box_id, "id", 60)
    end

    test "refuses a stopped box", %{conversation_id: cid} do
      insert_box(cid, @box_id, stopped_at: DateTime.utc_now())

      assert {:error, :box_stopped} = Box.run_command(cid, @box_id, "id", 60)
      assert {:error, :box_stopped} = Box.stop_box(cid, @box_id)
    end
  end

  describe "client" do
    test "fails closed without a configured credential", %{conversation_id: cid} do
      Application.delete_env(:openagents, :box_api_key)

      assert {:error, :box_not_configured} = Box.create_box(cid)
      assert {:error, :box_not_configured} = Client.get_box(@box_id)
    end

    test "maps provider statuses to typed errors" do
      for {status, expected} <- [
            {401, :box_unauthorized},
            {402, :box_billing_required},
            {404, :box_not_found},
            {429, :box_rate_limited}
          ] do
        Req.Test.expect(__MODULE__, fn conn ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{})
        end)

        assert Client.stop_box(@box_id) == {:error, expected}
      end

      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"code" => "provider_not_configured"})
      end)

      assert Client.stop_box(@box_id) ==
               {:error, {:box_request_refused, 409, "provider_not_configured"}}
    end

    test "a transport failure is unreachable, not a crash" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Client.command(@box_id, %{"command" => "id"}) == {:error, :box_unreachable}
    end

    test "retries a transient read failure" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, box_body())
      end)

      assert {:ok, %{"box" => %{"id" => @box_id}}} = Client.get_box(@box_id)
    end

    test "rejects a malformed box id before any request leaves the host" do
      for bad <- ["", "bx_", "bx_UPPERCASE", "../boxes", "bx_8bhkse3n/desktop", "bx_11111111"] do
        refute Client.valid_box_id?(bad)
        assert Client.get_box(bad) == {:error, :box_not_found}
      end

      assert Client.valid_box_id?(@box_id)
    end
  end

  defp insert_box(conversation_id, box_id, attributes \\ []) do
    %ConversationBox{}
    |> ConversationBox.changeset(
      Enum.into(attributes, %{
        conversation_id: conversation_id,
        box_id: box_id,
        state: "ready",
        setup_status: "done"
      })
    )
    |> Repo.insert!()
  end
end
