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
        "connect-src 'self' ws: wss:",
        "frame-ancestors 'none'",
        "img-src 'self' data: https://avatars.githubusercontent.com",
        "object-src 'none'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'"
      ],
      "; "
    )
  end
end
