defmodule OpenAgents.Notifications.EmailChannel do
  @moduledoc """
  The address an account is willing to receive mail at, and the proof of it.

  ## Why the address is typed rather than taken

  GitHub OAuth can be asked for `user:email` and hand over whatever address the
  provider holds. This deployment does not ask. An address taken from a
  provider is an address nobody chose to give this application, and the first
  thing it would be used for is unsolicited mail to a mailbox its owner never
  named here. So the address is typed into the notification settings, by the
  person who wants mail, on purpose.

  ## The gate

  `verified_address/1` is the only function anything sends to, and it returns
  `nil` unless the account both names an address and confirmed it. Confirmation
  is a code mailed to the address and typed back, which is the only evidence
  this application can have that the person asking controls the mailbox.

  Three things make the gate hold rather than merely exist:

    * The code is held as a SHA-256 digest. A database read is not enough to
      claim somebody else's mailbox.
    * Guesses are counted and bounded at five. A short code with free guesses
      is not a secret.
    * The check constraint `users_notification_email_state_check` refuses a
      verified timestamp on a row with no address, so the gate survives a bug
      in this module.

  Changing the address clears the verification, because the evidence was about
  the old mailbox. Removing it clears everything, including the outstanding
  code.

  ## What a deployment without a mail provider does

  `deliverable?/0` reads one configuration key rather than inferring from the
  Swoosh adapter, because the inference is wrong in both directions: the local
  adapter is real delivery in development — the mailbox preview at
  `/dev/mailbox` — and it is a black hole in production. A deployment that
  configures no provider says so, and the settings surface offers no address
  field rather than accepting one it cannot mail to.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Notifications.Email
  alias OpenAgents.Repo

  # Long enough that five guesses are hopeless, short enough to retype from a
  # phone. Crockford's alphabet without I, L, O and U: no character in it can
  # be confused with another in a proportional font, and none of them spell
  # anything.
  @code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @code_length 8

  @code_lifetime_seconds 1_800
  @resend_after_seconds 60
  @maximum_attempts 5

  @typedoc "What the settings surface needs to render the address, and nothing more."
  @type state :: %{address: String.t() | nil, verified?: boolean(), pending?: boolean()}

  @typedoc "Why an address or a code was refused."
  @type refusal ::
          :not_deliverable
          | :invalid_address
          | :too_soon
          | :nothing_pending
          | :expired
          | :incorrect_code
          | :too_many_attempts

  @doc """
  The address this account may be mailed at, or `nil`.

  Every outbound notification resolves its recipient here. An address that was
  typed but never confirmed returns `nil`, which is what makes an unverified
  address unreachable rather than merely discouraged.
  """
  @spec verified_address(User.t() | nil) :: String.t() | nil
  def verified_address(%User{notification_email: address, notification_email_verified_at: at})
      when is_binary(address) and not is_nil(at),
      do: address

  def verified_address(_user), do: nil

  @doc "Whether this deployment can send at all. See the module note on `deliverable?/0`."
  @spec deliverable?() :: boolean()
  def deliverable?, do: Keyword.get(configuration(), :deliverable, false)

  @doc "The `{name, address}` every message this channel sends is from."
  @spec from() :: {String.t(), String.t()}
  def from, do: Keyword.fetch!(configuration(), :from)

  @doc """
  What the settings surface renders: the address, whether it is confirmed, and
  whether a code is outstanding.

  Never the code, and never its digest.
  """
  @spec state(User.t()) :: state()
  def state(%User{} = user) do
    %{
      address: user.notification_email,
      verified?: not is_nil(user.notification_email_verified_at),
      pending?: pending?(user)
    }
  end

  @doc """
  Records an address and mails a code to it.

  The address is inert until the code comes back. Re-recording the address an
  account already confirmed changes nothing rather than quietly unverifying it,
  because retyping what you already proved is not a withdrawal of the proof.
  """
  @spec set_address(User.t(), String.t()) :: {:ok, User.t()} | {:error, refusal()}
  def set_address(%User{} = user, address) when is_binary(address) do
    with :ok <- require_deliverable(),
         {:ok, normalized} <- normalize(address) do
      if normalized == verified_address(user) do
        {:ok, user}
      else
        issue_code(user, normalized)
      end
    end
  end

  @doc """
  Mails another code to the address already on the account.

  Bounded by `#{@resend_after_seconds}` seconds since the last one, so the send
  button cannot be turned into a way to mail somebody repeatedly. Issuing a new
  code retires the old one and resets the attempt count: the person is asking
  again, not guessing again.
  """
  @spec resend_code(User.t()) :: {:ok, User.t()} | {:error, refusal()}
  def resend_code(%User{notification_email: address} = user) when is_binary(address) do
    with :ok <- require_deliverable(),
         :ok <- require_resend_window(user),
         do: issue_code(user, address)
  end

  def resend_code(%User{}), do: {:error, :nothing_pending}

  @doc """
  Confirms the address with the code that was mailed to it.

  A correct code marks the address verified and clears the outstanding one, so
  the same code cannot be replayed. A wrong one counts, and at the fifth the
  code is retired entirely: the next step is a fresh send, not another guess.

  The comparison is constant-time over digests, so a caller cannot learn the
  code one character at a time.
  """
  @spec verify(User.t(), String.t()) :: {:ok, User.t()} | {:error, refusal()}
  def verify(%User{} = user, code) when is_binary(code) do
    with :ok <- require_pending(user),
         :ok <- require_unexpired(user),
         :ok <- require_attempts_left(user) do
      if Plug.Crypto.secure_compare(
           user.notification_email_code_digest,
           digest(normalize_code(code))
         ) do
        confirm(user)
      else
        count_failure(user)
      end
    end
  end

  @doc """
  Forgets the address, the verification, and any outstanding code.

  One update rather than a soft delete: there is nothing here worth keeping
  once the account has said to stop mailing it.
  """
  @spec remove_address(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def remove_address(%User{} = user) do
    update(user, %{
      notification_email: nil,
      notification_email_verified_at: nil,
      notification_email_code_digest: nil,
      notification_email_code_sent_at: nil,
      notification_email_code_attempts: 0
    })
  end

  ## Internals

  # The row and the message have to agree, and only one of them is
  # transactional. Writing first is the order that cannot mail a code the
  # database does not hold; rolling back on a refused send is what keeps the
  # other direction from mattering, so a provider hiccup while changing an
  # address does not leave the account with its previous verification quietly
  # withdrawn.
  defp issue_code(user, address) do
    code = generate_code()

    Repo.transaction(fn ->
      case update(user, %{
             notification_email: address,
             notification_email_verified_at: nil,
             notification_email_code_digest: digest(code),
             notification_email_code_sent_at: DateTime.utc_now(),
             notification_email_code_attempts: 0
           }) do
        {:ok, updated} ->
          case Email.deliver_verification(address, code) do
            {:ok, _delivery} -> updated
            {:error, _reason} -> Repo.rollback(:not_deliverable)
          end

        {:error, %Ecto.Changeset{}} ->
          Repo.rollback(:invalid_address)
      end
    end)
  end

  defp confirm(user) do
    update(user, %{
      notification_email_verified_at: DateTime.utc_now(),
      notification_email_code_digest: nil,
      notification_email_code_attempts: 0
    })
  end

  defp count_failure(user) do
    attempts = user.notification_email_code_attempts + 1

    attributes =
      if attempts >= @maximum_attempts do
        %{notification_email_code_digest: nil, notification_email_code_attempts: attempts}
      else
        %{notification_email_code_attempts: attempts}
      end

    case update(user, attributes) do
      {:ok, _updated} when attempts >= @maximum_attempts -> {:error, :too_many_attempts}
      {:ok, _updated} -> {:error, :incorrect_code}
      {:error, _changeset} -> {:error, :incorrect_code}
    end
  end

  defp update(user, attributes) do
    user
    |> Ecto.Changeset.change(attributes)
    |> Ecto.Changeset.check_constraint(:notification_email,
      name: :users_notification_email_state_check
    )
    |> Repo.update()
  end

  defp require_deliverable do
    if deliverable?(), do: :ok, else: {:error, :not_deliverable}
  end

  defp require_pending(user) do
    if pending?(user), do: :ok, else: {:error, :nothing_pending}
  end

  defp require_unexpired(%User{notification_email_code_sent_at: sent_at}) do
    if DateTime.diff(DateTime.utc_now(), sent_at) <= @code_lifetime_seconds do
      :ok
    else
      {:error, :expired}
    end
  end

  defp require_attempts_left(%User{notification_email_code_attempts: attempts}) do
    if attempts < @maximum_attempts, do: :ok, else: {:error, :too_many_attempts}
  end

  defp require_resend_window(user) do
    case resend_available_at(user) do
      nil ->
        :ok

      available_at ->
        if DateTime.compare(DateTime.utc_now(), available_at) == :lt do
          {:error, :too_soon}
        else
          :ok
        end
    end
  end

  defp pending?(%User{notification_email_code_digest: digest}), do: is_binary(digest)

  defp resend_available_at(%User{notification_email_code_sent_at: nil}), do: nil

  defp resend_available_at(%User{notification_email_code_sent_at: sent_at}),
    do: DateTime.add(sent_at, @resend_after_seconds, :second)

  # Deliberately conservative, and deliberately not a full RFC 5322 grammar. The
  # address is not being parsed, it is being refused early: one at-sign, no
  # whitespace, a dot in the domain, and a length a column and a provider both
  # accept. Anything this admits that the provider rejects fails at the send,
  # which the outbox already handles.
  defp normalize(address) do
    normalized = address |> String.trim() |> String.downcase()

    if String.match?(normalized, ~r/\A[^\s@]+@[^\s@.]+(\.[^\s@.]+)+\z/) and
         String.length(normalized) <= 254 do
      {:ok, normalized}
    else
      {:error, :invalid_address}
    end
  end

  defp normalize_code(code), do: code |> String.trim() |> String.upcase()

  defp generate_code do
    size = length(@code_alphabet)

    @code_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&Enum.at(@code_alphabet, rem(&1, size)))
    |> List.to_string()
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp configuration, do: Application.get_env(:openagents, __MODULE__, [])
end
