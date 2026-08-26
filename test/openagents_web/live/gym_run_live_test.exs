defmodule OpenAgentsWeb.GymRunLiveTest do
  @moduledoc """
  `/gym/runs/:id` gates like every operator surface and streams the
  selected trial's transcript through the shared conversation components:
  the snapshot renders on mount, a later append arrives without reload, a
  malformed payload degrades to the neutral raw row, and a lane that left
  no thread renders a state-only placeholder.
  """

  use OpenAgentsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OpenAgents.Gym
  alias OpenAgents.Threads

  defp start_run(overrides \\ %{}) do
    {:ok, run, false} =
      Gym.start_run(
        Map.merge(
          %{
            "suite" => "terminal-bench@2.0",
            "agent" => "openagents-coder",
            "agent_version" => "0.3.5",
            "model" => "glm-5.3-flash",
            "lane" => "proxy",
            "tasks_total" => 3
          },
          overrides
        )
      )

    run
  end

  describe "access" do
    test "an ordinary authenticated account is redirected", %{conn: conn} do
      run = start_run()
      conn = log_in_github_user(conn, "gym-run-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/gym/runs/#{run.id}")
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      run = start_run()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/gym/runs/#{run.id}")
    end

    test "an unknown run id returns the operator to the scoreboard", %{conn: conn} do
      conn = log_in_admin_user(conn, "gym-run-unknown-operator")

      assert {:error, {:redirect, %{to: "/gym"}}} =
               live(conn, ~p"/gym/runs/#{Ecto.UUID.generate()}")

      assert {:error, {:redirect, %{to: "/gym"}}} = live(conn, ~p"/gym/runs/not-a-uuid")
    end
  end

  describe "the run page" do
    test "renders the header and updates the status in place on finalize", %{conn: conn} do
      run = start_run()
      conn = log_in_admin_user(conn, "gym-run-header-operator")

      {:ok, view, html} = live(conn, ~p"/gym/runs/#{run.id}")

      assert html =~ "terminal-bench@2.0"
      assert html =~ "openagents-coder"
      assert html =~ "glm-5.3-flash"
      assert view |> element("#gym-run-status") |> render() =~ "running"
      assert has_element?(view, "#gym-run-trials-empty")

      {:ok, _graded} =
        Gym.finalize_run(run, %{
          "tasks_total" => 3,
          "tasks_passed" => 2,
          "recipe_digest" => "sha256:" <> String.duplicate("9", 64)
        })

      assert view |> element("#gym-run-status") |> render() =~ "graded"
      assert view |> element("#gym-run-score") |> render() =~ "66.7%"
    end

    test "a trial reported after mount appears and becomes the selection", %{conn: conn} do
      run = start_run()
      bearer = github_user("gym-run-late-bearer")
      conn = log_in_admin_user(conn, "gym-run-late-operator")

      {:ok, view, _html} = live(conn, ~p"/gym/runs/#{run.id}")

      {:ok, trial} =
        Gym.record_trial(bearer, run, %{"task" => "hello-world", "state" => "running"})

      row = view |> element("#trials-#{trial.id}") |> render()
      assert row =~ "hello-world"
      assert row =~ ~s(data-selected="true")
      assert has_element?(view, "#gym-transcript-awaiting-thread")
    end
  end

  describe "the transcript" do
    defp linked_run(bearer) do
      {:ok, thread} = Threads.open(bearer, "Solve hello-world")
      run = start_run()

      {:ok, trial} =
        Gym.record_trial(bearer, run, %{
          "task" => "hello-world",
          "state" => "running",
          "thread_id" => thread.id
        })

      {run, trial, thread}
    end

    test "renders the snapshot and streams a live append through the chat components", %{
      conn: conn
    } do
      bearer = github_user("gym-run-transcript-bearer")
      {run, _trial, thread} = linked_run(bearer)

      {:ok, thread} = Threads.record_event(thread, "turn.user", %{"text" => "Fix the bug"})

      {:ok, thread} =
        Threads.record_event(thread, "turn.reasoning", %{"text" => "The bug is in the parser."})

      {:ok, thread} =
        Threads.record_event(thread, "tool.ran", %{
          "tool" => "read_file",
          "status" => "ok",
          "arguments" => %{"path" => "lib/parser.ex"},
          "result" => "defmodule Parser do"
        })

      conn = log_in_admin_user(conn, "gym-run-transcript-operator")
      {:ok, view, _html} = live(conn, ~p"/gym/runs/#{run.id}")

      user_row =
        view |> element("#gym-transcript-events [data-kind='turn.user']") |> render()

      assert user_row =~ "Fix the bug"
      assert user_row =~ ~s(data-from="user")

      assert view |> element("#gym-transcript-events [data-kind='turn.reasoning']") |> render() =~
               "The bug is in the parser."

      tool_row = view |> element("#gym-transcript-events [data-kind='tool.ran']") |> render()
      assert tool_row =~ "read_file"
      assert tool_row =~ "Completed"
      assert tool_row =~ "lib/parser.ex"
      assert tool_row =~ "defmodule Parser do"

      # The live append arrives without a reload, rendered as markdown.
      {:ok, _thread} =
        Threads.record_event(thread, "turn.assistant", %{"text" => "Fixed. It works **now**."})

      assistant_row =
        view |> element("#gym-transcript-events [data-kind='turn.assistant']") |> render()

      assert assistant_row =~ ~s(data-from="assistant")
      assert assistant_row =~ "<strong>now</strong>"
    end

    test "a malformed payload and an unknown type degrade to the neutral raw row", %{
      conn: conn
    } do
      bearer = github_user("gym-run-malformed-bearer")
      {run, _trial, thread} = linked_run(bearer)

      {:ok, thread} = Threads.record_event(thread, "turn.user", %{"no_text" => true})
      {:ok, _thread} = Threads.record_event(thread, "plugin.custom", %{"whatever" => [1, true]})

      conn = log_in_admin_user(conn, "gym-run-malformed-operator")
      {:ok, view, _html} = live(conn, ~p"/gym/runs/#{run.id}")

      textless =
        view
        |> element("#gym-transcript-events [data-kind='turn.user'] [data-transcript-raw]")
        |> render()

      assert textless =~ "no_text"

      unknown =
        view
        |> element("#gym-transcript-events [data-kind='plugin.custom'] [data-transcript-raw]")
        |> render()

      assert unknown =~ "plugin.custom"
    end

    test "selecting a trial moves the transcript, and a threadless lane says so", %{conn: conn} do
      bearer = github_user("gym-run-select-bearer")
      {run, linked, _thread} = linked_run(bearer)

      {:ok, local} =
        Gym.record_trial(bearer, run, %{"task" => "local-lane", "state" => "ungraded"})

      conn = log_in_admin_user(conn, "gym-run-select-operator")
      {:ok, view, _html} = live(conn, ~p"/gym/runs/#{run.id}")

      # The running linked trial is the default selection.
      assert view |> element("#trials-#{linked.id}") |> render() =~ ~s(data-selected="true")
      assert has_element?(view, "#gym-conversation")

      view |> element("#trials-#{local.id}") |> render_click()

      assert view |> element("#trials-#{local.id}") |> render() =~ ~s(data-selected="true")
      assert has_element?(view, "#gym-transcript-no-thread")
      refute has_element?(view, "#gym-conversation")

      view |> element("#trials-#{linked.id}") |> render_click()

      assert has_element?(view, "#gym-conversation")
    end
  end
end
