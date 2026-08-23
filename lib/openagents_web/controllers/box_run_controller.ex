defmodule OpenAgentsWeb.BoxRunController do
  @moduledoc "Authenticated API access to durable detached Box runs."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Box
  alias OpenAgents.Box.Run
  alias OpenAgents.BoxRuns
  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Conversation
  alias OpenAgentsWeb.BoxRateLimiter

  @maximum_command_bytes 8_000
  @maximum_idempotency_key_bytes 256

  def create(conn, %{
        "conversation_id" => conversation_id,
        "box_id" => box_id,
        "command" => command
      })
      when is_binary(command) do
    idempotency_key =
      Map.get(conn.params, "idempotency_key") ||
        List.first(Plug.Conn.get_req_header(conn, "idempotency-key"))

    with :ok <- validate_command(command),
         :ok <- validate_idempotency_key(idempotency_key),
         {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         :ok <- BoxRateLimiter.allow?(conn.assigns.current_user.id, :run_create),
         {:ok, run} <-
           BoxRuns.start_run(
             conversation_id,
             box_id,
             %{"type" => "user", "id" => conn.assigns.current_user.id},
             command,
             idempotency_key
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{"run" => projection(run)})
    else
      {:error, :invalid_command} ->
        refusal(conn, :unprocessable_entity, "invalid_command")

      {:error, :invalid_idempotency_key} ->
        refusal(conn, :unprocessable_entity, "invalid_idempotency_key")

      {:error, :not_found} ->
        refusal(conn, :not_found, "conversation_not_found")

      {:error, :rate_limited} ->
        refusal(conn, :too_many_requests, "box_api_rate_limited")

      {:error, reason} ->
        run_error(conn, reason)
    end
  end

  def create(conn, _params), do: refusal(conn, :unprocessable_entity, "invalid_command")

  def index(conn, %{"conversation_id" => conversation_id, "box_id" => box_id}) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         {:ok, _box} <- Box.get_box(conversation_id, box_id) do
      json(conn, %{"runs" => Enum.map(BoxRuns.list_runs(conversation_id, box_id), &projection/1)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, reason} -> run_error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, _conversation} <- owned_conversation(conn, params["conversation_id"]),
         {:ok, run} <- owned_run(params) do
      json(conn, %{"run" => projection(run)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :run_not_found} -> refusal(conn, :not_found, "box_run_not_found")
    end
  end

  def output(conn, params) do
    with {:ok, _conversation} <- owned_conversation(conn, params["conversation_id"]),
         {:ok, run} <- owned_run(params),
         {:ok, offset} <- parse_offset(params["offset"]),
         {:ok, result} <- BoxRuns.read_output(run, offset) do
      json(conn, %{"run_id" => run.id, "output" => result})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :run_not_found} -> refusal(conn, :not_found, "box_run_not_found")
      {:error, :invalid_offset} -> refusal(conn, :unprocessable_entity, "invalid_output_offset")
    end
  end

  def cancel(conn, params) do
    with {:ok, _conversation} <- owned_conversation(conn, params["conversation_id"]),
         {:ok, run} <- owned_run(params),
         {:ok, run} <- BoxRuns.cancel(run) do
      conn
      |> put_status(:accepted)
      |> json(%{"run" => projection(run)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :run_not_found} -> refusal(conn, :not_found, "box_run_not_found")
      {:error, reason} -> run_error(conn, reason)
    end
  end

  defp owned_conversation(conn, conversation_id) do
    case Conversations.get_conversation_for_user(conn.assigns.current_user, conversation_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end

  defp owned_run(params) do
    case BoxRuns.get_run(params["conversation_id"], params["box_id"], params["run_id"]) do
      {:ok, run} -> {:ok, run}
      {:error, :not_found} -> {:error, :run_not_found}
    end
  end

  defp validate_command(command) do
    if String.trim(command) != "" and String.valid?(command) and
         not String.contains?(command, "\0") and byte_size(command) <= @maximum_command_bytes do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp validate_idempotency_key(key)
       when is_binary(key) and byte_size(key) > 0 and
              byte_size(key) <= @maximum_idempotency_key_bytes,
       do: :ok

  defp validate_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp parse_offset(nil), do: {:ok, 0}
  defp parse_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}

  defp parse_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {value, ""} when value >= 0 -> {:ok, value}
      _invalid -> {:error, :invalid_offset}
    end
  end

  defp parse_offset(_offset), do: {:error, :invalid_offset}

  defp projection(%Run{} = run) do
    %{
      "id" => run.id,
      "box_id" => run.conversation_box.box_id,
      "command" => run.command,
      "state" => run.state,
      "exit_status" => run.exit_status,
      "timed_out" => run.timed_out,
      "output_offset" => run.last_output_offset,
      "output_base_offset" => run.output_base_offset,
      "failure_reason" => run.failure_reason,
      "admitted_at" => iso8601(run.admitted_at),
      "dispatched_at" => iso8601(run.dispatched_at),
      "started_at" => iso8601(run.started_at),
      "finished_at" => iso8601(run.finished_at),
      "deadline_at" => iso8601(run.deadline_at),
      "cancellation_requested_at" => iso8601(run.cancellation_requested_at),
      "cancellation_effective_at" => iso8601(run.cancellation_effective_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp run_error(conn, :box_run_in_progress),
    do: refusal(conn, :conflict, "box_run_in_progress")

  defp run_error(conn, :box_run_idempotency_conflict),
    do: refusal(conn, :conflict, "box_run_idempotency_conflict")

  defp run_error(conn, :box_quota_reached),
    do: refusal(conn, :conflict, "box_quota_reached")

  defp run_error(conn, reason) when reason in [:box_not_owned, :box_not_found],
    do: refusal(conn, :not_found, "box_not_found")

  defp run_error(conn, :box_billing_required),
    do: refusal(conn, :payment_required, "box_billing_required")

  defp run_error(conn, :box_rate_limited),
    do: refusal(conn, :too_many_requests, "box_provider_rate_limited")

  defp run_error(conn, reason) when reason in [:box_not_configured, :box_unreachable],
    do: refusal(conn, :service_unavailable, Atom.to_string(reason))

  defp run_error(conn, :box_response_invalid),
    do: refusal(conn, :bad_gateway, "box_provider_response_invalid")

  defp run_error(conn, {:box_request_refused, _status, _code}),
    do: refusal(conn, :bad_gateway, "box_provider_request_refused")

  defp run_error(conn, :box_unauthorized),
    do: refusal(conn, :bad_gateway, "box_provider_unauthorized")

  defp run_error(conn, :box_stopped),
    do: refusal(conn, :conflict, "box_stopped")

  defp run_error(conn, :box_not_ready),
    do: refusal(conn, :conflict, "box_not_ready")

  defp run_error(conn, reason), do: refusal(conn, :bad_gateway, Atom.to_string(reason))

  defp refusal(conn, status, code) do
    conn |> put_status(status) |> json(%{"error" => %{"code" => code}})
  end
end
