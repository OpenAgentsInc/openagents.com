defmodule OpenAgentsWeb.TraceController do
  @moduledoc """
  Accept ATIF v1 trace uploads at `POST /api/v3/traces`.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Traces
  alias OpenAgentsWeb.ApiError

  def create(conn, params) do
    document = conn.body_params
    visibility = parse_visibility(params)

    case Traces.store(conn.assigns.current_user, document, visibility: visibility) do
      {:ok, trace, :created} ->
        conn
        |> put_status(:created)
        |> json(trace_view(trace))

      {:ok, trace, :existing} ->
        conn
        |> put_status(:ok)
        |> json(trace_view(trace))

      {:error, :body_too_large} ->
        ApiError.refuse(conn, "trace_body_too_large")

      {:error, :invalid_atif} ->
        ApiError.validation_failed(conn, %{
          "document" => ["The document is not a valid ATIF v1 object."]
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        ApiError.changeset(conn, changeset)
    end
  end

  defp parse_visibility(params) do
    case Map.get(params, "visibility") do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp trace_view(trace) do
    %{
      "id" => trace.id,
      "url" => OpenAgentsWeb.Endpoint.url() <> "/api/v3/traces/" <> trace.id,
      "digest" => trace.digest,
      "byte_size" => trace.byte_size,
      "visibility" => trace.visibility,
      "inserted_at" => DateTime.to_iso8601(trace.inserted_at)
    }
  end
end
