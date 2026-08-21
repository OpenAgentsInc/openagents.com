defmodule OpenAgentsWeb.Plugs.PostHogBootstrap do
  @moduledoc """
  Assigns the browser analytics bootstrap values the root layout renders as
  data attributes.

  The token and host come from boot configuration; the identity comes from the
  `posthog_identity` session key written at login, so no database query runs on
  the render path. When capture is unconfigured, `posthog_enabled` is false and
  the browser bundle skips initialization entirely.
  """

  use Plug.Builder

  import Plug.Conn

  plug :assign_posthog_bootstrap

  defp assign_posthog_bootstrap(conn, _opts) do
    conn
    |> assign(:posthog_enabled, OpenAgents.Analytics.enabled?())
    |> assign(:posthog_token, Application.get_env(:openagents, :posthog_project_token))
    |> assign(:posthog_api_host, Application.get_env(:openagents, :posthog_api_host))
    |> assign(:posthog_identity, get_session(conn, "posthog_identity"))
  end
end
