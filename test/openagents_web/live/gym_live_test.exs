defmodule OpenAgentsWeb.GymLiveTest do
  @moduledoc """
  `/gym` gates like every operator surface: the operator sees the
  scoreboard, an ordinary account is redirected and told nothing, and the
  sidebar shows the Gym row only to operators.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Gym

  defp record_run(suite, digest_letter) do
    {:ok, run, false} =
      Gym.record_run(%{
        "suite" => suite,
        "agent" => "openagents-coder",
        "agent_version" => "0.3.5",
        "model" => "ox-alpha",
        "lane" => "proxy",
        "tasks_total" => 10,
        "tasks_passed" => 8,
        "recipe_digest" => "sha256:" <> String.duplicate(digest_letter, 64)
      })

    run
  end

  describe "access" do
    test "the operator reaches the surface", %{conn: conn} do
      conn = log_in_admin_user(conn, "gym-operator")

      {:ok, _view, html} = live(conn, ~p"/gym")

      assert html =~ "Gym"
      assert html =~ "No runs recorded yet"
    end

    test "an ordinary authenticated account is redirected", %{conn: conn} do
      conn = log_in_github_user(conn, "gym-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/gym")
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/gym")
    end
  end

  describe "sidebar" do
    test "the Gym row shows for the operator and not for an ordinary account", %{conn: conn} do
      operator = log_in_admin_user(conn, "gym-nav-operator")
      operator_home = operator |> get(~p"/repositories") |> html_response(200)
      assert operator_home =~ ~p"/gym"

      ordinary = log_in_github_user(conn, "gym-nav-ordinary")
      ordinary_home = ordinary |> get(~p"/repositories") |> html_response(200)
      refute ordinary_home =~ ~p"/gym"
    end
  end

  describe "live updates" do
    test "a running run appears, its tally moves, and it flips to graded in place", %{
      conn: conn
    } do
      conn = log_in_admin_user(conn, "gym-live-operator")
      {:ok, view, _html} = live(conn, ~p"/gym")

      bearer = github_user("gym-live-bearer")

      {:ok, run, false} =
        Gym.start_run(%{
          "suite" => "terminal-bench@2.0",
          "agent" => "openagents-coder",
          "model" => "ox-alpha",
          "lane" => "proxy",
          "tasks_total" => 2
        })

      running = view |> element("#gym-running-#{run.id}") |> render()
      assert running =~ "terminal-bench@2.0"
      assert running =~ "0 passed / 0 reported"
      assert running =~ ~p"/gym/runs/#{run.id}"

      {:ok, _trial} = Gym.record_trial(bearer, run, %{"task" => "hello", "state" => "passed"})

      assert view |> element("#gym-running-#{run.id}") |> render() =~ "1 passed / 1 reported"

      {:ok, graded} =
        Gym.finalize_run(run, %{
          "tasks_total" => 2,
          "tasks_passed" => 1,
          "recipe_digest" => "sha256:" <> String.duplicate("f", 64)
        })

      html = render(view)
      refute has_element?(view, "#gym-running-#{graded.id}")
      assert html =~ "50.0%"
    end
  end

  describe "runs" do
    test "recorded runs render with score, and the suite filter narrows", %{conn: conn} do
      _bench = record_run("terminal-bench@2.0", "d")
      _swe = record_run("swebench@lite", "e")

      conn = log_in_admin_user(conn, "gym-runs-operator")
      {:ok, view, html} = live(conn, ~p"/gym")

      assert html =~ "terminal-bench@2.0"
      assert html =~ "swebench@lite"
      assert html =~ "80.0%"
      assert html =~ "8/10"

      filtered =
        view
        |> element("#gym-suite-filter")
        |> render_change(%{"suite" => "swebench@lite"})

      assert filtered =~ "swebench@lite"
      refute filtered =~ "terminal-bench@2.0</td>"
    end
  end
end
