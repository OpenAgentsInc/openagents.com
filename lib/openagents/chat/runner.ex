defmodule OpenAgents.Chat.Runner do
  @moduledoc "Runs account-scoped chat requests for both LiveView and API clients."

  alias OpenAgents.Chat.OpenRouter

  @fallback_models ["openrouter/free"]
  @maximum_messages 100
  @maximum_content_bytes 128_000

  @spec request([map()], String.t(), String.t()) :: map()
  def request(history, message, reasoning) do
    %{
      "model" => OpenRouter.default_model(),
      "models" => @fallback_models,
      "reasoning" => OpenRouter.reasoning_effort(reasoning),
      "messages" =>
        Enum.map(history, &provider_message/1) ++ [%{"role" => "user", "content" => message}]
    }
  end

  @spec request_from_params(map()) :: {:ok, map()} | {:error, atom()}
  def request_from_params(params) when is_map(params) do
    with {:ok, messages} <- messages(params),
         :ok <- validate_messages(messages) do
      reasoning = reasoning(params)

      {:ok,
       %{
         "model" => OpenRouter.default_model(),
         "models" => @fallback_models,
         "reasoning" => reasoning,
         "messages" => messages
       }}
    end
  end

  @spec stream(map(), OpenAgents.Accounts.User.t(), (tuple() -> any()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stream(request, user, on_event, options \\ []) do
    provider = Keyword.get(options, :provider, configured_provider())
    provider.stream(request, on_event, Keyword.put(options, :tool_context, %{user: user}))
  end

  defp configured_provider,
    do: Application.get_env(:openagents, :chat_provider, OpenRouter)

  defp messages(%{"messages" => messages}) when is_list(messages), do: {:ok, messages}

  defp messages(%{"input" => input}) when is_binary(input),
    do: {:ok, [%{"role" => "user", "content" => input}]}

  defp messages(%{"input" => input}) when is_list(input), do: {:ok, input}
  defp messages(_params), do: {:error, :invalid_input}

  defp validate_messages(messages) when length(messages) in 1..@maximum_messages do
    valid? =
      Enum.all?(messages, fn
        %{"role" => role, "content" => content}
        when role in ["system", "user", "assistant"] and is_binary(content) ->
          byte_size(content) <= @maximum_content_bytes

        _invalid ->
          false
      end)

    if valid?, do: :ok, else: {:error, :invalid_input}
  end

  defp validate_messages(_messages), do: {:error, :invalid_input}

  defp reasoning(%{"reasoning" => %{"effort" => effort}}),
    do: OpenRouter.reasoning_effort(effort)

  defp reasoning(%{"reasoning" => effort}) when is_binary(effort),
    do: OpenRouter.reasoning_effort(effort)

  defp reasoning(_params), do: "high"

  defp provider_message(%{role: :assistant} = message) do
    %{"role" => "assistant", "content" => message.content}
    |> maybe_put("id", Map.get(message, :provider_message_id))
    |> maybe_put("status", Map.get(message, :provider_status))
    |> maybe_put_list("reasoning_items", Map.get(message, :provider_reasoning_items))
  end

  defp provider_message(%{role: role, content: content}),
    do: %{"role" => Atom.to_string(role), "content" => content}

  defp provider_message(%{"role" => _role, "content" => _content} = message), do: message

  defp maybe_put(message, _key, nil), do: message
  defp maybe_put(message, key, value), do: Map.put(message, key, value)

  defp maybe_put_list(message, key, values) when is_list(values) and values != [],
    do: Map.put(message, key, values)

  defp maybe_put_list(message, _key, _values), do: message
end
