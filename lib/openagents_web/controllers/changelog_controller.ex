defmodule OpenAgentsWeb.ChangelogController do
  @moduledoc """
  `GET /api/changelog` — the machine-readable changelog
  (schema `openagents.changelog.v1`), the superset of the public `/changelog`
  page including receipt row ids so agents can cross-check every claim
  against the receipt chain. Same posture as `/api/status`: public,
  read-only, bounded, no identity state.
  """

  use OpenAgentsWeb, :controller

  import OpenAgentsWeb.UserAuth, only: [fetch_current_user: 2]

  plug :fetch_session
  plug :fetch_current_user

  def show(conn, params) do
    repo = Map.get(params, "repo", "openagents.com")
    viewer = conn.assigns[:current_user]

    case OpenAgents.Changelog.projection(repo, viewer: viewer) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :not_public} ->
        conn |> put_status(:not_found) |> json(%{"error" => "not found"})
    end
  end
end
