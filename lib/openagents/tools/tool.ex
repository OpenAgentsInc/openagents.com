defmodule OpenAgents.Tools.Tool do
  @moduledoc "Host-owned contract implemented by every admitted Sarah tool."

  @enforce_keys [
    :module_id,
    :name,
    :version,
    :description,
    :input_schema,
    :output_schema,
    :side_effect,
    :required_scope,
    :required_authority,
    :executor,
    :maintainer,
    :attribution,
    :policy_facets,
    :module_metadata,
    :timeout_ms,
    :maximum_input_bytes,
    :maximum_output_bytes,
    :implementation
  ]
  # Optional, defaulted fields follow the enforced contract. `tags` are
  # human-authored discovery hints; effective discovery tags also fold in the
  # tool's authority and name tokens (see OpenAgents.Tools.Discovery.Doc).
  #
  # `reach` names what the *caller* must already hold for this tool to be able
  # to succeed at all, so a catalog can leave out a tool the caller cannot
  # reach instead of letting the model spend a turn discovering the refusal.
  # It is advisory to the catalog and never authoritative: the tool still
  # enforces its own gate. See `OpenAgents.Tools.Reach`.
  defstruct @enforce_keys ++ [tags: [], reach: []]

  @type side_effect :: :read_only | :reversible_write | :external_effect
  @type reach_requirement :: :signed_in_owner | :paired_computer | :operator
  @type t :: %__MODULE__{
          module_id: String.t(),
          name: String.t(),
          version: pos_integer(),
          description: String.t(),
          input_schema: map(),
          output_schema: map(),
          side_effect: side_effect(),
          required_scope: String.t(),
          required_authority: String.t(),
          executor: %{id: String.t(), disclosure: String.t()},
          maintainer: String.t(),
          attribution: [String.t()],
          policy_facets: map(),
          module_metadata: map(),
          timeout_ms: pos_integer(),
          maximum_input_bytes: pos_integer(),
          maximum_output_bytes: pos_integer(),
          implementation: module(),
          tags: [String.t()],
          reach: [reach_requirement()]
        }

  @callback specification() :: t()
  @callback execute(map(), OpenAgents.Tools.ExecutionContext.t()) ::
              {:ok, OpenAgents.Tools.ExecutionResult.t()} | {:error, atom()}
end
