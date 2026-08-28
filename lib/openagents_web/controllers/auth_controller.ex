defmodule OpenAgentsWeb.AuthController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.{Accounts, Analytics, DeviceAuthorizations, GitHubOAuth, Repositories}
  alias OpenAgents.Accounts.User

  @attempt_session_key "github_oauth_attempt"
  @github_connect_session_key "github_connect_pending"
  @identity_session_key "posthog_identity"

  def start(conn, params)

  # A repository-mode start is a grant decision, and an anonymous applicant
  # cannot make one: the stored token would have no account to land on. The
  # connect page is authenticated, so a request here without a session user
  # arrived from somewhere else and is refused rather than redirected into a
  # sign-in that silently loses the mode.
  def start(%{assigns: %{current_user: %User{}}} = conn, params) do
    if repository_mode?(params) do
      start_repository(conn)
    else
      start_sign_in(conn)
    end
  end

  def start(conn, params) do
    if repository_mode?(params) do
      auth_failure(conn, "unavailable")
    else
      start_sign_in(conn)
    end
  end

  defp start_sign_in(conn) do
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

  defp start_repository(conn) do
    user = conn.assigns.current_user
    pending_code = pending_github_connect_code(conn)

    with {:ok, attempt, authorization_url} <- GitHubOAuth.begin_repository_authorization(),
         :ok <- claim_pending_github_connect(pending_code, user) do
      attempt = Map.put(attempt, "user_code", pending_code)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_session(@attempt_session_key, attempt)
      |> redirect(external: authorization_url)
    else
      {:error, _reason} ->
        auth_failure(conn, "unavailable")
    end
  end

  defp repository_mode?(params) do
    mode = params["mode"] || get_in(params, ["auth", "mode"])
    mode in ["repository", "github_connect"]
  end

  # A CLI-initiated connect names its pending device authorization on the
  # connect page URL. The code is cast, never trusted: claiming only accepts
  # a pending, unexpired, github_connect row owned by nobody, and the device
  # token endpoint refuses to hand any credential out for this kind.
  defp pending_github_connect_code(conn) do
    case get_session(conn, @github_connect_session_key) || conn.params["code"] ||
           get_in(conn.params, ["auth", "code"]) do
      code when is_binary(code) ->
        case DeviceAuthorizations.cast_user_code(code) do
          {:ok, casted} -> casted
          :error -> nil
        end

      _absent ->
        nil
    end
  end

  defp claim_pending_github_connect(nil, _user), do: :ok

  defp claim_pending_github_connect(user_code, user) do
    case DeviceAuthorizations.claim_github_connect(user_code, user) do
      {:ok, _authorization} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    attempt = get_session(conn, @attempt_session_key)

    # Read before the session is cleared below, because clearing it is what
    # takes the remembered device code away.
    landing = landing_path(get_session(conn, OpenAgentsWeb.UserAuth.device_session_key()))

    conn = delete_session(conn, @attempt_session_key)

    with {:ok, attempt = %{"verifier" => verifier, "kind" => kind}} <-
           resume_attempt(attempt, state),
         {:ok, profile, access_token, granted_scopes} <-
           exchange_for_kind(kind, code, verifier),
         {:ok, user} <- Accounts.upsert_github_user(profile),
         {:ok, active_user} <- Accounts.get_active_user(user.id),
         {:ok, _namespace} <- Repositories.ensure_user_namespace(active_user),
         {:ok, _stored} <-
           Accounts.store_github_token(active_user, access_token, granted_scopes) do
      report_connect(kind, active_user, attempt["user_code"])

      if kind == "repository" do
        connect_success(conn, active_user)
      else
        capture_sign_in(active_user)

        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> put_session("user_id", active_user.id)
        |> put_session(@identity_session_key, identity(active_user))
        |> put_resp_header("cache-control", "no-store")
        |> redirect(to: landing)
      end
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

  # A repository grant returns to the connect page: the session must stay
  # intact so the person is still signed in, and the page shows the outcome.
  # The verifier is deleted, but never as a rewrite of the attempt map in the
  # session — the callback is a GET GitHub followed, so a write here would be
  # a second use of a one-time value.
  defp resume_attempt(nil, _state), do: {:error, :invalid_oauth_state}

  defp resume_attempt(attempt, state) when is_map(attempt) do
    with :ok <- GitHubOAuth.consume_attempt(attempt, state) do
      {:ok, attempt}
    end
  end

  defp exchange_for_kind("repository", code, verifier),
    do: GitHubOAuth.repository_exchange_and_fetch(code, verifier)

  defp exchange_for_kind(_kind, code, verifier),
    do: GitHubOAuth.exchange_and_fetch(code, verifier)

  defp report_connect("repository", user, _user_code) do
    Analytics.capture("github_repository_connected", Analytics.distinct_id(user), %{
      "github_login" => user.github_login
    })
  end

  defp report_connect(_kind, _user, _user_code), do: :ok

  defp connect_success(conn, user) do
    conn
    |> put_flash(
      :info,
      "GitHub connected as #{user.github_login}. Repository operations are enabled."
    )
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/github/connect")
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

  # Where a completed sign-in lands.
  #
  # A reader who came from `/device` is halfway through authorizing a terminal,
  # not starting a session at the dashboard. `OpenAgentsWeb.UserAuth` remembers
  # the terminal's code when it bounces them here, and this returns them to the
  # approval with the code still in hand, so approving is the next click rather
  # than a fresh errand.
  #
  # The code is cast a second time on the way out. The session is signed, so
  # this is not defending against a forged cookie; it is keeping one rule —
  # only a value this application mints ever becomes part of a URL — true at
  # every place that builds one, rather than true here because it happened to
  # be checked somewhere else.
  #
  # Nothing writes the key back. It has done its work, and `clear_session/1`
  # above takes it with the rest.
  defp landing_path(code) do
    case DeviceAuthorizations.cast_user_code(code) do
      {:ok, code} -> ~p"/device?user_code=#{code}"
      :error -> ~p"/sarah"
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
