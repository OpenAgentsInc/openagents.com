defmodule OpenAgents.Tools.Registry do
  @moduledoc "Builds, validates, installs, and snapshots the host-owned tool catalog."

  alias OpenAgents.Provenance.Canonical
  alias OpenAgents.Modules.Artifact
  alias OpenAgents.Providers.ToolDefinition
  alias OpenAgents.Tools.{Schema, Selector, Snapshot, Tool}

  @schema "sarah.module_registry.v1"
  @persistent_key {__MODULE__, :current}
  @identifier_regex ~r/\A[a-z][a-z0-9_.-]*\z/

  @spec install!([module()]) :: Snapshot.t()
  def install!(modules) do
    case build(modules) do
      {:ok, snapshot} ->
        :persistent_term.put(@persistent_key, snapshot)
        snapshot

      {:error, reason} ->
        raise ArgumentError, "invalid Sarah tool registry: #{inspect(reason)}"
    end
  end

  @spec current!() :: Snapshot.t()
  def current! do
    case :persistent_term.get(@persistent_key, :not_installed) do
      %Snapshot{} = snapshot -> snapshot
      :not_installed -> raise "Sarah tool registry is not installed"
    end
  end

  @spec build([module()]) :: {:ok, Snapshot.t()} | {:error, atom() | tuple()}
  def build(modules) when is_list(modules) and length(modules) <= 64 do
    with {:ok, tools} <- load_tools(modules),
         :ok <- validate_unique(tools),
         {:ok, artifacts} <- build_artifacts(tools),
         :ok <- validate_dependencies(artifacts) do
      executable_refs =
        artifacts
        |> Enum.filter(&Artifact.executable?/1)
        |> MapSet.new(&{&1.module_id, &1.version})

      modules_by_ref = Map.new(artifacts, &{{&1.module_id, &1.version}, &1})

      all_tools =
        tools
        |> Enum.map(&enrich_tool(&1, modules_by_ref))
        |> Map.new(&{&1.name, &1})

      tools_by_name =
        all_tools
        |> Enum.filter(fn {_name, tool} ->
          MapSet.member?(executable_refs, {tool.module_id, tool.version})
        end)
        |> Map.new()

      digest = catalog_digest(artifacts)

      {:ok,
       %Snapshot{
         schema: @schema,
         digest: digest,
         tools: tools_by_name,
         all_tools: all_tools,
         modules: modules_by_ref
       }}
    end
  end

  def build(_modules), do: {:error, :invalid_tool_modules}

  @spec admit_artifact(Snapshot.t(), Artifact.t()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def admit_artifact(%Snapshot{} = snapshot, %Artifact{} = artifact) do
    reference = {artifact.module_id, artifact.version}

    if Map.has_key?(snapshot.modules, reference) do
      {:error, :duplicate_module_reference}
    else
      modules = Map.put(snapshot.modules, reference, artifact)

      with :ok <- Artifact.validate(artifact),
           :ok <- validate_dependencies(Map.values(modules)) do
        {:ok, %{snapshot | modules: modules, digest: catalog_digest(Map.values(modules))}}
      end
    end
  end

  @spec capability_descriptors(Snapshot.t()) :: [map()]
  def capability_descriptors(%Snapshot{} = snapshot) do
    snapshot.tools
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn tool -> %{id: tool.name, description: tool.description} end)
  end

  @spec prompt_capability_descriptors(Snapshot.t()) :: [map()]
  def prompt_capability_descriptors(%Snapshot{} = snapshot) do
    snapshot
    |> prompt_catalog()
    |> Map.fetch!(:definitions)
    |> Enum.map(&%{id: &1.name, description: &1.description})
  end

  @spec provider_definitions(Snapshot.t()) :: [ToolDefinition.t()]
  def provider_definitions(%Snapshot{} = snapshot) do
    snapshot.tools
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> definitions_for()
  end

  @doc "Build provider ToolDefinitions for a specific, already-ordered tool list."
  @spec definitions_for([Tool.t()]) :: [ToolDefinition.t()]
  def definitions_for(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      %ToolDefinition{
        name: tool.name,
        description: tool.description,
        input_schema: tool.input_schema,
        strict: strict_provider_schema?(tool.input_schema)
      }
    end)
  end

  @doc """
  The tools exposed to the model for a turn, chosen by semantic + lexical
  relevance to `intent` (OpenAgents.Tools.Selector). There is no direct/discovery
  mode: the system always looks up the relevant subset so the model never has
  to. `mode` is always `"selected"`.
  """
  @spec prompt_catalog(Snapshot.t(), String.t() | nil, keyword()) :: map()
  def prompt_catalog(%Snapshot{} = snapshot, intent \\ "", opts \\ []) do
    {tools, omitted} = Selector.select(snapshot, intent, opts)

    %{
      schema: "sarah.prompt_tool_catalog.v1",
      digest: snapshot.digest,
      mode: "selected",
      definitions: definitions_for(tools),
      omitted_count: omitted
    }
  end

  @spec prompt_definitions(Snapshot.t(), String.t() | nil, keyword()) :: [ToolDefinition.t()]
  def prompt_definitions(%Snapshot{} = snapshot, intent \\ "", opts \\ []),
    do: prompt_catalog(snapshot, intent, opts).definitions

  @spec realtime_definitions(Snapshot.t(), String.t() | nil, keyword()) :: [map()]
  def realtime_definitions(%Snapshot{} = snapshot, intent \\ "", opts \\ []) do
    snapshot
    |> prompt_definitions(intent, opts)
    |> Enum.map(&realtime_definition/1)
  end

  @spec realtime_catalog(Snapshot.t(), String.t() | nil, keyword()) :: map()
  def realtime_catalog(%Snapshot{} = snapshot, intent \\ "", opts \\ []) do
    catalog = prompt_catalog(snapshot, intent, opts)

    %{
      "schema" => "sarah.realtime_tool_catalog.v1",
      "digest" => snapshot.digest,
      "mode" => catalog.mode,
      "omitted_count" => catalog.omitted_count,
      "tools" => Enum.map(catalog.definitions, &realtime_definition/1)
    }
  end

  defp realtime_definition(definition) do
    %{
      "type" => "function",
      "name" => definition.name,
      "description" => definition.description,
      "parameters" => definition.input_schema
    }
  end

  defp strict_provider_schema?(%{"properties" => properties, "required" => required}) do
    MapSet.new(Map.keys(properties)) == MapSet.new(required)
  end

  defp strict_provider_schema?(_schema), do: false

  @spec fetch(Snapshot.t(), String.t(), pos_integer()) :: {:ok, Tool.t()} | {:error, atom()}
  def fetch(%Snapshot{tools: tools, modules: modules}, name, version) do
    case Map.fetch(tools, name) do
      {:ok, %Tool{version: ^version} = tool} ->
        with {:ok, artifact} <- Map.fetch(modules, {tool.module_id, version}),
             :ok <- Artifact.verify_implementation(artifact, tool.implementation) do
          {:ok, tool}
        else
          :error -> {:error, :module_artifact_missing}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Tool{}} ->
        {:error, :incompatible_tool_version}

      :error ->
        {:error, :unknown_tool}
    end
  end

  @spec fetch_module(Snapshot.t(), String.t(), pos_integer()) ::
          {:ok, Artifact.t()} | {:error, atom()}
  def fetch_module(%Snapshot{modules: modules}, module_id, version) do
    case Map.fetch(modules, {module_id, version}) do
      {:ok, %Artifact{} = artifact} ->
        if Artifact.executable?(artifact), do: {:ok, artifact}, else: {:error, :module_ineligible}

      :error ->
        {:error, :unknown_module}
    end
  end

  @spec module_for_tool(Snapshot.t(), String.t(), pos_integer()) ::
          {:ok, Artifact.t()} | {:error, atom()}
  def module_for_tool(%Snapshot{} = snapshot, name, version) do
    with {:ok, tool} <- fetch(snapshot, name, version),
         {:ok, artifact} <- fetch_module(snapshot, tool.module_id, version) do
      {:ok, artifact}
    end
  end

  @spec transition_module(Snapshot.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def transition_module(%Snapshot{} = snapshot, module_id, version, state, options \\ []) do
    with {:ok, artifact} <- fetch_any_module(snapshot, module_id, version),
         {:ok, transitioned} <- Artifact.transition(artifact, state, options) do
      modules = Map.put(snapshot.modules, {module_id, version}, transitioned)

      tools = executable_tools(snapshot.all_tools, modules)

      {:ok,
       %Snapshot{
         snapshot
         | modules: modules,
           tools: tools,
           digest: catalog_digest(Map.values(modules))
       }}
    end
  end

  defp fetch_any_module(%Snapshot{modules: modules}, module_id, version) do
    case Map.fetch(modules, {module_id, version}) do
      {:ok, artifact} -> {:ok, artifact}
      :error -> {:error, :unknown_module}
    end
  end

  defp executable_tools(all_tools, modules) do
    all_tools
    |> Enum.reduce(%{}, fn {name, tool}, selected ->
      artifact = Map.fetch!(modules, {tool.module_id, tool.version})

      if Artifact.executable?(artifact) do
        Map.put(selected, name, enrich_tool(tool, %{{tool.module_id, tool.version} => artifact}))
      else
        selected
      end
    end)
  end

  defp load_tools(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, tools} ->
      with {:ok, tool} <- load_tool(module),
           :ok <- validate_tool(tool, module) do
        {:cont, {:ok, [tool | tools]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      error -> error
    end
  end

  defp load_tool(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :specification, 0) do
      try do
        {:ok, module.specification()}
      rescue
        _exception -> {:error, {:tool_specification_failed, module}}
      end
    else
      _missing -> {:error, {:tool_specification_missing, module}}
    end
  end

  defp load_tool(_module), do: {:error, :invalid_tool_module}

  defp validate_tool(%Tool{} = tool, module) do
    cond do
      tool.implementation != module ->
        {:error, {:implementation_mismatch, tool.name}}

      not identifier?(tool.module_id, 128) ->
        {:error, {:invalid_module_id, tool.name}}

      not identifier?(tool.name, 128) ->
        {:error, {:invalid_tool_name, tool.name}}

      not is_integer(tool.version) or tool.version < 1 ->
        {:error, {:invalid_version, tool.name}}

      not bounded_string?(tool.description, 1_000) ->
        {:error, {:invalid_description, tool.name}}

      tool.side_effect not in [:read_only, :reversible_write, :external_effect] ->
        {:error, {:invalid_side_effect, tool.name}}

      not identifier?(tool.required_scope, 128) ->
        {:error, {:invalid_scope, tool.name}}

      not identifier?(tool.required_authority, 128) ->
        {:error, {:invalid_authority, tool.name}}

      not valid_executor?(tool.executor) ->
        {:error, {:invalid_executor, tool.name}}

      not bounded_string?(tool.maintainer, 256) ->
        {:error, {:invalid_maintainer, tool.name}}

      not valid_refs?(tool.attribution) ->
        {:error, {:invalid_attribution, tool.name}}

      not is_map(tool.policy_facets) or map_size(tool.policy_facets) > 32 ->
        {:error, {:invalid_policy_facets, tool.name}}

      not is_map(tool.module_metadata) or map_size(tool.module_metadata) > 32 ->
        {:error, {:invalid_module_metadata, tool.name}}

      not is_integer(tool.timeout_ms) or tool.timeout_ms not in 1..600_000 ->
        {:error, {:invalid_timeout, tool.name}}

      not is_integer(tool.maximum_input_bytes) or tool.maximum_input_bytes not in 1..262_144 ->
        {:error, {:invalid_input_limit, tool.name}}

      not is_integer(tool.maximum_output_bytes) or tool.maximum_output_bytes not in 1..1_048_576 ->
        {:error, {:invalid_output_limit, tool.name}}

      true ->
        with :ok <- Schema.validate_schema(tool.input_schema),
             :ok <- Schema.validate_schema(tool.output_schema),
             {:ok, encoded} <- Canonical.encode(metadata(tool)),
             true <- byte_size(encoded) <= 65_536 do
          :ok
        else
          false -> {:error, {:tool_specification_too_large, tool.name}}
          {:error, reason} -> {:error, {:invalid_tool_schema_or_policy, tool.name, reason}}
        end
    end
  end

  defp validate_tool(_tool, module), do: {:error, {:invalid_tool_specification, module}}

  defp validate_unique(tools) do
    names = Enum.map(tools, & &1.name)
    module_ids = Enum.map(tools, & &1.module_id)

    cond do
      length(names) != length(Enum.uniq(names)) -> {:error, :duplicate_tool_name}
      length(module_ids) != length(Enum.uniq(module_ids)) -> {:error, :duplicate_module_id}
      true -> :ok
    end
  end

  defp build_artifacts(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, artifacts} ->
      case Artifact.from_tool(tool) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, reason} -> {:halt, {:error, {:invalid_module_artifact, tool.module_id, reason}}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp enrich_tool(tool, modules_by_ref) do
    artifact = Map.fetch!(modules_by_ref, {tool.module_id, tool.version})

    executor =
      Map.merge(tool.executor, %{
        implementation_digest: artifact.implementation_digest,
        module_artifact_digest: artifact.artifact_digest,
        attribution_policy: artifact.attribution_policy,
        cost_units: artifact.facets["cost_units"]
      })

    %{tool | executor: executor}
  end

  defp validate_dependencies(artifacts) do
    refs = MapSet.new(artifacts, &{&1.module_id, &1.version})

    case Enum.find_value(artifacts, fn artifact ->
           Enum.find(artifact.compatibility["dependencies"], fn dependency ->
             not MapSet.member?(refs, {dependency["module_id"], dependency["version"]})
           end)
           |> case do
             nil -> nil
             dependency -> {artifact, dependency}
           end
         end) do
      nil ->
        :ok

      {artifact, dependency} ->
        {:error,
         {:module_dependency_missing, artifact.module_id, dependency["module_id"],
          dependency["version"]}}
    end
  end

  defp catalog_digest(artifacts) do
    artifacts
    |> Enum.sort_by(&{&1.module_id, &1.version})
    |> Enum.map(
      &%{
        "module_id" => &1.module_id,
        "version" => &1.version,
        "digest" => &1.artifact_digest,
        "state" => &1.state
      }
    )
    |> then(&%{"schema" => @schema, "modules" => &1})
    |> Canonical.digest!()
  end

  defp metadata(tool) do
    tool
    |> Map.from_struct()
    |> Map.delete(:implementation)
    |> Map.update!(:side_effect, &Atom.to_string/1)
  end

  defp identifier?(value, maximum),
    do:
      is_binary(value) and byte_size(value) <= maximum and Regex.match?(@identifier_regex, value)

  defp bounded_string?(value, maximum),
    do: is_binary(value) and value != "" and byte_size(value) <= maximum

  defp valid_executor?(%{id: id, disclosure: disclosure}),
    do: identifier?(id, 128) and bounded_string?(disclosure, 256)

  defp valid_executor?(_executor), do: false

  defp valid_refs?(refs) when is_list(refs) and length(refs) <= 32,
    do: Enum.all?(refs, &bounded_string?(&1, 256))

  defp valid_refs?(_refs), do: false
end
