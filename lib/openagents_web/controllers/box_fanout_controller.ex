defmodule OpenAgentsWeb.BoxFanoutController do
  @moduledoc "Authenticated API access to durable Box fan-out admission plans."

  use OpenAgentsWeb, :controller

  alias OpenAgents.Conversations
  alias OpenAgents.Box.Fanout
  alias OpenAgents.Conversations.Conversation
  alias OpenAgentsWeb.BoxRateLimiter

  @maximum_requested_count 100

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         {:ok, count} <- requested_count(params),
         {:ok, labels} <- labels(params),
         :ok <- BoxRateLimiter.allow?(conn.assigns.current_user.id, :create),
         {:ok, plan} <-
           Fanout.admit(
             conversation_id,
             %{"type" => "user", "id" => conn.assigns.current_user.id},
             count,
             labels: labels,
             budgeted: budgeted?(params)
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{"plan" => projection(plan)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :conversation_not_found} -> refusal(conn, :not_found, "conversation_not_found")
      {:error, :invalid_box_count} -> refusal(conn, :unprocessable_entity, "invalid_box_count")
      {:error, :invalid_box_labels} -> refusal(conn, :unprocessable_entity, "invalid_box_labels")
      {:error, :box_label_taken} -> refusal(conn, :conflict, "box_label_taken")
      {:error, :rate_limited} -> refusal(conn, :too_many_requests, "box_api_rate_limited")
      {:error, reason} -> fanout_error(conn, reason)
    end
  end

  def create(conn, _params), do: refusal(conn, :unprocessable_entity, "invalid_box_count")

  def show(conn, %{"conversation_id" => conversation_id, "request_id" => request_id}) do
    with {:ok, _conversation} <- owned_conversation(conn, conversation_id),
         {:ok, plan} <- Fanout.get(conversation_id, request_id) do
      json(conn, %{"plan" => projection(plan)})
    else
      {:error, :not_found} -> refusal(conn, :not_found, "conversation_not_found")
    end
  end

  defp owned_conversation(conn, conversation_id) do
    case Conversations.get_conversation_for_user(conn.assigns.current_user, conversation_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end

  defp requested_count(%{"count" => count}) when is_integer(count), do: validate_count(count)

  defp requested_count(%{"count" => count}) when is_binary(count) do
    case Integer.parse(count) do
      {count, ""} -> validate_count(count)
      _invalid -> {:error, :invalid_box_count}
    end
  end

  defp requested_count(_params), do: {:error, :invalid_box_count}

  defp validate_count(count) when count in 1..@maximum_requested_count, do: {:ok, count}
  defp validate_count(_count), do: {:error, :invalid_box_count}

  defp labels(%{"labels" => labels}) when is_list(labels), do: {:ok, labels}
  defp labels(%{"labels" => _labels}), do: {:error, :invalid_box_labels}
  defp labels(_params), do: {:ok, nil}

  defp budgeted?(params) do
    params["budgeted"] == true or params["budget"] == true or
      get_in(params, ["budget", "enabled"]) == true
  end

  defp projection(plan) do
    items = plan.items || []

    %{
      "id" => plan.id,
      "requested_count" => plan.requested_count,
      "admitted" =>
        Enum.map(items, &item_projection/1) |> Enum.filter(&(&1["state"] == "admitted")),
      "queued" => Enum.map(items, &item_projection/1) |> Enum.filter(&(&1["state"] == "queued")),
      "effective_limits" => plan.effective_limits,
      "budgeted" => plan.budgeted,
      "created_at" => iso8601(plan.inserted_at),
      "updated_at" => iso8601(plan.updated_at)
    }
  end

  defp item_projection(item) do
    %{
      "position" => item.position,
      "label" => item.label,
      "state" => item.state,
      "box_id" => box_id(item),
      "queue_reason" => item.queue_reason,
      "estimated_burn_rate_microusd" => item.estimated_burn_rate_microusd,
      "admitted_at" => iso8601(item.admitted_at)
    }
  end

  defp box_id(%{conversation_box: %{box_id: box_id}}), do: box_id
  defp box_id(_item), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp fanout_error(conn, :box_owner_quota_reached),
    do: refusal(conn, :conflict, "box_owner_quota_reached")

  defp fanout_error(conn, :box_global_quota_reached),
    do: refusal(conn, :conflict, "box_global_quota_reached")

  defp fanout_error(conn, reason)
       when reason in [:box_quota_reached, "conversation_active_limit"],
       do: refusal(conn, :conflict, "box_quota_reached")

  defp fanout_error(conn, reason)
       when reason in ["conversation_burn_rate_ceiling", "owner_burn_rate_ceiling"],
       do: refusal(conn, :conflict, reason)

  defp fanout_error(conn, _reason), do: refusal(conn, :bad_gateway, "box_request_failed")

  defp refusal(conn, status, code) do
    conn |> put_status(status) |> json(%{"error" => %{"code" => code}})
  end
end
