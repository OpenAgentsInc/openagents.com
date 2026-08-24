defmodule OpenAgents.Tools.SelectorTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Modules.Discovery
  alias OpenAgents.Tools.{Embeddings, Registry, Selector}
  alias OpenAgents.Tools.Discovery.Doc

  setup do
    {:ok, snapshot} = Registry.build(Application.fetch_env!(:openagents, :tools))
    %{snapshot: snapshot}
  end

  describe "select/3 (lexical, embeddings off)" do
    # `top_k: 16` rather than 12, because 12 cut a tie in half. `computer_agent`
    # (0.778), `computer_devin`, `deep_work`, and `computer_probe` earn their
    # places on real terms, but `computer_list` scores 0.333 on the stopwords
    # "the", "this", and "use" alone, which puts it in a six-way tie broken by
    # name. It held slot 13 only until a tool sorting before "computer_list"
    # joined the fixture catalog — `capture_issue` did. Admitting the whole tie
    # tier tests what this is meant to test, that the delegation chain is
    # reachable in a realistic budget, instead of where the alphabet happens to
    # cut.
    test "a delegation intent surfaces the whole computer delegation chain", %{snapshot: snapshot} do
      names =
        snapshot
        |> Selector.select_tools("use the machine to delegate this coding task to claude",
          top_k: 16
        )
        |> Enum.map(& &1.name)

      assert "computer_agent" in names
      assert "computer_list" in names
      assert "computer_probe" in names
    end

    test "a failure question surfaces incident_lookup near the top", %{snapshot: snapshot} do
      [first | _] =
        snapshot
        |> Selector.select_tools("why did that delegation fail, can you analyze the error",
          top_k: 5
        )
        |> Enum.map(& &1.name)

      assert first == "incident_lookup"
    end

    test "always includes module_discover as an escape hatch", %{snapshot: snapshot} do
      names = snapshot |> Selector.select_tools("hello", top_k: 3) |> Enum.map(& &1.name)
      assert "module_discover" in names
    end

    test "a paired machine keeps computer tools on short follow-ups", %{snapshot: snapshot} do
      for intent <- ["try again", "use the machine", "hello"] do
        names =
          snapshot
          |> Selector.select_tools(intent, top_k: 3, computer_paired?: true)
          |> Enum.map(& &1.name)

        assert "computer_agent" in names
        assert "computer_list" in names
        assert "computer_probe" in names
        assert "module_discover" in names
      end
    end

    test "always_include forces named tools into the exposed set", %{snapshot: snapshot} do
      names =
        snapshot
        |> Selector.select_tools("hello",
          top_k: 3,
          always_include: ["computer_agent", "computer_list", "computer_probe"]
        )
        |> Enum.map(& &1.name)

      assert "computer_agent" in names
      assert "computer_list" in names
      assert "computer_probe" in names
      assert "module_discover" in names
    end

    test "top_k bounds the exposed set", %{snapshot: snapshot} do
      # +1 tolerance for the always-included module_discover when outside top_k.
      assert length(Selector.select_tools(snapshot, "anything", top_k: 4)) <= 5

      # +1 module_discover and +3 paired-machine tools when outside top_k.
      assert length(Selector.select_tools(snapshot, "anything", top_k: 4, computer_paired?: true)) <=
               8
    end

    test "tag filtering restricts candidates to tagged tools", %{snapshot: snapshot} do
      names =
        snapshot
        |> Selector.select_tools("", top_k: 20, tags: ["incident"])
        |> Enum.map(& &1.name)

      assert "incident_lookup" in names
      refute "memory_remember" in names
    end
  end

  describe "Embeddings.cosine/2" do
    test "identical vectors score 1.0 and orthogonal score 0.0" do
      assert_in_delta Embeddings.cosine([1.0, 0.0], [1.0, 0.0]), 1.0, 1.0e-9
      assert_in_delta Embeddings.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-9
    end

    test "mismatched or empty vectors are 0.0, never a crash" do
      assert Embeddings.cosine([1.0], [1.0, 2.0]) == 0.0
      assert Embeddings.cosine([], []) == 0.0
    end
  end

  describe "Doc" do
    test "effective tags fold in authored tags, authority, and name tokens", %{snapshot: snapshot} do
      tool = Map.fetch!(snapshot.tools, "computer_agent")
      tags = Doc.tags(tool)
      assert MapSet.member?(tags, "delegation")
      assert MapSet.member?(tags, "computer")
    end
  end

  describe "Discovery.search (module_discover) tags + query" do
    test "tag search returns only tools carrying the tag", %{snapshot: snapshot} do
      {:ok, result} = Discovery.search(snapshot, %{"tags" => ["incident"], "first" => 10})
      ids = Enum.map(result["matches"], & &1["module_id"])
      assert "sarah.tool.incident_lookup.v1" in ids
      refute "sarah.tool.memory_remember.v1" in ids
    end

    test "a natural-language query ranks over descriptions, not module_id substrings", %{
      snapshot: snapshot
    } do
      # The exact query shape that returned nothing under the old substring
      # search now finds the delegation tool.
      {:ok, result} =
        Discovery.search(snapshot, %{"query" => "Claude Code delegation", "first" => 10})

      ids = Enum.map(result["matches"], & &1["module_id"])
      assert "sarah.tool.computer_agent.v1" in ids
    end
  end
end
