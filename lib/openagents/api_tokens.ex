defmodule OpenAgents.ApiTokens do
  @moduledoc "Scoped, expiring first-party credentials for non-browser API clients."

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Audit
  alias OpenAgents.ApiTokens.ApiToken
  alias OpenAgents.Repo

  @prefix "oa_pat_"
  # `deployments:write` speaks to the deployment control plane. It is deliberately
  # not `forge:write`, and deliberately not the operator-only
  # `deployments:promote` fleet scope: holding it lets a caller address the
  # deployment API, while repository membership and environment policy still
  # decide what it may deploy.
  @allowed_scopes [
    "chat:account",
    "forge:write",
    "deployments:write",
    "box:control",
    "computer:control"
  ]
  @maximum_lifetime_days 90

  @spec create(User.t(), map()) ::
          {:ok, ApiToken.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(%User{id: user_id}, attributes) when is_map(attributes) do
    with {:ok, name} <- name(attributes),
         {:ok, scopes} <- scopes(attributes),
         {:ok, lifetime_days} <- lifetime_days(attributes) do
      id = Ecto.UUID.generate()
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      plaintext = @prefix <> id <> "." <> secret

      Repo.transaction(fn ->
        token =
          %ApiToken{id: id, user_id: user_id, token_digest: digest(plaintext)}
          |> ApiToken.create_changeset(%{
            name: name,
            scopes: scopes,
            expires_at: DateTime.add(DateTime.utc_now(), lifetime_days, :day)
          })
          |> Repo.insert!()

        Audit.record!("api_token.created", {:user, user_id}, "api_token", token.id,
          metadata: %{"scopes" => scopes}
        )

        token
      end)
      |> case do
        {:ok, token} -> {:ok, token, plaintext}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create(%User{}, _attributes), do: {:error, :invalid_api_token}

  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t(), ApiToken.t()} | {:error, :invalid_api_token}
  def authenticate(@prefix <> rest = plaintext, required_scope)
      when byte_size(plaintext) < 160 and required_scope in @allowed_scopes do
    result =
      Repo.transaction(fn ->
        with [id, secret] <- String.split(rest, ".", parts: 2),
             true <- byte_size(secret) in 40..64,
             {:ok, token_id} <- Ecto.UUID.cast(id),
             %ApiToken{} = token <-
               Repo.one(from(t in ApiToken, where: t.id == ^token_id, lock: "FOR UPDATE")),
             true <- Plug.Crypto.secure_compare(token.token_digest, digest(plaintext)),
             true <- usable?(token, required_scope),
             %User{status: "active"} = user <- Repo.get(User, token.user_id) do
          now = DateTime.utc_now()
          Repo.update_all(from(t in ApiToken, where: t.id == ^token.id), set: [last_used_at: now])
          {user, %{token | last_used_at: now}}
        else
          _invalid -> Repo.rollback(:invalid_api_token)
        end
      end)

    case result do
      {:ok, {user, token}} -> {:ok, user, token}
      {:error, _invalid} -> {:error, :invalid_api_token}
    end
  end

  def authenticate(_plaintext, _required_scope), do: {:error, :invalid_api_token}

  @spec list(User.t()) :: [ApiToken.t()]
  def list(%User{id: user_id}) do
    Repo.all(
      from(token in ApiToken,
        where: token.user_id == ^user_id,
        order_by: [desc: token.inserted_at]
      )
    )
  end

  @spec revoke(User.t(), String.t()) :: {:ok, ApiToken.t()} | {:error, :not_found}
  def revoke(%User{id: user_id}, id) when is_binary(id) do
    with {:ok, token_id} <- Ecto.UUID.cast(id),
         %ApiToken{user_id: ^user_id} = token <- Repo.get(ApiToken, token_id) do
      token
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update()
    else
      _missing -> {:error, :not_found}
    end
  end

  def revoke(%User{}, _id), do: {:error, :not_found}

  @spec metadata(User.t()) :: [map()]
  def metadata(%User{} = user) do
    Enum.map(list(user), fn token ->
      %{
        id: token.id,
        name: token.name,
        scopes: token.scopes,
        expires_at: token.expires_at,
        last_used_at: token.last_used_at,
        revoked_at: token.revoked_at,
        inserted_at: token.inserted_at
      }
    end)
  end

  defp usable?(token, required_scope) do
    is_nil(token.revoked_at) and required_scope in token.scopes and
      DateTime.compare(DateTime.utc_now(), token.expires_at) == :lt
  end

  defp name(attributes) do
    case Map.get(attributes, "name") || Map.get(attributes, :name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_api_token}
          trimmed -> {:ok, String.slice(trimmed, 0, 80)}
        end

      _invalid ->
        {:error, :invalid_api_token}
    end
  end

  defp scopes(attributes) do
    requested = Map.get(attributes, "scopes") || Map.get(attributes, :scopes)

    if is_list(requested) and requested != [] and
         Enum.all?(requested, &(&1 in @allowed_scopes)) do
      {:ok, Enum.uniq(requested)}
    else
      {:error, :invalid_api_token}
    end
  end

  defp lifetime_days(attributes) do
    case Map.get(attributes, "lifetime_days") || Map.get(attributes, :lifetime_days) || 30 do
      days when is_integer(days) and days in 1..@maximum_lifetime_days -> {:ok, days}
      days when is_binary(days) -> parse_lifetime_days(days)
      _invalid -> {:error, :invalid_api_token}
    end
  end

  defp parse_lifetime_days(value) do
    case Integer.parse(value) do
      {days, ""} when days in 1..@maximum_lifetime_days -> {:ok, days}
      _invalid -> {:error, :invalid_api_token}
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
end
