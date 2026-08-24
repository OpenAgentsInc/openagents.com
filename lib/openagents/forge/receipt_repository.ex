defmodule OpenAgents.Forge.ReceiptRepository do
  @moduledoc """
  Which repository a forge receipt belongs to.

  `forge_builds.repo` and `forge_deploys.repo` hold `Target.repo`, which
  `OpenAgents.Forge.Targets` constrains to a member of `:forge_repos` — a
  repository *name*, or `owner/name`. `repositories` is unique on
  `{namespace_id, name_key}` rather than on `name`, so a name can answer for
  two repositories and a receipt keyed only by that name names neither.

  `forge_pushes.repo` is a different value with a different property: it is
  `Repository.storage_key`, which carries a unique index, so a push receipt
  already names exactly one repository. It has no `repository_id` and does not
  need one — see `EXIT-003`, which requires every `forge_pushes` column to be
  re-derivable from the WAL.

  Two operations, and they are deliberately asymmetric:

    * `resolve/1` runs once, at receipt time, and turns a string into a
      repository or into nothing. A name two repositories answer to resolves to
      nothing, so the receipt records a null key rather than a guess.
    * `scope/3` runs at read time and does not consult a string at all for a
      receipt that carries a key. The string stays as the fallback for the rows
      the backfill could not settle, and it is read only for those rows, so a
      shared name can no longer pull one repository's receipts into another's
      answer.
  """

  import Ecto.Query

  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  @doc """
  The one repository `repo` names, or `nil`.

  Zero candidates and two candidates are the same answer on purpose: attaching
  a receipt to the wrong repository is worse than attaching it to none.
  """
  @spec resolve(term()) :: Repository.t() | nil
  def resolve(repo) when is_binary(repo) do
    Repository
    |> where(
      [repository],
      repository.storage_key == ^repo or repository.name == ^repo or
        fragment("? || '/' || ?", repository.owner, repository.name) == ^repo
    )
    |> limit(2)
    |> Repo.all()
    |> case do
      [%Repository{} = repository] -> repository
      _ambiguous_or_absent -> nil
    end
  end

  def resolve(_repo), do: nil

  @doc "The id of the one repository `repo` names, or `nil`."
  @spec resolve_id(term()) :: Ecto.UUID.t() | nil
  def resolve_id(repo) do
    case resolve(repo) do
      %Repository{id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Narrows a `forge_builds` or `forge_deploys` query to one repository.

  With a repository in hand, a receipt matches on its key, and the string is
  consulted only for a receipt that has no key. Without one — a name that
  settles to nothing — the string is all there is, which is the same answer
  this surface gave before the key existed.
  """
  @spec scope(Ecto.Queryable.t(), Repository.t() | nil, [String.t()]) :: Ecto.Query.t()
  def scope(query, nil, repo_keys) do
    from receipt in query, where: receipt.repo in ^repo_keys
  end

  def scope(query, %Repository{id: repository_id}, repo_keys) do
    from receipt in query,
      where:
        receipt.repository_id == ^repository_id or
          (is_nil(receipt.repository_id) and receipt.repo in ^repo_keys)
  end

  @doc """
  Fills `repository_id` for the rows of `table` whose `repo` string settles.

  The migration that added the column runs exactly this statement, and it lives
  here rather than inside the migration so the rule is proven by a test instead
  of asserted by a comment. It is idempotent: a row that already carries a key
  is left alone, and a row whose name answers for two repositories, or for
  none, is left null. A null means "not settled", never "no repository".

  `forge_deploys` carries the `forge_deploy_receipts_immutable` trigger, which
  refuses every `UPDATE`. The caller suspends it; this function does not, so a
  backfill cannot quietly acquire the authority to rewrite a receipt.
  """
  @spec backfill!(String.t()) :: non_neg_integer()
  def backfill!(table) when table in ~w(forge_builds forge_deploys) do
    %Postgrex.Result{num_rows: filled} =
      Repo.query!("""
      WITH candidate AS (
        SELECT
          receipt.id AS receipt_id,
          repository.id AS repository_id,
          count(*) OVER (PARTITION BY receipt.id) AS matches
        FROM #{table} AS receipt
        JOIN repositories AS repository
          ON repository.storage_key = receipt.repo
          OR repository.name = receipt.repo
          OR repository.owner || '/' || repository.name = receipt.repo
      )
      UPDATE #{table} AS receipt
      SET repository_id = candidate.repository_id
      FROM candidate
      WHERE candidate.receipt_id = receipt.id
        AND candidate.matches = 1
        AND receipt.repository_id IS NULL
      """)

    filled
  end
end
