defmodule OpenAgentsWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Adds the browser content security policy and one response-scoped script nonce.

  The root layout uses the nonce only for the synchronous theme bootstrap. All
  other JavaScript remains in the same-origin application bundle.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "base-uri 'self'",
        # The PostHog ingest and asset hosts carry browser analytics batches
        # (docs/2026-08-21-posthog-integration-runbook.md).
        "connect-src 'self' ws: wss: https://us.i.posthog.com https://us-assets.i.posthog.com",
        "frame-ancestors 'none'",
        "img-src 'self' data: https://avatars.githubusercontent.com",
        "object-src 'none'",
        # `posthog-js` is bundled, but it loads optional browser modules from
        # PostHog's versioned asset host after it receives remote configuration.
        "script-src 'self' 'nonce-#{nonce}' https://us-assets.i.posthog.com",
        "style-src 'self' 'unsafe-inline'"
      ],
      "; "
    )
  end
end
