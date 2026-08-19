defmodule OpenAgentsWeb.UserAuth do
  @moduledoc "Session and LiveView authorization for active OpenAgents users."

  use OpenAgentsWeb, :verified_routes

  import Plug.Conn

  alias OpenAgents.Accounts

  @session_key "user_id"

  def fetch_current_user(conn, _options) do
    with user_id when is_binary(user_id) <- get_session(conn, @session_key),
         {:ok, user} <- Accounts.get_active_user(user_id) do
      Plug.Conn.assign(conn, :current_user, user)
    else
      _missing_or_inactive ->
        conn
        |> delete_session(@session_key)
        |> Plug.Conn.assign(:current_user, nil)
    end
  end

  def require_authenticated_user(
        %{assigns: %{current_user: %{status: "active"}}} = conn,
        _options
      ),
      do: conn

  def require_authenticated_user(conn, _options) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.redirect(to: ~p"/")
    |> halt()
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    with user_id when is_binary(user_id) <- session[@session_key],
         {:ok, user} <- Accounts.get_active_user(user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:current_scope, user)}
    else
      _missing_or_inactive ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:current_user, nil)
         |> Phoenix.Component.assign(:current_scope, nil)}
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    with user_id when is_binary(user_id) <- session[@session_key],
         {:ok, user} <- Accounts.get_active_user(user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:current_scope, user)
       |> Phoenix.LiveView.attach_hook(
         :active_user_guard,
         :handle_event,
         &ensure_active_event/3
       )}
    else
      _missing_or_inactive ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Log in with GitHub to continue.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  defp ensure_active_event(_event, _params, socket) do
    case Accounts.get_active_user(socket.assigns.current_user.id) do
      {:ok, user} ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      {:error, _inactive_or_missing} ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "This session is no longer active.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
