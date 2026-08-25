defmodule OpenAgentsWeb.CapacityControllerTest do
  use OpenAgentsWeb.ConnCase, async: false

  setup do
    original_capacity = Application.get_env(:openagents, OpenAgents.Capacity, [])
    original_evidence = Application.get_env(:openagents, :capacity_test_evidence)

    Application.put_env(
      :openagents,
      OpenAgents.Capacity,
      Keyword.merge(original_capacity, evidence_source: OpenAgents.CapacityEvidenceStub)
    )

    Application.put_env(
      :openagents,
      :capacity_test_evidence,
      {:ok, %{"classes" => []}}
    )

    on_exit(fn ->
      Application.put_env(:openagents, OpenAgents.Capacity, original_capacity)

      if is_nil(original_evidence) do
        Application.delete_env(:openagents, :capacity_test_evidence)
      else
        Application.put_env(:openagents, :capacity_test_evidence, original_evidence)
      end
    end)

    :ok
  end

  test "capacity projection is shared by session and bearer routes", %{conn: conn} do
    session_conn =
      conn
      |> log_in_github_user("capacity-session")
      |> get("/api/capacity")

    bearer_conn =
      build_conn()
      |> put_chat_api_token("capacity-bearer")
      |> get("/api/v1/capacity")

    assert json_response(session_conn, 200) == json_response(bearer_conn, 200)
  end

  test "matching returns the contract status for unsupported isolation", %{conn: conn} do
    conn =
      conn
      |> put_chat_api_token("capacity-unsupported")
      |> post("/api/v1/capacity/matches", %{
        "requirement" => %{
          "isolation" => "managed_confidential",
          "egress" => "policy_broker",
          "data_location" => "openagents_managed"
        }
      })

    assert %{
             "schema" => "openagents.capacity_refusal.v1",
             "error" => %{"code" => "unsupported_isolation"}
           } =
             json_response(conn, 422)
  end
end
