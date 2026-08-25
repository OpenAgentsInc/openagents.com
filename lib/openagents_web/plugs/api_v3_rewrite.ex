defmodule OpenAgentsWeb.Plugs.ApiV3Rewrite do
  @moduledoc """
  Transparently rewrites `/api/v3/*` requests to `/api/v1/*`.

  The API moved from `/api/v3` to `/api/v1` in one deploy, so clients released
  against the old prefix keep working while the fleet upgrades. This plug
  modifies `conn.path_info` before the router sees it, rather than redirecting,
  because the old clients `POST` and do not follow redirects reliably.

  The alias is dated, not permanent. It exists for released clients, not for
  `gh`: `gh` reaches a non-github.com host at `/api/v3`, but its ported
  commands run on GraphQL and `GET /api/v3/meta`, neither of which this
  application serves, so keeping the prefix would not make `gh` work. See
  `docs/decisions/0009-serve-a-github-shaped-api-not-a-gh-compatible-one.md`
  and `INVARIANTS.md`, FORGEAPI-002.

  This module is the only place in `lib/` that names the old prefix. Nothing
  routes at it and no response emits it, which is what makes deleting the alias
  a one-file change.
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
