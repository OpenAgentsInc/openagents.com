defmodule OpenAgents.Notifications.Delivery do
  @moduledoc """
  The durable outbound half of a notification.

  In-product delivery needs no queue: the record is written in the transaction
  that writes the comment it announces, so it exists exactly when the event
  does. Email cannot work that way. A send happens after that transaction
  commits and can fail on somebody else's server, so the asking has to be
  durable even though the doing is not.

  `enqueue/1` is called inside the same transaction as the notification row and
  writes one `email.delivery` effect. From there `OpenAgents.Effects` owns the
  schedule: a lease per attempt, exponential backoff between them, and a
  terminal `failed` at `maximum_attempts`. The effect's idempotency key is the
  recipient and the notification's `dedupe_key`, which is the same key the
  unique index on `notifications` uses, so a replayed fan-out produces one
  record and one send rather than two of each.

  ## What the payload may carry

  Identifiers, and no address. The recipient is resolved at send time by
  `OpenAgents.Notifications.email_dispatch/1` from the account's confirmed
  address, so a queued delivery cannot outlive the consent it was queued under:
  an account that removes its address, switches the channel off, or loses
  access to the repository stops being mailed, including for effects already
  sitting in the queue.
  """

  alias OpenAgents.Effects

  @kind "email.delivery"
  @source_kind "notification"

  @doc """
  Enqueue the email half of one notification.

  Requires `:dedupe_key`, `:user_id`, `:issue_id`, and `:kind`, and accepts
  `:actor_login` and `:maximum_attempts`. The idempotency key is scoped to the
  account, so the same event for two recipients is two deliveries.
  """
  @spec enqueue(map() | keyword()) :: {:ok, Effects.Effect.t()} | {:error, term()}
  def enqueue(attrs) when is_list(attrs), do: enqueue(Map.new(attrs))

  def enqueue(attrs) when is_map(attrs) do
    dedupe_key = fetch!(attrs, :dedupe_key)
    user_id = fetch!(attrs, :user_id)
    issue_id = fetch!(attrs, :issue_id)
    kind = fetch!(attrs, :kind)

    Effects.enqueue(@kind, %{
      payload: %{
        "dedupe_key" => dedupe_key,
        "user_id" => user_id,
        "issue_id" => issue_id,
        "kind" => kind,
        "actor_login" => Map.get(attrs, :actor_login)
      },
      source_kind: @source_kind,
      source_id: dedupe_key,
      idempotency_key: Effects.idempotency_key(@kind, @source_kind, "#{user_id}/#{dedupe_key}"),
      maximum_attempts: Map.get(attrs, :maximum_attempts, 5)
    })
  end

  @doc "The configured delivery adapter. Defaults to the no-op NullAdapter."
  @spec adapter() :: module()
  def adapter do
    :openagents
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, OpenAgents.Notifications.Delivery.NullAdapter)
  end

  defp fetch!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value != nil -> value
      _ -> raise ArgumentError, "delivery enqueue requires #{inspect(key)}"
    end
  end
end
