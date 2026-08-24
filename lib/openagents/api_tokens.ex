defmodule OpenAgents.ApiTokens do
  @moduledoc "Scoped, expiring first-party credentials for non-browser API clients."

  import Ecto.Query

  alias OpenAgents.Accounts
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
  # `deployments:promote` is the operator-only fleet promotion scope. It is
  # deliberately absent from every ordinary issuance path: the list below only
  # says the scope exists, and `privileged_scopes/0` says who may hold one.
  @allowed_scopes [
    "chat:account",
    "forge:write",
    "deployments:write",
    "deployments:promote",
    "box:control",
    "computer:control"
  ]
  @privileged_scopes ["deployments:promote"]
  # What signing in gets you. Both scopes are what a person who signs in from
  # the CLI came for: `forge:write` to push, `chat:account` to talk to a model
  # and to open a coder thread. Leaving chat out made a plain `openagents auth
  # login` produce a credential that could not open a thread, and the refusal
  # arrived one command later, which reads as the product being broken rather
  # than as a scope not asked for.
  @default_scopes ["chat:account", "forge:write"]
  @default_lifetime_days 30
  @maximum_lifetime_days 90
  @privileged_maximum_lifetime_days 7

  @doc "Every scope a credential may carry."
  @spec allowed_scopes() :: [String.t()]
  def allowed_scopes, do: @allowed_scopes

  @doc "The scopes a credential carries when its requester names none."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc """
  Scopes that only a current operator may be issued.

  A privileged scope authorizes a fleet-wide action, so it is never mixed into
  an ordinary credential, never selectable by an ordinary account, and never
  issued for longer than `#{@privileged_maximum_lifetime_days}` days.
  """
  @spec privileged_scopes() :: [String.t()]
  def privileged_scopes, do: @privileged_scopes

  @doc "Whether this scope set contains a scope only an operator may hold."
  @spec privileged?([String.t()]) :: boolean()
  def privileged?(scopes) when is_list(scopes),
    do: Enum.any?(scopes, &(&1 in @privileged_scopes))

  def privileged?(_scopes), do: false

  @doc "The longest lifetime this scope set may be issued for, in days."
  @spec maximum_lifetime_days([String.t()]) :: pos_integer()
  def maximum_lifetime_days(scopes) do
    if privileged?(scopes), do: @privileged_maximum_lifetime_days, else: @maximum_lifetime_days
  end

  @spec create(User.t(), map()) ::
          {:ok, ApiToken.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(%User{id: user_id} = user, attributes) when is_map(attributes) do
    with {:ok, name} <- name(attributes),
         {:ok, scopes} <- scopes(attributes),
         :ok <- authorize_scopes(user, scopes),
         {:ok, lifetime_days} <- lifetime_days(attributes, scopes) do
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

  # A privileged credential is checked twice: once here, so a non-operator can
  # never be issued one, and again on every request, so losing operator
  # standing takes effect before the next call rather than at expiry.
  defp authorize_scopes(%User{} = user, scopes) do
    cond do
      not privileged?(scopes) -> :ok
      Accounts.admin?(user) -> :ok
      true -> {:error, :invalid_api_token}
    end
  end

  # An omitted lifetime takes the shorter of the ordinary default and the
  # scope set's ceiling. An explicit lifetime above that ceiling is refused
  # rather than silently shortened, so a caller never believes it holds a
  # longer-lived credential than it does.
  defp lifetime_days(attributes, scopes) do
    maximum = maximum_lifetime_days(scopes)

    requested =
      Map.get(attributes, "lifetime_days") || Map.get(attributes, :lifetime_days) ||
        min(@default_lifetime_days, maximum)

    case requested do
      days when is_integer(days) and days >= 1 and days <= maximum -> {:ok, days}
      days when is_binary(days) -> parse_lifetime_days(days, maximum)
      _invalid -> {:error, :invalid_api_token}
    end
  end

  defp parse_lifetime_days(value, maximum) do
    case Integer.parse(value) do
      {days, ""} when days >= 1 -> if days <= maximum, do: {:ok, days}, else: error()
      _invalid -> {:error, :invalid_api_token}
    end
  end

  defp error, do: {:error, :invalid_api_token}

  defp digest(value), do: :crypto.hash(:sha256, value)
end
