defmodule OpenAgentsWeb.BoxController do
  @moduledoc "Authenticated API access to conversation-owned Box computers."

  use OpenAgentsWeb, :controller

  alias OpenAgents.{Box, Conversations}
  alias OpenAgents.Conversations.Conversation
  alias OpenAgents.Tools.BoxOutput
  alias OpenAgentsWeb.BoxRateLimiter

  @default_timeout_seconds 60
  @maximum_timeout_seconds 570

  def index(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id) do
      boxes = Box.list_boxes(conversation_id)
      json(conn, %{"boxes" => Enum.map(boxes, &box_projection/1)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         :ok <- BoxRateLimiter.allow?(conn.assigns.current_user.id, :create),
         {:ok, record} <- Box.create_box(conversation_id, label: params["label"]) do
      conn
      |> put_status(:created)
      |> json(%{"box" => box_projection(record)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :rate_limited} -> refusal(conn, :too_many_requests, "box_api_rate_limited")
      {:error, reason} -> box_error(conn, reason)
    end
  end

  def show(conn, %{"conversation_id" => conversation_id, "box_id" => box_id}) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         {:ok, record} <- Box.get_box(conversation_id, box_id) do
      json(conn, %{"box" => box_projection(record)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, reason} -> box_error(conn, reason)
    end
  end

  def command(
        conn,
        %{"conversation_id" => conversation_id, "box_id" => box_id, "command" => command} = params
      )
      when is_binary(command) do
    with :ok <- validate_command(command),
         {:ok, timeout_seconds} <- timeout_seconds(params),
         {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         :ok <- BoxRateLimiter.allow?(conn.assigns.current_user.id, :command),
         {:ok, body} <- Box.run_command(conversation_id, box_id, command, timeout_seconds) do
      json(conn, %{"result" => command_projection(box_id, body)})
    else
      {:error, :invalid_command} ->
        refusal(conn, :unprocessable_entity, "invalid_command")

      {:error, :invalid_command_timeout} ->
        refusal(conn, :unprocessable_entity, "invalid_command_timeout")

      {:error, :not_found} ->
        refusal(conn, :not_found, "conversation_not_found")

      {:error, :rate_limited} ->
        refusal(conn, :too_many_requests, "box_api_rate_limited")

      {:error, reason} ->
        box_error(conn, reason)
    end
  end

  def command(conn, _params), do: refusal(conn, :unprocessable_entity, "invalid_command")

  def stop(conn, %{"conversation_id" => conversation_id, "box_id" => box_id}) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         {:ok, record} <- Box.stop_box(conversation_id, box_id) do
      json(conn, %{"box" => box_projection(record)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, reason} -> box_error(conn, reason)
    end
  end

  defp owned_conversation(conn, conversation_id) do
    case Conversations.get_conversation_for_user(conn.assigns.current_user, conversation_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end

  defp box_projection(record) do
    %{
      "box_id" => record.box_id,
      "label" => record.label,
      "state" => record.state,
      "setup_status" => record.setup_status,
      "created_at" => iso8601(record.inserted_at),
      "updated_at" => iso8601(record.updated_at),
      "stopped_at" => iso8601(record.stopped_at)
    }
  end

  defp command_projection(box_id, body) do
    {stdout, stdout_truncated} = BoxOutput.bounded(body["stdout"])
    {stderr, stderr_truncated} = BoxOutput.bounded(body["stderr"])

    %{
      "box_id" => box_id,
      "exit_code" => body["exitCode"],
      "stdout" => stdout,
      "stderr" => stderr,
      "timed_out" => body["timedOut"] == true,
      "stdout_truncated" => stdout_truncated or body["stdoutTruncated"] == true,
      "stderr_truncated" => stderr_truncated or body["stderrTruncated"] == true
    }
  end

  defp validate_command(command) do
    cond do
      String.trim(command) == "" -> {:error, :invalid_command}
      not String.valid?(command) -> {:error, :invalid_command}
      String.contains?(command, "\0") -> {:error, :invalid_command}
      byte_size(command) > 4_000 -> {:error, :invalid_command}
      true -> :ok
    end
  end

  defp timeout_seconds(params) do
    case Map.get(params, "timeout_seconds", @default_timeout_seconds) do
      seconds
      when is_integer(seconds) and seconds >= 1 and seconds <= @maximum_timeout_seconds ->
        {:ok, seconds}

      _invalid ->
        {:error, :invalid_command_timeout}
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp box_error(conn, :box_quota_reached),
    do: refusal(conn, :conflict, "box_quota_reached")

  defp box_error(conn, :box_owner_quota_reached),
    do: refusal(conn, :conflict, "box_owner_quota_reached")

  defp box_error(conn, :box_global_quota_reached),
    do: refusal(conn, :conflict, "box_global_quota_reached")

  defp box_error(conn, :box_label_taken),
    do: refusal(conn, :conflict, "box_label_taken")

  defp box_error(conn, reason) when reason in [:box_not_owned, :box_not_found],
    do: refusal(conn, :not_found, "box_not_found")

  defp box_error(conn, :box_billing_required),
    do: refusal(conn, :payment_required, "box_billing_required")

  defp box_error(conn, :box_rate_limited),
    do: refusal(conn, :too_many_requests, "box_provider_rate_limited")

  defp box_error(conn, reason) when reason in [:box_not_configured, :box_unreachable],
    do: refusal(conn, :service_unavailable, Atom.to_string(reason))

  defp box_error(conn, :box_response_invalid),
    do: refusal(conn, :bad_gateway, "box_provider_response_invalid")

  defp box_error(conn, {:box_request_refused, _status, _code}),
    do: refusal(conn, :bad_gateway, "box_provider_request_refused")

  defp box_error(conn, :box_unauthorized),
    do: refusal(conn, :bad_gateway, "box_provider_unauthorized")

  defp box_error(conn, :box_stopped),
    do: refusal(conn, :conflict, "box_stopped")

  defp box_error(conn, :box_not_ready),
    do: refusal(conn, :conflict, "box_not_ready")

  defp box_error(conn, _reason), do: refusal(conn, :bad_gateway, "box_request_failed")

  defp refusal(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"code" => code}})
  end
end
