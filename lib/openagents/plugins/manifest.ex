defmodule OpenAgents.Plugins.Manifest do
  @moduledoc """
  Typed manifest validation for plugin registries.

  A plugin manifest is the unit the registry indexes. It carries identity,
  a typed interface, declared capabilities, discovery text, and reserved
  economy fields. This module validates the wire shape without running the
  artifact and returns a field-keyed error for any malformed value.
  """

  alias __MODULE__.ValidationError

  defmodule ValidationError do
    @moduledoc "A typed validation refusal naming the field that failed."
    defstruct [:field, :reason]

    @type t :: %__MODULE__{
            field: String.t(),
            reason: atom()
          }
  end

  @manifest_keys ~w(manifest_version name version author description artifact
                    abi interface capabilities surfaces price_msats license)

  @required_keys ~w(manifest_version name version author description artifact
                    abi interface capabilities price_msats license)

  @name_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @semver_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+.A-Za-z0-9]+)?\z/
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/

  @schema_types MapSet.new(~w(object array string integer number boolean null))

  @doc "Validate a decoded manifest map and return the normalized manifest or a field-keyed error."
  @spec validate(map()) :: {:ok, map()} | {:error, ValidationError.t()}
  def validate(%{} = manifest) do
    with :ok <- required_keys(manifest, @required_keys),
         :ok <- exact_keys(manifest, @manifest_keys),
         :ok <- validate_identity(manifest),
         :ok <- validate_artifact(manifest["artifact"]),
         :ok <- validate_abi(manifest["abi"]),
         :ok <- validate_interface(manifest["interface"]),
         :ok <- validate_capabilities(manifest["capabilities"]),
         :ok <- validate_surfaces(manifest["surfaces"]),
         :ok <- validate_reserved(manifest) do
      {:ok, normalize(manifest)}
    end
  end

  def validate(_manifest), do: error("root", :not_a_map)

  defp required_keys(manifest, required) do
    keys = manifest |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    case Enum.find(required, &(!MapSet.member?(keys, &1))) do
      nil -> :ok
      key -> error(key, :missing)
    end
  end

  defp exact_keys(manifest, allowed) do
    keys = Map.keys(manifest) |> Enum.map(&to_string/1) |> Enum.sort()
    allowed = Enum.sort(allowed)

    case keys -- allowed do
      [] -> :ok
      [extra | _] -> error(extra, :unexpected_field)
    end
  end

  defp exact_nested_keys(map, allowed, prefix) do
    keys = Map.keys(map) |> Enum.map(&to_string/1) |> Enum.sort()
    allowed = Enum.sort(allowed)

    case keys -- allowed do
      [] -> :ok
      [extra | _] -> error("#{prefix}.#{extra}", :unexpected_field)
    end
  end

  defp validate_identity(manifest) do
    with :ok <- require_integer(manifest, "manifest_version"),
         :ok <- require_string(manifest, "name", &valid_name?/1),
         :ok <- require_string(manifest, "version", &valid_version?/1),
         :ok <- require_string(manifest, "author", &non_empty?/1),
         :ok <- require_string(manifest, "description", &non_empty?/1) do
      :ok
    end
  end

  defp valid_name?(name), do: Regex.match?(@name_pattern, name)
  defp valid_version?(version), do: Regex.match?(@semver_pattern, version)
  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_artifact(%{} = artifact) do
    with :ok <- exact_nested_keys(artifact, ~w(path digest), "artifact"),
         :ok <- require_string_value(artifact["path"], "artifact.path", &non_empty?/1),
         :ok <- require_string_value(artifact["digest"], "artifact.digest", &valid_digest?/1) do
      :ok
    end
  end

  defp validate_artifact(nil), do: error("artifact", :missing)
  defp validate_artifact(_), do: error("artifact", :not_a_map)

  defp valid_digest?(digest), do: Regex.match?(@digest_pattern, digest)

  defp validate_abi(%{} = abi) do
    with :ok <- exact_nested_keys(abi, ~w(kind entry alloc), "abi"),
         :ok <- require_string_value(abi["kind"], "abi.kind", &non_empty?/1),
         :ok <- require_string_value(abi["entry"], "abi.entry", &non_empty?/1),
         :ok <- require_string_value(abi["alloc"], "abi.alloc", &non_empty?/1) do
      :ok
    end
  end

  defp validate_abi(nil), do: error("abi", :missing)
  defp validate_abi(_), do: error("abi", :not_a_map)

  defp validate_interface(%{} = interface) do
    with :ok <- exact_nested_keys(interface, ~w(input output), "interface"),
         :ok <- validate_schema(interface["input"], "interface.input"),
         :ok <- validate_schema(interface["output"], "interface.output") do
      :ok
    end
  end

  defp validate_interface(nil), do: error("interface", :missing)
  defp validate_interface(_), do: error("interface", :not_a_map)

  defp validate_schema(nil, field), do: error(field, :missing)

  defp validate_schema(%{} = schema, field) do
    with :ok <- require_type(schema["type"], "#{field}.type"),
         :ok <- validate_schema_body(schema, field) do
      :ok
    end
  end

  defp validate_schema(_, field), do: error(field, :not_a_schema)

  defp require_type(nil, field), do: error(field, :missing)

  defp require_type(type, field) when is_binary(type) do
    if MapSet.member?(@schema_types, type),
      do: :ok,
      else: error(field, :invalid_type)
  end

  defp require_type(types, field) when is_list(types) and types != [] do
    Enum.reduce_while(types, :ok, fn type, :ok ->
      if is_binary(type) and MapSet.member?(@schema_types, type) do
        {:cont, :ok}
      else
        {:halt, error(field, :invalid_type)}
      end
    end)
  end

  defp require_type(_, field), do: error(field, :invalid_type)

  defp validate_schema_body(schema, field) do
    case schema["type"] do
      "object" -> validate_object_schema(schema, field)
      "array" -> validate_array_schema(schema, field)
      _ -> validate_simple_schema(schema, field)
    end
  end

  defp validate_object_schema(schema, field) do
    with :ok <-
           exact_nested_keys(
             schema,
             ~w(type properties required additionalProperties description),
             field
           ),
         :ok <- validate_schema_properties(schema["properties"], "#{field}.properties"),
         :ok <- validate_required_strings(schema["required"], "#{field}.required"),
         :ok <-
           validate_additional_properties(
             schema["additionalProperties"],
             "#{field}.additionalProperties"
           ) do
      :ok
    end
  end

  defp validate_schema_properties(nil, _field), do: :ok

  defp validate_schema_properties(%{} = props, field) do
    Enum.reduce_while(props, :ok, fn {name, sub_schema}, :ok ->
      key = to_string(name)

      case validate_schema(sub_schema, "#{field}.#{key}") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_schema_properties(_, field), do: error(field, :not_a_map)

  defp validate_required_strings(nil, _field), do: :ok

  defp validate_required_strings(required, field) when is_list(required) do
    Enum.reduce_while(required, :ok, fn name, :ok ->
      case require_string_value(name, field, &non_empty?/1) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_required_strings(_, field), do: error(field, :not_a_list)

  defp validate_additional_properties(nil, _field), do: :ok
  defp validate_additional_properties(value, _field) when is_boolean(value), do: :ok
  defp validate_additional_properties(_, field), do: error(field, :invalid_boolean)

  defp validate_array_schema(schema, field) do
    with :ok <- exact_nested_keys(schema, ~w(type items description), field),
         :ok <- validate_schema(schema["items"], "#{field}.items") do
      :ok
    end
  end

  defp validate_simple_schema(schema, field) do
    exact_nested_keys(schema, ~w(type description), field)
  end

  defp validate_capabilities(%{} = caps) do
    with :ok <-
           exact_nested_keys(caps, ~w(mounts hosts timeout_ms memory_max_mib), "capabilities"),
         :ok <- require_list(caps["mounts"], "capabilities.mounts"),
         :ok <- validate_mounts(caps["mounts"]),
         :ok <- require_list(caps["hosts"], "capabilities.hosts"),
         :ok <- validate_hosts(caps["hosts"]),
         :ok <- require_positive_integer(caps["timeout_ms"], "capabilities.timeout_ms"),
         :ok <- require_positive_integer(caps["memory_max_mib"], "capabilities.memory_max_mib") do
      :ok
    end
  end

  defp validate_capabilities(nil), do: error("capabilities", :missing)
  defp validate_capabilities(_), do: error("capabilities", :not_a_map)

  defp validate_mounts(mounts) when is_list(mounts) do
    Enum.reduce_while(Enum.with_index(mounts), :ok, fn {mount, idx}, :ok ->
      case validate_mount(mount, "capabilities.mounts.#{idx}") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_mount(%{} = mount, field) do
    with :ok <- exact_nested_keys(mount, ~w(path readonly), field),
         :ok <- require_string_value(mount["path"], "#{field}.path", &non_empty?/1),
         :ok <- require_literal_true(mount["readonly"], "#{field}.readonly") do
      :ok
    end
  end

  defp validate_mount(_, field), do: error(field, :not_a_map)

  defp validate_hosts(hosts) when is_list(hosts) do
    Enum.reduce_while(Enum.with_index(hosts), :ok, fn {host, idx}, :ok ->
      case require_string_value(host, "capabilities.hosts.#{idx}", &non_empty?/1) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_surfaces(nil), do: :ok

  defp validate_surfaces(surfaces) when is_list(surfaces) do
    Enum.reduce_while(Enum.with_index(surfaces), :ok, fn {surface, idx}, :ok ->
      case validate_surface(surface, "surfaces.#{idx}") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_surfaces(_), do: error("surfaces", :not_a_list)

  defp validate_surface(%{} = surface, field) do
    with :ok <-
           exact_nested_keys(surface, ~w(kind name description slash_commands tools), field),
         :ok <- require_string_value(surface["name"], "#{field}.name", &non_empty?/1),
         :ok <-
           require_string_value(surface["description"], "#{field}.description", &non_empty?/1),
         :ok <- validate_slash_commands(surface["slash_commands"], "#{field}.slash_commands"),
         :ok <- validate_tools(surface["tools"], "#{field}.tools") do
      :ok
    end
  end

  defp validate_surface(_, field), do: error(field, :not_a_map)

  defp validate_slash_commands(nil, _field), do: :ok

  defp validate_slash_commands(commands, field) when is_list(commands) do
    Enum.reduce_while(Enum.with_index(commands), :ok, fn {cmd, idx}, :ok ->
      case validate_slash_command(cmd, "#{field}.#{idx}") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_slash_commands(_, field), do: error(field, :not_a_list)

  defp validate_slash_command(%{} = cmd, field) do
    with :ok <- exact_nested_keys(cmd, ~w(command description), field),
         :ok <- require_string_value(cmd["command"], "#{field}.command", &non_empty?/1),
         :ok <- require_string_value(cmd["description"], "#{field}.description", &non_empty?/1) do
      :ok
    end
  end

  defp validate_slash_command(_, field), do: error(field, :not_a_map)

  defp validate_tools(nil, _field), do: :ok

  defp validate_tools(tools, field) when is_list(tools) do
    Enum.reduce_while(Enum.with_index(tools), :ok, fn {tool, idx}, :ok ->
      case validate_tool(tool, "#{field}.#{idx}") do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_tools(_, field), do: error(field, :not_a_list)

  defp validate_tool(%{} = tool, field) do
    with :ok <- exact_nested_keys(tool, ~w(name description), field),
         :ok <- require_string_value(tool["name"], "#{field}.name", &non_empty?/1),
         :ok <- require_string_value(tool["description"], "#{field}.description", &non_empty?/1) do
      :ok
    end
  end

  defp validate_tool(_, field), do: error(field, :not_a_map)

  defp validate_reserved(manifest) do
    with :ok <- validate_price(manifest["price_msats"]),
         :ok <- validate_license(manifest["license"]) do
      :ok
    end
  end

  defp validate_price(nil), do: :ok
  defp validate_price(price) when is_integer(price) and price >= 0, do: :ok
  defp validate_price(_), do: error("price_msats", :invalid_price_msats)

  defp validate_license(nil), do: :ok
  defp validate_license(license) when is_binary(license), do: :ok
  defp validate_license(_), do: error("license", :invalid_license)

  defp require_integer(manifest, key) do
    case manifest[key] do
      value when is_integer(value) and value > 0 -> :ok
      nil -> error(key, :missing)
      _ -> error(key, :invalid_integer)
    end
  end

  defp require_string(manifest, key, pred) do
    case manifest[key] do
      nil ->
        error(key, :missing)

      value when is_binary(value) ->
        if pred.(value), do: :ok, else: error(key, :invalid_string)

      _ ->
        error(key, :invalid_string)
    end
  end

  defp require_string_value(nil, key, _pred), do: error(key, :missing)

  defp require_string_value(value, key, pred) when is_binary(value) do
    if pred.(value), do: :ok, else: error(key, :invalid_string)
  end

  defp require_string_value(_, key, _pred), do: error(key, :invalid_string)

  defp require_list(nil, key), do: error(key, :missing)
  defp require_list(value, _key) when is_list(value), do: :ok
  defp require_list(_, key), do: error(key, :not_a_list)

  defp require_literal_true(nil, field), do: error(field, :missing)
  defp require_literal_true(true, _field), do: :ok
  defp require_literal_true(_, field), do: error(field, :invalid_readonly)

  defp require_positive_integer(nil, key), do: error(key, :missing)

  defp require_positive_integer(value, _key) when is_integer(value) and value > 0,
    do: :ok

  defp require_positive_integer(_, key), do: error(key, :invalid_positive_integer)

  defp error(field, reason) do
    {:error, %ValidationError{field: to_string(field), reason: reason}}
  end

  defp normalize(manifest) do
    Map.new(manifest, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize_value(v)} end)

  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value
end
