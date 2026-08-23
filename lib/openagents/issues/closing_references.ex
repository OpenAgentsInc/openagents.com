defmodule OpenAgents.Issues.ClosingReferences do
  @moduledoc """
  Close issues that a commit says it closes.

  `OpenAgents.Forge.CommitReferences` reads the message; this module decides
  what to do about it. The decision is deliberately narrow, because the input
  arrives on the push path and a wrong close is expensive to notice:

    * **Same repository only.** A `owner/repo#N` reference is dropped, the
      same boundary the prerequisite edges of #100 draw. Closing across
      repositories asks a second authority question this slice does not
      answer.
    * **Write authority.** The push principal must be a user who can write
      the issue's repository. Any other principal records nothing.
    * **Once.** The `{issue_id, commit_sha}` unique index is the gate. A
      replayed WAL entry, a reconciled receipt, and a force push that
      re-presents the same commit all find the row already there and stop.
    * **Never reopen.** An already-closed issue records the reference and
      keeps its state. A revert is a new commit, and reopening on one is a
      separate policy with its own failure modes.

  The caller decides which commits are eligible. `OpenAgents.Forge.Pushes`
  passes only commits newly reachable from the repository's default branch,
  which is what stops an unmerged topic branch from closing anything.
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge.CommitReferences
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{ClosingReference, Issue}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  @doc """
  Apply the closing references in `message` for one commit.

  `context` carries the push provenance recorded on each row: `:repo`,
  `:wal_seq`, `:push_receipt_id`, and `:principal`.

  Returns the references recorded by this call, which is `[]` when the
  message names nothing, when the principal cannot write the repository, or
  when every reference was already recorded.
  """
  @spec apply_commit(Repository.t(), User.t() | nil, String.t(), String.t(), keyword()) ::
          [ClosingReference.t()]
  def apply_commit(repository, actor, commit_sha, message, context \\ [])

  def apply_commit(%Repository{} = repository, %User{} = actor, commit_sha, message, context)
      when is_binary(commit_sha) and is_binary(message) do
    references = CommitReferences.closing(message)

    if references == [] or not Repositories.writable?(repository, actor) do
      []
    else
      references
      |> Enum.filter(&CommitReferences.same_repository?/1)
      |> Enum.flat_map(&record(repository, actor, commit_sha, &1, context))
    end
  end

  def apply_commit(_repository, _actor, _commit_sha, _message, _context), do: []

  @doc "The closing references recorded against one issue, oldest first."
  @spec for_issue(Issue.t()) :: [ClosingReference.t()]
  def for_issue(%Issue{id: issue_id}) do
    ClosingReference
    |> where([reference], reference.issue_id == ^issue_id)
    |> order_by([reference], asc: reference.inserted_at)
    |> preload(:closed_by_user)
    |> Repo.all()
  end

  @doc "The closing references one commit recorded, with the issue preloaded."
  @spec for_commit(Repository.t(), String.t()) :: [ClosingReference.t()]
  def for_commit(%Repository{id: repository_id}, commit_sha) when is_binary(commit_sha) do
    ClosingReference
    |> where(
      [reference],
      reference.repository_id == ^repository_id and reference.commit_sha == ^commit_sha
    )
    |> order_by([reference], asc: reference.inserted_at)
    |> preload(:issue)
    |> Repo.all()
  end

  def for_commit(_repository, _commit_sha), do: []

  # ── internals ────────────────────────────────────────────────────────────

  defp record(repository, actor, commit_sha, reference, context) do
    case fetch_issue(repository, reference.number) do
      nil ->
        []

      %Issue{} = issue ->
        insert_and_close(repository, actor, issue, commit_sha, reference, context)
    end
  end

  defp fetch_issue(%Repository{id: repository_id}, number) do
    Repo.one(
      from issue in Issue,
        where: issue.repository_id == ^repository_id and issue.number == ^number
    )
  end

  # The reference row and the close land together. A failure anywhere rolls
  # both back, so reconciliation retries a half-applied close instead of
  # leaving a reference that claims a close that never happened.
  defp insert_and_close(repository, actor, issue, commit_sha, reference, context) do
    Repo.transaction(fn ->
      attrs = %{
        repository_id: repository.id,
        issue_id: issue.id,
        commit_sha: commit_sha,
        repo: Keyword.get(context, :repo),
        wal_seq: Keyword.get(context, :wal_seq),
        principal: Keyword.get(context, :principal) || "user:#{actor.id}",
        verb: reference.verb,
        closed: issue.state == "open",
        closed_by_user_id: actor.id,
        push_receipt_id: Keyword.get(context, :push_receipt_id)
      }

      # The read and the insert share the transaction, so the check and the
      # row it guards cannot disagree. A concurrent writer that beats the
      # insert still meets the unique index, and the constraint error rolls
      # the close back with it rather than closing twice.
      if recorded?(issue, commit_sha) do
        []
      else
        case %ClosingReference{} |> ClosingReference.changeset(attrs) |> Repo.insert() do
          {:ok, %ClosingReference{} = recorded} -> close(issue, actor, recorded)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
    |> case do
      {:ok, recorded} ->
        recorded

      {:error, reason} ->
        Logger.warning(
          "issue_closing_reference_failed issue=#{issue.number} code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        []
    end
  end

  defp recorded?(%Issue{id: issue_id}, commit_sha) do
    Repo.exists?(
      from reference in ClosingReference,
        where: reference.issue_id == ^issue_id and reference.commit_sha == ^commit_sha
    )
  end

  defp close(%Issue{state: "open"} = issue, actor, recorded) do
    case Issues.update_issue(issue, %{"state" => "closed", "state_reason" => "completed"}, actor) do
      {:ok, _closed} -> [recorded]
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Already closed: the reference is worth keeping — it is what links the
  # issue to the commit that shipped it — but the state does not move.
  defp close(%Issue{}, _actor, recorded), do: [recorded]
end
