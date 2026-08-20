defmodule OpenAgents.SCV.CodexAppServerTest do
  use ExUnit.Case, async: true

  alias OpenAgents.SCV.CodexAppServer

  test "initializes and exposes the device-code response without merging tracing output" do
    codex_home =
      Path.join(System.tmp_dir!(), "codex-app-server-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(codex_home) end)

    server =
      start_supervised!(
        {CodexAppServer, owner: self(), executable: fixture(), codex_home: codex_home, args: []}
      )

    assert {:ok, %{"codexHome" => ^codex_home}} =
             CodexAppServer.request(server, "initialize", %{
               "clientInfo" => %{"name" => "test", "version" => "test"}
             })

    assert :ok = CodexAppServer.notify(server, "initialized")

    assert {:ok,
            %{
              "type" => "chatgptDeviceCode",
              "verificationUrl" => "https://auth.openai.com/codex/device",
              "userCode" => "TEST-CODE"
            }} =
             CodexAppServer.request(server, "account/login/start", %{
               "type" => "chatgptDeviceCode"
             })

    assert_receive {:codex_app_server, ^server,
                    {:notification,
                     %{
                       "method" => "account/login/completed",
                       "params" => %{"success" => true}
                     }}}
  end

  defp fixture do
    Path.expand("../../support/fake_codex_app_server.sh", __DIR__)
  end
end
