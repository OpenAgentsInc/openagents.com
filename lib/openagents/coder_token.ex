defmodule OpenAgents.CoderToken do
  @moduledoc """
  Mints the Coder-audience token as a compact JWT signed with Ed25519.

  Coder validates the token locally against the matching public key, so no
  claim in it depends on Phoenix's symmetric secret. The signing key is a
  dedicated 32-byte Ed25519 seed from `CODER_TOKEN_SIGNING_KEY`, standard
  base64. Without a configured key the endpoint refuses to mint rather than
  falling back to symmetric signing.
  """

  @issuer "openagents.com"
  @audience "coder"
  @ttl_seconds 600

  @type mint_error ::
          :signing_key_unconfigured | :signing_key_invalid | :github_connection_required

  @doc "How long a minted token lives, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Mints a token for the account, or says why it cannot.

  The claims carry the GitHub identity the identity bridge would report, so
  Coder can map the caller to the same person without a callback.
  """
  @spec mint(OpenAgents.Accounts.User.t()) :: {:ok, String.t()} | {:error, mint_error()}
  def mint(user) do
    with {:ok, seed} <- signing_seed(),
         :ok <- github_identity(user) do
      now = System.system_time(:second)

      claims = %{
        "iss" => @issuer,
        "sub" => to_string(user.id),
        "aud" => @audience,
        "iat" => now,
        "exp" => now + @ttl_seconds,
        "jti" => Ecto.UUID.generate(),
        "scope" => "responses",
        "login" => user.github_login,
        "github_id" => user.github_id
      }

      {:ok, sign(claims, seed)}
    end
  end

  defp github_identity(%{github_id: github_id, github_login: login})
       when is_integer(github_id) and github_id > 0 and is_binary(login) and login != "",
       do: :ok

  defp github_identity(_user), do: {:error, :github_connection_required}

  defp signing_seed do
    case Application.get_env(:openagents, :coder_token_signing_key) do
      nil ->
        {:error, :signing_key_unconfigured}

      encoded when is_binary(encoded) ->
        case Base.decode64(String.trim(encoded)) do
          {:ok, seed} when byte_size(seed) == 32 -> {:ok, seed}
          _invalid -> {:error, :signing_key_invalid}
        end
    end
  end

  defp sign(claims, seed) do
    header = encode_segment(%{"alg" => "EdDSA", "typ" => "JWT"})
    payload = encode_segment(claims)
    message = header <> "." <> payload
    signature = :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
    message <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode_segment(map) do
    map |> Jason.encode!() |> Base.url_encode64(padding: false)
  end
end
