defmodule OpenAgentsWeb.AgentFrontDoorController do
  @moduledoc """
  Serves the agent front door in its two representations.

  `/agents.md` is the address episode 230 gave for standing instructions to
  agents, and `/agents.json` is the same contract as data. Both come from
  `OpenAgentsWeb.ContributionContract`, so a reader who follows the Markdown
  and a client that parses the JSON are following one document.

  The origin the request arrived on is the base URL both representations
  describe, so a staging deployment tells the truth about staging rather than
  advertising production.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgentsWeb.ContributionContract

  def markdown(conn, _params) do
    conn
    |> send_contract("text/markdown; charset=utf-8", ContributionContract.markdown(base(conn)))
  end

  def json(conn, _params) do
    body = conn |> base() |> ContributionContract.document() |> Jason.encode!()

    send_contract(conn, "application/json; charset=utf-8", body)
  end

  defp send_contract(conn, content_type, body) do
    conn
    |> put_resp_content_type_string(content_type)
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("etag", ~s("#{sha256(body)}"))
    |> send_resp(:ok, body)
  end

  # `put_resp_content_type/2` appends its own charset and rejects a type that
  # already carries one, so the header is set directly.
  defp put_resp_content_type_string(conn, content_type),
    do: put_resp_header(conn, "content-type", content_type)

  defp base(conn), do: conn.assigns[:url_base] || OpenAgentsWeb.Endpoint.url()

  defp sha256(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
end
