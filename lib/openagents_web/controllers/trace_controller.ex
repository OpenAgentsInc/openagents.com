defmodule OpenAgentsWeb.TraceController do
  @moduledoc """
  Accept ATIF v1 trace uploads at `POST /api/v1/traces`.

  A document may name the attempt it is a trajectory of, as
  `assignment_id`, which is what lets the issue that attempt was admitted
  against say a trajectory exists. Only the account that requested the attempt
  may bind to it; anybody else is refused rather than having the binding
  dropped. What an issue's readers then learn is decided by
  `OpenAgents.Issues.TraceDisclosure`, and it is never the document.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Traces
  alias OpenAgentsWeb.ApiError

  def create(conn, params) do
    document = conn.body_params
    visibility = parse_visibility(params)
    assignment_id = parse_assignment_id(params, document)

    options = [visibility: visibility, assignment_id: assignment_id]

    case Traces.store(conn.assigns.current_user, document, options) do
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

      {:error, :trace_assignment_forbidden} ->
        ApiError.refuse(conn, "trace_assignment_forbidden")

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

  # Read from the query string or from the document, in that order. The
  # document is the natural home for a client that produced the trajectory
  # under an attempt it already knows the id of, and either way the claim is
  # checked against the attempt rather than believed.
  defp parse_assignment_id(params, document) do
    case Map.get(params, "assignment_id") || Map.get(document, "assignment_id") do
      value when is_binary(value) -> String.trim(value)
      _absent -> nil
    end
  end

  defp trace_view(trace) do
    %{
      "id" => trace.id,
      "url" => OpenAgentsWeb.Endpoint.url() <> "/api/v1/traces/" <> trace.id,
      "digest" => trace.digest,
      "byte_size" => trace.byte_size,
      "visibility" => trace.visibility,
      "inserted_at" => DateTime.to_iso8601(trace.inserted_at)
    }
  end
end
