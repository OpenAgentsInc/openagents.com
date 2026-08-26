defmodule OpenAgents.Inference.ModelsSelectTest do
  use ExUnit.Case, async: false

  alias OpenAgents.Inference.Health
  alias OpenAgents.Inference.Models

  setup do
    if is_nil(Process.whereis(OpenAgents.Inference.Health)) do
      start_supervised!({OpenAgents.Inference.Health, []})
    end

    Health.reset()
    on_exit(&Health.reset/0)
    :ok
  end

  test "select returns the catalog default when every lane is healthy" do
    assert Models.select().id == Models.default_id()
  end

  test "select prefers the first configured and non-degraded lane when the default is degraded" do
    default = Models.default_id()

    for _ <- 1..Health.degraded_after() do
      Health.record_failure(default)
    end

    selected = Models.select()
    refute selected.id == default
    assert selected.id == "gemini-3.7-flash"
    assert selected.id == Enum.at(Models.ids(), 1)
  end

  test "select returns the default when all configured lanes are degraded, not the first one" do
    # Make the default unavailable so the first configured lane would be a
    # non-default entry under the old fallback.
    previous = Application.get_env(:openagents, :vercel_gateway_provider)

    Application.put_env(
      :openagents,
      :vercel_gateway_provider,
      OpenAgents.Providers.UnconfiguredTestProvider
    )

    on_exit(fn -> Application.put_env(:openagents, :vercel_gateway_provider, previous) end)

    for id <- Models.ids(), id != Models.default_id(), _ <- 1..Health.degraded_after() do
      Health.record_failure(id)
    end

    assert Models.select().id == Models.default_id()
  end

  test "select returns the catalog default when no lane is configured" do
    lanes = [:provider, :openrouter_provider, :vercel_gateway_provider]
    previous = Map.new(lanes, &{&1, Application.get_env(:openagents, &1)})

    for lane <- lanes do
      Application.put_env(:openagents, lane, OpenAgents.Providers.UnconfiguredTestProvider)
    end

    on_exit(fn ->
      for {lane, value} <- previous, do: Application.put_env(:openagents, lane, value)
    end)

    assert Models.select().id == Models.default_id()
  end

  describe "the boundary of server selection" do
    test "a lane named in the body is never substituted, even when degraded" do
      # PROVIDER-002: a caller that named a model gets that model or an error.
      # Selection exists only for the case where nothing named one.
      for _ <- 1..Health.degraded_after(), do: Health.record_failure("gemini-3.7-flash", 503)

      assert {:ok, model} = Models.fetch("gemini-3.7-flash")
      assert model.id == "gemini-3.7-flash"
      assert Models.availability(model) == "degraded"
    end
  end
end
