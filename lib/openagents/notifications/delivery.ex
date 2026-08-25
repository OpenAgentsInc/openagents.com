defmodule OpenAgents.Notifications.Delivery do
  @moduledoc """
  Durable outbound email delivery seam for notifications.

  Enqueues one `email.delivery` effect keyed to a notification `dedupe_key`.
  A recipient is optional in the caller's data; if none is provided the handler
  records a terminal `nothing_to_send_to` outcome instead of a failure.

  No real send happens here. The adapter is a future seam: the default
  `OpenAgents.Notifications.Delivery.NullAdapter` refuses unless a real
  provider is configured, and the caller supplies a `to` address.
  """

  alias OpenAgents.Effects
  alias OpenAgents.Notifications.Notification

  @kind "email.delivery"
  @source_kind "notification"

  @doc """
  Enqueue an email delivery for a `Notification` or a bare `dedupe_key`.

  Accepted shapes:
    * `%Notification{}`
    * a map or keyword with `:dedupe_key` and optional `:data`, `:user_id`,
      `:notification_id`, and `:maximum_attempts`

  When a `user_id` is known, the idempotency key is scoped to that user so the
  same `dedupe_key` for two different accounts stays two distinct deliveries.
  """
  @spec enqueue(Notification.t() | map() | keyword()) ::
          {:ok, Effects.Effect.t()} | {:error, term()}
  def enqueue(%Notification{} = notification) do
    enqueue(%{
      dedupe_key: notification.dedupe_key,
      user_id: notification.user_id,
      notification_id: notification.id,
      data: %{}
    })
  end

  def enqueue(attrs) when is_list(attrs), do: enqueue(Map.new(attrs))

  def enqueue(attrs) when is_map(attrs) do
    dedupe_key = fetch!(attrs, :dedupe_key)
    user_id = Map.get(attrs, :user_id)
    notification_id = Map.get(attrs, :notification_id)
    data = Map.get(attrs, :data) || %{}

    idempotency_source = if user_id, do: "#{user_id}/#{dedupe_key}", else: dedupe_key

    Effects.enqueue(@kind, %{
      payload: %{
        "dedupe_key" => dedupe_key,
        "user_id" => user_id,
        "notification_id" => notification_id,
        "data" => data
      },
      source_kind: @source_kind,
      source_id: dedupe_key,
      idempotency_key: Effects.idempotency_key(@kind, @source_kind, idempotency_source),
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
