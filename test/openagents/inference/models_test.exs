defmodule OpenAgents.Inference.ModelsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Inference.Models

  test "the default is the catalog's first entry, served by that lane's adapter" do
    default = Models.default()

    # Gemini 3.7 Flash leads: a caller that names no model is holding a
    # conversation, and that is what this deployment answers one with.
    assert default.id == "gemini-3.7-flash"
    assert default.provider_model == "google/gemini-3.7-flash"
    assert default.adapter == Application.fetch_env!(:openagents, :openrouter_provider)
    assert Models.default_id() == default.id
    assert Models.default_id() == hd(Models.ids())
  end

  test "the OpenAI lane is still served, as the backup it now is" do
    configured = Application.fetch_env!(:openagents, :openai_model)

    assert {:ok, luna} = Models.fetch(configured)
    assert luna.provider_model == luna.id
    assert luna.adapter == Application.fetch_env!(:openagents, :provider)
  end

  test "ox-alpha publishes a public id and routes the vendor string" do
    assert {:ok, model} = Models.fetch("ox-alpha")
    assert model.id == "ox-alpha"
    assert model.provider_model == OpenRouter.default_model()
    refute model.id == model.provider_model
    assert model.adapter == Application.fetch_env!(:openagents, :openrouter_provider)
  end

  test "the vendor spelling resolves to the same model" do
    assert {:ok, model} = Models.fetch(OpenRouter.default_model())
    assert model.id == "ox-alpha"
  end

  test "every routed model is listed once, and only routed models are" do
    ids = Models.ids()

    assert ids == Enum.uniq(ids)
    assert Models.default_id() in ids
    assert "ox-alpha" in ids
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
    test "Ox Alpha's is large enough for a model that reasons before it answers" do
      # Its thinking is charged against the same allowance as its answer. At
      # 4,096 a child agent with a real task spent the whole budget reasoning
      # and returned nothing, after three minutes, on a 200.
      {:ok, ox} = Models.fetch("ox-alpha")

      assert ox.max_output >= 32_000
      assert ox.context_window >= 1_000_000
    end

    test "the published catalog carries it, so a client is not guessing" do
      entry = Enum.find(Models.catalog(), &(&1["id"] == "ox-alpha"))

      assert entry["max_output"] == 64_000
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

    test "an unpriced model has no pricing key in the public catalog" do
      luna_id = Application.fetch_env!(:openagents, :openai_model)
      luna = Enum.find(Models.catalog(), &(&1["id"] == luna_id))

      refute Map.has_key?(luna, "pricing")
    end

    test "the resolved model carries pricing, or nil when none is declared" do
      assert %{pricing: %{input_per_million_tokens: 1_250_000}} = Models.default()

      luna_id = Application.fetch_env!(:openagents, :openai_model)
      assert {:ok, %{pricing: nil}} = Models.fetch(luna_id)
    end
  end
end
