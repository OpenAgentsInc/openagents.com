defmodule OpenAgentsWeb.ChatTurnController do
  @moduledoc "Bearer-authenticated access to an account's durable chat turns."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Chat.AccountTurns

  def index(conn, _params) do
    json(conn, %{"events" => AccountTurns.list_events(conn.assigns.current_user)})
  end

  def create(conn, %{"message" => message} = params) when is_binary(message) do
    case AccountTurns.submit(conn.assigns.current_user, message, reasoning: params["reasoning"]) do
      {:ok, turn} -> conn |> put_status(:accepted) |> json(%{"turn" => turn})
      {:error, reason} -> submit_error(conn, reason)
    end
  end

  def create(conn, _params), do: error(conn, :unprocessable_entity, "invalid_message")

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
