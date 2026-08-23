defmodule OpenAgents.Tools.ExecutionContext do
  @moduledoc "Application-verified scope and authority supplied to a tool execution."

  @enforce_keys [:scope, :scope_ref, :authorities]
  defstruct @enforce_keys ++
              [
                surface: "text",
                approval_receipts: [],
                job_ref: nil,
                conversation_id: nil,
                current_user_message_id: nil,
                current_tool_call_id: nil,
                owner_user_id: nil,
                owner_visitor_id: nil,
                workspace: nil,
                memory_snapshot_ref: nil,
                profile_memory_snapshot_ref: nil,
                memory_consent: nil,
                module_registry_snapshot: nil
              ]

  @type t :: %__MODULE__{
          scope: String.t(),
          scope_ref: String.t(),
          authorities: MapSet.t(String.t()),
          surface: String.t(),
          approval_receipts: [map()],
          job_ref: String.t() | nil,
          conversation_id: Ecto.UUID.t() | nil,
          current_user_message_id: Ecto.UUID.t() | nil,
          current_tool_call_id: String.t() | nil,
          owner_user_id: Ecto.UUID.t() | nil,
          owner_visitor_id: Ecto.UUID.t() | nil,
          workspace: map() | nil,
          memory_snapshot_ref: String.t() | nil,
          profile_memory_snapshot_ref: String.t() | nil,
          memory_consent: map() | nil,
          module_registry_snapshot: OpenAgents.Tools.Snapshot.t() | nil
        }
end
