defmodule OpenAgents.Notifications.Delivery.Adapter do
  @moduledoc """
  Behaviour for a future email delivery adapter.

  The adapter is a seam: nothing here performs a real send. A concrete
  implementation receives the recipient address and the caller's data map and
  returns either an ok result map or an error reason that the durable outbox
  will retry.
  """

  @doc "Deliver `data` to `recipient`. Returns `:ok`, `{:ok, result}`, or `{:error, reason}`."
  @callback deliver(recipient :: String.t() | nil, data :: map()) ::
              :ok | {:ok, map()} | {:error, term()}
end
