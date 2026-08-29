defmodule OpenAgents.Inference.CoderApiHopTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Inference.CoderApiHop

  defmodule SlowSseStub do
    @behaviour Plug

    def init(parent), do: parent

    def call(conn, parent) do
      conn =
        conn
        |> Plug.Conn.put_resp_header("x-openagents-model", "gemini-3.7-flash")
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: {\"choices\":[{\"delta\":{\"reasoning\":\"Considering\"}}],\"model\":\"gemini-3.7-flash\"}\n\n"
        )

      send(parent, {:first_sent, self()})

      receive do
        :continue -> :ok
      after
        5_000 -> :ok
      end

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: {\"choices\":[{\"delta\":{\"content\":\"Ready\"}}],\"model\":\"gemini-3.7-flash\"}\n\n"
        )

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"total_tokens\":12}}\n\n"
        )

      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  defmodule RefuseStub do
    @behaviour Plug

    def init(parent), do: parent

    def call(conn, parent) do
      send(parent, :refused)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(502, ~s({"error":"coder_api_hop"}))
    end
  end

  test "usage_from_sse reads OpenAI prompt and completion tokens" do
    body = """
    data: {"choices":[{"delta":{"content":"hi"}}],"model":"gemini-3.7-flash"}

    data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

    data: [DONE]

    """

    assert CoderApiHop.usage_from_sse(body) == %{
             "input_tokens" => 10,
             "output_tokens" => 2,
             "total_tokens" => 12
           }
  end

  test "served_model reads the rust attribution header" do
    assert CoderApiHop.served_model(%{"x-openagents-model" => ["gemini-3.7-flash"]}) ==
             "gemini-3.7-flash"

    assert CoderApiHop.served_model([{"x-openagents-model", "glm-5.3-flash"}]) == "glm-5.3-flash"
    assert CoderApiHop.served_model(%{}) == nil
  end

  test "target is local when origin or token is missing" do
    old_origin = Application.get_env(:openagents, :coder_api_origin)
    old_token = Application.get_env(:openagents, :coder_api_internal_token)
    Application.put_env(:openagents, :coder_api_origin, nil)
    Application.put_env(:openagents, :coder_api_internal_token, nil)
    assert CoderApiHop.target() == :local
    Application.put_env(:openagents, :coder_api_origin, old_origin)
    Application.put_env(:openagents, :coder_api_internal_token, old_token)
  end

  test "post returns the async body before rust finishes writing" do
    parent = self()

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.SlowSseStub, parent},
        scheme: :http,
        port: 0,
        thousand_island_options: [num_acceptors: 1]
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    origin = "http://127.0.0.1:#{port}"
    on_exit(fn -> Process.exit(pid, :normal) end)

    collector = self()

    task =
      Task.async(fn ->
        assert {:ok, 200, headers, %Req.Response.Async{} = async} =
                 CoderApiHop.post(origin, "hop-secret", "gemini-3.7-flash", %{
                   "messages" => [%{"role" => "user", "content" => "hey"}]
                 })

        send(collector, {:post_returned, headers})

        CoderApiHop.reduce_chunks(async, {"", 0}, fn chunk, {acc, n} ->
          send(collector, {:chunk, n, chunk})
          {acc <> chunk, n + 1}
        end)
      end)

    assert_receive {:first_sent, stub}, 2_000

    # `into: :self` returns after headers. Collecting the whole body would
    # deadlock here: rust is still waiting for :continue. The async body must
    # be read in this same process — Req delivers chunks to the caller.
    assert_receive {:post_returned, headers}, 1_000
    assert CoderApiHop.served_model(headers) == "gemini-3.7-flash"

    assert_receive {:chunk, 0, first}, 1_000
    assert first =~ "Considering"
    refute Task.yield(task, 150)

    send(stub, :continue)
    {collected, count} = Task.await(task, 2_000)
    assert count >= 2
    assert collected =~ "Ready"
    assert collected =~ "[DONE]"

    assert CoderApiHop.usage_from_sse(collected) == %{
             "input_tokens" => 10,
             "output_tokens" => 2,
             "total_tokens" => 12
           }
  end

  test "discard drains a refused async hop body" do
    parent = self()

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.RefuseStub, parent},
        scheme: :http,
        port: 0,
        thousand_island_options: [num_acceptors: 1]
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    origin = "http://127.0.0.1:#{port}"
    on_exit(fn -> Process.exit(pid, :normal) end)

    assert {:ok, 502, _headers, body} =
             CoderApiHop.post(origin, "hop-secret", "gemini-3.7-flash", %{
               "messages" => [%{"role" => "user", "content" => "hey"}]
             })

    assert_receive :refused
    assert CoderApiHop.discard(body) == :ok
  end
end
