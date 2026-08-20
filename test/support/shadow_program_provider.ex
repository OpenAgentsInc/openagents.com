defmodule OpenAgents.ShadowPrograms.TestProvider do
  def id, do: "test.shadow"

  def evaluate(_artifact, _signature, _input, _timeout_ms) do
    Process.get(:shadow_program_result, {
      :ok,
      %{
        output: %{"intent" => "remember", "confidence" => 0.95},
        response_id: "response-shadow-test",
        usage: %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
      }
    })
  end
end
