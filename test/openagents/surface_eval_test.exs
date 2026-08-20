defmodule OpenAgents.SurfaceEvalTest do
  use ExUnit.Case, async: true
  @moduletag :skip
  alias OpenAgents.Context.Composer

  test "cross-surface corpus is versioned and text and voice retain one Sarah identity" do
    corpus =
      "priv/sarah/evals/surfaces/identity-authority.v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert corpus["schema"] == "sarah.surface_eval_corpus.v1"

    assert Enum.map(corpus["cases"], & &1["id"]) == [
             "text-voice-one-identity",
             "external-effect-under-read-authority",
             "oversized-catalog",
             "unavailable-executor"
           ]

    text = Composer.compose!(surface: "text")
    voice = Composer.compose!(surface: "voice")

    assert {text.persona_id, text.persona_digest} == {voice.persona_id, voice.persona_digest}
    assert {text.role_id, text.role_digest} == {voice.role_id, voice.role_digest}
    assert text.role_selection["surface"] == "text"
    assert voice.role_selection["surface"] == "voice"
  end
end
