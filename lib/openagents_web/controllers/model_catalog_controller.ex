defmodule OpenAgentsWeb.ModelCatalogController do
  @moduledoc """
  `GET /api/v3/models`: the typed model catalog this deployment serves.

  The CLI renders model selection from this list instead of guessing, so it is
  the same list every admission checks against — `OpenAgents.Inference.Models`
  admits a thread's model, refuses a grant, and routes the proxy from the one
  catalog this endpoint publishes (PROVIDER-002). A model whose provider
  credential is not configured is listed with availability `unavailable`
  rather than omitted, so a client can tell "not served here" from "served
  here, not currently configured"; selecting it is refused with
  `model_unavailable`, never answered by another model.

  Behind the same bearer scope as threads: the catalog names what a thread
  grant can be minted for, so the caller who can open a thread is the caller
  who reads it.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Inference.Models

  def index(conn, _params) do
    json(conn, %{
      "models" => Models.catalog(),
      "default" => Models.default_id()
    })
  end
end
