defmodule OpenAgents.ChatProviderStub do
  @moduledoc false

  def stream(request, on_event, options) do
    user = options |> Keyword.fetch!(:tool_context) |> Map.fetch!(:user)
    message = request["messages"] |> List.last() |> Map.fetch!("content")
    on_event.({:reasoning_delta, "Checking account context."})

    on_event.(
      {:tool_call_started, %{"id" => "call_1", "name" => "test_account", "arguments" => %{}}}
    )

    on_event.(
      {:tool_call_completed,
       %{"id" => "call_1", "name" => "test_account", "result" => %{"login" => user.github_login}}}
    )

    output = "#{user.github_login}: #{message}"
    on_event.({:text_delta, output})

    {:ok,
     %{
       "object" => "response",
       "model" => "test/provider",
       "assistant_message_id" => "msg_test",
       "assistant_content" => output,
       "reasoning_summary" => "Checking account context."
     }}
  end
end
