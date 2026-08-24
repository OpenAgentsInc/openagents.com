defmodule OpenAgents.Machines do
  @moduledoc """
  Paired computers and their device-style controller pairing flow.

  A pairing starts unauthenticated from the CLI, is approved by the signed-in
  account owner in the browser, and is claimed once by the CLI with a poll
  secret. Sarah stores only a digest of the computer token; the plaintext is
  sealed at rest solely for the claim window and wiped on claim.
  """

  import Ecto.Query

  alias OpenAgents.Accounts.User
  alias OpenAgents.Machines.{Machine, Pairing, TokenVault}
  alias OpenAgents.Repo

  @pairing_lifetime_seconds 600
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"
  @maximum_probe_bytes 32_768
  @maximum_machines 8

  @spec start_pairing(map()) ::
          {:ok, %{pairing: Pairing.t(), code: String.t(), poll_secret: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def start_pairing(attributes) do
    code = generate_code()
    poll_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @pairing_lifetime_seconds, :second)

    %Pairing{}
    |> Pairing.create_changeset(attributes)
    |> Ecto.Changeset.change(
      code_digest: digest(code),
      poll_secret_digest: digest(poll_secret),
      expires_at: expires_at
    )
    |> Repo.insert()
    |> case do
      {:ok, pairing} -> {:ok, %{pairing: pairing, code: code, poll_secret: poll_secret}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec pending_pairing(String.t()) :: {:ok, Pairing.t()} | {:error, atom()}
  def pending_pairing(code) when is_binary(code) do
    case Repo.get_by(Pairing, code_digest: digest(normalize_code(code))) do
      %Pairing{status: "pending"} = pairing ->
        if expired?(pairing), do: {:error, :pairing_expired}, else: {:ok, pairing}

      %Pairing{} ->
        {:error, :pairing_consumed}

      nil ->
        {:error, :pairing_not_found}
    end
  end

  def pending_pairing(_code), do: {:error, :pairing_not_found}

  @spec approve_pairing(User.t(), String.t(), keyword()) :: {:ok, Machine.t()} | {:error, atom()}
  @spec approve_pairing(User.t(), String.t(), String.t()) ::
          {:ok, Machine.t()} | {:error, atom()}
  @spec approve_pairing(User.t(), String.t(), String.t(), keyword()) ::
          {:ok, Machine.t()} | {:error, atom()}
  @spec approve_pairing(User.t(), String.t()) :: {:ok, Machine.t()} | {:error, atom()}
  def approve_pairing(%User{id: user_id}, pairing_or_code, code_or_options \\ [], options \\ [])
      when is_binary(pairing_or_code) do
    cond do
      is_binary(code_or_options) and is_list(options) ->
        do_approve_pairing(user_id, pairing_or_code, code_or_options, options)

      is_list(code_or_options) and options == [] ->
        do_approve_pairing(user_id, nil, pairing_or_code, code_or_options)

      true ->
        {:error, :pairing_not_found}
    end
  end

  @spec update_scoped_forge_credentials(User.t(), String.t(), boolean()) ::
          {:ok, Machine.t()} | {:error, atom()}
  def update_scoped_forge_credentials(%User{id: user_id}, machine_id, enabled)
      when is_boolean(enabled) do
    with {:ok, machine} <- get_machine(user_id, machine_id),
         {:ok, updated} <-
           machine
           |> Ecto.Changeset.change(scoped_forge_credentials_enabled: enabled)
           |> Repo.update() do
      if enabled do
        :ok
      else
        _ =
          OpenAgents.Forge.Assignments.finish_for_machine(
            machine.id,
            "scoped_forge_credentials_disabled"
          )
      end

      broadcast_machine_updated(updated)
      {:ok, updated}
    else
      {:error, _changeset} -> {:error, :machine_not_found}
      error -> error
    end
  end

  def update_scoped_forge_credentials(_user, _machine_id, _enabled),
    do: {:error, :machine_not_found}

  defp do_approve_pairing(user_id, pairing_id, code, options) do
    Repo.transaction(fn ->
      with {:ok, pairing} <- pending_pairing_for_update(code),
           :ok <- verify_pairing_id(pairing, pairing_id),
           %User{} <- Repo.get_for_update!(User, user_id),
           :ok <- verify_capacity(user_id) do
        token = "smct_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        {:ok, sealed} = TokenVault.seal(token)

        token_expires_at =
          DateTime.add(DateTime.utc_now(), machine_token_ttl_seconds(), :second)

        machine =
          %Machine{user_id: user_id}
          |> Machine.create_changeset(%{
            "name" => pairing.name,
            "tier" => pairing.tier,
            "platform" => pairing.platform,
            "agent_version" => pairing.agent_version,
            "roots" => pairing.roots
          })
          |> Ecto.Changeset.change(
            token_digest: digest(token),
            token_expires_at: token_expires_at,
            scoped_forge_credentials_enabled:
              Keyword.get(options, :scoped_forge_credentials_enabled, false)
          )
          |> Repo.insert!()

        pairing
        |> Ecto.Changeset.change(
          status: "approved",
          machine_id: machine.id,
          token_ciphertext: sealed
        )
        |> Repo.update!()

        machine
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec claim_pairing(String.t(), String.t()) ::
          {:ok, %{token: String.t(), machine_id: String.t(), name: String.t()}}
          | {:error, atom()}
  def claim_pairing(pairing_id, poll_secret)
      when is_binary(pairing_id) and is_binary(poll_secret) do
    result =
      Repo.transaction(fn ->
        with {:ok, pairing_id} <- Ecto.UUID.cast(pairing_id),
             %Pairing{} = pairing <-
               Repo.one(from(p in Pairing, where: p.id == ^pairing_id, lock: "FOR UPDATE")),
             true <-
               Plug.Crypto.secure_compare(pairing.poll_secret_digest, digest(poll_secret)) do
          claim_locked_pairing(pairing)
        else
          _missing -> {:error, :pairing_not_found}
        end
      end)

    case result do
      {:ok, claim_result} -> claim_result
      {:error, _transaction_failure} -> {:error, :pairing_not_found}
    end
  end

  def claim_pairing(_pairing_id, _poll_secret), do: {:error, :pairing_not_found}

  @spec authenticate_token(String.t()) :: {:ok, Machine.t()} | {:error, atom()}
  def authenticate_token("smct_" <> _rest = token) when byte_size(token) < 128 do
    case Repo.get_by(Machine, token_digest: digest(token)) do
      %Machine{status: "active"} = machine ->
        if DateTime.compare(DateTime.utc_now(), machine.token_expires_at) == :lt,
          do: {:ok, machine},
          else: {:error, :machine_expired}

      %Machine{} ->
        {:error, :machine_revoked}

      nil ->
        {:error, :machine_not_found}
    end
  end

  def authenticate_token(_token), do: {:error, :machine_not_found}

  @spec list_machines(String.t()) :: [Machine.t()]
  def list_machines(user_id) when is_binary(user_id) do
    Repo.all(from m in Machine, where: m.user_id == ^user_id, order_by: [desc: m.inserted_at])
  end

  @spec active_machine?(String.t() | nil) :: boolean()
  def active_machine?(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from m in Machine,
        where: m.user_id == ^user_id and m.status == "active" and m.token_expires_at > ^now
    )
  end

  def active_machine?(_user_id), do: false

  @spec get_machine(String.t(), String.t()) :: {:ok, Machine.t()} | {:error, atom()}
  def get_machine(user_id, machine_id) when is_binary(user_id) and is_binary(machine_id) do
    with {:ok, _cast} <- Ecto.UUID.cast(machine_id),
         %Machine{user_id: ^user_id} = machine <- Repo.get(Machine, machine_id) do
      {:ok, machine}
    else
      _missing -> {:error, :machine_not_found}
    end
  end

  def get_machine(_user_id, _machine_id), do: {:error, :machine_not_found}

  @external_effect_modules [
    {"sarah.tool.computer_run.v1", 1},
    {"sarah.tool.computer_devin.v1", 1},
    {"sarah.tool.computer_agent.v1", 1}
  ]

  @doc """
  Approval receipts backed by the owner's explicit computer pairings.

  Approving a pairing on /computers is the operator's explicit approval for
  the computer-effect modules; each active computer yields one receipt per
  module, scoped to the current conversation.
  """
  @spec approval_receipts(String.t() | nil, String.t()) :: [map()]
  def approval_receipts(user_id, scope_ref) when is_binary(user_id) and is_binary(scope_ref) do
    now = DateTime.utc_now()

    for machine <- list_machines(user_id),
        machine.status == "active",
        DateTime.compare(machine.token_expires_at, now) == :gt,
        {module_id, version} <- @external_effect_modules do
      %{
        "schema" => "sarah.module_approval.v1",
        "approval_class" => "explicit_operator_approval",
        "module_id" => module_id,
        "version" => version,
        "scope_ref" => scope_ref,
        "explicit" => true,
        "actor_type" => "operator",
        "receipt_ref" => "machine:#{machine.id}"
      }
    end
  end

  def approval_receipts(_user_id, _scope_ref), do: []

  @spec record_seen(Machine.t()) :: Machine.t()
  def record_seen(%Machine{} = machine) do
    updated =
      machine
      |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
      |> Repo.update!()

    broadcast_machine_updated(updated)
    updated
  end

  @spec store_probe(Machine.t(), map()) :: {:ok, Machine.t()} | {:error, atom()}
  def store_probe(%Machine{} = machine, report) when is_map(report) do
    if byte_size(Jason.encode!(report)) <= @maximum_probe_bytes do
      machine
      |> Ecto.Changeset.change(last_probe: report, last_seen_at: DateTime.utc_now())
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast_machine_updated(updated)
          {:ok, updated}

        {:error, _changeset} ->
          {:error, :invalid_probe_report}
      end
    else
      {:error, :probe_report_too_large}
    end
  end

  def store_probe(_machine, _report), do: {:error, :invalid_probe_report}

  @doc """
  Revoke a computer: close its channel, finish its assignments, and end the
  inference authority it is still holding.

  The last of those used to be missing. A revoked computer kept every
  `inference_grants` row minted for it, each carrying a plaintext token already
  delivered to that computer and each good at the inference proxy — which
  authenticates the token and never the computer — until its own budget or
  `expires_at` closed it. `OpenAgents.Inference.revoke_active_for_machine/1`
  now runs in the same transaction as the revoked row, and a grant minted while
  that transaction is open is refused rather than left behind (IDENTITY-008).
  """
  @spec revoke_machine(User.t(), String.t()) :: {:ok, Machine.t()} | {:error, atom()}
  def revoke_machine(%User{id: user_id}, machine_id) do
    with {:ok, machine} <- get_machine(user_id, machine_id) do
      # One transaction, and the computer row is locked before the sweep, so a
      # concurrent mint either lands before it and is swept, or blocks on the
      # lock, re-reads `revoked`, and is refused.
      Repo.transaction(fn ->
        locked = Repo.get_for_update!(Machine, machine.id)

        case locked
             |> Ecto.Changeset.change(status: "revoked", revoked_at: DateTime.utc_now())
             |> Repo.update() do
          {:ok, revoked} ->
            _ = OpenAgents.Inference.revoke_active_for_machine(revoked.id)
            revoked

          {:error, _changeset} ->
            Repo.rollback(:machine_not_found)
        end
      end)
      |> case do
        {:ok, revoked} ->
          _ = OpenAgents.Forge.Assignments.finish_for_machine(machine.id)

          Phoenix.PubSub.broadcast(
            OpenAgents.PubSub,
            "machine:#{machine.id}",
            {:machine_revoked, machine.id}
          )

          {:ok, revoked}

        {:error, _reason} ->
          {:error, :machine_not_found}
      end
    end
  end

  @doc """
  Expire every pairing whose window has closed, without waiting for a poll.

  `claim_pairing/2` already expires an elapsed pairing, and that was the only
  thing that ever did. A pairing the CLI stops polling — killed, disconnected,
  or simply abandoned after the owner approved it — therefore stayed `approved`
  forever, holding the sealed computer token `TokenVault` promises lives only
  for the claim window, and leaving the computer it created `active` with a
  token nobody ever received.

  This is the same transition without a bearer. It reads
  `machine_pairings.expires_at`, which is what
  `machine_pairings_expires_at_index` exists for and what nothing read, then
  applies `claim_pairing/2`'s own expiry to each row under that row's lock: the
  status moves to `expired`, `token_ciphertext` is nulled, and any computer the
  pairing created is revoked along with the inference grants it holds
  (IDENTITY-008, IDENTITY-011).
  """
  @spec expire_elapsed_pairings() :: non_neg_integer()
  def expire_elapsed_pairings do
    DateTime.utc_now()
    |> elapsed_pairing_ids()
    |> Enum.count(&(expire_elapsed_pairing(&1) == :ok))
  end

  @doc """
  The rows `expire_elapsed_pairings/0` will act on, as of `now`.

  This is a separate function because it is the only thing in the release that
  reads `machine_pairings.expires_at`, and therefore the only reader
  `machine_pairings_expires_at_index` has. `expire_elapsed_pairing/1` re-reads
  each row under its own lock and refuses anything terminal or still fresh, so
  a widened predicate here changes no outcome and no result — it only makes the
  sweep read rows it will not touch, and stops using the index, invisibly. The
  selection is proved on its own for that reason.
  """
  @spec elapsed_pairing_ids(DateTime.t()) :: [Ecto.UUID.t()]
  def elapsed_pairing_ids(%DateTime{} = now), do: now |> elapsed_pairing_query() |> Repo.all()

  @doc "The selection above, unexecuted, so a proof can read its plan."
  @spec elapsed_pairing_query(DateTime.t()) :: Ecto.Query.t()
  def elapsed_pairing_query(%DateTime{} = now) do
    Pairing
    |> where([p], p.status in ["pending", "approved"] and p.expires_at <= ^now)
    |> select([p], p.id)
  end

  # One transaction per row. The re-read under `FOR UPDATE` is what makes the
  # sweep safe next to a claim arriving at the same moment: whichever takes the
  # lock first moves the row, and the other finds a status it no longer acts on.
  defp expire_elapsed_pairing(pairing_id) do
    Repo.transaction(fn ->
      case Repo.one(from(p in Pairing, where: p.id == ^pairing_id, lock: "FOR UPDATE")) do
        %Pairing{status: status} = pairing when status in ["pending", "approved"] ->
          if expired?(pairing), do: expire_locked_pairing(pairing), else: :fresh

        _consumed ->
          :consumed
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      _unchanged -> :unchanged
    end
  end

  defp verify_capacity(user_id) do
    now = DateTime.utc_now()

    active =
      Repo.aggregate(
        from(m in Machine,
          where: m.user_id == ^user_id and m.status == "active" and m.token_expires_at > ^now
        ),
        :count
      )

    if active < @maximum_machines, do: :ok, else: {:error, :too_many_machines}
  end

  # Pairing approval is a two-resource transition: exactly one caller may
  # consume a pairing, and one owner's active-machine count may not race past
  # the cap. Locking the pairing first gives same-code approvals one winner;
  # locking the owner row next serializes different pairing codes for that
  # account before the capacity check and insert.
  defp pending_pairing_for_update(code) when is_binary(code) do
    case Repo.get_by_for_update(Pairing, code_digest: digest(normalize_code(code))) do
      %Pairing{status: "pending"} = pairing ->
        if expired?(pairing), do: {:error, :pairing_expired}, else: {:ok, pairing}

      %Pairing{} ->
        {:error, :pairing_consumed}

      nil ->
        {:error, :pairing_not_found}
    end
  end

  defp pending_pairing_for_update(_code), do: {:error, :pairing_not_found}

  defp verify_pairing_id(%Pairing{}, nil), do: :ok

  defp verify_pairing_id(%Pairing{id: pairing_id}, pairing_id), do: :ok

  defp verify_pairing_id(%Pairing{}, _pairing_id), do: {:error, :pairing_not_found}

  defp claim_locked_pairing(%Pairing{} = pairing) do
    cond do
      expired?(pairing) ->
        expire_locked_pairing(pairing)
        {:error, :pairing_expired}

      pairing.status == "pending" ->
        {:error, :pairing_pending}

      pairing.status == "approved" and is_binary(pairing.token_ciphertext) ->
        with {:ok, token} <- TokenVault.open(pairing.token_ciphertext) do
          pairing
          |> Ecto.Changeset.change(status: "claimed", token_ciphertext: nil)
          |> Repo.update!()

          {:ok, %{token: token, machine_id: pairing.machine_id, name: pairing.name}}
        end

      true ->
        {:error, :pairing_consumed}
    end
  end

  defp expire_locked_pairing(pairing) do
    now = DateTime.utc_now()

    pairing
    |> Ecto.Changeset.change(status: "expired", token_ciphertext: nil)
    |> Repo.update!()

    if pairing.machine_id do
      {revoked, _returned} =
        from(machine in Machine,
          where: machine.id == ^pairing.machine_id and machine.status == "active"
        )
        |> Repo.update_all(set: [status: "revoked", revoked_at: now, updated_at: now])

      # The other revocation path, and it owes the same thing: this runs inside
      # the claim transaction, after the update has taken the computer row's
      # lock, so an interleaved mint cannot slip a live grant past it.
      _ = OpenAgents.Inference.revoke_active_for_machine(pairing.machine_id)

      # `revoke_machine/2` announces its revocation so the computer's channel
      # closes and an open /computers stops showing the card as live. This path
      # revokes too, and until the sweep existed nothing ever ran it headlessly.
      if revoked > 0 do
        Phoenix.PubSub.broadcast(
          OpenAgents.PubSub,
          "machine:#{pairing.machine_id}",
          {:machine_revoked, pairing.machine_id}
        )
      end
    end

    :ok
  end

  defp expired?(%Pairing{expires_at: expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  defp normalize_code(code) do
    code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp generate_code do
    for <<byte <- :crypto.strong_rand_bytes(8)>>, into: "" do
      <<Enum.at(@code_alphabet, rem(byte, length(@code_alphabet)))>>
    end
  end

  defp broadcast_machine_updated(machine) do
    Phoenix.PubSub.broadcast(
      OpenAgents.PubSub,
      "machine:#{machine.id}",
      {:machine_updated, machine}
    )
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp machine_token_ttl_seconds,
    do: Application.fetch_env!(:openagents, :machine_token_ttl_seconds)
end
