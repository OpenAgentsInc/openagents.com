defmodule OpenAgents.Providers.ToolCallingTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.Request

  @impl true
  def id, do: "test.tool_calling_provider"

  @impl true
  def capabilities, do: [:text, :tools, :usage]

  @impl true
  def configured?, do: true

  # First call: ask for a tool. Second call — recognizable by the outputs the
  # caller replays — answer from them. The two-step is the whole agentic loop
  # in miniature, which is what a surface carrying tools must survive.
  @impl true
  def stream(%Request{} = request, on_event) when is_function(on_event, 1) do
    on_event.({:response_started, "tool-calling-response"})

    if request.tool_outputs == [] do
      on_event.(
        {:tool_call,
         %{call_id: "call_1", name: "read_conversation", raw_arguments: ~s({"max_turns":4})}}
      )
    else
      [output | _rest] = request.tool_outputs
      on_event.({:text_delta, "The tool said: "})
      on_event.({:text_delta, output.output["content"]})
    end

    on_event.({:usage, %{"input_tokens" => 6, "output_tokens" => 3}})
    on_event.({:response_completed, "tool-calling-response"})
    :ok
  end
end
