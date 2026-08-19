defmodule OpenAgents.Chat.Message do
  @moduledoc "A simple chat message struct for the /chat demo."

  defstruct [:id, :role, :content, :status, :inserted_at]
end
