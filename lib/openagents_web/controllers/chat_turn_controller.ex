defmodule OpenAgentsWeb.ChatTurnController do
  @moduledoc """
  Bearer-authenticated access to an account's durable chat turns.

  A turn may name the backend that answers it with `model`, whose supported
  values `GET /api/v1` publishes. An unsupported value is refused with a
  field-level `422` rather than quietly answered by the default, because a
  caller that asked for one model and was served another has no way to tell.
  """

  use OpenAgentsWeb, :controller

  alias OpenAgents.Chat.{AccountTurns, Backends}
  alias OpenAgentsWeb.ApiError

  def index(conn, _params) do
    json(conn, %{"events" => AccountTurns.list_events(conn.assigns.current_user)})
  end

  def create(conn, %{"message" => message} = params) when is_binary(message) do
    case Backends.fetch(params["model"]) do
      {:ok, backend} -> submit(conn, message, params, backend)
      {:error, :unsupported_backend} -> unsupported_model(conn, params["model"])
    end
  end

  def create(conn, _params), do: error(conn, :unprocessable_entity, "invalid_message")

  defp submit(conn, message, params, backend) do
    case AccountTurns.submit(conn.assigns.current_user, message,
           reasoning: params["reasoning"],
           backend: backend.id
         ) do
      {:ok, turn} -> conn |> put_status(:accepted) |> json(%{"turn" => turn})
      {:error, reason} -> submit_error(conn, reason)
    end
  end

  # The envelope names the field and the values that would have worked, so a
  # client corrects the request from the refusal instead of from the docs. The
  # legacy `error` key stays beside it for the clients already reading it.
  defp unsupported_model(conn, value) do
    ApiError.validation_failed(
      conn,
      %{
        "model" => [
          "#{inspect(value)} is not a supported model. " <>
            "Supported: #{Enum.join(Backends.ids(), ", ")}."
        ]
      },
      legacy: %{"error" => "unsupported_model"}
    )
  end

  defp submit_error(conn, :empty_message),
    do: error(conn, :unprocessable_entity, "empty_message")

  defp submit_error(conn, :message_too_long),
    do: error(conn, :unprocessable_entity, "message_too_long")

  defp submit_error(conn, :invalid_message),
    do: error(conn, :unprocessable_entity, "invalid_message")

  defp submit_error(conn, :rate_limited), do: error(conn, :too_many_requests, "rate_limited")
  defp submit_error(conn, :turn_in_progress), do: error(conn, :conflict, "turn_in_progress")

  defp submit_error(conn, :turn_start_failed),
    do: error(conn, :service_unavailable, "turn_start_failed")

  defp submit_error(conn, _reason), do: error(conn, :unprocessable_entity, "turn_not_created")

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{"error" => code})
end
