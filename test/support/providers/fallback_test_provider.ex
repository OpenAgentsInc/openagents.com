defmodule OpenAgents.Providers.FallbackTestProvider do
  @moduledoc false

  @behaviour OpenAgents.Providers.Provider

  alias OpenAgents.Providers.Request

  @impl true
  def id, do: "test.fallback_provider"

  @impl true
  def capabilities, do: [:text, :usage]

  @impl true
  def configured?, do: true

  # Stands in for the Vercel AI Gateway lane with a fallback model list: the
  # model that answers is not necessarily the model that was asked for.
  @impl true
  def substitutable?, do: true

  @doc """
  Emit one response, optionally disclosing which model served it.

  `config :openagents, :test_fallback_served_model` is the name the response
  carries. Anything that is not a binary — the default — is a response that
  discloses nothing, which is the case the host must read as unresolved rather
  than as the requested model.
  """
  @impl true
  def stream(%Request{}, on_event) when is_function(on_event, 1) do
    on_event.({:response_started, "fallback-response"})

    case Application.get_env(:openagents, :test_fallback_served_model) do
      name when is_binary(name) -> on_event.({:model_served, name})
      _undisclosed -> :ok
    end

    on_event.({:text_delta, "Served."})
    on_event.({:usage, %{"input_tokens" => 4, "output_tokens" => 8}})
    on_event.({:response_completed, "fallback-response"})
    :ok
  end
end
