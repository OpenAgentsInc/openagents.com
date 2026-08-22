defmodule OpenAgentsWeb.Plugs.RequestOrigin do
  @moduledoc """
  Assigns `:url_base`, the origin the request actually arrived on.

  The value comes from the conn scheme, host, and port. Phoenix rewrites
  `conn.scheme` through trusted proxy headers such as `X-Forwarded-Proto`
  only when the endpoint declares `rewrite_on`, so untrusted forwarded
  headers cannot invent an origin here. API responses use this base to
  build resource URLs instead of advertising a hardcoded production host.
  """

  import Plug.Conn

  def init(options), do: options

  def call(conn, _options) do
    assign(conn, :url_base, base_url(conn))
  end

  defp base_url(conn) do
    case conn.port do
      port when port in [80, 443] ->
        "#{conn.scheme}://#{conn.host}"

      port ->
        "#{conn.scheme}://#{conn.host}:#{port}"
    end
  end
end
