defmodule OpenAgents.Chat do
  @moduledoc "Mock chat data and message generation for the /chat demo."

  alias OpenAgents.Chat.Message

  @replies [
    "I'm a mock assistant. I can't do real work yet.",
    "Got it. This is placeholder behavior while the real inference layer is wired.",
    "Interesting. Tell me more.",
    "Copy that. The chat UI is rendering with fake data."
  ]

  def messages do
    [
      %Message{
        id: "msg-1",
        role: "user",
        content: "Hello",
        status: "complete",
        inserted_at: ~U[2026-08-19 20:00:00Z]
      },
      %Message{
        id: "msg-2",
        role: "assistant",
        content: "Hi. This is the OpenAgents chat interface running on mock data.",
        status: "complete",
        inserted_at: ~U[2026-08-19 20:00:01Z]
      }
    ]
  end

  def fake_reply(content) when is_binary(content) do
    now = DateTime.utc_now()
    user_id = "msg-#{System.unique_integer([:positive, :monotonic])}"
    assistant_id = "msg-#{System.unique_integer([:positive, :monotonic])}"

    [
      %Message{
        id: user_id,
        role: "user",
        content: content,
        status: "complete",
        inserted_at: now
      },
      %Message{
        id: assistant_id,
        role: "assistant",
        content: Enum.random(@replies),
        status: "complete",
        inserted_at: DateTime.add(now, 1, :second)
      }
    ]
  end
end
