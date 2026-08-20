defmodule OpenAgentsWeb.NetworkStatusController do
  @moduledoc """
  `GET /api/status` — the full machine-readable network-state projection
  (schema `openagents.network_status.v1`, see `OpenAgents.NetworkStatus`). A superset of
  the legacy `/status` payload (`status`/`revision` keys are preserved), so
  pollers migrate here without a translation step. Public, bounded,
  content-free (STATUS-001).
  """

  use OpenAgentsWeb, :controller

  def show(conn, _params) do
    json(conn, OpenAgents.NetworkStatus.projection())
  end
end
