defmodule OpenAgents.Memory.LexicalRecall do
  @moduledoc false

  def capture_ref(_repo, _conversation_id, _message_id) do
    {:ok, "message:00000000-0000-0000-0000-000000000000"}
  end
end
