defmodule OpenAgents.Providers.PersonaBoundaryTest do
  @moduledoc """
  The executable enumeration behind PERSONA-001's two universal clauses.

  PERSONA-001 says every request built for an OpenAgents inference receives
  instructions composed from the installed persona artifact, and that provider
  adapters contain no independent OpenAgents persona. `OpenAgents.PersonaTest`
  proves the artifact is admitted by its content SHA-256 and installed before
  the supervision tree starts, which is a proof of the artifact rather than of
  either sentence: an adapter that composed its own instruction text alongside
  the installed one passed every test in this repository, and so did a request
  built somewhere the contract had not counted.

  Both populations are derived from compiled truth instead of remembered.

  1. **The adapters.** Three behaviours declare a provider boundary —
     `OpenAgents.Providers.Provider`, `OpenAgents.Voice.CallProvider`, and
     `OpenAgents.Voice.SidebandProvider`. A module that implements one records
     the behaviour in its BEAM attribute chunk, so the implementor set is read
     back rather than listed, and the configured providers must be members, so
     an adapter reached by configuration that declared no behaviour fails too.
  2. **The request builders.** A `%OpenAgents.Providers.Request{}` literal puts
     the struct's module name in the building module's atom table, so every
     module that constructs, matches, or otherwise names one is read back from
     that chunk and classified here by where its instructions come from.

  Import edges are read from BEAM import tables rather than from source text,
  so a comment cannot add a caller, a rename cannot hide one, and an alias
  cannot disguise one.

  **What this does not close.** The wire probes read the outbound body, not
  headers or a second request an adapter might make. `:outbound_socket`
  adapters are bounded by what they can name rather than by a captured frame.
  PERSONA-001 records both.
  """

  use ExUnit.Case, async: true

  alias OpenAgents.Providers.{OpenAI, Request, ToolDefinition}
  alias OpenAgents.Voice.Config

  setup {Req.Test, :verify_on_exit!}

  # The behaviours that declare a provider boundary, and the application
  # configuration keys that select an implementation of one.
  @provider_behaviours [
    OpenAgents.Providers.Provider,
    OpenAgents.Voice.CallProvider,
    OpenAgents.Voice.SidebandProvider
  ]
  @configured_provider_keys [
    :provider,
    :openrouter_provider,
    :voice_call_provider,
    :voice_sideband_provider
  ]

  # Every provider adapter, classified by what it can put in front of a model.
  #
  #   * `:outbound_http` — it builds a request body, so the body is captured
  #     and every string in it is accounted for.
  #   * `:outbound_socket` — it relays frames the host composes, so it is
  #     bounded by the fact that it can name no instruction field.
  #   * `:in_process` — it never leaves the VM, so it has no model to instruct.
  @adapters %{
    OpenAgents.Providers.OpenAI => :outbound_http,
    OpenAgents.Providers.OpenRouter => :outbound_http,
    OpenAgents.Providers.VercelGateway => :outbound_http,
    OpenAgents.Providers.FailingTestProvider => :in_process,
    OpenAgents.Providers.FallbackTestProvider => :in_process,
    OpenAgents.Providers.RecordingTestProvider => :in_process,
    OpenAgents.Providers.Test => :in_process,
    OpenAgents.Providers.ToolCallingTestProvider => :in_process,
    OpenAgents.Providers.UnconfiguredTestProvider => :in_process,
    OpenAgents.Voice.OpenAI.CallClient => :outbound_http,
    OpenAgents.Voice.OpenAI.Sideband => :outbound_socket,
    OpenAgents.Voice.TestCallProvider => :in_process,
    OpenAgents.Voice.TestSidebandProvider => :in_process
  }

  # The modules an adapter would have to reach to obtain or recompose the
  # OpenAgents persona. No adapter names any of them.
  @persona_namespaces [
    "Elixir.OpenAgents.Persona",
    "Elixir.OpenAgents.Context.Composer",
    "Elixir.OpenAgents.Roles",
    "Elixir.OpenAgents.Blueprint"
  ]

  # What an `:in_process` adapter would need to send anything anywhere, or to
  # read persona text off disk.
  @egress_modules [Req, Req.Request, WebSockex, File, :httpc, :gen_tcp, :ssl, :file, :socket]

  # Every module whose atom table names `OpenAgents.Providers.Request`,
  # classified by where the instructions on that request come from. A new
  # module that names the struct fails this until someone answers the question.
  @request_sites %{
    OpenAgents.Turns.TurnServer => :composes_installed_persona,
    OpenAgents.Work.JobServer => :composes_installed_persona,
    OpenAgents.CompensationFixtures => :composes_installed_persona,
    OpenAgents.Persona.Evaluation.Runner => :composes_persona_candidate,
    OpenAgentsWeb.InferenceProxyController => :relays_caller_instructions,
    OpenAgentsWeb.ResponsesController => :relays_caller_instructions,
    OpenAgents.Conversations => :pins_a_composed_request,
    OpenAgents.Providers.OpenAI => :adapter,
    OpenAgents.Providers.OpenRouter => :adapter,
    OpenAgents.Providers.VercelGateway => :adapter,
    OpenAgents.Providers.FailingTestProvider => :adapter,
    OpenAgents.Providers.FallbackTestProvider => :adapter,
    OpenAgents.Providers.RecordingTestProvider => :adapter,
    OpenAgents.Providers.Test => :adapter,
    OpenAgents.Providers.ToolCallingTestProvider => :adapter,
    OpenAgents.Providers.Request => :the_struct_itself
  }

  # Every module that composes instructions from the installed artifact. The
  # voice surface reaches the composer through `OpenAgents.Voice.ContextCapture`
  # rather than through a `%Request{}`, so it is named here and not above.
  @composer_callers [
    OpenAgents.CompensationFixtures,
    OpenAgents.Persona.Evaluation.Runner,
    OpenAgents.Turns.TurnServer,
    OpenAgents.Voice.ContextCapture,
    OpenAgents.Work.JobServer
  ]

  describe "the adapter population" do
    test "the modules implementing a provider behaviour are exactly the ones classified here" do
      assert_exact_set(
        Enum.flat_map(@provider_behaviours, &implementors/1),
        Map.keys(@adapters),
        "implements a provider behaviour"
      )
    end

    test "every configured provider is one of the classified adapters" do
      for key <- @configured_provider_keys do
        configured = Application.fetch_env!(:openagents, key)

        assert Map.has_key?(@adapters, configured), """
        `config :openagents, #{inspect(key)}` selects #{inspect(configured)},
        which this test does not classify. An adapter reached by configuration
        that declares no provider behaviour is invisible to the implementor
        enumeration, so PERSONA-001 must name it here.
        """
      end
    end
  end

  describe "no adapter carries an independent persona" do
    test "no adapter can obtain or recompose the OpenAgents persona" do
      for {adapter, _classification} <- @adapters, module <- namespace(adapter) do
        reached =
          module
          |> imports()
          |> Enum.map(fn {called, _function, _arity} -> called end)
          |> Enum.filter(&persona_module?/1)
          |> Enum.uniq()

        assert reached == [], """
        #{inspect(module)} reaches #{inspect(reached)}.

        PERSONA-001 says provider adapters contain no independent OpenAgents
        persona. An adapter that can read the installed artifact or call the
        composer can put instruction text of its own in front of the model,
        and the host cannot see that it did.
        """
      end
    end

    test "an in-process adapter can send nothing anywhere" do
      for {adapter, :in_process} <- @adapters, module <- namespace(adapter) do
        reached =
          module
          |> imports()
          |> Enum.map(fn {called, _function, _arity} -> called end)
          |> Enum.filter(&(&1 in @egress_modules))
          |> Enum.uniq()

        assert reached == [], """
        #{inspect(module)} is classified `:in_process` but reaches
        #{inspect(reached)}. It can now send a request, so classify it
        `:outbound_http` and give it a wire probe.
        """
      end
    end

    test "an outbound socket adapter can name no instruction field" do
      for {adapter, :outbound_socket} <- @adapters, module <- namespace(adapter) do
        refute :instructions in atoms(module), """
        #{inspect(module)} names `:instructions`. It relays frames the host
        composes and holds no session configuration of its own, which is the
        only bound PERSONA-001 claims for a socket adapter. Capture its frames
        and probe them, or amend PERSONA-001.
        """

        config_edges =
          module
          |> imports()
          |> Enum.filter(fn {called, _function, _arity} -> called == Config end)

        assert config_edges == [], """
        #{inspect(module)} calls #{inspect(config_edges)}, so it can build a
        session payload rather than relay one. A socket adapter that reaches
        `OpenAgents.Voice.Config` can compose an instruction field.
        """
      end
    end
  end

  describe "the wire carries the composed instructions and nothing else" do
    test "the OpenAI adapter sends the composed instructions byte for byte" do
      instructions = "SENTINEL composed instructions for the persona boundary probe."
      prompt = "SENTINEL user input."
      test_process = self()

      request = %Request{
        model_id: "sentinel-model",
        instructions: instructions,
        input: [%{role: "user", content: prompt}],
        tool_definitions: [
          %ToolDefinition{
            name: "sentinel_tool",
            description: "SENTINEL tool description.",
            input_schema: %{"type" => "object", "properties" => %{}},
            strict: true
          }
        ]
      }

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_process, {:outbound_body, body})
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      assert {:error, {:http_status, 503}} =
               OpenAI.stream(request, fn _event -> :ok end,
                 api_key: "sentinel-secret",
                 request_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_received {:outbound_body, body}
      payload = Jason.decode!(body)

      assert payload["instructions"] == instructions, """
      The OpenAI adapter changed the instructions the host composed. PERSONA-001
      says the request receives the composed instructions; an adapter that adds
      to them has a persona of its own.
      """

      assert_exact_set(
        payload_text(payload) -- supplied_strings(request),
        ["function"],
        "is free text the OpenAI adapter added to the outbound body"
      )
    end

    test "the voice call adapter sends the composed session payload byte for byte" do
      instructions = "SENTINEL composed voice instructions for the persona boundary probe."
      sdp_offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
      safety_identifier = String.duplicate("a", 64)
      test_process = self()

      config =
        Config.current!()
        |> Map.put(:enabled?, true)
        |> Config.with_context(instructions, [])

      session = Jason.encode!(Config.session_payload(config))
      assert String.contains?(session, instructions)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_process, {:outbound_body, body})
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      assert {:error, {:http_status, 503}} =
               OpenAgents.Voice.OpenAI.CallClient.create(sdp_offer, safety_identifier, config,
                 api_key: "sentinel-secret",
                 request_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_received {:outbound_body, body}

      assert String.contains?(body, session), """
      The voice call adapter did not send `OpenAgents.Voice.Config.session_payload/1`
      byte for byte. The instructions in that payload are the ones
      `OpenAgents.Voice.ContextCapture` composed from the installed artifact.
      """

      assert occurrences(body, instructions) == 1, """
      The composed instructions appear #{occurrences(body, instructions)} times in
      the outbound body. They belong in the session payload once and nowhere else.
      """

      assert_exact_set(
        Regex.scan(~r/name="([^"]+)"/, body, capture: :all_but_first) |> List.flatten(),
        ["sdp", "session"],
        "is a part the voice call adapter put in the outbound body"
      )
    end
  end

  describe "the request builders" do
    test "the modules that name a provider request are exactly the ones classified here" do
      assert_exact_set(
        modules_naming(Request),
        Map.keys(@request_sites),
        "names OpenAgents.Providers.Request; classify where its instructions come from"
      )
    end

    test "every builder that claims the installed persona reaches the composer" do
      for {module, :composes_installed_persona} <- @request_sites do
        assert module in callers_of(OpenAgents.Context.Composer), """
        #{inspect(module)} is classified `:composes_installed_persona` but does
        not call `OpenAgents.Context.Composer`, so its instructions come from
        somewhere PERSONA-001 does not name.
        """
      end
    end

    test "a surface that relays a caller's instructions composes no OpenAgents persona" do
      relays =
        for({module, :relays_caller_instructions} <- @request_sites, do: module)
        |> Enum.sort()

      # Both surfaces take a caller's own instructions and answer them. The
      # OpenResponses surface joined the inference proxy here rather than
      # earning a classification of its own, because the property PERSONA-001
      # needs from it is identical: it must reach no persona module.
      assert relays ==
               Enum.sort([
                 OpenAgentsWeb.InferenceProxyController,
                 OpenAgentsWeb.ResponsesController
               ])

      for module <- relays do
        reached =
          module
          |> imports()
          |> Enum.map(fn {called, _function, _arity} -> called end)
          |> Enum.filter(&persona_module?/1)
          |> Enum.uniq()

        assert reached == [], """
        #{inspect(module)} reaches #{inspect(reached)}.

        PERSONA-001 excludes the delegated-probe proxy from the composed-persona
        clause because the probe supplies its own system messages and the model
        in that call is not OpenAgents. If the proxy starts composing the
        installed artifact, the exclusion is wrong and PERSONA-001 must say so.
        """
      end
    end

    test "the modules that compose the installed artifact are exactly the ones named" do
      assert_exact_set(
        callers_of(OpenAgents.Context.Composer),
        @composer_callers,
        "composes instructions from the installed persona artifact"
      )
    end
  end

  # ── enumeration helpers ────────────────────────────────────────────────

  defp application_modules do
    {:ok, modules} = :application.get_key(:openagents, :modules)
    modules
  end

  defp implementors(behaviour) do
    Enum.filter(application_modules(), fn module ->
      behaviour in (module.__info__(:attributes)
                    |> Keyword.get_values(:behaviour)
                    |> List.flatten())
    end)
  end

  defp namespace(adapter) do
    prefix = Atom.to_string(adapter)
    Enum.filter(application_modules(), &String.starts_with?(Atom.to_string(&1), prefix))
  end

  defp modules_naming(struct_module) do
    Enum.filter(application_modules(), &(struct_module in atoms(&1)))
  end

  defp callers_of(module) do
    Enum.filter(application_modules(), fn candidate ->
      Enum.any?(imports(candidate), fn {called, _function, _arity} -> called == module end)
    end)
  end

  defp persona_module?(module) do
    name = Atom.to_string(module)
    Enum.any?(@persona_namespaces, &String.starts_with?(name, &1))
  end

  defp imports(module), do: chunk(module, :imports)

  defp atoms(module) do
    module |> chunk(:atoms) |> Enum.map(fn {_index, atom} -> atom end)
  end

  # Read from the compiled BEAM rather than from source text.
  defp chunk(module, name) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, [{^name, entries}]}} <- :beam_lib.chunks(path, [name]) do
      entries
    else
      _unreadable -> []
    end
  end

  # ── payload helpers ────────────────────────────────────────────────────

  # Every string the host handed the adapter, so what is left in the outbound
  # body is what the adapter itself put there.
  defp supplied_strings(%Request{} = request) do
    [request.model_id, request.instructions] ++
      Enum.flat_map(request.input, &strings/1) ++
      Enum.flat_map(request.tool_definitions, fn definition ->
        [definition.name, definition.description] ++ strings(definition.input_schema)
      end)
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_atom(value) and not is_nil(value), do: [Atom.to_string(value)]

  defp strings(value) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {key, item} -> strings(key) ++ strings(item) end)
  end

  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(_value), do: []

  # The text an outbound JSON body carries. Object keys are the vendor's wire
  # schema rather than text the adapter wrote, so only values are collected.
  defp payload_text(value) when is_binary(value), do: [value]

  defp payload_text(value) when is_map(value) do
    value |> Map.values() |> Enum.flat_map(&payload_text/1)
  end

  defp payload_text(value) when is_list(value), do: Enum.flat_map(value, &payload_text/1)
  defp payload_text(_value), do: []

  defp occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp assert_exact_set(actual, declared, what) do
    actual = MapSet.new(actual)
    declared = MapSet.new(declared)

    assert MapSet.difference(actual, declared) |> MapSet.to_list() == [],
           """
           Something that #{what} is not named in
           test/openagents/providers/persona_boundary_test.exs. Amend PERSONA-001
           in INVARIANTS.md, then add it here.

           Undeclared: #{inspect(MapSet.difference(actual, declared) |> MapSet.to_list())}
           """

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == [],
           """
           This test names something that no longer #{what}. Amend PERSONA-001
           in INVARIANTS.md, then remove it here.

           Stale: #{inspect(MapSet.difference(declared, actual) |> MapSet.to_list())}
           """
  end
end
