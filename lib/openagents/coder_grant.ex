defmodule OpenAgents.CoderGrant do
  @moduledoc """
  Mints the signed spending grant that funds Coder work from OpenAgents credit.

  A grant is a compact Ed25519-signed JWT with the `coder-grant` audience,
  signed with the same `CODER_TOKEN_SIGNING_KEY` seed as the Coder-audience
  token, so Coder validates it locally against one public key. The claims are
  the settlement contract's grant shape: `iss`, `aud`, `sub` (the account),
  `iat`, `exp` (one hour), `jti` (the grant id), and `amount_microusd` (the
  spending bound).

  The amount is bounded twice. `coder_grant_ceiling_microusd` in config caps
  what any single grant may authorize, and the account's remaining inference
  credit (`OpenAgents.Inference.Credit`) caps it again, so a grant never
  authorizes credit the account does not hold. An account with nothing left is
  refused rather than handed a zero grant.

  This slice mints and bounds only. Phoenix keeps no durable grant record yet;
  the settlement half — accepting Coder's asynchronous usage reports against
  the `jti` and drawing the credit down — is the rest of B1.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.CoderToken
  alias OpenAgents.Inference.Credit

  @issuer "openagents.com"
  @audience "coder-grant"
  @ttl_seconds 3_600
  @default_amount_microusd 5_000_000

  @type mint_error ::
          :signing_key_unconfigured | :signing_key_invalid | :insufficient_credit

  @type grant :: %{
          token: String.t(),
          jti: String.t(),
          amount_microusd: pos_integer(),
          expires_in: pos_integer()
        }

  @doc "How long a minted grant lives, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "The most one grant may authorize, in microUSD."
  @spec ceiling_microusd() :: pos_integer()
  def ceiling_microusd do
    Application.get_env(:openagents, :coder_grant_ceiling_microusd, @default_amount_microusd)
  end

  @doc """
  Mints a grant for the account, or says why it cannot.

  `requested` is the amount the caller asked for in microUSD, or `nil` for the
  default. The minted amount is the requested figure clamped to the config
  ceiling and to the account's remaining credit, so it never exceeds either.
  """
  @spec mint(User.t(), pos_integer() | nil) :: {:ok, grant()} | {:error, mint_error()}
  def mint(%User{} = user, requested \\ nil) do
    remaining = Credit.account_credit(user).remaining_microusd

    case amount(requested, remaining) do
      0 ->
        {:error, :insufficient_credit}

      amount ->
        now = System.system_time(:second)
        jti = Ecto.UUID.generate()

        claims = %{
          "iss" => @issuer,
          "sub" => to_string(user.id),
          "aud" => @audience,
          "iat" => now,
          "exp" => now + @ttl_seconds,
          "jti" => jti,
          "amount_microusd" => amount
        }

        with {:ok, token} <- CoderToken.sign_claims(claims) do
          {:ok, %{token: token, jti: jti, amount_microusd: amount, expires_in: @ttl_seconds}}
        end
    end
  end

  defp amount(requested, remaining) do
    requested
    |> case do
      requested when is_integer(requested) and requested > 0 -> requested
      _unrequested -> @default_amount_microusd
    end
    |> min(ceiling_microusd())
    |> min(remaining)
    |> max(0)
  end
end
