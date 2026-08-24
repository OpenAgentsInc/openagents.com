defmodule OpenAgentsWeb.ForgeAnchorController do
  @moduledoc """
  Serve the published WAL anchor (`EXIT-005`, ADR 0008).

  The stored bytes are served verbatim, because the digest a reader computes is
  a digest of the bytes they fetched and the next anchor names that digest as
  its `previous_digest`. Re-encoding the document from columns would let key
  order drift between releases and turn every archived copy into apparent
  tampering.

  Anonymous by construction: an anchor a reader has to authenticate for is an
  anchor the operator can withhold from the reader who would check it. There is
  nothing here to withhold anyway — the document names only repositories an
  anonymous reader can already see.

  What re-fetching settles is nothing, and the document says so on its face.
  The evidence is the copy a reader *kept*: an operator who rewrote the log
  would serve the rewritten head here too.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Forge.Anchor

  def show(conn, _params) do
    case Anchor.latest() do
      %{body: body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      nil ->
        # Not an error, and not a silence either. A reader who fetches this
        # path deserves to be told that nothing is anchored yet rather than to
        # read a 404 as "wrong URL".
        conn
        |> put_status(:not_found)
        |> json(%{
          "schema" => Anchor.schema(),
          "published" => false,
          "reason" => "no anchor has been published yet",
          "decision" => "docs/decisions/0008-publish-the-forge-wal-anchor-at-a-well-known-path.md"
        })
    end
  end
end
