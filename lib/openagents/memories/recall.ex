defmodule OpenAgents.Memories.Recall do
  @moduledoc """
  What one turn's recall found, and what it left behind.

  `dropped` is the point of the struct. Recall is bounded — by how many
  memories may attach and by how many characters they may spend — and a bound
  that silently discards is a bound nobody can debug. So the count of what did
  not fit travels with what did, and the note states it in words rather than
  trailing off.
  """

  alias OpenAgents.Memories.Memory
  alias OpenAgents.Memories.Retrieval

  @enforce_keys [:memories, :dropped, :backend]
  defstruct [:memories, :dropped, :backend]

  @type t :: %__MODULE__{
          memories: [Memory.t()],
          dropped: non_neg_integer(),
          backend: Retrieval.backend()
        }
end
