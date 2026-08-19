defmodule OpenAgents.Tools.ExecutionResult do
  @moduledoc """
  Typed, pre-normalization result returned by an admitted tool implementation.

  `status` lets a tool that COMPLETED its own execution report an honest
  non-succeeded outcome for the work it brokered — a delegation that timed
  out, a remote refusal — while keeping the rich result payload durable
  (partial output, session ids). Plain `{:error, atom}` returns remain the
  path for the tool itself failing; this field is for brokered outcomes with
  evidence worth keeping. Defaults to `"succeeded"`.
  """

  @statuses ~w(succeeded failed refused unavailable cancelled)

  @enforce_keys [:result]
  defstruct result: nil,
            status: "succeeded",
            error: nil,
            target_receipt_refs: [],
            attribution_refs: []

  @type t :: %__MODULE__{
          result: map(),
          status: String.t(),
          error: map() | nil,
          target_receipt_refs: [String.t()],
          attribution_refs: [String.t()]
        }

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
