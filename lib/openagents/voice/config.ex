defmodule OpenAgents.Voice.Config do
  @moduledoc """
  Validated admission configuration for Sarah's spoken surface.

  Voice identity is selected before a Realtime call is created. There is no
  implicit provider, model, voice, or architecture fallback.
  """

  @supported_architectures [:openai_realtime]
  @supported_voices ~w(marin cedar)

  @enforce_keys [
    :enabled?,
    :architecture,
    :provider,
    :model,
    :voice,
    :reasoning_effort,
    :maximum_session_seconds
  ]
  defstruct @enforce_keys ++
              [instructions: nil, tools: []]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          architecture: :openai_realtime,
          provider: String.t(),
          model: String.t(),
          voice: String.t(),
          reasoning_effort: String.t(),
          maximum_session_seconds: pos_integer(),
          instructions: String.t() | nil,
          tools: [map()]
        }

  @spec current!() :: t()
  def current! do
    :openagents
    |> Application.fetch_env!(:voice)
    |> build!()
  end

  @spec validate_boot!() :: :ok
  def validate_boot! do
    :ok =
      current!()
      |> validate_runtime!()

    validate_attempt_limits!()
  end

  @spec validate_runtime!(t(), (String.t() -> String.t() | nil)) :: :ok
  def validate_runtime!(config, get_environment \\ &configured_secret/1)

  def validate_runtime!(%__MODULE__{enabled?: false}, _get_environment), do: :ok

  def validate_runtime!(%__MODULE__{enabled?: true}, get_environment)
      when is_function(get_environment, 1) do
    case get_environment.("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> :ok
      _missing -> raise ArgumentError, "enabled Sarah voice requires OPENAI_API_KEY"
    end
  end

  @spec build!(keyword()) :: t()
  def build!(attributes) when is_list(attributes) do
    config = %__MODULE__{
      enabled?: Keyword.fetch!(attributes, :enabled),
      architecture: Keyword.fetch!(attributes, :architecture),
      provider: Keyword.fetch!(attributes, :provider),
      model: Keyword.fetch!(attributes, :model),
      voice: Keyword.fetch!(attributes, :voice),
      reasoning_effort: Keyword.fetch!(attributes, :reasoning_effort),
      maximum_session_seconds: Keyword.fetch!(attributes, :maximum_session_seconds)
    }

    case validate(config) do
      :ok -> config
      {:error, reason} -> raise ArgumentError, "invalid Sarah voice configuration: #{reason}"
    end
  end

  def build!(_attributes), do: raise(ArgumentError, "invalid Sarah voice configuration")

  @spec session_payload(t()) :: map()
  def session_payload(%__MODULE__{} = config) do
    payload = %{
      type: "realtime",
      model: config.model,
      reasoning: %{effort: config.reasoning_effort},
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
        output: %{voice: config.voice}
      }
    }

    payload
    |> maybe_put(:instructions, config.instructions)
    |> maybe_put_tools(config.tools)
  end

  @spec with_context(t(), String.t(), [map()]) :: t()
  def with_context(%__MODULE__{} = config, instructions, tools)
      when is_binary(instructions) and byte_size(instructions) in 1..65_536 and is_list(tools) and
             length(tools) <= 64 do
    %{config | instructions: instructions, tools: tools}
  end

  def with_context(%__MODULE__{}, _instructions, _tools) do
    raise ArgumentError, "invalid Realtime context"
  end

  defp validate(%__MODULE__{} = config) do
    cond do
      not is_boolean(config.enabled?) -> {:error, "enabled must be boolean"}
      config.architecture not in @supported_architectures -> {:error, "unsupported architecture"}
      config.provider != "openai" -> {:error, "unsupported provider"}
      config.model != "gpt-realtime-2.1" -> {:error, "unadmitted Realtime model"}
      config.voice not in @supported_voices -> {:error, "unadmitted voice artifact"}
      config.reasoning_effort not in ~w(low medium high) -> {:error, "invalid reasoning effort"}
      config.maximum_session_seconds not in 1..3_300 -> {:error, "invalid session duration"}
      true -> :ok
    end
  end

  defp configured_secret("OPENAI_API_KEY") do
    case OpenAgents.RuntimeConfig.fetch_secret(:openai_api_key) do
      {:ok, value} -> value
      {:error, :not_configured} -> nil
    end
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) when is_list(tools) do
    payload
    |> Map.put(:tools, tools)
    |> Map.put(:tool_choice, "auto")
  end

  defp validate_attempt_limits! do
    attempt_limit = Application.fetch_env!(:openagents, :voice_attempt_limit)
    window_seconds = Application.fetch_env!(:openagents, :voice_attempt_window_seconds)
    concurrent_sessions = Application.fetch_env!(:openagents, :voice_maximum_concurrent_sessions)
    maximum_session_tokens = Application.fetch_env!(:openagents, :voice_maximum_session_tokens)

    maximum_response_output_tokens =
      Application.fetch_env!(:openagents, :voice_maximum_response_output_tokens)

    maximum_cost =
      Application.fetch_env!(:openagents, :voice_maximum_estimated_cost_microusd)

    retention_days = Application.fetch_env!(:openagents, :voice_operational_retention_days)

    if attempt_limit not in 1..30 do
      raise ArgumentError, "invalid Sarah voice attempt limit"
    end

    if window_seconds not in 60..86_400 do
      raise ArgumentError, "invalid Sarah voice attempt window"
    end

    if concurrent_sessions not in 1..100 do
      raise ArgumentError, "invalid Sarah voice concurrent-session limit"
    end

    if maximum_session_tokens not in 1_000..100_000_000 do
      raise ArgumentError, "invalid Sarah voice session token budget"
    end

    if maximum_response_output_tokens not in 128..32_000 do
      raise ArgumentError, "invalid Sarah voice response output-token budget"
    end

    if maximum_cost not in 10_000..1_000_000_000 do
      raise ArgumentError, "invalid Sarah voice session cost budget"
    end

    if retention_days not in 1..365 do
      raise ArgumentError, "invalid Sarah voice operational retention"
    end

    :ok
  end
end
