defmodule OpenAgentsWeb.UserAuth do
  @moduledoc "Session and LiveView authorization for active OpenAgents users."

  use OpenAgentsWeb, :verified_routes

  import Plug.Conn

  alias OpenAgents.Accounts

  @session_key "user_id"

  def put_no_store(conn, _options), do: put_resp_header(conn, "cache-control", "no-store")

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

  def require_admin_user(conn, _options) do
    if Accounts.admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Phoenix.Controller.redirect(to: ~p"/")
      |> halt()
    end
  end

  # Which sections the reader has collapsed, so the first paint already agrees
  # with them. See `OpenAgentsWeb.Plugs.SidebarSections`.
  defp assign_sidebar_sections(socket, session) do
    Phoenix.Component.assign(
      socket,
      :sidebar_sections,
      OpenAgentsWeb.Plugs.SidebarSections.from_session(session)
    )
  end

  # The scope is the user, plus the answers the layout needs on every render
  # and must not re-ask for. Resolved once here, at mount.
  #
  # It deliberately does not depend on the page's params. It used to carry the
  # repository the sidebar's Issues and Projects rows pointed at, read from
  # `:owner`/`:repo` when the route had them, so a global nav row silently
  # retargeted as you browsed. Those rows now address `/issues` and
  # `/projects`, which mean the same thing on every page.
  defp scope(user) do
    %{user | agent_surfaces?: OpenAgents.Conversations.user_has_messages?(user)}
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    socket = assign_sidebar_sections(socket, session)

    with user_id when is_binary(user_id) <- session[@session_key],
         {:ok, user} <- Accounts.get_active_user(user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:current_scope, scope(user))}
    else
      _missing_or_inactive ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:current_user, nil)
         |> Phoenix.Component.assign(:current_scope, nil)}
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = assign_sidebar_sections(socket, session)

    with user_id when is_binary(user_id) <- session[@session_key],
         {:ok, user} <- Accounts.get_active_user(user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:current_scope, scope(user))
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

  def on_mount(:ensure_admin, _params, _session, socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         {:ok, user} <- Accounts.get_active_user(user_id),
         true <- Accounts.admin?(user) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.LiveView.attach_hook(:admin_guard, :handle_event, &ensure_admin_event/3)}
    else
      _not_an_operator ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
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

  defp ensure_admin_event(_event, _params, socket) do
    with {:ok, user} <- Accounts.get_active_user(socket.assigns.current_user.id),
         true <- Accounts.admin?(user) do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      _not_an_operator -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  def require_authenticated_api_user(
        %{assigns: %{current_user: %{status: "active"}}} = conn,
        _options
      ),
      do: conn

  def require_authenticated_api_user(conn, _options) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_header("cache-control", "no-store")
    |> Phoenix.Controller.json(%{error: "authentication_required"})
    |> halt()
  end

  def require_operator_api_user(conn, _options) do
    if Accounts.admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> put_resp_header("cache-control", "no-store")
      |> Phoenix.Controller.json(%{error: "operator_required"})
      |> halt()
    end
  end
end
