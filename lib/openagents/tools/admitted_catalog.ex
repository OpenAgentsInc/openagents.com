defmodule OpenAgents.Tools.AdmittedCatalog do
  @moduledoc "Builds a provider catalog from tools authorized for one captured execution context."

  alias OpenAgents.Modules.SurfacePolicy
  alias OpenAgents.Providers.ToolDefinition
  alias OpenAgents.Tools.{ExecutionContext, Registry, Selector, Snapshot, Tool}

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
