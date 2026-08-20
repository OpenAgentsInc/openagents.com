defmodule OpenAgentsWeb.AllowedOrigins do
  @moduledoc """
  Validates and normalizes the CORS/check origin allow-list for production.

  The primary host is always allowed. The optional alias list comes from a
  comma-separated environment string and is intended for Cloud Run generated
  URLs.
  """

  @primary_scheme "https"

  @doc """
  Returns a list of allowed origins for production.

  `primary_host` is the canonical host (e.g. `stage.openagents.com`); it is
  always returned as `https://` first. `aliases` is a comma-separated string
  of `https://` origins. Each alias is validated: it must use `https` and
  must not contain a path.
  """
  @spec for_production(String.t(), String.t()) :: [String.t()]
  def for_production(primary_host, aliases) when is_binary(primary_host) do
    primary = "#{@primary_scheme}://#{primary_host}"

    parsed_aliases =
      aliases
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&validate_origin!/1)
      |> Enum.reject(&(&1 == primary))

    [primary | parsed_aliases]
  end

  defp validate_origin!(""), do: raise(ArgumentError, "origin cannot be empty")

  defp validate_origin!(origin) do
    uri = URI.parse(origin)

    cond do
      uri.scheme != "https" ->
        raise ArgumentError, "origin must use https: #{origin}"

      not is_nil(uri.path) and uri.path != "" ->
        raise ArgumentError, "origin must not contain a path: #{origin}"

      is_nil(uri.host) or uri.host == "" ->
        raise ArgumentError, "origin must include a host: #{origin}"

      true ->
        origin
    end
  end
end
