defmodule OpenAgents.Inference.CoderApiHopTest do
  use ExUnit.Case, async: true

  alias OpenAgents.Inference.CoderApiHop

  test "usage_from_sse reads OpenAI prompt and completion tokens" do
    body = """
    data: {"choices":[{"delta":{"content":"hi"}}],"model":"gemini-3.7-flash"}

    data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

    data: [DONE]

    """

    assert CoderApiHop.usage_from_sse(body) == %{
             "input_tokens" => 10,
             "output_tokens" => 2,
             "total_tokens" => 12
           }
  end

  test "served_model reads the rust attribution header" do
    assert CoderApiHop.served_model(%{"x-openagents-model" => ["gemini-3.7-flash"]}) ==
             "gemini-3.7-flash"

    assert CoderApiHop.served_model([{"x-openagents-model", "glm-5.3-flash"}]) == "glm-5.3-flash"
    assert CoderApiHop.served_model(%{}) == nil
  end

  test "target is local when origin or token is missing" do
    old_origin = Application.get_env(:openagents, :coder_api_origin)
    old_token = Application.get_env(:openagents, :coder_api_internal_token)
    Application.put_env(:openagents, :coder_api_origin, nil)
    Application.put_env(:openagents, :coder_api_internal_token, nil)
    assert CoderApiHop.target() == :local
    Application.put_env(:openagents, :coder_api_origin, old_origin)
    Application.put_env(:openagents, :coder_api_internal_token, old_token)
  end
end
