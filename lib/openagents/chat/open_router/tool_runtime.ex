defmodule OpenAgents.Chat.OpenRouter.ToolRuntime do
  @moduledoc """
  Captures one tool registry and execution context for an OpenRouter turn.

  A Responses tool loop must keep using the same registry snapshot across
  provider continuations. This adapter also keeps OpenRouter transport details
  out of tool implementations: provider definitions come from the registry,
  and every call enters the shared `OpenAgents.Tools.Runner` authority boundary.
  """

  alias OpenAgents.Providers.ToolDefinition

  alias OpenAgents.Tools.{
    AdmittedCatalog,
    ConversationExecutionContext,
    ExecutionContext,
    Registry,
    Runner,
    Snapshot
  }

  @enforce_keys [:snapshot, :execution_context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          snapshot: Snapshot.t(),
          execution_context: ExecutionContext.t()
        }

  @doc "Captures the immutable registry and execution context for one turn."
  @spec capture(keyword()) :: {:ok, t()} | {:error, :invalid_tool_runtime}
  def capture(options) when is_list(options) do
    snapshot = Keyword.get_lazy(options, :tool_registry_snapshot, &Registry.current!/0)

    with %Snapshot{} <- snapshot,
         {:ok, execution_context} <- execution_context(snapshot, options) do
      {:ok, %__MODULE__{snapshot: snapshot, execution_context: execution_context}}
    else
      _invalid -> {:error, :invalid_tool_runtime}
    end
  rescue
    _exception -> {:error, :invalid_tool_runtime}
  end

  @doc "Returns OpenRouter Responses function definitions from the captured registry."
  @spec provider_definitions(t(), String.t()) :: [map()]
  def provider_definitions(
        %__MODULE__{snapshot: snapshot, execution_context: execution_context},
        intent \\ ""
      ) do
    snapshot
    |> AdmittedCatalog.provider_definitions(execution_context, intent)
    |> Enum.map(&provider_definition/1)
  end

  @doc "Runs a provider function call through the shared tool runner."
  @spec run(t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = runtime, call_id, name, raw_arguments)
      when is_binary(call_id) and is_binary(name) and is_binary(raw_arguments) do
    version =
      case Map.fetch(runtime.snapshot.tools, name) do
        {:ok, tool} -> tool.version
        :error -> 1
      end

    case Runner.run(
           runtime.snapshot,
           %{call_id: call_id, name: name, version: version, raw_arguments: raw_arguments},
           runtime.execution_context
         ) do
      {:ok, outcome} -> {:ok, OpenAgents.Tools.Redaction.redact(outcome)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execution_context(snapshot, options) do
    case Keyword.get(options, :tool_execution_context) do
      %ExecutionContext{} = context ->
        {:ok, %{context | module_registry_snapshot: snapshot}}

      nil ->
        context = Keyword.get(options, :tool_context, %{})
        user = Map.get(context, :user)
        owner_user_id = Map.get(context, :owner_user_id) || user_id(user)

        conversation_id = Map.get(context, :conversation_id)
        owner_visitor_id = Map.get(context, :owner_visitor_id) || owner_user_id

        attributes = %{
          surface: Map.get(context, :surface, "text"),
          conversation_id: conversation_id,
          current_user_message_id: Map.get(context, :current_user_message_id),
          owner_visitor_id: owner_visitor_id,
          owner_user_id: owner_user_id,
          workspace: Map.get(context, :workspace),
          memory_snapshot_ref: Map.get(context, :memory_snapshot_ref),
          profile_memory_snapshot_ref: Map.get(context, :profile_memory_snapshot_ref),
          module_registry_snapshot: snapshot
        }

        if is_binary(conversation_id) and is_binary(owner_visitor_id) do
          {:ok, ConversationExecutionContext.build(attributes)}
        else
          {:ok,
           %ExecutionContext{
             scope: "browser_conversation",
             scope_ref: "conversation:unbound",
             authorities: MapSet.new(),
             surface: Map.get(context, :surface, "text"),
             module_registry_snapshot: snapshot
           }}
        end

      _invalid ->
        {:error, :invalid_tool_runtime}
    end
  end

  defp user_id(%{id: id}) when is_binary(id), do: id
  defp user_id(_user), do: nil

  defp provider_definition(%ToolDefinition{} = definition) do
    %{
      "type" => "function",
      "name" => definition.name,
      "description" => definition.description,
      "parameters" => definition.input_schema,
      "strict" => definition.strict
    }
  end
end
