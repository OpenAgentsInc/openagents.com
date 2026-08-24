defmodule OpenAgents.DeviceAuthorizations do
  @moduledoc """
  Short-lived, one-claim browser authorization for the OpenAgents CLI.

  A device authorization may *request* any scope the credential model admits,
  including the operator-only `deployments:promote`. Requesting is not
  holding: the approver sees the requested scopes on the approval page, and a
  request for a privileged scope is refused unless the approving account is a
  current operator. That is what lets an operator bootstrap a release CLI
  without issuing the credential from a settings page.
  """

  import Ecto.Query

  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.ApiTokens
  alias OpenAgents.DeviceAuthorizations.DeviceAuthorization
  alias OpenAgents.Repo

  @ttl_seconds 600
  @interval_seconds 5
  @maximum_create_attempts 3

  def create(scopes \\ ApiTokens.default_scopes())

  def create(scopes) when is_list(scopes), do: create(scopes, @maximum_create_attempts)

  def create(_scopes), do: {:error, :invalid_scopes}

  def get_pending_by_user_code(user_code) when is_binary(user_code) do
    now = DateTime.utc_now()

    Repo.one(
      from authorization in DeviceAuthorization,
        where:
          authorization.user_code_digest == ^digest(normalize_user_code(user_code)) and
            authorization.state == "pending" and authorization.expires_at > ^now
    )
  end

  def get_pending_by_user_code(_user_code), do: nil

  def approve(user_code, %User{status: "active", id: user_id} = user) do
    transition(user_code, "approved", user_id, user)
  end

  def approve(_user_code, %User{}), do: {:error, :access_denied}

  def deny(user_code, %User{status: "active", id: user_id} = user) do
    transition(user_code, "denied", user_id, user)
  end

  def deny(_user_code, %User{}), do: {:error, :access_denied}

  def poll(device_code) when is_binary(device_code) and byte_size(device_code) < 256 do
    Repo.transaction(fn -> poll_locked(device_code, DateTime.utc_now()) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def poll(_device_code), do: {:error, :access_denied}

  defp create(_scopes, 0), do: {:error, :authorization_unavailable}

  defp create(scopes, attempts_left) do
    device_code = random_url_token(32)
    user_code = random_user_code()
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    %DeviceAuthorization{}
    |> DeviceAuthorization.create_changeset(%{
      device_code_digest: digest(device_code),
      user_code_digest: digest(user_code),
      expires_at: expires_at,
      interval_seconds: @interval_seconds,
      scopes: scopes
    })
    |> Repo.insert()
    |> case do
      {:ok, authorization} ->
        {:ok, authorization, device_code, user_code}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :device_code_digest) or
             Keyword.has_key?(changeset.errors, :user_code_digest),
           do: create(scopes, attempts_left - 1),
           else: {:error, changeset}
    end
  end

  defp transition(user_code, next_state, user_id, user) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        authorization =
          Repo.one(
            from authorization in DeviceAuthorization,
              where:
                authorization.user_code_digest == ^digest(normalize_user_code(user_code)) and
                  authorization.state == "pending" and authorization.expires_at > ^now,
              lock: "FOR UPDATE"
          )

        case authorization do
          %DeviceAuthorization{scopes: scopes} = authorization ->
            if next_state == "approved" and ApiTokens.privileged?(scopes) and
                 not Accounts.admin?(user) do
              Repo.rollback(:access_denied)
            end

            attrs =
              if next_state == "approved",
                do: [state: "approved", user_id: user_id, approved_at: now],
                else: [state: "denied", user_id: user_id, denied_at: now]

            authorization
            |> Ecto.Changeset.change(attrs)
            |> Repo.update!()

          nil ->
            Repo.rollback(:access_denied)
        end
      end)

    case result do
      {:ok, authorization} -> {:ok, authorization}
      {:error, _reason} -> {:error, :access_denied}
    end
  end

  defp poll_locked(device_code, now) do
    authorization =
      Repo.one(
        from authorization in DeviceAuthorization,
          where: authorization.device_code_digest == ^digest(device_code),
          lock: "FOR UPDATE"
      )

    case authorization do
      %DeviceAuthorization{expires_at: expires_at} = authorization ->
        if DateTime.compare(expires_at, now) != :gt,
          do: {:error, :access_denied},
          else: poll_by_state(authorization, now)

      _unavailable ->
        {:error, :access_denied}
    end
  end

  defp poll_by_state(%DeviceAuthorization{state: "pending"} = pending, now) do
    poll_pending(pending, now)
  end

  defp poll_by_state(%DeviceAuthorization{state: "approved", user_id: user_id} = approved, now) do
    claim(approved, Repo.get(User, user_id), now)
  end

  defp poll_by_state(_authorization, _now), do: {:error, :access_denied}

  defp poll_pending(%DeviceAuthorization{} = authorization, now) do
    elapsed =
      if authorization.last_polled_at,
        do: DateTime.diff(now, authorization.last_polled_at, :second),
        else: authorization.interval_seconds

    authorization
    |> Ecto.Changeset.change(
      last_polled_at: now,
      poll_count: authorization.poll_count + 1
    )
    |> Repo.update!()

    if elapsed < authorization.interval_seconds,
      do: {:error, :slow_down},
      else: {:error, :authorization_pending}
  end

  defp claim(
         %DeviceAuthorization{scopes: scopes} = authorization,
         %User{status: "active"} = user,
         now
       ) do
    case ApiTokens.create(user, %{
           name: "OpenAgents CLI",
           scopes: scopes,
           lifetime_days: min(30, ApiTokens.maximum_lifetime_days(scopes))
         }) do
      {:ok, api_token, plaintext} ->
        authorization
        |> Ecto.Changeset.change(
          state: "claimed",
          api_token_id: api_token.id,
          claimed_at: now
        )
        |> Repo.update!()

        {:ok, plaintext, api_token}

      {:error, _reason} ->
        Repo.rollback(:authorization_unavailable)
    end
  end

  defp claim(_authorization, _user, _now), do: {:error, :access_denied}

  defp normalize_user_code(code) do
    code
    |> String.trim()
    |> String.upcase()
  end

  defp random_user_code do
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    8
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> String.at(alphabet, rem(byte, byte_size(alphabet))) end)
    |> then(fn <<left::binary-size(4), right::binary-size(4)>> -> left <> "-" <> right end)
  end

  defp random_url_token(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
end
