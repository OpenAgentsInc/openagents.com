defmodule OpenAgents.Memory.RecallSnapshot do
  @moduledoc "Immutable high-water cursor for one browser-conversation recall view."

  @enforce_keys [:conversation_id, :message_id, :inserted_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          conversation_id: Ecto.UUID.t(),
          message_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }

  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{message_id: message_id}), do: "message:#{message_id}"
end
