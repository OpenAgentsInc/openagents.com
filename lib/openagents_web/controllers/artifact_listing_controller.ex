defmodule OpenAgentsWeb.ArtifactListingController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.ArtifactCatalog.Listing

  def index(conn, params) do
    listings =
      params
      |> ArtifactCatalog.list_public_listings()
      |> Enum.map(&Listing.public_projection/1)

    json(conn, %{"listings" => listings})
  end

  def show(conn, %{"id" => id}) do
    case ArtifactCatalog.get_public_listing(id) do
      {:ok, listing} ->
        json(conn, %{"listing" => Listing.public_projection(listing)})

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def export(conn, %{"id" => id}) do
    case ArtifactCatalog.export_public_listing(id) do
      {:ok, export} ->
        conn
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="artifact-listing-#{id}.json")
        )
        |> json(export)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "listing_not_found"})
  end
end
