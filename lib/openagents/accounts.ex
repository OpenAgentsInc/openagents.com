defmodule OpenAgents.Accounts do
  @moduledoc "Durable GitHub identity and authentication-attempt authority."

  import Ecto.Query

  alias OpenAgents.Accounts.{OAuthAttempt, TokenVault, User}
  alias OpenAgents.Repo

  @oauth_attempt_retention_seconds 86_400

  @spec upsert_github_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_github_user(profile) when is_map(profile) do
    now = DateTime.utc_now()

    attributes = %{
      github_id: profile.github_id,
      github_login: profile.github_login,
      github_name: Map.get(profile, :github_name),
      github_avatar_url: profile.github_avatar_url,
      last_authenticated_at: now
    }

    %User{}
    |> User.github_changeset(attributes)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :github_login,
           :github_name,
           :github_avatar_url,
           :last_authenticated_at,
           :updated_at
         ]},
      conflict_target: [:github_id],
      returning: true
    )
  end

  @doc "Seals and stores the user's GitHub OAuth access token for server-side API calls."
  @spec store_github_token(User.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def store_github_token(%User{} = user, token) when is_binary(token) do
    with {:ok, sealed} <- TokenVault.seal(token) do
      user
      |> Ecto.Changeset.change(github_token_ciphertext: sealed)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _changeset} -> {:error, :token_storage_failed}
      end
    end
  end

  @doc "Unseals the stored GitHub access token. Never expose the result to clients or logs."
  @spec github_token(User.t()) :: {:ok, String.t()} | {:error, atom()}
  def github_token(%User{github_token_ciphertext: sealed}) when is_binary(sealed),
    do: TokenVault.open(sealed)

  def github_token(%User{}), do: {:error, :github_token_missing}

  def get_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, user_id} -> Repo.get(User, user_id)
      :error -> nil
    end
  end

  def get_user(_invalid), do: nil

  def get_active_user(id) do
    case get_user(id) do
      %User{status: "active"} = user -> {:ok, user}
      %User{status: "banned"} -> {:error, :banned}
      nil -> {:error, :not_found}
    end
  end

  def create_oauth_attempt(state, expires_at)
      when is_binary(state) and is_struct(expires_at, DateTime) do
    prune_oauth_attempts()

    %OAuthAttempt{}
    |> OAuthAttempt.create_changeset(%{
      state_digest: state_digest(state),
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  def consume_oauth_attempt(attempt_id, state)
      when is_binary(attempt_id) and is_binary(state) do
    with {:ok, id} <- Ecto.UUID.cast(attempt_id) do
      now = DateTime.utc_now()

      {updated_count, _rows} =
        from(attempt in OAuthAttempt,
          where:
            attempt.id == ^id and attempt.state_digest == ^state_digest(state) and
              is_nil(attempt.consumed_at) and attempt.expires_at > ^now
        )
        |> Repo.update_all(set: [consumed_at: now])

      if updated_count == 1, do: :ok, else: {:error, :invalid_or_consumed_oauth_attempt}
    else
      :error -> {:error, :invalid_or_consumed_oauth_attempt}
    end
  end

  def consume_oauth_attempt(_attempt_id, _state),
    do: {:error, :invalid_or_consumed_oauth_attempt}

  defp prune_oauth_attempts do
    cutoff = DateTime.add(DateTime.utc_now(), -@oauth_attempt_retention_seconds, :second)

    {_deleted_count, nil} =
      Repo.delete_all(
        from(attempt in OAuthAttempt,
          where:
            attempt.expires_at < ^cutoff or
              (not is_nil(attempt.consumed_at) and attempt.consumed_at < ^cutoff)
        )
      )

    :ok
  end

  defp state_digest(state), do: :crypto.hash(:sha256, state)
end
