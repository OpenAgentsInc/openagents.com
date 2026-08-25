defmodule OpenAgents.Effects.Handlers.EmailDelivery do
  @moduledoc """
  Drives an `email.delivery` effect to a terminal state.

  The payload carries the notification `dedupe_key` and optional `data`. When
  `data` does not contain a `to` recipient, the handler records a successful
  `nothing_to_send_to` terminal outcome. Otherwise it calls the configured
  `OpenAgents.Notifications.Delivery` adapter, which is a future seam: no real
  send happens unless a provider is configured.
  """

  @behaviour OpenAgents.Effects.Handler

  alias OpenAgents.Effects.Effect
  alias OpenAgents.Notifications.Delivery

  @impl OpenAgents.Effects.Handler
  def run(%Effect{payload: payload}, _idempotency_key) do
    data = Map.get(payload, "data", %{})

    case recipient(data) do
      nil ->
        {:ok, %{"outcome" => "nothing_to_send_to"}}

      to ->
        Delivery.adapter().deliver(to, data)
    end
  end

  defp recipient(data) when is_map(data) do
    case Map.get(data, "to") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
