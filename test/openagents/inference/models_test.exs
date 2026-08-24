defmodule OpenAgents.Inference.ModelsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Inference.Models

  test "the default model is the configured one, served by the configured adapter" do
    default = Models.default()

    assert default.id == Application.fetch_env!(:openagents, :openai_model)
    assert default.provider_model == default.id
    assert default.adapter == Application.fetch_env!(:openagents, :provider)
    assert Models.default_id() == default.id
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
      assert Enum.sort(Map.keys(entry)) ==
               ~w(availability context_window default id max_output provider)

      assert entry["availability"] in ["available", "unavailable"]
      refute entry["provider"] =~ "Elixir."
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
end
