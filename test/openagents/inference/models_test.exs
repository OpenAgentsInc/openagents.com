defmodule OpenAgents.Inference.ModelsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Inference.Models

  test "the default is the catalog's first entry, served by that lane's adapter" do
    default = Models.default()

    # GLM 5.3 Flash leads: a caller that names no model is holding a
    # conversation, and that is what this deployment answers one with. It is
    # reached on the gateway's own slug, not on the id a caller asks for.
    assert default.id == "glm-5.3-flash"
    assert default.provider == :vercel_gateway
    assert default.provider_model == "zai/glm-5.3-flash"
    assert default.adapter == Application.fetch_env!(:openagents, :vercel_gateway_provider)
    assert Models.default_id() == default.id
    assert Models.default_id() == hd(Models.ids())
  end

  test "a withdrawn model is not served, so nothing can be minted against it" do
    # `gpt-5.6-luna` and `ox-alpha` were both admitted here until they were
    # withdrawn at owner direction. Withdrawal is what this asserts: the names
    # do not resolve, so `OpenAgents.Inference.mint/1` refuses a grant that
    # pins one and the proxy refuses a grant minted before the withdrawal.
    #
    # `ox-alpha` is the interesting one. It was `stealth/ox-alpha`, the
    # pre-launch name of the model now admitted as `glm-5.3-flash`, and
    # OpenRouter answers that slug with a 404 saying so. Resolving the old name
    # to the new entry would be a silent substitution of exactly the kind
    # PROVIDER-002 forbids, so it does not resolve at all.
    assert Models.fetch(Application.fetch_env!(:openagents, :openai_model)) == :error
    assert Models.fetch("ox-alpha") == :error
    assert Models.fetch("stealth/ox-alpha") == :error

    # OpenRouter's spelling of the live model is not this deployment's lane
    # either: the catalog reaches it through the Vercel gateway.
    assert Models.fetch("z-ai/glm-5.3-flash") == :error
  end

  test "the vendor spelling resolves to the same model" do
    assert {:ok, model} = Models.fetch("zai/glm-5.3-flash")
    assert model.id == "glm-5.3-flash"
    refute model.id == model.provider_model
  end

  test "every routed model is listed once, and only routed models are" do
    ids = Models.ids()

    assert ids == Enum.uniq(ids)
    assert Models.default_id() in ids
    assert ids == ["glm-5.3-flash", "gemini-3.7-flash"]
    assert Enum.map(Models.all(), & &1.id) == ids
    assert Models.fetch("attacker/gpt-9-ultra") == :error
    assert Models.fetch(nil) == :error
  end

  test "every catalog entry carries the typed ceilings and a provider lane" do
    for model <- Models.all() do
      assert is_binary(model.id) and model.id != ""
      assert is_atom(model.provider)
      assert is_atom(model.adapter)
      assert is_binary(model.provider_model) and model.provider_model != ""
      assert is_integer(model.context_window) and model.context_window > 0
      assert is_integer(model.max_output) and model.max_output > 0
    end
  end

  test "the public catalog projects each model without its adapter module" do
    catalog = Models.catalog()

    assert Enum.map(catalog, & &1["id"]) == Models.ids()

    for entry <- catalog do
      assert Enum.all?(
               ~w(availability context_window default id max_output provider),
               &(&1 in Map.keys(entry))
             )

      assert entry["availability"] in ["available", "unavailable"]
      refute entry["provider"] =~ "Elixir."

      if entry["pricing"] do
        assert Enum.all?(
                 ~w(input_per_million_tokens output_per_million_tokens),
                 &(&1 in Map.keys(entry["pricing"]))
               )

        assert is_integer(entry["pricing"]["input_per_million_tokens"])
        assert is_integer(entry["pricing"]["output_per_million_tokens"])
      end
    end

    assert Enum.count(catalog, & &1["default"]) == 1
    assert Enum.find(catalog, & &1["default"])["id"] == Models.default_id()
  end

  # The test adapters export `configured?/0` returning true, so in this
  # environment every lane is available; PROVIDER-002's unavailable branch is
  # driven by the controller tests, which swap in an adapter that reports
  # false.
  test "a lane whose adapter reports a configured credential is available" do
    for model <- Models.all() do
      assert Models.available?(model)
    end

    assert Models.available_ids() == Models.ids()
  end

  describe "the answer allowance a model publishes" do
    test "GLM 5.3 Flash's is large enough for a model that reasons before it answers" do
      # Its thinking is charged against this allowance before a word of the
      # answer is. At 256 tokens a request spent 243 of them reasoning and the
      # answer was cut off mid-word on `finish_reason: "length"`, which reads
      # to a caller as the model having failed.
      {:ok, glm} = Models.fetch("glm-5.3-flash")

      assert glm.max_output == 131_000
      assert glm.context_window == 1_000_000
    end

    test "the published catalog carries it, so a client is not guessing" do
      entry = Enum.find(Models.catalog(), &(&1["id"] == "glm-5.3-flash"))

      assert entry["max_output"] == 131_000
      assert entry["context_window"] == 1_000_000
    end

    test "GLM 5.3 Flash is routed through the gateway, on the slug the gateway knows" do
      # `zai/glm-5.3-flash`, not `glm-5.3-flash`, which is what a caller asks
      # for. The gateway resolves it to z.ai against this account's BYOK z.ai
      # credentials, so the call spends those rather than OpenRouter's, which
      # serves the same model as `z-ai/glm-5.3-flash`.
      {:ok, glm} = Models.fetch("glm-5.3-flash")

      assert glm.provider == :vercel_gateway
      assert glm.provider_model == "zai/glm-5.3-flash"
    end

    test "Gemini is routed through the gateway, on the slug the gateway knows" do
      # Not `gemini-3.7-flash`, which is what a caller asks for. The gateway
      # resolves `creator/model` slugs, and it is pinned to Vertex so the call
      # spends this account's Google credits.
      {:ok, gemini} = Models.fetch("gemini-3.7-flash")

      assert gemini.provider == :vercel_gateway
      assert gemini.provider_model == "google/gemini-3.7-flash"
    end
  end

  describe "pricing" do
    test "a priced model publishes its per-million-token rates in the public catalog" do
      gemini = Enum.find(Models.catalog(), &(&1["id"] == "gemini-3.7-flash"))

      assert %{"pricing" => pricing} = gemini
      assert pricing["input_per_million_tokens"] == 1_250_000
      assert pricing["output_per_million_tokens"] == 10_000_000
      assert pricing["cached_input_per_million_tokens"] == 100_000
    end

    test "the default's rates are provisional, so nothing may bill from them" do
      glm = Enum.find(Models.catalog(), &(&1["id"] == "glm-5.3-flash"))

      assert glm["pricing"]["id"] == "placeholder.glm-5.3-flash.v1"
      assert glm["pricing"]["input_per_million_tokens"] == 150_000
      assert glm["pricing"]["output_per_million_tokens"] == 500_000
      assert glm["pricing"]["cached_input_per_million_tokens"] == 30_000

      # Read off the gateway's own listing, which still is not an operator
      # declaring them (METER-001).
      assert glm["pricing_basis"] == "provisional"
      assert glm["pricing"]["basis"] == "provisional"
    end

    test "every published lane carries a pricing block, because every one is priced" do
      for entry <- Models.catalog() do
        assert Map.has_key?(entry, "pricing")
        assert entry["pricing_basis"] == "provisional"
      end
    end

    test "the resolved model carries pricing, and a withdrawn one resolves to nothing" do
      assert %{pricing: %{input_per_million_tokens: 150_000}} = Models.default()

      luna_id = Application.fetch_env!(:openagents, :openai_model)
      assert Models.fetch(luna_id) == :error
    end
  end
end
