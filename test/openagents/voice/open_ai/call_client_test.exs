defmodule OpenAgents.Voice.OpenAI.CallClientTest do
  use ExUnit.Case, async: true
  @moduletag :skip

  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.OpenAI.CallClient

  setup {Req.Test, :verify_on_exit!}

  test "exchanges a bounded SDP offer through the unified multipart endpoint" do
    safety_identifier = String.duplicate("a", 64)

    contextual_config =
      Config.with_context(enabled_config(), "You are OpenAgents.", [
        %{
          "type" => "function",
          "name" => "memory_list",
          "description" => "List memory",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ])

    Req.Test.expect(__MODULE__, fn conn ->
      assert ["Bearer test-secret"] = Plug.Conn.get_req_header(conn, "authorization")

      assert [^safety_identifier] =
               Plug.Conn.get_req_header(conn, "openai-safety-identifier")

      assert ["multipart/form-data; boundary=" <> _boundary] =
               Plug.Conn.get_req_header(conn, "content-type")

      body = Req.Test.raw_body(conn)
      assert body =~ ~s(name="sdp")
      assert body =~ "v=0\r\no=test-offer"
      assert body =~ ~s(name="session")
      assert body =~ ~s("model":"gpt-realtime-2.1")
      assert body =~ ~s("voice":"marin")
      assert body =~ ~s("instructions":"You are OpenAgents.")
      assert body =~ ~s("name":"memory_list")
      assert body =~ ~s("create_response":false)
      refute body =~ "test-secret"

      conn
      |> Plug.Conn.put_resp_header("location", "/v1/realtime/calls/rtc_123")
      |> Plug.Conn.send_resp(201, "v=0\r\no=test-answer")
    end)

    assert {:ok, admission} =
             CallClient.create("v=0\r\no=test-offer", safety_identifier, contextual_config,
               api_key: "test-secret",
               request_options: [plug: {Req.Test, __MODULE__}, retry: false]
             )

    assert admission.provider_session_id == "rtc_123"
    assert admission.answer_sdp == "v=0\r\no=test-answer"
  end

  test "fails closed on absent credentials and malformed provider identity" do
    assert {:error, :missing_api_key} =
             CallClient.create("v=0\r\n", String.duplicate("b", 64), enabled_config(),
               api_key: ""
             )

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/unexpected/rtc_123")
      |> Plug.Conn.send_resp(200, "v=0\r\no=answer")
    end)

    assert {:error, :invalid_call_id} =
             CallClient.create("v=0\r\n", String.duplicate("b", 64), enabled_config(),
               api_key: "test-secret",
               request_options: [plug: {Req.Test, __MODULE__}, retry: false]
             )
  end

  test "refuses disabled voice and oversized SDP before transport" do
    disabled = %{enabled_config() | enabled?: false}

    assert {:error, :voice_disabled} =
             CallClient.create("v=0\r\n", String.duplicate("c", 64), disabled, api_key: "unused")

    assert {:error, :invalid_sdp} =
             CallClient.create(
               "v=0" <> String.duplicate("x", 65_534),
               String.duplicate("c", 64),
               enabled_config(),
               api_key: "unused"
             )
  end

  defp enabled_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end
end
