defmodule OpenAgentsWeb.AuthController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.{Accounts, Analytics, GitHubOAuth, Repositories}

  @attempt_session_key "github_oauth_attempt"
  @identity_session_key "posthog_identity"

  def start(conn, %{"github_tools" => "enabled"}) do
    case GitHubOAuth.begin_authorization() do
      {:ok, attempt, authorization_url} ->
        Analytics.capture("auth_started", Analytics.browser_distinct_id(conn))

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_session(@attempt_session_key, attempt)
        |> redirect(external: authorization_url)

      {:error, _reason} ->
        auth_failure(conn, "unavailable")
    end
  end

  def start(conn, _params), do: auth_failure(conn, "consent_required")

  def callback(conn, %{"code" => code, "state" => state}) do
    attempt = get_session(conn, @attempt_session_key)
    verifier = if is_map(attempt), do: attempt["verifier"]
    conn = delete_session(conn, @attempt_session_key)

    with :ok <- GitHubOAuth.consume_attempt(attempt, state),
         {:ok, profile, access_token, granted_scopes} <-
           GitHubOAuth.exchange_and_fetch(code, verifier),
         {:ok, user} <- Accounts.upsert_github_user(profile),
         {:ok, active_user} <- Accounts.get_active_user(user.id),
         {:ok, _namespace} <- Repositories.ensure_user_namespace(active_user),
         {:ok, _stored} <-
           Accounts.store_github_token(active_user, access_token, granted_scopes) do
      capture_sign_in(active_user)

      conn
      |> clear_session()
      |> configure_session(renew: true)
      |> put_session("user_id", active_user.id)
      |> put_session(@identity_session_key, identity(active_user))
      |> put_resp_header("cache-control", "no-store")
      |> redirect(to: ~p"/sarah")
    else
      {:error, :banned} -> auth_failure(conn, "banned")
      {:error, _reason} -> auth_failure(conn, "failed")
    end
  end

  def callback(conn, %{"error" => _provider_error}) do
    conn = delete_session(conn, @attempt_session_key)
    auth_failure(conn, "denied")
  end

  def callback(conn, _params) do
    conn = delete_session(conn, @attempt_session_key)
    auth_failure(conn, "failed")
  end

  def logout(conn, _params) do
    case get_session(conn, @identity_session_key) do
      %{"distinct_id" => distinct_id} when is_binary(distinct_id) ->
        Analytics.capture("user_logged_out", distinct_id)

      _absent ->
        :ok
    end

    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/")
  end

  def disconnect(conn, _params) do
    case Accounts.disconnect_github(conn.assigns.current_user) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "GitHub tools disconnected and the retained grant was revoked.")
        |> put_resp_header("cache-control", "no-store")
        |> redirect(to: ~p"/sarah")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "GitHub tools could not be disconnected. Try again.")
        |> put_resp_header("cache-control", "no-store")
        |> redirect(to: ~p"/sarah")
    end
  end

  # A row created and updated in the same write is a first sign-in; anything
  # else reauthenticated an existing account.
  defp capture_sign_in(user) do
    event =
      if DateTime.compare(user.inserted_at, user.updated_at) == :eq,
        do: "user_signed_up",
        else: "user_signed_in"

    Analytics.capture(event, Analytics.distinct_id(user), %{
      "github_login" => user.github_login
    })
  end

  defp identity(user) do
    %{"distinct_id" => Analytics.distinct_id(user), "login" => user.github_login}
  end

  defp auth_failure(conn, code) do
    Analytics.capture("auth_failed", Analytics.browser_distinct_id(conn), %{"reason" => code})

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/?auth_error=#{code}")
  end
end
