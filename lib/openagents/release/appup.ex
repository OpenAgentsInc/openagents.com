defmodule OpenAgents.Release.Appup do
  @moduledoc """
  Derives one release pair's appup instructions from the two builds' modules.

  `:systools.make_relup/4` consumes an appup verbatim. It never compares module
  contents, so a constant instruction list upgrades only the modules it names
  and leaves every other changed module running the old code while the node
  reports itself converged. This module reads both builds' compiled modules and
  emits one instruction per module that actually differs.

  Both directories must be application `ebin` directories from the same build
  stage — `_build/<env>/lib/openagents/ebin` on each side — so that protocol
  consolidation, which `mix release` performs later, cannot make the two sides
  disagree about modules neither revision changed.

  `OpenAgents.ReleaseState` always takes an advanced update carrying the target
  schema version, because the target schema belongs to the other release and a
  running module cannot infer it. `OpenAgents.ReleaseState.install_barrier/0`
  runs after the module instructions in both directions.

  Consolidated protocol modules live outside the application `ebin` directory
  and no appup covers them. A revision that changes protocol consolidation is a
  structural change and belongs on the rolling replacement path.
  """

  @state_module OpenAgents.ReleaseState
  @barrier {:apply, {OpenAgents.ReleaseState, :install_barrier, []}}
  @schema_versions [1, 2]
  @version_pattern ~r/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

  @doc """
  Build the complete appup term for one concrete release pair.

  Returns `{to_version, [{from_version, up}], [{from_version, down}]}` in the
  charlist shape `:systools` expects.
  """
  def build(options) do
    from_version = version!(options, :from_version)
    to_version = version!(options, :to_version)

    if from_version == to_version do
      raise ArgumentError, "from_version and to_version must differ"
    end

    {up, down} = instructions(options)

    {String.to_charlist(to_version), [{String.to_charlist(from_version), up}],
     [{String.to_charlist(from_version), down}]}
  end

  @doc """
  Return `{up, down}` instruction lists covering every module that differs.

  Options:

    * `:from_ebin` — the older build's application `ebin` directory
    * `:to_ebin` — the newer build's application `ebin` directory
    * `:from_state_version` — the older build's `ReleaseState` schema
    * `:to_state_version` — the newer build's `ReleaseState` schema
  """
  def instructions(options) do
    from = read_modules(Keyword.fetch!(options, :from_ebin))
    to = read_modules(Keyword.fetch!(options, :to_ebin))
    from_schema = schema!(options, :from_state_version)
    to_schema = schema!(options, :to_state_version)

    added = Enum.sort(Map.keys(to) -- Map.keys(from))
    removed = Enum.sort(Map.keys(from) -- Map.keys(to))

    changed =
      for {module, entry} <- to,
          previous = Map.get(from, module),
          previous != nil,
          previous.digest != entry.digest,
          do: module

    migrated =
      changed
      |> with_state_module(from, to)
      |> Enum.sort()

    up =
      Enum.map(added, &{:add_module, &1}) ++
        Enum.map(migrated, &instruction(&1, to, to_schema)) ++
        [@barrier] ++
        Enum.map(removed, &{:delete_module, &1})

    down =
      Enum.map(removed, &{:add_module, &1}) ++
        Enum.map(migrated, &instruction(&1, from, from_schema)) ++
        [@barrier] ++
        Enum.map(added, &{:delete_module, &1})

    {up, down}
  end

  @doc """
  Raise unless the generated relup names every module the two builds differ in.

  `:systools` reads the appup from the candidate's `ebin` directory, so a stale
  appup, missing build environment, or dropped instruction produces a relup
  that installs fewer modules than the revisions changed. This recomputes the
  instruction list from the same two `ebin` directories and checks the relup
  against it in both directions. It proves the packaging pipeline carried the
  instructions through; it cannot prove that loading a module is the right
  instruction for it.

  Returns the sorted list of modules the upgrade direction covers.
  """
  def verify_relup!(path, options) do
    {up, down} = instructions(options)

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{_to_version, up_entries, down_entries}]} ->
        check_direction!(path, "upgrade", up, up_entries)
        check_direction!(path, "downgrade", down, down_entries)
        up |> Enum.flat_map(&instruction_module/1) |> Enum.sort()

      other ->
        raise ArgumentError, "#{path} is not a relup file: #{inspect(other)}"
    end
  end

  @doc "Return every atom a relup or appup instruction term names."
  def named_atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> named_atoms()
  def named_atoms(term) when is_list(term), do: Enum.flat_map(term, &named_atoms/1)
  def named_atoms(term) when is_atom(term), do: [term]
  def named_atoms(_term), do: []

  defp check_direction!(path, direction, expected_instructions, entries) do
    expected = expected_instructions |> Enum.flat_map(&instruction_module/1) |> MapSet.new()
    named = entries |> named_atoms() |> MapSet.new()
    missing = expected |> MapSet.difference(named) |> Enum.sort()

    if missing != [] do
      raise "#{path} carries no #{direction} instruction for: #{Enum.map_join(missing, ", ", &inspect/1)}"
    end
  end

  defp instruction_module({:add_module, module}), do: [module]
  defp instruction_module({:delete_module, module}), do: [module]
  defp instruction_module({:load_module, module}), do: [module]
  defp instruction_module({:update, module, _change}), do: [module]
  defp instruction_module(_instruction), do: []

  defp with_state_module(changed, from, to) do
    if Map.has_key?(from, @state_module) and Map.has_key?(to, @state_module) do
      Enum.uniq([@state_module | changed])
    else
      changed
    end
  end

  defp instruction(@state_module, _modules, schema),
    do: {:update, @state_module, {:advanced, [schema_version: schema]}}

  defp instruction(module, modules, _schema) do
    if modules[module].supervisor?,
      do: {:update, module, :supervisor},
      else: {:load_module, module}
  end

  defp read_modules(directory) when is_binary(directory) do
    beams = directory |> Path.join("*.beam") |> Path.wildcard()

    if beams == [] do
      raise ArgumentError, "no compiled modules found in #{directory}"
    end

    Map.new(beams, &read_module/1)
  end

  defp read_module(path) do
    charlist = String.to_charlist(path)

    case :beam_lib.md5(charlist) do
      {:ok, {module, digest}} ->
        {module, %{digest: digest, supervisor?: supervisor?(charlist)}}

      {:error, :beam_lib, reason} ->
        raise ArgumentError, "cannot read #{path}: #{inspect(reason)}"
    end
  end

  # `use Supervisor` records the Elixir behaviour, but the process it starts is
  # an `:supervisor` process registered under the callback module, so the
  # supervisor instruction is the one that reaches it. Anything else takes
  # `load_module`, which is correct whenever the process state shape did not
  # change; a revision that changes a running process's state shape is a
  # structural change and belongs on the rolling replacement path.
  defp supervisor?(charlist) do
    case :beam_lib.chunks(charlist, [:attributes]) do
      {:ok, {_module, [attributes: attributes]}} ->
        attributes
        |> Enum.flat_map(fn
          {:behaviour, behaviours} when is_list(behaviours) -> behaviours
          _other -> []
        end)
        |> Enum.any?(&(&1 in [:supervisor, Supervisor]))

      _other ->
        false
    end
  end

  defp version!(options, key) do
    version = Keyword.fetch!(options, key)

    if is_binary(version) and Regex.match?(@version_pattern, version) do
      version
    else
      raise ArgumentError, "#{key} must be an X.Y.Z version, got: #{inspect(version)}"
    end
  end

  defp schema!(options, key) do
    schema = Keyword.fetch!(options, key)

    if schema in @schema_versions do
      schema
    else
      raise ArgumentError,
            "#{key} must be one of #{inspect(@schema_versions)}, got: #{inspect(schema)}"
    end
  end
end
