defmodule OpenAgents.GitHubOAuth do
  @moduledoc "GitHub OAuth state, PKCE, code exchange, and identity projection."

  alias OpenAgents.Accounts
  alias OpenAgents.GitHubOAuth.RuntimeConfig

  @default_authorize_url "https://github.com/login/oauth/authorize"
  @default_token_url "https://github.com/login/oauth/access_token"
  @default_user_url "https://api.github.com/user"
  @default_attempt_ttl_seconds 600
  @github_api_version "2022-11-28"
  @user_agent "OpenAgents-Sarah"

  @type attempt :: %{required(String.t()) => String.t() | integer()}

  def begin_authorization do
    with {:ok, config} <- config(),
         state <- random_url_token(),
         verifier <- random_url_token(),
         challenge <- pkce_challenge(verifier),
         expires_at <- DateTime.add(DateTime.utc_now(), config.attempt_ttl_seconds, :second),
         {:ok, receipt} <- Accounts.create_oauth_attempt(state, expires_at) do
      attempt = %{
        "id" => receipt.id,
        "state" => state,
        "verifier" => verifier,
        "expires_at" => DateTime.to_unix(expires_at)
      }

      query =
        URI.encode_query(%{
          "client_id" => config.client_id,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "redirect_uri" => config.redirect_uri,
          "scope" => "read:user repo",
          "state" => state
        })

      {:ok, attempt, config.authorize_url <> "?" <> query}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :oauth_attempt_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def consume_attempt(
        %{"id" => attempt_id, "state" => expected_state, "expires_at" => expires_at},
        returned_state
      )
      when is_binary(attempt_id) and is_binary(expected_state) and is_integer(expires_at) and
             is_binary(returned_state) do
    with true <- DateTime.to_unix(DateTime.utc_now()) < expires_at,
         true <- secure_equal?(expected_state, returned_state),
         :ok <- Accounts.consume_oauth_attempt(attempt_id, returned_state) do
      :ok
    else
      _invalid -> {:error, :invalid_oauth_state}
    end
  end

  def consume_attempt(_attempt, _returned_state), do: {:error, :invalid_oauth_state}

  def exchange_and_fetch(code, verifier) when is_binary(code) and is_binary(verifier) do
    with :ok <- validate_code_and_verifier(code, verifier),
         {:ok, config} <- config(),
         {:ok, access_token} <- exchange_code(config, code, verifier),
         {:ok, profile} <- fetch_profile(config, access_token) do
      {:ok, profile, access_token}
    end
  end

  def exchange_and_fetch(_code, _verifier), do: {:error, :invalid_oauth_callback}

  defp exchange_code(config, code, verifier) do
    request_options =
      [
        form: [
          client_id: config.client_id,
          client_secret: config.client_secret,
          code: code,
          redirect_uri: config.redirect_uri,
          code_verifier: verifier
        ],
        headers: oauth_headers(),
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(config.request_options)

    case Req.post(config.token_url, request_options) do
      {:ok, %Req.Response{status: status, body: %{"access_token" => token}}}
      when status in 200..299 and is_binary(token) and byte_size(token) > 0 ->
        {:ok, token}

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        {:error, :oauth_code_exchange_rejected}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_oauth_token_response}

      {:error, _transport_error} ->
        {:error, :github_unavailable}
    end
  end

  defp fetch_profile(config, access_token) do
    request_options =
      [
        auth: {:bearer, access_token},
        headers: api_headers(),
        receive_timeout: 10_000,
        retry: false
      ]
      |> Keyword.merge(config.request_options)

    case Req.get(config.user_url, request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_profile(body)

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        {:error, :github_profile_rejected}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_github_profile_response}

      {:error, _transport_error} ->
        {:error, :github_unavailable}
    end
  end

  defp parse_profile(%{"id" => id, "login" => login, "avatar_url" => avatar_url} = body)
       when is_integer(id) and id > 0 and is_binary(login) and is_binary(avatar_url) do
    name = parse_name(body)

    profile = %{
      github_id: id,
      github_login: login,
      github_name: name,
      github_avatar_url: avatar_url
    }

    case OpenAgents.Accounts.User.github_changeset(%OpenAgents.Accounts.User{}, %{
           github_id: id,
           github_login: login,
           github_name: name,
           github_avatar_url: avatar_url,
           last_authenticated_at: DateTime.utc_now()
         }) do
      %{valid?: true} -> {:ok, profile}
      _invalid -> {:error, :invalid_github_profile}
    end
  end

  defp parse_profile(_body), do: {:error, :invalid_github_profile}

  defp parse_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp parse_name(_body), do: nil

  defp config do
    settings = Application.get_env(:openagents, :github_oauth, [])

    with client_id when is_binary(client_id) and client_id != "" <- settings[:client_id],
         client_secret when is_binary(client_secret) and client_secret != "" <-
           settings[:client_secret],
         redirect_uri when is_binary(redirect_uri) and redirect_uri != "" <-
           settings[:redirect_uri],
         :ok <- RuntimeConfig.validate_redirect_uri(redirect_uri),
         attempt_ttl_seconds when attempt_ttl_seconds in 60..900 <-
           settings[:attempt_ttl_seconds] || @default_attempt_ttl_seconds,
         request_options when is_list(request_options) <- settings[:request_options] || [] do
      {:ok,
       %{
         client_id: client_id,
         client_secret: client_secret,
         redirect_uri: redirect_uri,
         authorize_url: settings[:authorize_url] || @default_authorize_url,
         token_url: settings[:token_url] || @default_token_url,
         user_url: settings[:user_url] || @default_user_url,
         attempt_ttl_seconds: attempt_ttl_seconds,
         request_options: request_options
       }}
    else
      {:error, reason} -> {:error, reason}
      _missing -> {:error, :github_oauth_not_configured}
    end
  end

  defp validate_code_and_verifier(code, verifier) do
    if code != "" and byte_size(code) <= 1_024 and byte_size(verifier) in 43..128,
      do: :ok,
      else: {:error, :invalid_oauth_callback}
  end

  defp oauth_headers do
    [
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]
  end

  defp api_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", @user_agent},
      {"x-github-api-version", @github_api_version}
    ]
  end

  defp random_url_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp pkce_challenge(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
end
