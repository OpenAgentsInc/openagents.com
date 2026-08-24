defmodule OpenAgents.Providers.RecordingTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.Request

  @impl true
  def id, do: "test.recording_provider"

  @impl true
  def capabilities, do: [:text, :usage]

  @impl true
  def stream(%Request{} = request, on_event) when is_function(on_event, 1) do
    case Application.fetch_env(:openagents, :test_recording_provider_observer) do
      {:ok, observer} -> send(observer, {:recorded_request, id(), request})
      :error -> :ok
    end

    on_event.({:response_started, "recording-response"})
    on_event.({:text_delta, "Recorded."})
    on_event.({:usage, %{"input_tokens" => 4, "output_tokens" => 8}})
    on_event.({:response_completed, "recording-response"})
    :ok
  end
end
