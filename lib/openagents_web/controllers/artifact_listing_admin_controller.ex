defmodule OpenAgentsWeb.ArtifactListingAdminController do
  use OpenAgentsWeb, :controller

  alias OpenAgents.ArtifactCatalog
  alias OpenAgents.ArtifactCatalog.Listing
  alias OpenAgents.ArtifactCatalog.Receipt

  def create(conn, params) do
    case ArtifactCatalog.publish_listing(params) do
      {:ok, listing} ->
        conn
        |> put_status(:created)
        |> json(%{"listing" => Listing.public_projection(listing)})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    attributes =
      params
      |> Map.put_new("actor_ref", conn.assigns.current_user.github_login)
      |> Map.put_new("receipt_ref", "artifact-removal:#{Ecto.UUID.generate()}")

    case ArtifactCatalog.remove_listing(id, attributes) do
      {:ok, listing} ->
        json(conn, %{
          "listing_id" => listing.id,
          "listing_digest" => listing.listing_digest,
          "state" => listing.state,
          "removed_at" => listing.removed_at
        })

      {:error, reason} ->
        operation_error(conn, reason)
    end
  end

  def export(conn, %{"id" => id}) do
    case ArtifactCatalog.export_listing_history(id) do
      {:ok, export} ->
        conn
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="artifact-listing-history-#{id}.json")
        )
        |> json(export)

      {:error, reason} ->
        operation_error(conn, reason)
    end
  end

  def record(conn, %{"id" => id, "action" => action} = params) do
    case ArtifactCatalog.record_transaction(id, action, params) do
      {:ok, %Receipt{} = receipt} ->
        conn
        |> put_status(:created)
        |> json(%{"receipt" => Receipt.projection(receipt)})

      {:error, reason} ->
        operation_error(conn, reason)
    end
  end

  def authorize(conn, %{"id" => id} = params) do
    case ArtifactCatalog.authorize_source_access(id, params) do
      {:ok, authorization} ->
        json(conn, %{"authorization" => authorization})

      {:error, reason} ->
        operation_error(conn, reason)
    end
  end

  defp validation_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "invalid_listing", "fields" => errors})
  end

  defp operation_error(conn, reason) do
    status =
      case reason do
        :not_found -> :not_found
        :not_authorized -> :forbidden
        :listing_removed -> :conflict
        :stale_license -> :conflict
        {:digest_mismatch, _field} -> :unprocessable_entity
        {:invalid_predecessor, _action} -> :unprocessable_entity
        %Ecto.Changeset{} -> :unprocessable_entity
        _other -> :unprocessable_entity
      end

    conn
    |> put_status(status)
    |> json(%{"error" => error_code(reason)})
  end

  defp error_code({:digest_mismatch, field}), do: "digest_mismatch:#{field}"
  defp error_code({:invalid_predecessor, action}), do: "invalid_predecessor:#{action}"
  defp error_code(%Ecto.Changeset{}), do: "invalid_receipt"
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
end
