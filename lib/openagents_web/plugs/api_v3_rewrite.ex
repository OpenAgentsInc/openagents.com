defmodule OpenAgentsWeb.Plugs.ApiV3Rewrite do
  @moduledoc """
  Transparently rewrites `/api/v3/*` requests to `/api/v1/*`.

  During the `/api/v3` to `/api/v1` migration, legacy clients continue to call
  `/api/v3/*`. This plug modifies `conn.path_info` so the router routes the
  request to the `/api/v1` scopes without requiring an HTTP redirect.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api", "v3" | rest]} = conn, _opts) do
    %{conn | path_info: ["api", "v1" | rest]}
  end

  def call(conn, _opts), do: conn
end
