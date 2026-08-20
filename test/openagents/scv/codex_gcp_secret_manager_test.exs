defmodule OpenAgents.SCV.CodexGcpSecretManagerTest do
  use ExUnit.Case, async: false

  alias OpenAgents.SCV.CodexCredentialStore.GcpSecretManager
  alias OpenAgents.SCV.DriverAccount

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.fetch_env!(:openagents, :scv_codex)

    Application.put_env(
      :openagents,
      :scv_codex,
      Keyword.merge(original,
        request_options: [plug: {Req.Test, __MODULE__}],
        secret_manager_api_base: "https://secretmanager.example.test",
        metadata_api_base: "http://metadata.example.test"
      )
    )

    on_exit(fn -> Application.put_env(:openagents, :scv_codex, original) end)
  end

  test "adds an immutable secret version and returns its numeric generation" do
    expect_metadata_token()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path ==
               "/v1/projects/staging/secrets/scv-codex-operator-1:addVersion"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer workload-token"]

      body = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert {:ok, decoded} = Base.decode64(body["payload"]["data"])
      assert Jason.decode!(decoded) == %{"auth_mode" => "chatgpt"}

      Req.Test.json(conn, %{
        "name" => "projects/staging/secrets/scv-codex-operator-1/versions/7"
      })
    end)

    account = %DriverAccount{
      secret_ref: "projects/staging/secrets/scv-codex-operator-1"
    }

    assert {:ok, 7} = GcpSecretManager.put(account, Jason.encode!(%{auth_mode: "chatgpt"}))
  end

  test "fetches only the account's recorded secret version" do
    expect_metadata_token()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path ==
               "/v1/projects/staging/secrets/scv-codex-operator-1/versions/11:access"

      Req.Test.json(conn, %{
        "payload" => %{"data" => Base.encode64(Jason.encode!(%{auth_mode: "chatgpt"}))}
      })
    end)

    account = %DriverAccount{
      secret_ref: "projects/staging/secrets/scv-codex-operator-1",
      credential_version: 11
    }

    assert {:ok, encoded} = GcpSecretManager.fetch(account)
    assert Jason.decode!(encoded) == %{"auth_mode" => "chatgpt"}
  end

  defp expect_metadata_token do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path ==
               "/computeMetadata/v1/instance/service-accounts/default/token"

      assert Plug.Conn.get_req_header(conn, "metadata-flavor") == ["Google"]
      Req.Test.json(conn, %{"access_token" => "workload-token", "expires_in" => 3_600})
    end)
  end
end
