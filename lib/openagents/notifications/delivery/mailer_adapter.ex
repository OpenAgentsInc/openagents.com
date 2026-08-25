defmodule OpenAgents.Notifications.Delivery.MailerAdapter do
  @moduledoc """
  The delivery adapter that actually sends, through `OpenAgents.Mailer`.

  It is deliberately thin. Everything that decides whether a message may be
  sent — the confirmed address, the channel switch, the category, and the
  recipient's current access to the repository — is settled by
  `OpenAgents.Notifications.email_dispatch/1` before the adapter is reached, so
  this module has no authority to add or to withhold. It turns a resolved
  pointer into a message and reports what the provider said.

  A provider refusal comes back as `{:error, reason}`, which leaves the effect
  pending: the durable outbox counts the attempt, backs off, and stops at
  `maximum_attempts` with a terminal `failed`. That is the whole retry policy,
  and it lives in `OpenAgents.Effects` rather than here.
  """

  @behaviour OpenAgents.Notifications.Delivery.Adapter

  alias OpenAgents.Notifications.Email

  @impl true
  def deliver(recipient, data) when is_binary(recipient) do
    case Email.deliver_notification(recipient, data) do
      {:ok, _metadata} -> {:ok, %{"outcome" => "sent"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver(_recipient, _data), do: {:error, :no_recipient}
end
