defmodule OpenAgentsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use OpenAgentsWeb, :controller
      use OpenAgentsWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths,
    do:
      ~w(assets fonts images favicon.ico favicon-32x32.png favicon-16x16.png apple-touch-icon.png robots.txt install.sh install.ps1)

  @doc """
  Prefixes for static files that are served under a digested name.

  `Plug.Static`'s `:only` matches a whole path segment, and digesting rewrites
  the segment: `favicon-32x32.png` is requested as
  `favicon-32x32-<hash>.png`, which matches nothing in `static_paths/0` and is
  refused. Every file listed there that sits at the root -- rather than inside
  `assets`, `fonts` or `images`, whose directory name is the segment being
  matched -- needs a prefix here or it 404s in any environment that digests.

  It only widens what may be served to names that begin this way; a file still
  has to exist in `priv/static` to be sent.
  """
  def static_prefixes, do: ~w(favicon apple-touch-icon robots install)

  @doc """
  `Plug.Static` options for this application's endpoint.

  Assembled here rather than written inline in the endpoint so a test can hold
  the real options against a real `Plug.Static` and check that a digested file
  is actually served.
  """
  def static_options(overrides \\ []) do
    Keyword.merge(
      [
        at: "/",
        from: :openagents,
        only: static_paths(),
        only_matching: static_prefixes()
      ],
      overrides
    )
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: OpenAgentsWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())

      import OpenAgentsWeb.Components.RepoHeader
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: OpenAgentsWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # OpenAgents interface primitives
      import OpenAgentsWeb.UI

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias OpenAgentsWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: OpenAgentsWeb.Endpoint,
        router: OpenAgentsWeb.Router,
        statics: OpenAgentsWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
