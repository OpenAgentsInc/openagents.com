defmodule OpenAgents.Tools.AdmittedCatalog do
  @moduledoc """
  Builds a provider catalog from tools authorized for one captured execution
  context.

  Two narrowings, in order. The caller's reach comes first, resolved once from
  the context, so a tool the caller cannot use never takes a selection slot
  (`OpenAgents.Tools.Reach`). Scope, authority, and surface admission follow,
  so a tool the *host* will not run for this context never reaches the model
  either.
  """

  alias OpenAgents.Modules.SurfacePolicy
  alias OpenAgents.Providers.ToolDefinition
  alias OpenAgents.Tools.{ExecutionContext, Reach, Registry, Selector, Snapshot, Tool}

  @spec provider_definitions(Snapshot.t(), ExecutionContext.t(), String.t() | nil, keyword()) ::
          [ToolDefinition.t()]
  def provider_definitions(
        %Snapshot{} = snapshot,
        %ExecutionContext{} = context,
        intent,
        opts \\ []
      ) do
    snapshot
    |> tools(context, intent, opts)
    |> Registry.definitions_for()
  end

  @spec realtime_catalog(Snapshot.t(), ExecutionContext.t(), String.t() | nil, keyword()) :: map()
  def realtime_catalog(%Snapshot{} = snapshot, %ExecutionContext{} = context, intent, opts \\ []) do
    definitions = provider_definitions(snapshot, context, intent, opts)

    %{
      "schema" => "sarah.realtime_tool_catalog.v1",
      "digest" => snapshot.digest,
      "mode" => "selected",
      "tools" => Enum.map(definitions, &realtime_definition/1)
    }
  end

  @spec tools(Snapshot.t(), ExecutionContext.t(), String.t() | nil, keyword()) :: [Tool.t()]
  def tools(%Snapshot{} = snapshot, %ExecutionContext{} = context, intent, opts \\ []) do
    # The context is the only authority on who is calling, so the caller is
    # resolved here rather than trusted from the option list.
    opts = Keyword.put(opts, :reach, Reach.caller(context))
    {selected, _omitted} = Selector.select(snapshot, intent, opts)
    Enum.filter(selected, &authorized?(snapshot, &1, context))
  end

  defp authorized?(snapshot, tool, context) do
    with true <- tool.required_scope == context.scope,
         true <- MapSet.member?(context.authorities, tool.required_authority),
         {:ok, artifact} <- Registry.module_for_tool(snapshot, tool.name, tool.version),
         :ok <- SurfacePolicy.authorize_execution(artifact, context) do
      true
    else
      _refused -> false
    end
  end

  defp realtime_definition(definition) do
    %{
      "type" => "function",
      "name" => definition.name,
      "description" => definition.description,
      "parameters" => definition.input_schema
    }
  end
end
