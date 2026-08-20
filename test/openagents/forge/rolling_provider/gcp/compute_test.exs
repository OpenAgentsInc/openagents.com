defmodule OpenAgents.Forge.RollingProvider.Gcp.ComputeTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Forge.RollingProvider.Gcp.Compute

  setup {Req.Test, :verify_on_exit!}

  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)

  test "updates bounded identity metadata and resets one exact instance" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/compute/v1/projects/staging-project/zones/us-central1-a/instances/fleet-1"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

      Req.Test.json(conn, %{
        "metadata" => %{
          "fingerprint" => "fingerprint-1",
          "items" => [
            %{"key" => "retained", "value" => "yes"},
            %{"key" => "openagents-sha", "value" => "old"}
          ]
        }
      })
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/compute/v1/projects/staging-project/zones/us-central1-a/instances/fleet-1/setMetadata"

      body = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert body["fingerprint"] == "fingerprint-1"

      assert Map.new(body["items"], &{&1["key"], &1["value"]}) == %{
               "openagents-image" =>
                 "us-central1-docker.pkg.dev/staging-project/openagents/app@#{@digest}",
               "openagents-image-digest" => @digest,
               "openagents-sha" => @sha,
               "retained" => "yes"
             }

      Req.Test.json(conn, %{"name" => "set-metadata-1", "status" => "DONE"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/compute/v1/projects/staging-project/zones/us-central1-a/instances/fleet-1/reset"

      Req.Test.json(conn, %{"name" => "reset-1", "status" => "DONE"})
    end)

    assert :ok = Compute.replace("fleet-1", @sha, @digest, config())
  end

  test "returns only bounded status when the API response contains private data" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"access_token" => "private-sentinel"})
    end)

    result = Compute.replace("fleet-1", @sha, @digest, config())
    assert result == {:error, {:compute_api_error, :get_instance, 500}}
    refute inspect(result) =~ "private-sentinel"
  end

  test "refuses malformed identity before making a request" do
    assert {:error, :invalid_replacement_identity} =
             Compute.replace("fleet-1", "not-a-sha", @digest, config())
  end

  defp config do
    [
      project_id: "staging-project",
      zone: "us-central1-a",
      image_repository: "us-central1-docker.pkg.dev/staging-project/openagents/app",
      token_provider: fn -> {:ok, "test-token"} end,
      request_options: [plug: {Req.Test, __MODULE__}],
      operation_attempts: 1,
      operation_interval_ms: 0
    ]
  end
end
