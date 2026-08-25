defmodule OpenAgents.Effects.Handlers.EmailDelivery do
  @moduledoc """
  Drives an `email.delivery` effect to a terminal state.

  The payload names an account and an event. It does not name an address, and
  no caller can put one there: the recipient is resolved on the way out by
  `OpenAgents.Notifications.email_dispatch/1`, which returns an address only
  when the account confirmed it and asked for mail. An address that was typed
  and never confirmed is therefore unreachable from the queue as well as from
  the settings surface, and an account that switched the channel off between
  the enqueue and the send is not mailed on the strength of what it wanted
  earlier.

  A refusal is a completion, not a failure. Nothing about "this account has no
  confirmed address" improves by being tried again in eight seconds, so the
  effect records the reason and stops. Only a provider that could not be
  reached leaves the effect pending for the outbox to retry.
  """

  @behaviour OpenAgents.Effects.Handler

  alias OpenAgents.Effects.Effect
  alias OpenAgents.Notifications
  alias OpenAgents.Notifications.Delivery

  @impl OpenAgents.Effects.Handler
  def run(%Effect{payload: payload}, _idempotency_key) do
    case Notifications.email_dispatch(payload) do
      {:ok, recipient, pointer} -> Delivery.adapter().deliver(recipient, pointer)
      {:refused, outcome} -> {:ok, %{"outcome" => outcome}}
    end
  end
end
