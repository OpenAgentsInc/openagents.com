defmodule OpenAgents.PostHogTest do
  use ExUnit.Case, async: false

  alias OpenAgents.PostHog

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

  defp configure(overrides \\ []) do
    Application.put_env(
      :openagents,
      :posthog_analytics,
      Keyword.merge(
        [
          personal_api_key: "phx_test_key",
          project_id: 303_178,
          app_host: "https://posthog-api.internal",
          request_options: [plug: {Req.Test, __MODULE__}]
        ],
        overrides
      )
    )
  end

  describe "enabled?/0" do
    test "requires both a key and a positive numeric project id" do
      refute PostHog.enabled?()

      configure(personal_api_key: nil)
      refute PostHog.enabled?()

      configure(project_id: "0")
      refute PostHog.enabled?()

      configure(project_id: 303_178)
      assert PostHog.enabled?()

      configure(personal_api_key: "   ")
      refute PostHog.enabled?()
    end
  end

  describe "overview/0" do
    test "is not configured without credentials and sends nothing" do
      assert {:error, :not_configured} = PostHog.overview()
    end

    test "shapes the six projections from one pull" do
      configure()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "uniq(person_id)"
        assert ["Bearer phx_test_key"] = Plug.Conn.get_req_header(conn, "authorization")
        assert conn.request_path == "/api/projects/303178/query/"

        Req.Test.json(conn, %{
          "columns" => ["event", "count", "people"],
          "results" => [["$pageview", 118, 8], ["chat_opened", 17, 3]]
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "'auth_started'"

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
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "'chat_turn_completed'"

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
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "'$pageview'"

        Req.Test.json(conn, %{
          "columns" => ["url", "views"],
          "results" => [["https://openagents.com/", 20], [nil, 4]]
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "properties.is_maintainer"
        assert body =~ "unlabeled_after_24h_percent"

        Req.Test.json(conn, %{
          "columns" => [
            "median_first_maintainer_response_hours",
            "eligible_issues",
            "unlabeled_issues",
            "unlabeled_after_24h_percent"
          ],
          "results" => [[12.5, 20, 3, 15.0]]
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "toStartOfWeek"
        assert body =~ "properties.issue_state_changed"

        Req.Test.json(conn, %{
          "columns" => ["week", "created", "closed"],
          "results" => [["2026-08-10", 8, 5], ["2026-08-17", 11, 9]]
        })
      end)

      assert {:ok, overview} = PostHog.overview()
      assert %DateTime{} = overview.generated_at

      assert [%{"event" => "$pageview", "count" => 118, "people" => 8}] =
               Enum.slice(overview.event_counts, 0, 1)

      assert overview.funnel["user_signed_up"] == 1
      assert overview.funnel["chat_message_sent"] == 6

      assert overview.chat_turns == %{
               "turns" => 6,
               "completed" => 6,
               "failed" => 0,
               "cancelled" => 0,
               "avg_duration_ms" => 4525,
               "max_duration_ms" => 7414
             }

      assert [%{"url" => "https://openagents.com/", "views" => 20} | _] = overview.top_pages

      assert overview.triage_health == %{
               "median_first_maintainer_response_hours" => 12.5,
               "eligible_issues" => 20,
               "unlabeled_issues" => 3,
               "unlabeled_after_24h_percent" => 15.0
             }

      assert overview.weekly_issue_flow == [
               %{"week" => "2026-08-10", "created" => 8, "closed" => 5},
               %{"week" => "2026-08-17", "created" => 11, "closed" => 9}
             ]
    end

    test "a rejected key is unavailable, never raised" do
      configure()

      Req.Test.expect(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      assert {:error, :unavailable} = PostHog.overview()
    end

    test "an unreachable host is unavailable, never raised" do
      configure(request_options: [])

      assert {:error, :unavailable} = PostHog.overview()
    end
  end
end
