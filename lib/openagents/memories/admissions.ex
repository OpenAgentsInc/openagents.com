defmodule OpenAgents.Memories.Admissions do
  @moduledoc """
  The gate in front of the system bucket: anyone can propose, only evidence
  admits, and only a steward writes the receipt.

  ## Why admission is a record rather than a field

  A wrong `user` memory misleads one session. A wrong `system` memory would
  reach every session on the network, so the store treats a status the way the
  promise registry treats a green promise: it is derived from a receipt
  somebody is answerable for, never read from a flag the claimant set. An
  author who writes `admission: "admitted"` on their own row has claimed
  something, and `status/1` still answers `"candidate"` until a steward records
  a verdict.

  ## Who admits

  A steward, and nobody else. The specification called for a published, signed
  allowlist of pubkeys evaluated as of an event's timestamp; on this substrate
  a single trusted server holds the role and checks it where the row is
  created, so what survives is the rule the machinery existed to enforce.

  The role is `OpenAgents.Accounts.admin?/1` — the operator allowlist of
  immutable GitHub numeric IDs, bootstrapped to the owner's account. That is
  the honest reading of "accounts the operator has marked as stewards,
  bootstrapped to the operator's own account", and it is the only account-level
  authority this server has: there is no `role` column on `users`, and the one
  per-account grant table in the repository grants roles on a repository rather
  than on the network. Broadening the steward set later touches the role
  assignment, not these record shapes. ADMIN-001 enumerates this module as an
  operator gate.

  ## What this module deliberately does not do

  It does not surface anything. An admitted system memory is stored, derived,
  and read by nobody: `OpenAgents.Memories.recall/3` reads the `user` and
  `learned` buckets only, and MEMORY-001 and MEMORY-010 confine recall to the
  acting account with no unscoped fallback. Reading an admitted row into every
  account's turn is cross-account recall by construction, so it is a privacy
  decision that belongs to the recall issue rather than a ranking detail this
  one can settle.

  It also never reads another account's memory. The composite foreign key
  `(memory_id, memory_bucket)` is what proves a candidate is a `system` row, so
  `record/3` writes without a lookup, and `supersede/3` authorizes inside the
  `UPDATE` predicate and learns nothing from a refusal.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OpenAgents.Accounts
  alias OpenAgents.Accounts.User
  alias OpenAgents.Memories
  alias OpenAgents.Memories.{Admission, Memory}
  alias OpenAgents.Repo

  @doc """
  Whether `user` may admit.

  A steward is an operator account. `admin?/1` refuses a banned account and
  reads the GitHub numeric ID rather than the login, so a renamed account keeps
  its authority and a transferred login does not inherit it.
  """
  @spec steward?(User.t() | nil) :: boolean()
  def steward?(user), do: Accounts.admin?(user)

  @doc """
  Writes one admission record against a candidate system memory.

  Attributes: `verdict` (`admitted` or `rejected`) and `ground` (why). The
  steward and the candidate are set on the struct, so a request body can name
  neither.

  Refuses `:steward_required` for an account without the role, and
  `:not_found` when `memory_id` does not name a system memory — the composite
  foreign key decides that, so a caller learns nothing about a row in another
  bucket beyond the fact that it is not admissible.
  """
  @spec record(User.t(), String.t(), map()) ::
          {:ok, Admission.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :steward_required}
          | {:error, :not_found}
  def record(%User{} = steward, memory_id, attrs) when is_map(attrs) do
    if steward?(steward) do
      with {:ok, id} <- cast_id(memory_id) do
        %Admission{memory_id: id, steward_id: steward.id}
        |> Admission.changeset(normalize(attrs))
        |> Repo.insert()
        |> case do
          {:ok, admission} -> {:ok, admission}
          {:error, changeset} -> refusal(changeset)
        end
      end
    else
      {:error, :steward_required}
    end
  end

  @doc """
  A candidate's effective admission status.

  Derived from the admission records that reference it, newest verdict first,
  and never from the candidate's own `admission` field. A memory with no
  admission record behind it is a `candidate`, whatever it says about itself.

  Answers `nil` for a memory outside the system bucket, which has no admission
  status to have.
  """
  @spec status(Memory.t() | String.t()) :: String.t() | nil
  def status(%Memory{bucket: "system", id: id}), do: status(id)
  def status(%Memory{}), do: nil

  def status(memory_id) when is_binary(memory_id) do
    case cast_id(memory_id) do
      {:ok, id} -> Repo.one(latest(id)) || "candidate"
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Every admission record against one candidate, oldest first.

  Append-only, so this is the whole history rather than the current state, and
  `status/1` is what reads a state out of it.
  """
  @spec list(Memory.t() | String.t()) :: [Admission.t()]
  def list(%Memory{id: id}), do: list(id)

  def list(memory_id) when is_binary(memory_id) do
    case cast_id(memory_id) do
      {:ok, id} ->
        Repo.all(
          from(record in Admission,
            where: record.memory_id == ^id,
            order_by: [asc: record.inserted_at, asc: record.id]
          )
        )

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Corrects a system memory by writing a replacement and pointing the old row at
  it.

  Only the original author or a steward may correct a system slug. Anyone else
  who disagrees files a challenge; the store has no path for editing somebody
  else's claim, and supersession is the only correction path there is.

  `attrs` describe the replacement, which is written under `user`'s account
  through the ordinary write path — same evidence requirement, same tier floor,
  same constraint. Name the target's slug on it: the slug is what binds the
  correction to the claim it corrects. A correction is admitted at the account
  ceiling, as `OpenAgents.Memories.create/2` admits one, because it replaces a
  live row with a live row.

  The authorization is the `UPDATE` predicate rather than a read followed by a
  decision. A caller with no standing gets `:not_supersedable` and learns
  nothing about the row, including whether it exists.
  """
  @spec supersede(User.t(), String.t(), map()) ::
          {:ok, Memory.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_supersedable}
  def supersede(%User{} = user, target_id, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_target(target_id) do
      replacement = Memories.build(user, Map.put(normalize(attrs), "bucket", "system"))

      Multi.new()
      |> Multi.insert(:replacement, replacement)
      |> Multi.run(:target, fn repo, %{replacement: written} ->
        updates = [superseded_by_id: written.id, updated_at: DateTime.utc_now()]

        case repo.update_all(correctable(user, id), set: updates) do
          {1, _rows} -> {:ok, written}
          {0, _rows} -> {:error, :not_supersedable}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{replacement: written}} -> {:ok, written}
        {:error, :replacement, changeset, _changes} -> {:error, changeset}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # ── internal ───────────────────────────────────────────────────────────────

  # MEMORY-010: the account boundary is a predicate in the query. Here it is
  # one half of the authorization — the row is the actor's own — and the other
  # half is the steward role, which lives in the operator allowlist rather than
  # in a column and so arrives as a bound boolean. A caller who is neither
  # matches no row, so the update reports zero and nothing is read out.
  defp correctable(%User{id: user_id} = user, target_id) do
    steward = steward?(user)

    from(memory in Memory,
      where: memory.id == ^target_id,
      where: memory.bucket == "system",
      where: is_nil(memory.superseded_by_id),
      where: memory.user_id == ^user_id or type(^steward, :boolean)
    )
  end

  defp latest(memory_id) do
    from(record in Admission,
      where: record.memory_id == ^memory_id,
      where: record.role == "admission",
      order_by: [desc: record.inserted_at, desc: record.id],
      limit: 1,
      select: record.verdict
    )
  end

  # The composite foreign key is what refuses a candidate outside the system
  # bucket, so its violation is reported as absence rather than as a changeset
  # error about a column the caller never named.
  defp refusal(changeset) do
    if Enum.any?(changeset.errors, fn {field, _error} -> field == :memory_id end) do
      {:error, :not_found}
    else
      {:error, changeset}
    end
  end

  defp cast_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_value), do: {:error, :not_found}

  defp cast_target(value) do
    case cast_id(value) do
      {:ok, id} -> {:ok, id}
      {:error, :not_found} -> {:error, :not_supersedable}
    end
  end

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
