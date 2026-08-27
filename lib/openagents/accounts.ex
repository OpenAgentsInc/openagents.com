defmodule OpenAgents.Accounts do
  @moduledoc "Durable GitHub identity and authentication-attempt authority."

  import Ecto.Query

  alias OpenAgents.Accounts.{OAuthAttempt, TokenVault, User}
  alias OpenAgents.Inference.Credit
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
    # The credit a new account is granted, written once at creation. The
    # `on_conflict` replacement list below deliberately omits it, so a sign-in
    # by an account that already exists carries its own allowance forward
    # rather than being re-granted the current figure — which is what makes
    # "new accounts get $20" different from "every account now has $20".
    |> Ecto.Changeset.put_change(
      :credit_allowance_microusd,
      Credit.new_account_allowance()
    )
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

  @doc "Seals and stores an explicitly authorized GitHub token and its non-secret metadata."
  @spec store_github_token(User.t(), String.t(), [String.t()]) ::
          {:ok, User.t()} | {:error, atom()}
  def store_github_token(%User{} = user, token, scopes \\ configured_github_scopes())
      when is_binary(token) and is_list(scopes) do
    with true <- valid_scopes?(scopes),
         {:ok, sealed, key_id} <- TokenVault.seal_with_metadata(token) do
      now = DateTime.utc_now()

      user
      |> Ecto.Changeset.change(
        github_token_ciphertext: sealed,
        github_token_key_id: key_id,
        github_token_scopes: scopes,
        github_token_connected_at: now,
        github_token_rotated_at: nil
      )
      |> Ecto.Changeset.check_constraint(:github_token_ciphertext,
        name: :users_github_token_connection_state_check
      )
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _changeset} -> {:error, :token_storage_failed}
      end
    else
      false -> {:error, :invalid_token_scopes}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unseals the stored GitHub access token. Never expose the result to clients or logs."
  @spec github_token(User.t()) :: {:ok, String.t()} | {:error, atom()}
  def github_token(%User{github_token_ciphertext: sealed}) when is_binary(sealed),
    do: TokenVault.open(sealed)

  def github_token(%User{}), do: {:error, :github_token_missing}

  @doc "Rewraps one retained token with the active key without exposing plaintext."
  @spec rotate_github_token(User.t()) :: {:ok, User.t()} | {:error, atom()}
  def rotate_github_token(%User{} = user) do
    with {:ok, token} <- github_token(user),
         {:ok, sealed, key_id} <- TokenVault.seal_with_metadata(token) do
      replace_github_envelope(user, sealed, key_id)
    end
  end

  @doc "Revokes the provider grant, then removes all local token material and metadata."
  @spec disconnect_github(User.t(), (String.t() -> :ok | {:error, atom()})) ::
          {:ok, User.t()} | {:error, atom()}
  def disconnect_github(%User{} = user, revoker \\ &OpenAgents.GitHubOAuth.revoke/1)
      when is_function(revoker, 1) do
    case github_token(user) do
      {:ok, token} ->
        with :ok <- revoker.(token), do: clear_github_token(user)

      {:error, :github_token_missing} ->
        clear_github_token(user)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Non-secret GitHub connection metadata for UI and data-rights projections."
  @spec github_connection(User.t()) :: map()
  def github_connection(%User{} = user) do
    %{
      connected: is_binary(user.github_token_ciphertext),
      scopes: user.github_token_scopes,
      connected_at: user.github_token_connected_at,
      rotated_at: user.github_token_rotated_at
    }
  end

  @doc """
  Sets whether this account is withheld from the public leaderboard.

  The board is the one projection that crosses the account boundary
  (`INVARIANTS.md` LEADERBOARD-001), so the account it is about decides whether
  it appears. The cached projection is invalidated on every change, including a
  change that removes the account, so opting out takes effect on the next push
  to connected viewers rather than at the next unrelated recompute.
  """
  @spec set_public_leaderboard_opt_out(User.t(), boolean()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_public_leaderboard_opt_out(%User{} = user, opted_out?) when is_boolean(opted_out?) do
    case user |> User.leaderboard_changeset(opted_out?) |> Repo.update() do
      {:ok, updated} ->
        :ok = OpenAgents.Leaderboard.invalidate()
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Rewraps every retained GitHub token atomically; returns only the rotated count."
  @spec rotate_github_tokens!() :: non_neg_integer()
  def rotate_github_tokens! do
    Repo.transaction(fn ->
      from(user in User,
        where: not is_nil(user.github_token_ciphertext),
        order_by: [asc: user.id],
        lock: "FOR UPDATE"
      )
      |> Repo.stream(max_rows: 100)
      |> Enum.reduce(0, fn user, count ->
        case rotate_github_token(user) do
          {:ok, _rotated} -> count + 1
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise "GitHub token rotation failed: #{reason}"
    end
  end

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

  @doc """
  Whether this account may use the operator surface.

  Matched on GitHub's immutable numeric ID, never on the login.
  """
  @spec admin?(User.t() | nil) :: boolean()
  def admin?(%User{status: "active", github_id: github_id}) when is_integer(github_id),
    do: github_id in admin_github_ids()

  def admin?(_user), do: false

  # The owner, by GitHub's immutable numeric id. Operator access is otherwise
  # configured per environment, and `runtime.exs` replaces the list wholesale
  # from `OPENAGENTS_ADMIN_GITHUB_IDS` -- so an environment whose variable is
  # unset, mistyped, or lost in a redeploy would lock the owner out of the very
  # surface used to fix it. Unioned in here rather than defaulted in config so
  # no environment can drop it.
  @owner_github_id 14_167_547

  @doc """
  The operator GitHub IDs: the owner, plus whatever this environment configures.
  """
  @spec admin_github_ids() :: [pos_integer()]
  def admin_github_ids do
    configured =
      :openagents
      |> Application.get_env(:admin_github_ids, [])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))

    Enum.uniq([@owner_github_id | configured])
  end

  @doc false
  def ban_user(%User{} = user, reason_code) when is_binary(reason_code) do
    user
    |> User.ban_changeset(reason_code)
    |> Repo.update()
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

  defp clear_github_token(%User{} = user) do
    now = DateTime.utc_now()

    {updated, _rows} =
      user
      |> matching_github_token_query()
      |> Repo.update_all(
        set: [
          github_token_ciphertext: nil,
          github_token_key_id: nil,
          github_token_scopes: [],
          github_token_connected_at: nil,
          github_token_rotated_at: nil,
          updated_at: now
        ]
      )

    if updated == 1 do
      {:ok, Repo.get!(User, user.id)}
    else
      {:error, :github_connection_changed}
    end
  end

  defp replace_github_envelope(user, sealed, key_id) do
    now = DateTime.utc_now()

    {updated, _rows} =
      user
      |> matching_github_token_query()
      |> Repo.update_all(
        set: [
          github_token_ciphertext: sealed,
          github_token_key_id: key_id,
          github_token_rotated_at: now,
          updated_at: now
        ]
      )

    if updated == 1 do
      {:ok, Repo.get!(User, user.id)}
    else
      {:error, :github_connection_changed}
    end
  end

  defp matching_github_token_query(%User{id: id, github_token_ciphertext: nil}) do
    from(user in User, where: user.id == ^id and is_nil(user.github_token_ciphertext))
  end

  defp matching_github_token_query(%User{id: id, github_token_ciphertext: ciphertext}) do
    from(user in User, where: user.id == ^id and user.github_token_ciphertext == ^ciphertext)
  end

  defp configured_github_scopes,
    do: Application.fetch_env!(:openagents, :github_oauth_scopes)

  defp valid_scopes?(scopes) do
    scopes in [configured_github_scopes(), OpenAgents.GitHubOAuth.required_scopes()]
  end
end
