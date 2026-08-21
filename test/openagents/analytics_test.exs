defmodule OpenAgents.AnalyticsTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Analytics

  # A sink that forwards every capture to the test process so assertions stay
  # in-process and the suite never touches the network.
  defmodule TestSink do
    def capture(event, distinct_id, properties) do
      send(:analytics_test_process, {:captured, event, distinct_id, properties})
      :ok
    end
  end

  setup do
    Process.register(self(), :analytics_test_process)

    original_token = Application.get_env(:openagents, :posthog_project_token)
    original_sink = Application.get_env(:openagents, :analytics_sink)

    Application.put_env(:openagents, :posthog_project_token, "phc_test_token")
    Application.put_env(:openagents, :analytics_sink, TestSink)

    on_exit(fn ->
      restore_env(:openagents, :posthog_project_token, original_token)
      restore_env(:openagents, :analytics_sink, original_sink)
    end)

    :ok
  end

  defp restore_env(app, key, :unset), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp captured do
    assert_receive {:captured, event, distinct_id, properties}, 500
    %{event: event, distinct_id: distinct_id, properties: properties}
  end

  describe "capture/3 when configured" do
    test "dispatches through the sink with standard properties" do
      :ok = Analytics.capture("user_signed_up", "user_abc", %{"github_login" => "octocat"})

      captured = captured()

      assert captured.event == "user_signed_up"
      assert captured.distinct_id == "user_abc"
      assert captured.properties["github_login"] == "octocat"
      assert is_binary(captured.properties["environment"])
      assert is_binary(captured.properties["app_revision"])
      assert captured.properties["surface"] == "server"
    end

    test "a caller-provided surface survives" do
      :ok = Analytics.capture("issue_created", "user_abc", %{"surface" => "api"})
      assert captured().properties["surface"] == "api"
    end

    test "sensitive keys are dropped before dispatch" do
      :ok =
        Analytics.capture("event", "user_abc", %{
          "token" => "leaked",
          "github_secret" => "leaked",
          "password" => "leaked",
          "safe_property" => "kept"
        })

      properties = captured().properties

      refute Map.has_key?(properties, "token")
      refute Map.has_key?(properties, "github_secret")
      refute Map.has_key?(properties, "password")
      assert properties["safe_property"] == "kept"
    end

    test "oversized values are truncated to a marker" do
      :ok = Analytics.capture("event", "user_abc", %{"big" => String.duplicate("x", 2_000)})
      assert captured().properties["big"] == "[truncated]"
    end

    test "nested maps are bounded by depth and entry count" do
      deep = %{"a" => %{"a" => %{"a" => %{"a" => %{"a" => %{"a" => 1}}}}}}

      wide = Map.new(1..60, fn i -> {"entry_#{i}", i} end)

      :ok = Analytics.capture("event", "user_abc", %{"deep" => deep, "wide" => wide})

      properties = captured().properties

      assert map_size(properties["wide"]) <= 20

      refute match?(
               %{"deep" => %{"a" => %{"a" => %{"a" => %{"a" => _}}}}},
               properties
             )
    end

    test "non-scalar shapes are dropped" do
      :ok =
        Analytics.capture("event", "user_abc", %{"struct" => URI.parse("https://example.com")})

      refute Map.has_key?(captured().properties, "struct")
    end

    test "a raising sink never propagates" do
      Application.put_env(:openagents, :analytics_sink, RaisingSink)
      :ok = Analytics.capture("event", "user_abc", %{})
    end
  end

  describe "capture/3 when unconfigured" do
    test "no-ops without touching the sink" do
      Application.put_env(:openagents, :posthog_project_token, nil)

      send_to_self = fn event, distinct_id, properties ->
        send(:analytics_test_process, {:captured, event, distinct_id, properties})
      end

      :ok = Analytics.capture("event", "user_abc")

      refute_receive {:captured, _, _, _}, 100
      assert is_function(send_to_self)
    end

    test "blank tokens count as unconfigured" do
      Application.put_env(:openagents, :posthog_project_token, "   ")
      :ok = Analytics.capture("event", "user_abc")
      refute_receive {:captured, _, _, _}, 100
    end
  end

  describe "distinct_id/1" do
    test "prefixes an account id" do
      assert Analytics.distinct_id("0f0e0d0c-1111-2222-3333-444455556666") ==
               "user_0f0e0d0c-1111-2222-3333-444455556666"
    end

    test "derives from a struct with an id" do
      assert Analytics.distinct_id(%{id: "abc"}) == "user_abc"
    end

    test "passes prefixed identifiers through unchanged" do
      assert Analytics.distinct_id("system_forge") == "system_forge"
      assert Analytics.distinct_id("visitor_xyz") == "visitor_xyz"
      assert Analytics.distinct_id("anonymous") == "anonymous"
    end

    test "system ids are stable per surface" do
      assert Analytics.system_distinct_id("forge") == "system_forge"
    end
  end

  describe "browser_distinct_id/1" do
    import Plug.Conn

    test "reads the tracing header when present" do
      conn = put_req_header(build_conn(), "x-posthog-distinct-id", "browser-123")
      assert Analytics.browser_distinct_id(conn) == "browser-123"
    end

    test "falls back to anonymous" do
      assert Analytics.browser_distinct_id(build_conn()) == "anonymous"
    end

    test "rejects oversized header values" do
      conn = put_req_header(build_conn(), "x-posthog-distinct-id", String.duplicate("x", 300))
      assert Analytics.browser_distinct_id(conn) == "anonymous"
    end

    defp build_conn, do: %Plug.Conn{}
  end
end

defmodule RaisingSink do
  def capture(_event, _distinct_id, _properties), do: raise("sink exploded")
end
