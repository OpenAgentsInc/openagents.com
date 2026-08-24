defmodule OpenAgentsWeb.ToolActivityProjectionTest do
  @moduledoc """
  The executable enumeration behind UI-002's provider-identifier clause.

  UI-002 says provider identifiers (call, item, and response IDs) never enter
  socket assigns or HTML. The assigns a LiveView sets are not declared anywhere
  the way a struct is, so that half of the sentence cannot be enumerated
  directly. What can be enumerated is the only thing those assigns are built
  from: the durable tool-step row, and the map projections the application
  selects out of it. UI-002 is narrowed to that population and proven over it.

  Both sides are derived.

    * The **forbidden fields** are every column of `OpenAgents.Conversations.ToolStep`
      and `OpenAgents.Voice.ToolStep` whose name begins with `provider_`, read
      from `__schema__(:fields)`. A provider identifier added to either table
      joins the prohibition without anyone remembering.
    * The **projections** are every map-shaped `select:` in an Ecto query rooted
      at either tool-step schema, read from the source AST of every file under
      `lib/`. A new projection anywhere in the application is found, whether or
      not it is the one the interface renders.

  What the AST establishes is which columns a projection selects. That the
  rendered strings are then byte-capped is `OpenAgentsWeb.ToolActivityTest`'s,
  and what reaches the transcript is `OpenAgentsWeb.ChatLiveTest`'s. UI-002's
  other enumerated half — the ephemeral computer-delegation stream the 2026-08-18
  amendment sanctions — is pinned by the exact event key sets in
  `OpenAgents.ComputerActivityTest`.
  """

  use ExUnit.Case, async: true

  @tool_step_schemas [OpenAgents.Conversations.ToolStep, OpenAgents.Voice.ToolStep]

  # The alias segments an Ecto query is rooted at for those two schemas. Both
  # modules are named `ToolStep`; `OpenAgents.Memory.LexicalRecall` aliases them
  # apart.
  @tool_step_roots [:ToolStep, :TurnToolStep, :VoiceToolStep]

  # Every map projection built from a tool-step row, with the keys it publishes.
  # The first four are what the interface renders. The rest never reach a
  # template and are named so the enumeration is exact in both directions.
  @tool_step_projections %{
    {OpenAgents.Conversations, :list_tool_step_activity, 1} => [
      :attribution_policy_id,
      :billable,
      :completed_at,
      :cost_units,
      :error,
      :executor_disclosure,
      :executor_id,
      :id,
      :module_artifact_digest,
      :module_id,
      :module_version,
      :outcome_receipt_ref,
      :raw_arguments,
      :requested_at,
      :result,
      :sequence,
      :started_at,
      :status,
      :tool_name
    ],
    {OpenAgents.Conversations, :list_tool_step_activity_by_message, 1} => [
      :attribution_policy_id,
      :billable,
      :completed_at,
      :cost_units,
      :error,
      :executor_disclosure,
      :executor_id,
      :id,
      :module_artifact_digest,
      :module_id,
      :module_version,
      :outcome_receipt_ref,
      :raw_arguments,
      :requested_at,
      :result,
      :sequence,
      :started_at,
      :status,
      :tool_name
    ],
    {OpenAgents.Voice, :list_tool_step_activity, 1} => [
      :completed_at,
      :error,
      :executor_disclosure,
      :executor_id,
      :id,
      :raw_arguments,
      :requested_at,
      :result,
      :sequence,
      :started_at,
      :status,
      :tool_name
    ],
    {OpenAgents.Voice, :list_tool_step_activity_by_message, 1} => [
      :completed_at,
      :error,
      :executor_disclosure,
      :executor_id,
      :id,
      :raw_arguments,
      :requested_at,
      :result,
      :sequence,
      :started_at,
      :status,
      :tool_name
    ],

    # Recall's lexical document over durable tool activity (MEMORY-004). It is
    # scored and excerpted, never rendered as a step row.
    {OpenAgents.Memory.LexicalRecall, :turn_tool_step_rows, 6} => [
      :error,
      :id,
      :observed_at,
      :result,
      :score,
      :status,
      :tool_name
    ],
    {OpenAgents.Memory.LexicalRecall, :voice_tool_step_rows, 6} => [
      :error,
      :id,
      :observed_at,
      :result,
      :score,
      :status,
      :tool_name
    ],

    # The voice response-contract check, which reads its own steps server-side.
    {OpenAgents.Voice, :maybe_evaluate_response_contract, 3} => [:id, :status, :tool_name]
  }

  test "the provider-identifier columns are read from the tool-step schemas" do
    assert provider_fields() != MapSet.new(), """
    Neither tool-step schema has a column beginning with `provider_`, so this
    enumeration is prohibiting nothing. UI-002 names call, item, and response
    IDs; check `#{inspect(@tool_step_schemas)}`.
    """
  end

  test "no projection of a tool-step row selects a provider identifier" do
    forbidden = provider_fields()

    for {location, projection} <- tool_step_projections() do
      leaked = projection.fields |> MapSet.intersection(forbidden) |> MapSet.to_list()

      assert leaked == [], """
      #{describe(location)} selects #{inspect(leaked)} out of a tool-step row.

      UI-002 says provider identifiers never enter socket assigns or HTML, and
      a projection is where one would enter. Drop the column, or amend UI-002
      in INVARIANTS.md first.
      """
    end
  end

  test "the projections of a tool-step row are exactly the ones UI-002 names" do
    actual = tool_step_projections() |> Map.new(fn {location, p} -> {location, p.keys} end)

    assert actual != %{}, """
    No map projection of a tool-step row was found under `lib/`, so this
    enumeration is reading nothing.
    """

    declared =
      Map.new(@tool_step_projections, fn {location, keys} -> {location, Enum.sort(keys)} end)

    assert Map.keys(actual) -- Map.keys(declared) == [], """
    A map projection of a tool-step row exists that UI-002 does not name:

    #{Enum.map_join(Map.keys(actual) -- Map.keys(declared), "\n", &"  #{describe(&1)}")}

    Amend UI-002 in INVARIANTS.md, then name it here with the keys it publishes.
    """

    assert Map.keys(declared) -- Map.keys(actual) == [], """
    UI-002 names a tool-step projection that no longer exists:

    #{Enum.map_join(Map.keys(declared) -- Map.keys(actual), "\n", &"  #{describe(&1)}")}
    """

    for {location, keys} <- declared do
      assert Map.fetch!(actual, location) == keys, """
      #{describe(location)} publishes a different key set than UI-002 names.

      Expected #{inspect(keys)}
      Selected #{inspect(Map.fetch!(actual, location))}

      Every key here reaches a template. Amend UI-002 in INVARIANTS.md, then
      change it here.
      """
    end
  end

  # ── Population: the columns that must not be projected ────────────────────

  defp provider_fields do
    @tool_step_schemas
    |> Enum.flat_map(& &1.__schema__(:fields))
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "provider_"))
    |> MapSet.new()
  end

  # ── Population: the projections the application builds ────────────────────

  defp tool_step_projections do
    for path <- Path.wildcard("lib/**/*.ex"),
        ast = Code.string_to_quoted!(File.read!(path)),
        module = defining_module(ast),
        {name, arity, body} <- definitions(ast),
        node <- tool_step_queries(body),
        pairs <- select_maps(node),
        into: %{} do
      {{module, name, arity},
       %{
         keys: pairs |> Enum.map(fn {key, _value} -> key end) |> Enum.sort(),
         fields: field_names(pairs)
       }}
    end
  end

  defp defining_module(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, segments} | _rest]} = node, acc ->
          {node, [Module.concat(segments) | acc]}

        node, acc ->
          {node, acc}
      end)

    List.last(modules)
  end

  defp definitions(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {kind, _, [{:when, _, [{name, _, arguments} | _guard]} | _rest]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{name, length(List.wrap(arguments)), node} | acc]}

        {kind, _, [{name, _, arguments} | _rest]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{name, length(List.wrap(arguments)), node} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp tool_step_queries(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:from, _, [{:in, _, [_binding, {:__aliases__, _, segments}]} | _rest]} = node, acc ->
          if List.last(segments) in @tool_step_roots, do: {node, [node | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp select_maps(node) do
    {_ast, found} =
      Macro.prewalk(node, [], fn
        {:select, expression} = select, acc ->
          {_inner, maps} =
            Macro.prewalk(expression, [], fn
              {:%{}, _, pairs} = map, inner -> {map, [pairs | inner]}
              inner_node, inner -> {inner_node, inner}
            end)

          {select, maps ++ acc}

        inner_node, acc ->
          {inner_node, acc}
      end)

    found
  end

  # The row columns a projection reads, not the keys it publishes them under, so
  # renaming `provider_call_id` to `call_id` in the map does not hide it.
  defp field_names(pairs) do
    {_ast, fields} =
      Macro.prewalk({:%{}, [], pairs}, MapSet.new(), fn
        {{:., _, [{_binding, _, _context}, field]}, _, []} = leaf, acc when is_atom(field) ->
          {leaf, MapSet.put(acc, field)}

        leaf, acc ->
          {leaf, acc}
      end)

    fields
  end

  defp describe({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
