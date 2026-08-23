defmodule OpenAgentsWeb.AdminAnalyticsLiveTest do
  @moduledoc """
  `/admin/analytics` gates like every operator surface, and its data path is
  honest about the states it can be in: unconfigured credentials, a PostHog
  that did not answer, and loaded aggregates.

  The assertions hold the same line as `/admin`: aggregate operational facts
  only. Nothing rendered here names conversation or memory content.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:openagents, :posthog_analytics)
    Application.put_env(:openagents, :posthog_analytics, personal_api_key: nil, project_id: nil)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:openagents, :posthog_analytics),
        else: Application.put_env(:openagents, :posthog_analytics, original)
    end)

    :ok
  end

  describe "access" do
    test "the operator reaches the surface", %{conn: conn} do
      conn = log_in_admin_user(conn, "analytics-operator")

      {:ok, _view, html} = live(conn, ~p"/admin/analytics")

      assert html =~ "Product analytics"
    end

    test "an ordinary authenticated account is redirected and told nothing", %{conn: conn} do
      conn = log_in_github_user(conn, "analytics-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/analytics")

      response = get(conn, ~p"/admin/analytics")
      assert redirected_to(response) == ~p"/"
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/analytics")
    end
  end

  describe "states" do
    test "without credentials the page says so instead of showing stale numbers",
         %{conn: conn} do
      Application.put_env(:openagents, :posthog_analytics,
        personal_api_key: nil,
        project_id: nil
      )

      conn = log_in_admin_user(conn, "analytics-unconfigured")

      {:ok, view, _html} = live(conn, ~p"/admin/analytics")
      render_async(view)

      assert has_element?(view, "#analytics-not-configured")
      refute has_element?(view, "#analytics-event-volume")
    end

    test "a failed pull offers retry and renders no numbers", %{conn: conn} do
      configure_posthog(fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      conn = log_in_admin_user(conn, "analytics-failed")

      {:ok, view, _html} = live(conn, ~p"/admin/analytics")
      render_async(view)

      assert has_element?(view, "#analytics-unavailable")
      refute has_element?(view, "#analytics-event-volume")
    end

    test "a successful pull renders bounded aggregates and refreshes", %{conn: conn} do
      Application.put_env(:openagents, :posthog_analytics,
        personal_api_key: "phx_test_key",
        project_id: 303_178,
        app_host: "https://posthog-api.internal",
        request_options: [plug: {Req.Test, __MODULE__}]
      )

      # One pull is six questions.
      Req.Test.expect(__MODULE__, 6, fn conn -> respond_by_query(conn) end)

      conn = log_in_admin_user(conn, "analytics-loaded")

      {:ok, view, _html} = live(conn, ~p"/admin/analytics")
      render_async(view)

      assert has_element?(view, "#analytics-generated-at")
      assert has_element?(view, "#analytics-triage-health")
      assert has_element?(view, "#analytics-weekly-issue-flow")
      assert has_element?(view, "#analytics-funnel")
      assert has_element?(view, "#analytics-chat-turns")
      assert html = render(view)
      assert html =~ "12.5h"
      assert html =~ "15.0%"
      assert html =~ "$pageview"
      assert html =~ "https://openagents.com/"

      # A second full pull backs the refresh click.
      Req.Test.expect(__MODULE__, 6, fn conn -> respond_by_query(conn) end)

      assert view |> element("#analytics-refresh") |> render_click() =~ "LIVE POSTHOG"
      render_async(view)
      assert has_element?(view, "#analytics-generated-at")
    end
  end

  defp configure_posthog(handler) when is_function(handler, 1) do
    Application.put_env(:openagents, :posthog_analytics,
      personal_api_key: "phx_test_key",
      project_id: 303_178,
      app_host: "https://posthog-api.internal",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.expect(__MODULE__, handler)
  end

  # The client asks six questions in a fixed order; each stub answers by
  # matching the HogQL in the request body rather than relying on call order.
  defp respond_by_query(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    cond do
      body =~ "uniq(person_id)" ->
        Req.Test.json(conn, %{
          "columns" => ["event", "count", "people"],
          "results" => [["$pageview", 118, 8], ["chat_opened", 17, 3]]
        })

      body =~ "'auth_started'" ->
        Req.Test.json(conn, %{
          "columns" => [
            "auth_started",
            "user_signed_up",
            "user_signed_in",
            "identified_signups",
            "chat_message_sent"
          ],
          "results" => [[3, 1, 2, 1, 6]]
        })

      body =~ "'chat_turn_completed'" ->
        Req.Test.json(conn, %{
          "columns" => [
            "turns",
            "completed",
            "failed",
            "cancelled",
            "avg_duration_ms",
            "max_duration_ms"
          ],
          "results" => [[6, 6, 0, 0, 4525.0, 7414]]
        })

      body =~ "unlabeled_after_24h_percent" ->
        Req.Test.json(conn, %{
          "columns" => [
            "median_first_maintainer_response_hours",
            "eligible_issues",
            "unlabeled_issues",
            "unlabeled_after_24h_percent"
          ],
          "results" => [[12.5, 20, 3, 15.0]]
        })

      body =~ "toStartOfWeek" ->
        Req.Test.json(conn, %{
          "columns" => ["week", "created", "closed"],
          "results" => [["2026-08-10", 8, 5], ["2026-08-17", 11, 9]]
        })

      true ->
        Req.Test.json(conn, %{
          "columns" => ["url", "views"],
          "results" => [["https://openagents.com/", 20]]
        })
    end
  end
end
