defmodule OpenAgents.Issues.TaskReferences do
  @moduledoc """
  Keep task-list checkboxes that point at issues true to those issues.

  `OpenAgents.Issues.TaskList` says what a body should read; this module
  decides when to look and what to write. It runs on two triggers, and it
  needs both:

    * **On write.** `OpenAgents.Issues` renders an issue or comment body
      through `render/2` as it is created or updated, so a body arrives
      already agreeing with the issues it names.
    * **On state change.** `synchronize/2` runs after an issue opens or
      closes and rewrites the bodies in the same repository whose task-list
      items point at it.

  ## Why both, and what that buys

  One trigger alone leaves a hole. Fan-out without render-on-write loses to a
  person who saves a body they loaded before the checkbox moved. Render-on-write
  without fan-out only fixes a body somebody happens to touch.

  Together they make the rendered body a fixed point. Every writer computes the
  body from the same two inputs — the text in front of it and the current
  states — so an automatic edit and a human edit that cross still converge:
  whichever lands second recomputes from what is then true, and neither one
  leaves the checkbox describing the other's world. The checkbox stops being an
  independent assertion someone has to maintain and becomes a projection of
  issue state.

  A person can no longer hold a checkbox open against a closed issue, and that
  is the trade this makes deliberately. Reopen the issue if the work is not
  done; the checkbox follows.

  ## What bounds it

    * **Same repository.** `#N` resolves against the repository holding the
      body, and `owner/repo#N` stops the item entirely — the same boundary
      #100's prerequisite edges and #130's closing references both draw. No
      body can therefore learn anything about a repository its reader cannot
      already read, so the rewrite cannot leak a private issue's state into a
      public one.
    * **Only bodies that name the issue.** The candidate query filters on the
      literal `#N` before anything is read or rewritten, and `@body_limit`
      caps how many bodies one state change may touch.
    * **Only a real difference.** A body is written only when rendering
      returns something other than what is stored. That is the idempotency
      gate: running `synchronize/2` again finds every body already rendered,
      writes nothing, and records nothing.
    * **Never at the cost of the change that triggered it.** A failure here is
      caught and logged. Refusing a close because a tracking issue's body
      could not be rewritten would trade the important write for the
      cosmetic one.

  Each write it does make is recorded as an `OpenAgents.Issues.TaskSync` row
  attributed to the system, never to the person whose close triggered it, and
  the issue history renders those rows beside comments and closes.
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.Issues.{Comment, Issue, TaskList, TaskSync}
  alias OpenAgents.OperationalLog
  alias OpenAgents.Repo
  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.Repository

  # No single state change rewrites more bodies than this. A tracking issue
  # named by more bodies than this is a mention list, not a task list, and
  # rewriting it is not worth the write amplification on a close.
  @body_limit 200

  @principal "system"

  @doc """
  `body` with its task-list checkboxes rendered from `repository`'s issues.

  Returns `body` unchanged when it holds no task-list reference, when the
  repository is unknown, and whenever anything goes wrong. Safe to call on
  every write, including one inside a transaction.
  """
  @spec render(Repository.t() | binary() | nil, term()) :: term()
  def render(repository, body)

  def render(%Repository{id: repository_id}, body), do: render(repository_id, body)

  def render(repository_id, body) when is_binary(repository_id) and is_binary(body) do
    case TaskList.numbers(body) do
      [] -> body
      numbers -> TaskList.render(body, states(repository_id, numbers))
    end
  rescue
    error ->
      Logger.warning("issue_task_render_failed code=#{OperationalLog.code(error)}")
      body
  end

  def render(_repository, body), do: body

  @doc """
  Render the `"body"` key of `attrs` in place, when it holds one.

  `OpenAgents.Issues` builds string-keyed attribute maps, so this is the shape
  the write paths actually call.
  """
  @spec render_attrs(Repository.t() | binary() | nil, map()) :: map()
  def render_attrs(repository, attrs) when is_map(attrs) do
    case attrs do
      %{"body" => body} when is_binary(body) -> Map.put(attrs, "body", render(repository, body))
      _no_body -> attrs
    end
  end

  def render_attrs(_repository, attrs), do: attrs

  @doc """
  Rewrite the task lists that point at `changed`, after its state moved.

  `before` and `changed` are the issue either side of the update. Nothing runs
  when the state did not move, so an edited title or a new label rewrites
  nothing. Always returns `:ok`.
  """
  @spec synchronize(Issue.t(), Issue.t()) :: :ok
  def synchronize(before, changed)

  def synchronize(%Issue{state: state}, %Issue{state: state}), do: :ok

  def synchronize(%Issue{}, %Issue{} = changed) do
    written = rewrite_issue_bodies(changed) + rewrite_comment_bodies(changed)

    if written > 0, do: Repositories.broadcast_issues(changed.repository_id)

    :ok
  rescue
    error ->
      # A tracking issue that stayed stale is a smaller failure than a close
      # that did not happen, so this path swallows rather than propagates.
      Logger.warning(
        "issue_task_sync_failed issue=#{changed.number} code=#{OperationalLog.code(error)}"
      )

      :ok
  end

  def synchronize(_before, _changed), do: :ok

  @doc "The automatic task-list edits recorded against one issue, oldest first."
  @spec for_issue(Issue.t()) :: [TaskSync.t()]
  def for_issue(%Issue{id: issue_id}) do
    TaskSync
    |> where([sync], sync.issue_id == ^issue_id)
    |> order_by([sync], asc: sync.inserted_at)
    |> Repo.all()
  end

  def for_issue(_issue), do: []

  # ── internals ────────────────────────────────────────────────────────────

  defp states(repository_id, numbers) do
    Issue
    |> where([issue], issue.repository_id == ^repository_id and issue.number in ^numbers)
    |> select([issue], {issue.number, issue.state})
    |> Repo.all()
    |> Map.new()
  end

  # `ILIKE %#N%` is a superset filter, not the decision: it narrows the rows
  # read to those whose text contains the digits, and `TaskList` then decides
  # whether a real task-list reference to `N` is among them. `#12` matching a
  # body that only says `#120` costs one render that changes nothing.
  defp candidate_pattern(%Issue{number: number}), do: "%#" <> Integer.to_string(number) <> "%"

  defp rewrite_issue_bodies(%Issue{} = changed) do
    Issue
    |> where([issue], issue.repository_id == ^changed.repository_id)
    |> where([issue], ilike(issue.body, ^candidate_pattern(changed)))
    |> order_by([issue], asc: issue.number)
    |> limit(@body_limit)
    |> select([issue], issue.id)
    |> Repo.all()
    |> Enum.count(&rewrite_issue_body(changed, &1))
  end

  defp rewrite_comment_bodies(%Issue{} = changed) do
    Comment
    |> where([comment], comment.repository_id == ^changed.repository_id)
    |> where([comment], ilike(comment.body, ^candidate_pattern(changed)))
    |> order_by([comment], asc: comment.id)
    |> limit(@body_limit)
    |> select([comment], comment.id)
    |> Repo.all()
    |> Enum.count(&rewrite_comment_body(changed, &1))
  end

  # The row is re-read under `FOR UPDATE` and the new body is computed from
  # what the lock returns, never from the row the candidate query saw. That is
  # what stops this write from reverting prose a person saved in between: a
  # concurrent editor either commits before the lock, in which case their text
  # is the text rendered, or waits for it, in which case they render over a
  # body that already agrees with the issue.
  defp rewrite_issue_body(%Issue{} = changed, issue_id) do
    locked(fn ->
      case Repo.one(from issue in Issue, where: issue.id == ^issue_id, lock: "FOR UPDATE") do
        %Issue{body: body} = target when is_binary(body) ->
          apply_rewrite(changed, target.id, nil, body, fn rendered ->
            from(issue in Issue, where: issue.id == ^issue_id)
            |> Repo.update_all(set: [body: rendered, updated_at: now()])
          end)

        _absent ->
          false
      end
    end)
  end

  defp rewrite_comment_body(%Issue{} = changed, comment_id) do
    locked(fn ->
      case Repo.one(from c in Comment, where: c.id == ^comment_id, lock: "FOR UPDATE") do
        %Comment{body: body} = target when is_binary(body) ->
          apply_rewrite(changed, target.issue_id, target.id, body, fn rendered ->
            from(c in Comment, where: c.id == ^comment_id)
            |> Repo.update_all(set: [body: rendered, updated_at: now()])
          end)

        _absent ->
          false
      end
    end)
  end

  defp apply_rewrite(%Issue{} = changed, issue_id, comment_id, body, write) do
    numbers = TaskList.numbers(body)

    with true <- changed.number in numbers,
         rendered when rendered != body <-
           TaskList.render(body, states(changed.repository_id, numbers)) do
      write.(rendered)
      record(changed, issue_id, comment_id)
      true
    else
      _unchanged -> false
    end
  end

  defp record(%Issue{} = changed, issue_id, comment_id) do
    attrs = %{
      repository_id: changed.repository_id,
      issue_id: issue_id,
      comment_id: comment_id,
      reference_issue_id: changed.id,
      reference_number: changed.number,
      checked: changed.state == "closed",
      principal: @principal
    }

    case %TaskSync{} |> TaskSync.changeset(attrs) |> Repo.insert() do
      {:ok, %TaskSync{}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "issue_task_sync_unrecorded issue=#{changed.number} code=#{OperationalLog.code(reason)}"
        )

        :ok
    end
  end

  defp locked(work) do
    case Repo.transaction(work) do
      {:ok, written?} -> written?
      _failed -> false
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
