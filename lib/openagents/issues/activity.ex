defmodule OpenAgents.Issues.Activity do
  @moduledoc """
  The agent work and forge receipts that name an issue, scoped to a reader.

  The read is assembled from records that already exist. Threads that named the
  issue are read through `OpenAgents.Threads.list_for_issue/2`, so a thread's
  own visibility rules stay in force. Receipts are reached from the commit
  references an issue already claims through `OpenAgents.Issues.ClosingReferences`,
  using `OpenAgents.Forge.receipts_for/2` to scan the commit's push, build,
  target, and deployment receipts. No new work record, no new linkage table, and
  no new repository authority: the repository is checked once and the thread
  authority is composed rather than restated.
  """

  alias OpenAgents.Accounts.User
  alias OpenAgents.Forge
  alias OpenAgents.Issues.{ClosingReferences, Issue}
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Threads

  @doc """
  The threads and receipts that name `issue` and that `reader` may read.

  Returns `%{threads: [...], receipts: [...]}`. An issue with no closing
  references or no matching receipts returns an empty `:receipts` list, and an
  issue with no readable threads returns an empty `:threads` list.
  """
  @spec for_issue(Issue.t(), User.t() | nil) :: %{
          threads: [Threads.Thread.t()],
          receipts: [map()]
        }
  def for_issue(%Issue{} = issue, %User{} = reader), do: do_for_issue(issue, reader)
  def for_issue(%Issue{} = issue, _reader), do: do_for_issue(issue, nil)
  def for_issue(%Issue{} = issue), do: do_for_issue(issue, nil)

  defp do_for_issue(%Issue{} = issue, reader) do
    repository = visible_repository(issue, reader)
    threads = if reader, do: Threads.list_for_issue(issue, reader), else: []

    receipts =
      if repository do
        issue |> ClosingReferences.for_issue() |> receipts_for_references(repository)
      else
        []
      end

    %{threads: threads, receipts: receipts}
  end

  defp visible_repository(%Issue{repository_id: repository_id}, reader) do
    case Repositories.get_visible_repository(repository_id, reader) do
      %Repository{} = repository -> repository
      _not_visible -> nil
    end
  end

  defp receipts_for_references(references, %Repository{} = repository) do
    Enum.flat_map(references, fn reference ->
      sha = reference.commit_sha

      db_receipts =
        repository.storage_key
        |> Forge.receipts_for(sha)
        |> flatten_receipts(sha)

      gate_receipts =
        repository.storage_key
        |> Forge.gate_receipts_for(sha)
        |> flatten_receipts(sha)

      db_receipts ++ gate_receipts
    end)
  end

  defp flatten_receipts(receipts_by_family, sha) do
    for {family, receipts} <- receipts_by_family,
        receipt <- receipts,
        do: %{family: to_string(family), sha: sha, receipt: receipt}
  end
end
