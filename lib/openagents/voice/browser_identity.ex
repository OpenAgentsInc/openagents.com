defmodule OpenAgents.Voice.BrowserIdentity do
  @moduledoc "Reduces a user-agent string to an admitted browser family and major version."

  @spec parse(String.t() | nil) :: {String.t(), integer() | nil}
  def parse(user_agent) when is_binary(user_agent) do
    cond do
      match = Regex.run(~r/Edg\/(\d+)/, user_agent) ->
        version("edge", match)

      match = Regex.run(~r/(?:Chrome|CriOS)\/(\d+)/, user_agent) ->
        version("chrome", match)

      match = Regex.run(~r/(?:Firefox|FxiOS)\/(\d+)/, user_agent) ->
        version("firefox", match)

      String.contains?(user_agent, "Safari/") ->
        version("safari", Regex.run(~r/Version\/(\d+)/, user_agent))

      true ->
        {"other", nil}
    end
  end

  def parse(_user_agent), do: {"other", nil}

  defp version(family, [_full, major]) do
    case Integer.parse(major) do
      {value, ""} when value in 1..1000 -> {family, value}
      _invalid -> {family, nil}
    end
  end

  defp version(family, _match), do: {family, nil}
end
