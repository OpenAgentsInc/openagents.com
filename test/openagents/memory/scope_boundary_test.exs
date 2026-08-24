defmodule OpenAgents.Memory.ScopeBoundaryTest do
  @moduledoc """
  The executable enumeration behind MEMORY-001, MEMORY-004, and PRIVACY-001.

  Each of these three contracts quantifies over a population that a test of the
  recall queries and projections someone wrote cannot close:

    * `MEMORY-001` — no recall API offers a cross-conversation or unscoped
      fallback.
    * `MEMORY-004` — recall scope is enforced by `messages.conversation_id` in
      every PostgreSQL query, and profile-memory queries require
      `owner_visitor_id` in every predicate.
    * `PRIVACY-001` — every export or projection re-applies
      `openagents.memory.redaction.v1`.

  `ADMIN-001` carried the same shape before `443c74b`: it said no routed
  controller returns recording audio while one did, because the proof examined
  the surfaces someone remembered. So this file proves the quantifier instead of
  the prose, by closing each population against something that cannot forget a
  member.

  Three mechanisms close them.

    * The **recall backend** is `config/config.exs`'s `:recall_search_backend`.
      A backend's public API is `__info__(:functions)`, which grows the moment
      someone adds a function, so the entry points are enumerable and each one
      is driven across a conversation boundary here.
    * The **queries** are read from each module's own source AST, so every
      `from(x in Schema, …)` rooted at a scoped table is found whether or not
      anyone remembered it. A comment cannot add a query and a docstring cannot
      hide one, because the parser has already discarded both. What the AST
      establishes is that the predicate is written; that it refuses is the
      behaviour `OpenAgents.Memory.LexicalRecallTest` and
      `OpenAgents.ProfileMemoryTest` prove.
    * The **profile-memory readers** are read from each compiled module's import
      table, the way `OpenAgents.DependencyBoundaryTest` reads them, so a module
      that gains a query against the profile plane fails here until PRIVACY-001
      accounts for what it does with a stored claim.
  """

  use OpenAgents.DataCase, async: true

  alias OpenAgents.Conversations
  alias OpenAgents.Conversations.Message
  alias OpenAgents.Memory.RecallSnapshot

  # ── MEMORY-001 ────────────────────────────────────────────────────────────
  #
  # Recall is reached through the configured backend, so the backends are the
  # population of "recall APIs". Both implement the same surface; `HybridRecall`
  # composes the lexical one with pgvector.
  @recall_backends [OpenAgents.Memory.LexicalRecall, OpenAgents.Memory.HybridRecall]

  # Every public function of a recall backend, and how its scope is closed.
  # `:refuses_foreign_snapshot` entries are driven across a conversation
  # boundary below; the other two are closed by their own arguments.
  @recall_entry_points %{
    {:capture_ref, 3} => :takes_the_conversation_id,
    {:load_snapshot, 2} => :refuses_a_foreign_snapshot_ref,
    {:search, 3} => :refuses_foreign_snapshot,
    {:search, 4} => :refuses_foreign_snapshot,
    {:search_page, 3} => :refuses_foreign_snapshot,
    {:search_page, 4} => :refuses_foreign_snapshot,
    {:read, 3} => :refuses_foreign_snapshot,
    {:read, 4} => :refuses_foreign_snapshot
  }

  # ── MEMORY-004 ────────────────────────────────────────────────────────────
  #
  # Every table a scoped query may be rooted at, and the column names that
  # carry the scope for it. A query rooted at one of these schemas whose AST
  # names none of its columns is a query with no scope predicate.
  @scope_columns %{
    # The recall corpus. `conversation_id` reaches the tool-step tables through
    # the turn and the voice session, which is why the join binding, not the
    # step, carries it.
    Message: [:conversation_id],
    TurnToolStep: [:conversation_id],
    VoiceToolStep: [:conversation_id],

    # The profile-memory plane. `Source` and the message reads inside it reach
    # the owner through the conversation's `visitor_id`.
    Record: [:owner_visitor_id],
    Scope: [:owner_visitor_id],
    SnapshotRecord: [:owner_visitor_id],
    Source: [:owner_visitor_id, :visitor_id],
    Conversation: [:visitor_id]
  }

  # `OpenAgents.ProfileMemory` validates and admits its sources by reading the
  # owner's own messages, so `Message` is scoped there by the conversation's
  # owner rather than by one conversation.
  @owner_scoped_message_modules [OpenAgents.ProfileMemory]

  # ── PRIVACY-001 ───────────────────────────────────────────────────────────
  #
  # Every module that names a profile-memory schema, and what it does with a
  # stored claim. Only `:projects_claims` may hand claim text to a reader, and
  # every `:projects_claims` module must name `OpenAgents.Memory.Redaction`.
  @profile_memory_readers %{
    OpenAgents.ProfileMemory => :projects_claims,
    OpenAgents.DataRights => :erases_the_owner_plane_by_id_and_reads_no_claim,
    OpenAgents.Memory.Portability =>
      :compares_claims_for_import_admission_and_exports_through_profile_memory,
    OpenAgents.Tools.MemoryContract => :reads_the_category_list_only,
    OpenAgents.Tools.MemoryCorrect => :reads_the_category_list_only,
    OpenAgents.Tools.MemoryList => :reads_the_category_list_only,
    OpenAgents.Tools.MemoryRemember => :reads_the_category_list_only
  }

  describe "MEMORY-001" do
    test "the configured recall backend is one this invariant names" do
      configured = Application.fetch_env!(:openagents, :recall_search_backend)

      assert configured in @recall_backends, """
      `:recall_search_backend` names a module MEMORY-001 does not.

      Recall reaches PostgreSQL through the configured backend, so a backend
      this file does not enumerate is a recall API no test drives across a
      conversation boundary. Amend MEMORY-001, then name the module here.
      """
    end

    test "every public function of every recall backend is an enumerated entry point" do
      for backend <- @recall_backends do
        actual = MapSet.new(backend.__info__(:functions))
        declared = entry_point_set()

        assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
               """
               #{inspect(backend)} gained a public function MEMORY-001 does not
               name. A recall entry point that nothing drives across a
               conversation boundary is exactly the unscoped fallback the
               invariant says does not exist. Amend MEMORY-001, then name it
               here with how its scope is closed.
               """

        assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
               """
               MEMORY-001 names a recall entry point #{inspect(backend)} no
               longer exposes. Amend MEMORY-001, then remove it here.
               """
      end
    end

    test "every snapshot-taking entry point refuses another conversation's snapshot" do
      first = conversation!("scope-boundary-first")
      second = conversation!("scope-boundary-second")

      message = insert_message!(second, "user", "a private phrase from the other conversation")

      foreign = %RecallSnapshot{
        conversation_id: second.id,
        message_id: message.id,
        inserted_at: message.inserted_at
      }

      for backend <- @recall_backends,
          {{function, arity}, :refuses_foreign_snapshot} <- @recall_entry_points do
        arguments = foreign_call_arguments(function, arity, first, foreign, message)

        assert apply(backend, function, arguments) == {:error, :scope_refused}, """
        #{inspect(backend)}.#{function}/#{arity} answered a snapshot belonging
        to another conversation. MEMORY-001 says no recall API offers a
        cross-conversation fallback.
        """
      end
    end

    test "load_snapshot refuses a snapshot ref minted in another conversation" do
      first = conversation!("scope-boundary-load-first")
      second = conversation!("scope-boundary-load-second")
      message = insert_message!(second, "user", "another conversation's watermark")

      for backend <- @recall_backends do
        assert backend.load_snapshot(first, "message:#{message.id}") ==
                 {:error, :scope_refused}
      end
    end

    test "capture_ref watermarks the conversation it is given, never another" do
      first = conversation!("scope-boundary-capture-first")
      second = conversation!("scope-boundary-capture-second")
      _other = insert_message!(second, "user", "the other conversation's newest message")
      own = insert_message!(first, "user", "this conversation's only message")

      for backend <- @recall_backends do
        assert backend.capture_ref(Repo, first.id, Ecto.UUID.generate()) ==
                 {:ok, "message:#{own.id}"}
      end
    end
  end

  describe "MEMORY-004" do
    test "every recall query is rooted at a scoped table and names its scope column" do
      for backend <- @recall_backends, query <- rooted_queries(backend) do
        assert_scoped(backend, query, """
        MEMORY-004 says recall scope is enforced by `messages.conversation_id`
        in every PostgreSQL query, never by prompt instructions. A recall query
        with no scope predicate reads another conversation's history.
        """)
      end
    end

    test "every profile-memory query names the owner in its predicate" do
      modules = profile_memory_schema_callers()

      assert modules != [], """
      No compiled module names a profile-memory schema, so this enumeration is
      reading nothing. Check the schema files under
      `lib/openagents/profile_memory/`.
      """

      governed = governed_profile_schemas()

      queries =
        for module <- modules,
            query <- rooted_queries(module),
            MapSet.member?(governed_for(module, governed), query.schema),
            do: {module, query}

      assert queries != [], """
      No query in any profile-memory reader is rooted at a profile-memory
      schema, so this enumeration is reading nothing.
      """

      for {module, query} <- queries do
        assert_scoped(module, query, """
        MEMORY-004 says profile-memory queries require `owner_visitor_id` in
        every predicate and that unknown scope has no global fallback. A query
        with no owner predicate reads another account's plane.
        """)
      end
    end
  end

  describe "PRIVACY-001" do
    test "the modules that read the profile plane are exactly the set this invariant accounts for" do
      actual = MapSet.new(profile_memory_schema_callers())
      declared = @profile_memory_readers |> Map.keys() |> MapSet.new()

      assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
             """
             A module gained a dependency on a profile-memory schema without
             PRIVACY-001 accounting for it. A module that reads stored claims
             without naming `OpenAgents.Memory.Redaction` is the projection the
             invariant says cannot exist. Amend PRIVACY-001 in INVARIANTS.md,
             then add it here with what it does with a claim.
             """

      assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
             """
             PRIVACY-001 accounts for a profile-memory reader that no longer
             exists. Amend PRIVACY-001 in INVARIANTS.md, then remove it here.
             """
    end

    test "every module that projects a stored claim re-applies the redaction policy" do
      redaction_callers = MapSet.new(callers(&(elem(&1, 0) == OpenAgents.Memory.Redaction)))

      projectors =
        for {module, :projects_claims} <- @profile_memory_readers, do: module

      assert projectors == [OpenAgents.ProfileMemory], """
      PRIVACY-001 keeps one projector of stored claims. A second one is a
      second place the redaction policy has to be remembered.
      """

      for module <- projectors do
        assert MapSet.member?(redaction_callers, module), """
        #{inspect(module)} projects stored profile-memory claims without naming
        `OpenAgents.Memory.Redaction`, so a value that fails revalidation is
        published rather than withheld as a whole field.
        """
      end
    end

    test "the pinned policy identities are the ones PRIVACY-001 names" do
      # Stored records carry these strings forever, so the invariant has to
      # name what the code emits. It named `openagents.memory.redaction.v1`
      # and `openagents.memory.policy.v1`, which no record has ever carried.
      assert OpenAgents.Memory.Redaction.version() == "sarah.memory.redaction.v1"
      assert OpenAgents.Memory.Policy.version() == "sarah.memory.policy.v1"
    end
  end

  # ── Population: the recall entry points ───────────────────────────────────

  defp entry_point_set, do: @recall_entry_points |> Map.keys() |> MapSet.new()

  defp foreign_call_arguments(:read, 3, conversation, snapshot, message),
    do: [conversation, snapshot, "message:#{message.id}"]

  defp foreign_call_arguments(:read, 4, conversation, snapshot, message),
    do: [conversation, snapshot, "message:#{message.id}", []]

  defp foreign_call_arguments(function, 3, conversation, snapshot, _message)
       when function in [:search, :search_page],
       do: [conversation, snapshot, "phrase"]

  defp foreign_call_arguments(function, 4, conversation, snapshot, _message)
       when function in [:search, :search_page],
       do: [conversation, snapshot, "phrase", []]

  # ── Population: the queries a module writes ───────────────────────────────

  # Every `from(binding in Schema, …)` in the module's own source, with the
  # field names its expression mentions. Query refinements (`from([step] in
  # query, …)`) are not rooted at a schema and carry the scope of the query
  # they narrow, so they are correctly absent.
  defp rooted_queries(module) do
    {_ast, found} =
      module
      |> source_path()
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:from, meta, [{:in, _, [_binding, {:__aliases__, _, segments}]} | _rest]} = node, acc ->
          {node, [%{schema: List.last(segments), line: meta[:line], fields: fields(node)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp fields(node) do
    {_ast, fields} =
      Macro.prewalk(node, MapSet.new(), fn
        {{:., _, [{_binding, _, _context}, field]}, _, []} = leaf, acc when is_atom(field) ->
          {leaf, MapSet.put(acc, field)}

        leaf, acc ->
          {leaf, acc}
      end)

    fields
  end

  defp assert_scoped(module, %{schema: schema, line: line, fields: fields}, why) do
    columns = Map.get(@scope_columns, schema)

    assert columns != nil, """
    #{inspect(module)}:#{line} builds a query rooted at `#{schema}`, which
    MEMORY-004 does not give a scope column.

    #{why}
    Amend MEMORY-004 in INVARIANTS.md, then name the table and its scope column
    in `@scope_columns`.
    """

    columns = scope_columns(module, schema, columns)

    assert Enum.any?(columns, &MapSet.member?(fields, &1)), """
    #{inspect(module)}:#{line} builds a query rooted at `#{schema}` that names
    none of #{inspect(columns)}.

    #{why}
    """
  end

  defp scope_columns(module, :Message, _columns) when module in @owner_scoped_message_modules,
    do: [:visitor_id]

  defp scope_columns(_module, _schema, columns), do: columns

  # ── Population: the modules that reach the profile plane ──────────────────

  # Derived from the schema files themselves, so a schema added under
  # `lib/openagents/profile_memory/` joins this enumeration without anyone
  # remembering to add it.
  defp profile_memory_schemas do
    "lib/openagents/profile_memory/*.ex"
    |> Path.wildcard()
    |> Enum.map(fn path ->
      Module.concat([OpenAgents.ProfileMemory, Macro.camelize(Path.basename(path, ".ex"))])
    end)
  end

  defp profile_memory_schema_callers do
    schemas = profile_memory_schemas()
    assert schemas != []
    callers(fn {module, _function, _arity} -> module in schemas end)
  end

  # The tables MEMORY-004's owner rule governs: every schema under
  # `lib/openagents/profile_memory/`, derived so a new one joins without anyone
  # remembering. Queries a reader writes against other tables belong to other
  # contracts and are not checked here.
  defp governed_profile_schemas do
    profile_memory_schemas()
    |> Enum.map(&(&1 |> Module.split() |> List.last() |> String.to_atom()))
    |> MapSet.new()
  end

  # `OpenAgents.ProfileMemory` also validates and admits its sources by reading
  # the owner's own messages, so those two roots are governed there as well.
  defp governed_for(module, governed) when module in @owner_scoped_message_modules,
    do: MapSet.union(governed, MapSet.new([:Message, :Conversation]))

  defp governed_for(_module, governed), do: governed

  defp source_path(module) do
    path =
      module.module_info(:compile)
      |> Keyword.fetch!(:source)
      |> List.to_string()
      |> Path.relative_to_cwd()

    assert File.exists?(path), """
    #{inspect(module)} reports a source file this checkout does not have
    (#{path}), so its queries cannot be read.
    """

    path
  end

  # Read from each compiled module's import table rather than from source text,
  # so a comment cannot add a caller and a rename cannot hide one.
  defp callers(predicate) do
    {:ok, modules} = :application.get_key(:openagents, :modules)

    modules
    |> Enum.filter(fn module ->
      with path when is_list(path) <- :code.which(module),
           {:ok, {^module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
        Enum.any?(imports, predicate)
      else
        _unreadable -> false
      end
    end)
    |> Enum.sort()
  end

  defp conversation!(browser_id) do
    {:ok, conversation} =
      Conversations.ensure_conversation("#{browser_id}-#{System.unique_integer([:positive])}")

    conversation
  end

  defp insert_message!(conversation, role, content) do
    Repo.insert!(%Message{
      conversation_id: conversation.id,
      role: role,
      content: content,
      status: "complete",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end
end
