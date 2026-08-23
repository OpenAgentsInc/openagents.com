defmodule OpenAgents.Tools.ConversationExecutionContext do
  @moduledoc """
  Builds the shared tool execution context for text and voice conversations.

  Text and voice are two transports over one authority boundary. Keep every
  conversation-scoped authority and approval receipt here so adding a tool to
  one surface cannot silently leave the other surface behind.
  """

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Machines
  alias OpenAgents.Modules.RoutingPolicy
  alias OpenAgents.Repo
  alias OpenAgents.SCV.Deployments
  alias OpenAgents.Tools.ExecutionContext

  @authorities MapSet.new([
                 "computer.control",
                 "conversation.read",
                 "github.read",
                 "memory.read",
                 "memory.write",
                 "module.discover",
                 "repository.read",
                 "repository.write",
                 "scv.deploy",
                 "work.delegate"
               ])

  @doc "The authority set shared by every conversation transport."
  @spec authorities() :: MapSet.t(String.t())
  def authorities, do: @authorities

  @doc "The routing policy admitted for a conversation owner."
  @spec routing_policy(String.t() | nil) :: RoutingPolicy.t()
  def routing_policy(user_id) when is_binary(user_id) do
    user = Repo.get(User, user_id)

    cond do
      Accounts.admin?(user) -> RoutingPolicy.operator()
      Machines.active_machine?(user_id) -> RoutingPolicy.paired_machine()
      true -> RoutingPolicy.default()
    end
  end

  def routing_policy(_user_id), do: RoutingPolicy.default()

  @doc "Build a tool execution context for a text or voice conversation."
  @spec build(map()) :: ExecutionContext.t()
  def build(
        %{
          surface: surface,
          conversation_id: conversation_id,
          owner_visitor_id: owner_visitor_id,
          owner_user_id: owner_user_id
        } = attributes
      )
      when surface in ["text", "voice"] and is_binary(conversation_id) and
             is_binary(owner_visitor_id) do
    scope_ref = "conversation:#{conversation_id}"

    %ExecutionContext{
      scope: "browser_conversation",
      scope_ref: scope_ref,
      authorities: authorities(),
      approval_receipts: approval_receipts(owner_user_id, scope_ref),
      surface: surface,
      conversation_id: conversation_id,
      current_user_message_id: Map.get(attributes, :current_user_message_id),
      owner_user_id: owner_user_id,
      owner_visitor_id: owner_visitor_id,
      workspace:
        Map.get(attributes, :workspace) ||
          %{
            "type" => "connected_forge_repository",
            "binding" => "user_visible_repository",
            "owner_user_id" => owner_user_id,
            "read_only" => true
          },
      memory_snapshot_ref: Map.get(attributes, :memory_snapshot_ref),
      profile_memory_snapshot_ref: Map.get(attributes, :profile_memory_snapshot_ref),
      module_registry_snapshot: Map.get(attributes, :module_registry_snapshot)
    }
  end

  defp approval_receipts(user_id, scope_ref) when is_binary(user_id) do
    user = Repo.get(User, user_id)

    Machines.approval_receipts(user_id, scope_ref) ++
      Deployments.approval_receipts(user, scope_ref)
  end

  defp approval_receipts(_user_id, _scope_ref), do: []
end
