defmodule OpenAgents.Voice.ConfigTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Voice.Config

  test "admits one explicit native Realtime artifact without fallback" do
    config = Config.build!(valid_config())

    assert config.architecture == :openai_realtime
    assert config.model == "gpt-realtime-2.1"
    assert config.voice == "marin"

    assert Config.session_payload(config) == %{
             type: "realtime",
             model: "gpt-realtime-2.1",
             reasoning: %{effort: "low"},
             parallel_tool_calls: false,
             audio: %{
               input: %{
                 noise_reduction: %{type: "near_field"},
                 transcription: %{model: "gpt-4o-mini-transcribe", language: "en"},
                 turn_detection: %{
                   type: "semantic_vad",
                   create_response: false,
                   interrupt_response: true
                 }
               },
               output: %{voice: "marin"}
             }
           }
  end

  test "rejects unreviewed models, voices, and excessive session duration" do
    assert_raise ArgumentError, ~r/unadmitted Realtime model/, fn ->
      valid_config() |> Keyword.put(:model, "gpt-5.6-luna") |> Config.build!()
    end

    assert_raise ArgumentError, ~r/unadmitted voice artifact/, fn ->
      valid_config() |> Keyword.put(:voice, "leda") |> Config.build!()
    end

    assert_raise ArgumentError, ~r/invalid session duration/, fn ->
      valid_config() |> Keyword.put(:maximum_session_seconds, 3_301) |> Config.build!()
    end
  end

  test "attaches only bounded server-composed instructions and function definitions" do
    config =
      valid_config()
      |> Config.build!()
      |> Config.with_context("You are OpenAgents.", [
        %{
          "type" => "function",
          "name" => "memory_list",
          "description" => "List memory",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ])

    payload = Config.session_payload(config)
    assert payload.instructions == "You are OpenAgents."
    assert payload.tool_choice == "auto"
    assert [%{"name" => "memory_list"}] = Enum.map(payload.tools, &Map.take(&1, ["name"]))
  end

  test "enabled voice fails boot validation without a server credential" do
    config = Config.build!(valid_config())

    assert_raise ArgumentError, ~r/requires OPENAI_API_KEY/, fn ->
      Config.validate_runtime!(config, fn _name -> nil end)
    end

    assert :ok = Config.validate_runtime!(config, fn "OPENAI_API_KEY" -> "runtime-secret" end)

    disabled = Config.build!(Keyword.put(valid_config(), :enabled, false))
    assert :ok = Config.validate_runtime!(disabled, fn _name -> nil end)
  end

  defp valid_config do
    [
      enabled: true,
      architecture: :openai_realtime,
      provider: "openai",
      model: "gpt-realtime-2.1",
      voice: "marin",
      reasoning_effort: "low",
      maximum_session_seconds: 3_000
    ]
  end
end
