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
  @maximum_device_name_length 80

  # The alphabet `random_user_code/0` draws from. `I`, `O`, `0`, and `1` are
  # absent on purpose: a code is read off one screen and typed into another.
  @user_code_alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @user_code_pattern ~r/\A[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}\z/

  @doc """
  Casts a caller-supplied user code to the exact shape this module mints.

  `get_pending_by_user_code/1` can be handed anything and answers `nil`, which
  is the right answer for a lookup. It is the wrong answer for anything that
  puts the value back into a URL, a page, or a session, because "no such
  authorization" and "not a code at all" are then indistinguishable.

  This is that second question, and it is asked wherever a code the browser
  sent goes on to build something. The pattern is anchored with `\\A` and
  `\\z` rather than `^` and `$`, so a trailing newline cannot smuggle a second
  line past it, and it admits only the thirty-two characters and one hyphen
  above — never a path, a host, a scheme, a quote, or a tag.

  Trimming and upcasing come first, so a code retyped in lowercase is the same
  code. A letter this alphabet excludes is not silently corrected to one it
  admits: `i` upcases to `I`, which is not in the set, and is refused.
  """
  @spec cast_user_code(term()) :: {:ok, String.t()} | :error
  def cast_user_code(code) when is_binary(code) do
    normalized = normalize_user_code(code)

    if Regex.match?(@user_code_pattern, normalized), do: {:ok, normalized}, else: :error
  end

  def cast_user_code(_code), do: :error

  def create(scopes \\ ApiTokens.default_scopes(), device_name \\ nil, kind \\ "token")

  def create(scopes, device_name, kind)
      when kind in ["token", "github_connect"] and is_list(scopes),
      do:
        insert_authorization(
          scopes,
          normalize_device_name(device_name),
          @maximum_create_attempts,
          kind
        )

  def create(_scopes, _device_name, _kind), do: {:error, :invalid_scopes}

  @doc """
  Reads one pending github_connect authorization for the approval page.

  The code arrives on the connect page URL, so it is cast first and a lookup
  miss answers nil: the page renders the code-entry form again rather than an
  error about a value the URL may never have carried.
  """
  def get_pending_github_connect(user_code) when is_binary(user_code) do
    case cast_user_code(user_code) do
      {:ok, normalized} ->
        now = DateTime.utc_now()

        Repo.one(
          from authorization in DeviceAuthorization,
            where:
              authorization.user_code_digest == ^digest(normalized) and
                authorization.state == "pending" and
                authorization.kind == "github_connect" and
                authorization.expires_at > ^now
        )

      :error ->
        nil
    end
  end

  def get_pending_github_connect(_user_code), do: nil

  def get_pending_by_user_code(user_code) when is_binary(user_code) do
    case cast_user_code(user_code) do
      {:ok, normalized} ->
        now = DateTime.utc_now()

        Repo.one(
          from authorization in DeviceAuthorization,
            where:
              authorization.user_code_digest == ^digest(normalized) and
                authorization.state == "pending" and
                authorization.kind == "token" and
                authorization.expires_at > ^now
        )

      :error ->
        nil
    end
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

  @doc """
  Polls once for the outcome of one device authorization.

  A `token` authorization answers `{:ok, plaintext, api_token}` when its
  approval has been claimed. A `github_connect` authorization answers
  `{:ok, {:connected, github_login}, :connect_completed}` — there is no
  credential in the answer, because the retained GitHub token never leaves
  the server.
  """
  @spec poll(String.t() | nil) ::
          {:ok, String.t(), OpenAgents.ApiTokens.ApiToken.t()}
          | {:ok, {:connected, String.t()}, :connect_completed}
          | {:error, :authorization_pending | :slow_down | :access_denied}
  def poll(device_code) when is_binary(device_code) and byte_size(device_code) < 256 do
    Repo.transaction(fn -> poll_locked(device_code, DateTime.utc_now()) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def poll(_device_code), do: {:error, :access_denied}

  defp insert_authorization(_scopes, _device_name, 0, _kind),
    do: {:error, :authorization_unavailable}

  defp insert_authorization(scopes, device_name, attempts_left, kind) do
    device_code = random_url_token(32)
    user_code = random_user_code()
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    %DeviceAuthorization{}
    |> DeviceAuthorization.create_changeset(%{
      device_code_digest: digest(device_code),
      user_code_digest: digest(user_code),
      device_name: device_name,
      kind: kind,
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
           do: insert_authorization(scopes, device_name, attempts_left - 1, kind),
           else: {:error, changeset}
    end
  end

  # A computer name is display metadata, not authority. Normalize it rather
  # than letting a hostname with a control character or excessive length stop
  # sign-in. HEEx escapes the remaining text when the approval page renders it.
  defp normalize_device_name(name) when is_binary(name) do
    name =
      name
      |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
      |> String.trim()
      |> String.slice(0, @maximum_device_name_length)

    if name == "", do: nil, else: name
  end

  defp normalize_device_name(_name), do: nil

  @doc """
  Marks one pending github_connect authorization claimed by its owner.

  Approval of a CLI-initiated connect happens the moment the person starts the
  repository authorization while carrying the code: the OAuth grant decision
  is the approval, and it is made by the signed-in account, so the device row
  records that account immediately rather than after the callback.
  """
  def claim_github_connect(user_code, %User{status: "active", id: user_id}) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        authorization =
          Repo.one(
            from authorization in DeviceAuthorization,
              where:
                authorization.user_code_digest == ^digest(normalize_user_code(user_code)) and
                  authorization.state == "pending" and
                  authorization.kind == "github_connect" and
                  is_nil(authorization.user_id) and
                  authorization.expires_at > ^now,
              lock: "FOR UPDATE"
          )

        case authorization do
          %DeviceAuthorization{} = authorization ->
            authorization
            |> Ecto.Changeset.change(
              state: "approved",
              user_id: user_id,
              approved_at: now
            )
            |> Repo.update!()

          nil ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, authorization} -> {:ok, authorization}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  def claim_github_connect(_user_code, %User{}), do: {:error, :not_found}
  def claim_github_connect(_user_code, _other), do: {:error, :not_found}

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

  # A github_connect approval is not a credential: the retained GitHub token
  # lives in the user row and no API token is minted, so the poll answer
  # carries only the GitHub identity the connect completed with.
  defp claim(
         %DeviceAuthorization{kind: "github_connect"} = authorization,
         %User{status: "active", github_login: login} = _user,
         now
       )
       when is_binary(login) do
    authorization
    |> Ecto.Changeset.change(state: "claimed", claimed_at: now)
    |> Repo.update!()

    {:ok, {:connected, login}, :connect_completed}
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
    alphabet = @user_code_alphabet

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
