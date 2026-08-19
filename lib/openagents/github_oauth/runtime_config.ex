defmodule OpenAgents.GitHubOAuth.RuntimeConfig do
  @moduledoc "Boot-time validation for environment-owned GitHub OAuth settings."

  @callback_path "/auth/github/callback"
  @required_settings [
    client_id: "GITHUB_CLIENT_ID",
    client_secret: "GITHUB_CLIENT_SECRET",
    redirect_uri: "GITHUB_REDIRECT_URI"
  ]

  def load!(settings, environment, options \\ []) when is_list(settings) do
    normalized =
      Enum.reduce(@required_settings, settings, fn {key, _variable}, acc ->
        Keyword.put(acc, key, normalize(acc[key]))
      end)

    missing =
      for {key, variable} <- @required_settings,
          normalized[key] in [nil, ""],
          do: variable

    if missing != [] do
      raise ArgumentError,
            "GitHub OAuth configuration is incomplete for #{environment}: missing #{Enum.join(missing, ", ")}"
    end

    redirect_uri = Keyword.fetch!(normalized, :redirect_uri)

    with :ok <- validate_redirect_uri(redirect_uri),
         :ok <- validate_environment_redirect(environment, redirect_uri, options) do
      normalized
    else
      {:error, reason} ->
        raise ArgumentError,
              "GitHub OAuth redirect configuration is invalid for #{environment}: #{reason}"
    end
  end

  def validate_redirect_uri(uri) when is_binary(uri) do
    case URI.new(uri) do
      {:ok,
       %URI{
         scheme: scheme,
         host: host,
         path: @callback_path,
         query: nil,
         fragment: nil,
         userinfo: nil
       }}
      when scheme == "https" or (scheme == "http" and host in ["127.0.0.1", "localhost"]) ->
        :ok

      _invalid ->
        {:error,
         "GITHUB_REDIRECT_URI must be an exact HTTPS callback or a loopback HTTP callback"}
    end
  end

  def validate_redirect_uri(_uri),
    do:
      {:error, "GITHUB_REDIRECT_URI must be an exact HTTPS callback or a loopback HTTP callback"}

  defp validate_environment_redirect(:prod, redirect_uri, options) do
    public_host = options[:public_host]
    parsed = URI.parse(redirect_uri)

    cond do
      not is_binary(public_host) or public_host == "" ->
        {:error, "PHX_HOST is required"}

      parsed.scheme != "https" ->
        {:error, "production callbacks must use HTTPS"}

      parsed.host != public_host ->
        {:error, "callback host must match PHX_HOST"}

      true ->
        :ok
    end
  end

  defp validate_environment_redirect(:dev, redirect_uri, _options) do
    parsed = URI.parse(redirect_uri)

    if parsed.scheme == "http" and parsed.host in ["127.0.0.1", "localhost"],
      do: :ok,
      else: {:error, "development callbacks must use a loopback HTTP origin"}
  end

  defp validate_environment_redirect(_environment, _redirect_uri, _options), do: :ok

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(_value), do: nil
end
