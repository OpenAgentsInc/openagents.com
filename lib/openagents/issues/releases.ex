defmodule OpenAgents.Issues.Releases do
  @moduledoc """
  Which release carried an issue.

  The chain from an issue to its receipts already existed and already joined,
  but it joined on an exact revision. `OpenAgents.Issues.Evidence` binds an
  issue to the receipts that evaluated the precise commit its work produced,
  and `OpenAgents.Forge.receipts_for/2` matches a fleet target by comparing
  shas. That is the right rule for a build receipt, which evaluated one tree
  and no other. It is the wrong rule for a release: a release is promoted at
  the revision the fleet should converge to, and the commit that closed an
  issue is almost never that revision. It is an ancestor of it.

  So a reader could see that an issue's commit was pushed and built, and
  could not see that it shipped. This module answers the missing half by
  asking git the question the sha comparison cannot: is the issue's commit
  contained in the release's revision.

  ## What it reads

  Two records, both of which already exist:

    * `issue_closing_references` — the commits that say they close the issue.
      `OpenAgents.Issues.ClosingReferences` verified the pusher could write
      the issue and required the commit to be reachable from the default
      branch before recording one, so a topic branch claims nothing here.
    * `forge_fleet_targets` — the operator-approved revisions the fleet was
      told to converge to, with the deploy-lane status each reached.

  It writes nothing. There is no issue-to-release table, because there is no
  fact to store: containment is a property of the commit graph the forge
  already holds, and a stored copy of it would be a second authority that
  could disagree with git.

  ## Why only closing references

  `forge_assignments.terminal_commit` is the other commit-to-issue source the
  evidence chain reads, and this module deliberately does not. An attempt's
  self-reported revision is the executor's claim rather than a merge, and the
  evidence chain gates it behind `OpenAgents.Transparency.WorkDisclosure`
  because a branch name and a revision an attempt produced can restate private
  repository content. Everything this module returns is derived from commits
  on the default branch of a repository the caller has already been admitted
  to read, so it needs no second disclosure ladder — and a module that needed
  one would be the wrong place to add it.

  ## What it bounds

  A read path that spawns a git subprocess per pair needs a ceiling in both
  directions: at most four claiming commits and at most twelve recent release
  targets, which is inside the pair limit
  `OpenAgents.Forge.GitPlane.containing/3` enforces. `truncated` says the
  window cut something off, so a caller can tell "nothing shipped it" from
  "the window did not reach far enough".
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.Forge.{GitPlane, Target}
  alias OpenAgents.Issues.{ClosingReferences, Issue}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository

  # The newest claiming commits and the newest release targets this read looks
  # at. Their product stays inside `GitPlane.containing/3`'s pair limit.
  @commit_limit 4
  @target_limit 12

  @typedoc "One release target that contains a commit, projected."
  @type release :: %{
          id: binary(),
          sha: String.t(),
          status: String.t(),
          promoted_at: DateTime.t(),
          settled_at: DateTime.t()
        }

  @typedoc """
  The release answer for one issue.

  `released_in` is the oldest release that reached `live` and contains every
  claiming commit in the window — the first release that shipped the whole of
  what the issue asked for. It is `nil` when no such release is in the window,
  including when only some of the commits shipped.
  """
  @type t :: %{
          commits: [
            %{
              sha: String.t(),
              verb: String.t() | nil,
              referenced_at: DateTime.t(),
              releases: [release()]
            }
          ],
          released_in: release() | nil,
          truncated: boolean()
        }

  @doc """
  The releases that carried `issue`, resolved through the commit graph.

  Never raises. A repository whose bare cache cannot be read, a WAL that is
  unreachable, and an issue no commit claims all answer the same way: an empty
  list, which is the honest reading of "nothing here says this shipped".
  """
  @spec for_issue(Issue.t()) :: t()
  def for_issue(%Issue{repository_id: repository_id} = issue) do
    case Repo.get(Repository, repository_id) do
      %Repository{} = repository -> for_issue(repository, issue)
      nil -> empty()
    end
  end

  @doc """
  The releases that carried `issue` in a repository the caller already
  resolved.

  `repository` must be the issue's own repository; a caller that passes
  another one gets `empty/0` rather than another repository's releases.
  """
  @spec for_issue(Repository.t(), Issue.t()) :: t()
  def for_issue(%Repository{id: repository_id} = repository, %Issue{} = issue) do
    if issue.repository_id == repository_id do
      resolve(repository, issue)
    else
      empty()
    end
  rescue
    error ->
      Logger.warning("issue_releases_failed code=#{OpenAgents.OperationalLog.code(error)}")
      empty()
  end

  @doc "The answer for an issue nothing claims: no commits, no release."
  @spec empty() :: t()
  def empty, do: %{commits: [], released_in: nil, truncated: false}

  # ── internals ────────────────────────────────────────────────────────────

  defp resolve(%Repository{} = repository, %Issue{} = issue) do
    references = issue |> ClosingReferences.for_issue() |> Enum.uniq_by(& &1.commit_sha)
    kept = Enum.take(references, @commit_limit)
    targets = targets(repository)

    truncated? = length(references) > @commit_limit or length(targets) == @target_limit
    containment = containment(repository, kept, targets)

    commits =
      Enum.map(kept, fn reference ->
        %{
          sha: reference.commit_sha,
          verb: reference.verb,
          referenced_at: reference.inserted_at,
          releases: containment |> Map.get(reference.commit_sha, []) |> Enum.map(&release/1)
        }
      end)

    %{
      commits: commits,
      released_in: released_in(kept, containment),
      truncated: truncated?
    }
  end

  # A target names its repository by string, and two strings reach the same
  # repository: the storage key the git plane reads and the repository name a
  # promotion may have been recorded under. Both are read, and neither is
  # allowed to reach a repository other than this one.
  defp targets(%Repository{} = repository) do
    keys =
      [repository.storage_key, repository.name]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    Target
    |> where([target], target.repo in ^keys)
    |> order_by([target], desc: target.inserted_at, desc: target.id)
    |> limit(@target_limit)
    |> Repo.all()
  end

  defp containment(_repository, [], _targets), do: %{}
  defp containment(_repository, _references, []), do: %{}

  defp containment(%Repository{} = repository, references, targets) do
    commits = Enum.map(references, & &1.commit_sha)
    by_sha = Enum.group_by(targets, & &1.sha)
    shas = Map.keys(by_sha)

    case GitPlane.containing(repository.storage_key, commits, shas) do
      {:ok, matrix} ->
        Map.new(matrix, fn {commit, matched} ->
          {commit,
           matched
           |> Enum.flat_map(&Map.get(by_sha, &1, []))
           |> Enum.sort_by(& &1.inserted_at, DateTime)}
        end)

      # An unreachable WAL, a cache this node cannot read, and a matrix past
      # the pair bound are all "this read cannot answer", which is not the
      # same fact as "nothing shipped it" — but the caller sees the same empty
      # list either way, because an issue page that guessed would be worse
      # than one that says nothing.
      {:error, reason} ->
        Logger.debug(
          "issue_releases_containment_unavailable code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        %{}
    end
  end

  # The first release that carried the whole issue: the oldest `live` target
  # that contains every claiming commit in the window. A target that carried
  # some of them is on each of those commits' own lists and is not this.
  defp released_in([], _containment), do: nil

  defp released_in([first | rest], containment) do
    carried = Map.get(containment, first.commit_sha, [])

    shared =
      Enum.reduce(rest, MapSet.new(carried, & &1.id), fn reference, acc ->
        MapSet.intersection(
          acc,
          containment |> Map.get(reference.commit_sha, []) |> MapSet.new(& &1.id)
        )
      end)

    carried
    |> Enum.filter(&(&1.status == "live" and MapSet.member?(shared, &1.id)))
    |> Enum.min_by(& &1.inserted_at, DateTime, fn -> nil end)
    |> case do
      %Target{} = target -> release(target)
      nil -> nil
    end
  end

  defp release(%Target{} = target) do
    %{
      id: target.id,
      sha: target.sha,
      status: target.status,
      promoted_at: target.inserted_at,
      settled_at: target.updated_at
    }
  end
end
