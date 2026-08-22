defmodule OpenAgents.Chat.Tools.Demo do
  @moduledoc false

  @tool_name "get_demo_time"

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        "type" => "function",
        "name" => @tool_name,
        "description" =>
          "Get the current UTC time from the OpenAgents demo tool. Use this only when the user asks for the current time or asks to demonstrate a tool call.",
        "strict" => true,
        "parameters" => %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      }
    ]
  end

  @spec execute(String.t(), String.t()) :: {:ok, map()}
  def execute(@tool_name, arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, arguments} when arguments == %{} ->
        {:ok,
         %{
           "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "timezone" => "UTC",
           "source" => "OpenAgents demo tool"
         }}

      {:ok, _arguments} ->
        {:ok, %{"error" => "get_demo_time does not accept arguments."}}

      {:error, _reason} ->
        {:ok, %{"error" => "Tool arguments must be a JSON object."}}
    end
  end

  def execute(_name, _arguments), do: {:ok, %{"error" => "This tool is not available."}}
end
