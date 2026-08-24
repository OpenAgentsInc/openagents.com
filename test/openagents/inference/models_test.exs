defmodule OpenAgents.Inference.ModelsTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Chat.OpenRouter
  alias OpenAgents.Inference.Models

  test "the default model is the configured one, served by the configured provider" do
    default = Models.default()

    assert default.id == Application.fetch_env!(:openagents, :openai_model)
    assert default.provider_model == default.id
    assert default.provider == Application.fetch_env!(:openagents, :provider)
    assert Models.default_id() == default.id
  end

  test "ox-alpha publishes a public id and routes the vendor string" do
    assert {:ok, model} = Models.fetch("ox-alpha")
    assert model.id == "ox-alpha"
    assert model.provider_model == OpenRouter.default_model()
    refute model.id == model.provider_model
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
end
