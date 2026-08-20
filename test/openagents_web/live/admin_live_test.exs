defmodule OpenAgentsWeb.AdminLiveTest do
  @moduledoc """
  `/admin` is the only surface that reads across accounts for one person, so the
  gate matters more than the layout: who reaches it, who is told nothing, and
  what the page is allowed to show once it renders.
  """

  use OpenAgentsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias OpenAgents.Conversations
  alias OpenAgents.Voice
  alias OpenAgents.Voice.Config
  alias OpenAgents.Voice.Recordings

  @webm "audio/webm;codecs=opus"

  describe "access" do
    test "the operator reaches the panel", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-operator")

      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "Voice calls"
    end

    test "an ordinary authenticated account is redirected and told nothing", %{conn: conn} do
      conn = log_in_github_user(conn, "admin-ordinary")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")

      # No flash, no distinct status: the surface does not announce that it exists.
      response = get(conn, ~p"/admin")
      assert redirected_to(response) == ~p"/"
      assert Phoenix.Flash.get(response.assigns.flash, :error) in [nil, ""]
    end

    test "an unauthenticated visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "a login rename cannot carry operator access, because the ID is what matches",
         %{conn: conn} do
      user = github_user("admin-renamed")
      grant_operator(user)

      # Someone else takes the freed login. The allowlist is numeric, so the new
      # holder of the name gains nothing.
      impostor = github_user("admin-impostor")

      {:ok, _renamed} =
        OpenAgents.Accounts.upsert_github_user(%{
          github_id: impostor.github_id,
          github_login: user.github_login,
          github_avatar_url: impostor.github_avatar_url
        })

      impostor_conn = Plug.Test.init_test_session(conn, %{"user_id" => impostor.id})

      assert {:error, {:redirect, %{to: "/"}}} = live(impostor_conn, ~p"/admin")
    end

    test "losing operator access halts the connected socket on its next event", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-revoked")
      {:ok, view, _html} = live(conn, ~p"/admin")

      revoke_operator()

      assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "previous_page", %{})
    end

    test "a banned operator is not an operator", %{conn: conn} do
      user = github_user("admin-banned")
      grant_operator(user)
      {:ok, _banned} = OpenAgents.Accounts.ban_user(user, "policy")

      banned_conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

      assert {:error, {:redirect, %{to: "/"}}} = live(banned_conn, ~p"/admin")
    end
  end

  describe "the panel" do
    test "lists recording metadata without exposing a playback route", %{conn: conn} do
      caller = github_user("admin-recorded-caller")
      session = recorded_call(caller)

      conn = log_in_admin_user(conn, "admin-listener")
      {:ok, view, html} = live(conn, ~p"/admin")

      assert html =~ "@#{caller.github_login}"
      assert has_element?(view, "#admin-call-#{session.id}")
      refute has_element?(view, "audio")
      refute html =~ "/admin/recordings/"
      assert html =~ "Complete upload"
    end

    test "lists calls with no audio and says why, instead of hiding them", %{conn: conn} do
      caller = github_user("admin-silent-caller")
      {:ok, conversation} = Conversations.ensure_conversation(caller)
      {:ok, session} = Voice.admit_session(conversation, enabled_config())
      {:ok, _ended} = Voice.end_session(session, session.generation, "user_ended")

      conn = log_in_admin_user(conn, "admin-silent-listener")
      {:ok, view, html} = live(conn, ~p"/admin")

      assert has_element?(view, "#admin-call-#{session.id}")
      assert html =~ "No audio uploaded"
      refute has_element?(view, "#admin-audio-#{session.id}")
    end

    test "renders transcript counts but never transcript content", %{conn: conn} do
      caller = github_user("admin-transcript-caller")
      session = recorded_call(caller)

      {:ok, session} = Voice.attach_provider(session, session.generation, "rtc_admin_transcript")

      {:ok, session, _event, :created} =
        Voice.record_provider_event(
          session,
          session.generation,
          %OpenAgents.Voice.ProviderEvent{
            kind: :session_ready,
            provider_event_id: "evt-admin-ready",
            payload: %{}
          }
        )

      {:ok, _session, _event, :created} =
        Voice.record_provider_event(
          session,
          session.generation,
          %OpenAgents.Voice.ProviderEvent{
            kind: :user_transcript_final,
            provider_event_id: "evt-admin-user",
            payload: %{
              "item_id" => "item-admin-user",
              "response_id" => nil,
              "content" => "my private banking password is hunter2"
            }
          }
        )

      conn = log_in_admin_user(conn, "admin-transcript-listener")
      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "1 items"
      refute html =~ "hunter2"
    end

    test "renders no composed instructions, tool catalog, or provider call identity",
         %{conn: conn} do
      caller = github_user("admin-secrets-caller")
      session = recorded_call(caller)
      {:ok, attached} = Voice.attach_provider(session, session.generation, "rtc_admin_secret")

      conn = log_in_admin_user(conn, "admin-secrets-listener")
      {:ok, _view, html} = live(conn, ~p"/admin")

      refute html =~ attached.provider_session_id
      refute html =~ attached.instruction_digest
      refute html =~ "sarah.realtime_tool_catalog"
    end

    test "states the retention window, because listenable forever is a different promise",
         %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-retention-listener")
      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "#{Recordings.config().retention_days} days after a call ends"
    end

    test "the browser policy admits same-origin audio without loosening anything", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-csp-operator")
      response = get(conn, ~p"/admin")

      [policy] = get_resp_header(response, "content-security-policy")

      # No `media-src` directive, so audio falls back to `default-src 'self'`.
      # Asserted rather than assumed: a later directive added for another reason
      # would silently break playback.
      assert policy =~ "default-src 'self'"
      refute policy =~ "media-src"
    end

    test "shows an empty state before anyone has called", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-empty-listener")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#admin-empty")
    end

    test "renders the shared command bar with only the way back", %{conn: conn} do
      conn = log_in_admin_user(conn, "admin-chrome-operator")
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "header.command-bar")
      assert has_element?(view, "#return-to-conversation")
      assert has_element?(view, "#account-menu-trigger")
      # Nothing navigates onward from here, and nothing in the product links in.
      refute has_element?(view, "#open-leaderboard")
    end
  end

  defp recorded_call(user) do
    {:ok, conversation} = Conversations.ensure_conversation(user)
    {:ok, session} = Voice.admit_session(conversation, enabled_config())
    {:ok, _chunk} = Recordings.append_chunk(session, session.generation, 1, "opus-bytes", @webm)
    {:ok, _recording} = Recordings.finalize(session, session.generation, "complete", 3_000)
    session
  end

  defp enabled_config do
    Config.build!(
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    )
  end
end
