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
        "model" => "glm-5.3-flash",
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
      |> post(~p"/api/v1/gym/runs", payload())
      |> json_response(201)

    assert created["run"]["score"] == 0.7
    assert created["replayed"] == false

    replayed =
      authenticated
      |> post(~p"/api/v1/gym/runs", payload(%{"tasks_passed" => 1}))
      |> json_response(200)

    assert replayed["replayed"] == true
    assert replayed["run"]["id"] == created["run"]["id"]
    assert replayed["run"]["tasks_passed"] == 7
  end

  test "an ordinary forge:write token is refused and records nothing", %{conn: conn} do
    refused =
      conn
      |> put_forge_api_token("gym-ordinary")
      |> post(~p"/api/v1/gym/runs", payload())
      |> json_response(403)

    assert refused["code"] == "not_operator"
    assert Gym.list_runs() == []
  end

  test "an invalid run refuses with field errors", %{conn: conn} do
    refused =
      conn
      |> operator_token("gym-invalid")
      |> post(~p"/api/v1/gym/runs", payload(%{"tasks_passed" => 99}))
      |> json_response(422)

    assert refused["errors"]["tasks_passed"]
  end

  test "listing is operator-only and filters by suite", %{conn: conn} do
    authenticated = operator_token(conn, "gym-lister")

    _created =
      authenticated |> post(~p"/api/v1/gym/runs", payload()) |> json_response(201)

    listed = authenticated |> get(~p"/api/v1/gym/runs") |> json_response(200)
    assert [%{"suite" => "terminal-bench@2.0"}] = listed["runs"]

    filtered =
      authenticated
      |> get(~p"/api/v1/gym/runs?suite=swebench@lite")
      |> json_response(200)

    assert filtered["runs"] == []

    refused =
      conn
      |> put_forge_api_token("gym-list-ordinary")
      |> get(~p"/api/v1/gym/runs")
      |> json_response(403)

    assert refused["code"] == "not_operator"
  end

  defp start_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "suite" => "terminal-bench@2.0",
        "agent" => "openagents-coder",
        "model" => "glm-5.3-flash",
        "lane" => "proxy",
        "tasks_total" => 5
      },
      overrides
    )
  end

  defp start_run(authenticated, overrides \\ %{}) do
    authenticated
    |> post(~p"/api/v1/gym/runs/start", start_payload(overrides))
    |> json_response(201)
    |> Map.fetch!("run")
  end

  describe "POST /api/v1/gym/runs/start" do
    test "registers a running run and a digest retry replays it", %{conn: conn} do
      authenticated = operator_token(conn, "gym-start")

      started =
        authenticated
        |> post(~p"/api/v1/gym/runs/start", start_payload())
        |> json_response(201)

      assert started["replayed"] == false
      assert started["run"]["status"] == "running"
      assert started["run"]["id"]
      assert started["run"]["tasks_passed"] == nil
      assert started["run"]["score"] == nil
      assert String.starts_with?(started["run"]["recipe_digest"], "pending:")

      digest = "sha256:" <> String.duplicate("a", 64)

      _first =
        authenticated
        |> post(~p"/api/v1/gym/runs/start", start_payload(%{"recipe_digest" => digest}))
        |> json_response(201)

      replayed =
        authenticated
        |> post(~p"/api/v1/gym/runs/start", start_payload(%{"recipe_digest" => digest}))
        |> json_response(200)

      assert replayed["replayed"] == true
    end

    test "identity is required", %{conn: conn} do
      refused =
        conn
        |> operator_token("gym-start-invalid")
        |> post(~p"/api/v1/gym/runs/start", %{"suite" => "terminal-bench@2.0"})
        |> json_response(422)

      assert refused["errors"]["agent"]
      assert refused["errors"]["model"]
    end

    test "an ordinary forge:write token is refused", %{conn: conn} do
      refused =
        conn
        |> put_forge_api_token("gym-start-ordinary")
        |> post(~p"/api/v1/gym/runs/start", start_payload())
        |> json_response(403)

      assert refused["code"] == "not_operator"
      assert Gym.list_runs() == []
    end
  end

  describe "POST /api/v1/gym/runs/:id/trials" do
    test "upserts a trial and links the bearer's own thread", %{conn: conn} do
      authenticated = operator_token(conn, "gym-trials")
      bearer = github_user("api-token-gym-trials")
      {:ok, thread} = OpenAgents.Threads.open(bearer, "Run the hello-world trial")

      run = start_run(authenticated)

      reported =
        authenticated
        |> post(~p"/api/v1/gym/runs/#{run["id"]}/trials", %{
          "task" => "hello-world",
          "state" => "running",
          "thread_id" => thread.id
        })
        |> json_response(200)

      assert reported["trial"]["task"] == "hello-world"
      assert reported["trial"]["state"] == "running"
      assert reported["trial"]["thread_id"] == thread.id

      graded =
        authenticated
        |> post(~p"/api/v1/gym/runs/#{run["id"]}/trials", %{
          "task" => "hello-world",
          "state" => "passed"
        })
        |> json_response(200)

      assert graded["trial"]["id"] == reported["trial"]["id"]
      assert graded["trial"]["state"] == "passed"
      assert graded["trial"]["thread_id"] == thread.id
    end

    test "an unknown thread and an unowned one refuse identically", %{conn: conn} do
      authenticated = operator_token(conn, "gym-trials-refuse")
      stranger = github_user("gym-trials-stranger")
      {:ok, foreign} = OpenAgents.Threads.open(stranger, "Somebody else's trial")

      run = start_run(authenticated)

      unknown =
        authenticated
        |> post(~p"/api/v1/gym/runs/#{run["id"]}/trials", %{
          "task" => "a",
          "state" => "running",
          "thread_id" => Ecto.UUID.generate()
        })
        |> json_response(422)

      unowned =
        authenticated
        |> post(~p"/api/v1/gym/runs/#{run["id"]}/trials", %{
          "task" => "a",
          "state" => "running",
          "thread_id" => foreign.id
        })
        |> json_response(422)

      assert unknown["errors"]["thread_id"] == unowned["errors"]["thread_id"]
    end

    test "an unknown run is not found", %{conn: conn} do
      authenticated = operator_token(conn, "gym-trials-missing")

      refused =
        authenticated
        |> post(~p"/api/v1/gym/runs/#{Ecto.UUID.generate()}/trials", %{
          "task" => "a",
          "state" => "running"
        })
        |> json_response(404)

      assert refused["code"] == "not_found"
    end

    test "an ordinary forge:write token is refused", %{conn: conn} do
      refused =
        conn
        |> put_forge_api_token("gym-trials-ordinary")
        |> post(~p"/api/v1/gym/runs/#{Ecto.UUID.generate()}/trials", %{
          "task" => "a",
          "state" => "running"
        })
        |> json_response(403)

      assert refused["code"] == "not_operator"
    end
  end

  describe "PATCH /api/v1/gym/runs/:id" do
    test "finalizes with the grades and refuses a second grade", %{conn: conn} do
      authenticated = operator_token(conn, "gym-finalize")
      run = start_run(authenticated)
      digest = "sha256:" <> String.duplicate("b", 64)

      graded =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{run["id"]}", %{
          "status" => "graded",
          "tasks_total" => 5,
          "tasks_passed" => 4,
          "duration_seconds" => 90,
          "recipe_digest" => digest
        })
        |> json_response(200)

      assert graded["run"]["status"] == "graded"
      assert graded["run"]["score"] == 0.8
      assert graded["run"]["recipe_digest"] == digest
      assert graded["run"]["completed_at"]

      refused =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{run["id"]}", %{
          "status" => "graded",
          "tasks_total" => 5,
          "tasks_passed" => 5
        })
        |> json_response(409)

      assert refused["code"] == "run_already_graded"
      assert refused["run"]["id"] == run["id"]
    end

    test "a digest that names another run conflicts with that run in the body", %{conn: conn} do
      authenticated = operator_token(conn, "gym-conflict")

      existing =
        authenticated
        |> post(~p"/api/v1/gym/runs", payload())
        |> json_response(201)
        |> Map.fetch!("run")

      run = start_run(authenticated)

      refused =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{run["id"]}", %{
          "status" => "graded",
          "tasks_total" => 5,
          "tasks_passed" => 5,
          "recipe_digest" => existing["recipe_digest"]
        })
        |> json_response(409)

      assert refused["code"] == "recipe_digest_conflict"
      assert refused["run"]["id"] == existing["id"]
    end

    test "abandons a run without grades", %{conn: conn} do
      authenticated = operator_token(conn, "gym-abandon")
      run = start_run(authenticated)

      abandoned =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{run["id"]}", %{"status" => "abandoned"})
        |> json_response(200)

      assert abandoned["run"]["status"] == "abandoned"
      assert abandoned["run"]["tasks_passed"] == nil
    end

    test "an unknown run and an unknown status refuse", %{conn: conn} do
      authenticated = operator_token(conn, "gym-patch-refusals")

      missing =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{Ecto.UUID.generate()}", %{"status" => "abandoned"})
        |> json_response(404)

      assert missing["code"] == "not_found"

      run = start_run(authenticated)

      sideways =
        authenticated
        |> patch(~p"/api/v1/gym/runs/#{run["id"]}", %{"status" => "sideways"})
        |> json_response(422)

      assert sideways["errors"]["status"]
    end

    test "an ordinary forge:write token is refused", %{conn: conn} do
      refused =
        conn
        |> put_forge_api_token("gym-patch-ordinary")
        |> patch(~p"/api/v1/gym/runs/#{Ecto.UUID.generate()}", %{"status" => "abandoned"})
        |> json_response(403)

      assert refused["code"] == "not_operator"
    end
  end
end
