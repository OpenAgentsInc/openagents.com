defmodule OpenAgentsWeb.GymRunControllerTest do
  @moduledoc """
  The Gym's ingest door authenticates a `forge:write` bearer and then
  rechecks live operator standing on every request. An ordinary account with
  the same scope is refused with a typed `not_operator`, and nothing is
  recorded for it.
  """

  use OpenAgentsWeb.ConnCase, async: false

  alias OpenAgents.Gym

  @digest "sha256:" <> String.duplicate("c", 64)

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "suite" => "terminal-bench@2.0",
        "agent" => "openagents-coder",
        "model" => "ox-alpha",
        "tasks_total" => 10,
        "tasks_passed" => 7,
        "recipe_digest" => @digest
      },
      overrides
    )
  end

  defp operator_token(conn, key) do
    user = github_user("api-token-" <> key)
    grant_operator(user)
    put_forge_api_token(conn, key)
  end

  test "an operator records a run and a retry replays it", %{conn: conn} do
    authenticated = operator_token(conn, "gym-operator")

    created =
      authenticated
      |> post(~p"/api/v3/gym/runs", payload())
      |> json_response(201)

    assert created["run"]["score"] == 0.7
    assert created["replayed"] == false

    replayed =
      authenticated
      |> post(~p"/api/v3/gym/runs", payload(%{"tasks_passed" => 1}))
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["run"]["id"] == created["run"]["id"]
    assert replayed["run"]["tasks_passed"] == 7
  end

  test "an ordinary forge:write token is refused and records nothing", %{conn: conn} do
    refused =
      conn
      |> put_forge_api_token("gym-ordinary")
      |> post(~p"/api/v3/gym/runs", payload())
      |> json_response(403)

    assert refused["code"] == "not_operator"
    assert Gym.list_runs() == []
  end

  test "an invalid run refuses with field errors", %{conn: conn} do
    refused =
      conn
      |> operator_token("gym-invalid")
      |> post(~p"/api/v3/gym/runs", payload(%{"tasks_passed" => 99}))
      |> json_response(422)

    assert refused["errors"]["tasks_passed"]
  end

  test "listing is operator-only and filters by suite", %{conn: conn} do
    authenticated = operator_token(conn, "gym-lister")

    _created =
      authenticated |> post(~p"/api/v3/gym/runs", payload()) |> json_response(201)

    listed = authenticated |> get(~p"/api/v3/gym/runs") |> json_response(200)
    assert [%{"suite" => "terminal-bench@2.0"}] = listed["runs"]

    filtered =
      authenticated
      |> get(~p"/api/v3/gym/runs?suite=swebench@lite")
      |> json_response(200)

    assert filtered["runs"] == []

    refused =
      conn
      |> put_forge_api_token("gym-list-ordinary")
      |> get(~p"/api/v3/gym/runs")
      |> json_response(403)

    assert refused["code"] == "not_operator"
  end
end
