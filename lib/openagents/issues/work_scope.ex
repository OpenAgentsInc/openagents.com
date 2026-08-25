defmodule OpenAgents.Issues.WorkScope do
  @moduledoc """
  The bound an issue sets on an attempt to do it.

  Starting agent work from an issue is only meaningfully different from
  starting agent work beside an issue if the issue is what bounds the work.
  Before this module the objective came from the issue on one surface and from
  the caller on the other, and the wall clock came from the caller on both —
  so two attempts on the same issue could have been asked different questions
  and given different amounts of time to answer them.

  Every attempt now takes its scope and its limits from here, at
  `OpenAgents.Forge.Assignments.create/1`, which is the single admission point
  both the issue page and the API pass through.

  ## The scope

  `objective/1` is the prompt, written from the issue's own title and body. A
  caller may not widen it, because an agent asked to do something the issue
  does not say is producing work no reader of that issue asked for.

  `branch/1` is `agent/issue-<number>`. The attempt's credential is scoped to
  that one ref, so the branch is part of the bound rather than a convention.

  ## The limits

  `wall_clock_ms/1` is where the issue's own text decides what the work is
  worth. `OUTCOME-001` says a claim against an issue that does not state its
  problem, scope, acceptance criteria, and success metrics is `incomplete` and
  can never be accepted. An unscoped issue therefore cannot buy delivery: no
  amount of agent time on it can produce a graded outcome. It buys exploration
  instead — long enough to read the repository and say what the issue is
  missing, and not long enough to spend an hour of a machine on work nothing
  can accept.

  A scoped issue buys the full hour. That number is a ceiling, not a
  reservation: `deadline_at` may still be narrowed by the caller, and by the
  `:box_api` TTL. What a caller may never do is widen it, which is the whole
  difference between a bound and a suggestion.

  The bound outlives the request. It becomes `timeout_ms` on the delegation,
  which becomes `wall_clock_ms` in `work_jobs.budget_snapshot`, which is the
  `budget` field `OUTCOME-001` grades the attempt's binding against. So the
  issue's own scope is what the attempt is later held to, through records
  rather than through a parameter that was true once.

  The scope is read with `OpenAgents.Issues.CompletionClaims.sections/1` — the
  grader's own parser, not a second one. If the two ever disagreed about
  whether an issue is scoped, an attempt could buy a budget for work its own
  grader would refuse.
  """

  alias OpenAgents.Issues.CompletionClaims
  alias OpenAgents.Issues.Issue
  alias OpenAgents.AcceptedOutcome

  # `ComputerAgentJobs` refuses a prompt over 8,000 bytes. The body is clamped
  # well inside that so a long issue is trimmed rather than refused.
  @maximum_body_bytes 6_000

  # The ceiling `ComputerAgentJobs` already enforces for any delegation.
  @scoped_ms 3_600_000

  # Long enough to read a repository and report what the issue does not say.
  @unscoped_ms 900_000

  @typedoc "What an issue bounds an attempt on it to."
  @type t :: %{
          branch: String.t(),
          objective: String.t(),
          wall_clock_ms: pos_integer(),
          scoped?: boolean(),
          missing_sections: [atom()]
        }

  @doc "The whole bound, for one issue."
  @spec for_issue(Issue.t()) :: t()
  def for_issue(%Issue{} = issue) do
    missing = missing_sections(issue)

    %{
      branch: branch(issue),
      objective: objective(issue),
      wall_clock_ms: if(missing == [], do: @scoped_ms, else: @unscoped_ms),
      scoped?: missing == [],
      missing_sections: missing
    }
  end

  @doc "The one branch an attempt on `issue` may write."
  @spec branch(Issue.t()) :: String.t()
  def branch(%Issue{number: number}), do: "agent/issue-#{number}"

  @doc """
  The prompt for an attempt on `issue`, written from the issue.

  It names the branch the credential is scoped to, so an agent is not left to
  discover its one writable ref by being refused. `branch` is the branch the
  attempt was actually admitted on, which is `branch/1` unless the requester
  named another; passing it is what keeps the prompt from telling an agent to
  push somewhere its credential cannot reach.
  """
  @spec objective(Issue.t(), String.t() | nil) :: String.t()
  def objective(issue, branch \\ nil)

  def objective(%Issue{} = issue, requested) do
    body = issue.body || ""
    body = if byte_size(body) > @maximum_body_bytes, do: clamp(body), else: body
    branch = if is_binary(requested) and requested != "", do: requested, else: branch(issue)

    """
    Do the work issue ##{issue.number} describes, and nothing beyond it.

    Title: #{issue.title}

    #{body}

    Commit your work on the branch `#{branch}`, which is the only branch you \
    are authorized to write. Push it when the work is done.
    """
    |> String.trim()
  end

  @doc "The wall clock `issue` buys, in milliseconds."
  @spec wall_clock_ms(Issue.t()) :: pos_integer()
  def wall_clock_ms(%Issue{} = issue),
    do: if(scoped?(issue), do: @scoped_ms, else: @unscoped_ms)

  @doc "The wall clock a fully scoped issue buys."
  @spec scoped_wall_clock_ms() :: pos_integer()
  def scoped_wall_clock_ms, do: @scoped_ms

  @doc "The wall clock an issue missing any accepted-outcome section buys."
  @spec unscoped_wall_clock_ms() :: pos_integer()
  def unscoped_wall_clock_ms, do: @unscoped_ms

  @doc "Whether `issue` states every section `OUTCOME-001` requires."
  @spec scoped?(Issue.t()) :: boolean()
  def scoped?(%Issue{} = issue), do: missing_sections(issue) == []

  @doc """
  The accepted-outcome sections `issue` does not state, in contract order.

  An empty list is the scoped issue. Anything else is what a person has to
  write before an attempt on this issue can end in an accepted outcome, which
  is worth naming on the page rather than discovering at grading time.
  """
  @spec missing_sections(Issue.t()) :: [atom()]
  def missing_sections(%Issue{} = issue) do
    stated = CompletionClaims.sections(issue.body)

    Enum.reject(AcceptedOutcome.required_issue_sections(), fn section ->
      case Map.get(stated, section) do
        nil -> false
        [] -> false
        _stated -> true
      end
    end)
  end

  # Clamp on a character boundary: `binary_part/3` can cut a multi-byte
  # grapheme in half, and an invalid UTF-8 prompt is refused by
  # `ComputerAgentJobs.validate_prompt/1` for a reason that has nothing to do
  # with the issue being long.
  defp clamp(body) do
    body
    |> binary_part(0, @maximum_body_bytes)
    |> String.chunk(:valid)
    |> case do
      [valid | _rest] -> valid
      [] -> ""
    end
  end
end
