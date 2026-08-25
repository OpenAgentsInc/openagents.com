defmodule OpenAgents.Issues.TraceDisclosure do
  @moduledoc """
  What an issue's readers learn about the ATIF trajectories of its attempts.

  ## The decision

  **An issue publishes that a trace exists and what shape it has. It never
  publishes the trace.**

  An ATIF document is the whole run — every prompt, every assistant message,
  every tool call's raw arguments, every tool result. Handing that to an issue's
  readers would restate the contents of a repository, and the reasoning the
  agent did about it, in a place the repository's own gate does not cover.
  `OpenAgents.Transparency.WorkDisclosure` already refuses `work_jobs.goal` and
  `work_jobs.delegation` for exactly that reason, and a trajectory carries more
  of it than either. So the `trace` family's schedule stops at the digest, and
  no rung of it returns a step.

  That is also why this is not a readback. `EXIT-001` publishes, to anonymous
  callers, that `POST /api/v1/traces` accepts an upload and no route reads one
  back. This projection does not close that gap and must not be mistaken for
  closing it: nobody gets a document here, including the account that uploaded
  one.

  ## Two gates, and both must pass

  Consent and repository access are independent, and neither substitutes for
  the other.

    * **Consent** is `traces.visibility`, which the uploader sets and which
      defaults to `dark`. A `dark` trace is invisible on an issue no matter who
      is reading — an operator included. Consent is a ceiling this module
      never raises, only lowers.

    * **Repository access** is `OpenAgents.Repositories`, applied by the caller
      before this module is reached, exactly as `OpenAgents.Issues.Activity`
      applies it to receipts. A reader who cannot read the repository sees no
      traces, however widely the uploader consented, because the uploader
      consented to publishing their own trajectory and not to publishing which
      attempts ran in somebody else's private repository.

  The effective tier is the lower of the two, then clamped again by the
  viewer's own relationship to the repository through
  `WorkDisclosure.effective_tier/2`. Lowering twice and raising never is what
  makes the composition safe to reason about: adding a gate can only remove
  fields.

  ## Why the trace names the attempt

  A trace carries `assignment_id`, not `issue_id`. The attempt already records
  which issue and which repository it was admitted against, so binding to the
  attempt gives the issue its traces and gives the repository gate something to
  act on, without the issue gaining a second work record — the same reason
  `forge_assignments.work_job_id` points at the execution rather than the issue
  pointing at both.
  """

  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Traces
  alias OpenAgents.Traces.Trace
  alias OpenAgents.Transparency
  alias OpenAgents.Transparency.WorkDisclosure

  @family :trace

  @typedoc "One trace, projected at the tier both gates admit."
  @type projection :: %{
          required(:assignment_id) => binary(),
          required(:tier) => atom(),
          optional(atom()) => term()
        }

  @doc "The disclosure family this module projects."
  @spec family() :: atom()
  def family, do: @family

  @doc """
  The traces of `attempts`, projected for `viewer`.

  `attempts` are `forge_assignments` rows for one issue, and `viewer` is a
  `WorkDisclosure.viewer/2` descriptor — the caller has already applied
  repository authority to produce it. Returns one entry per disclosable trace,
  oldest first, each naming the attempt it belongs to.

  A trace whose two gates leave it at `dark` is absent rather than empty: an
  empty shell would still say the trajectory exists, which is the disclosure
  `dark` is refusing.
  """
  @spec for_attempts([Assignment.t()], map()) :: [projection()]
  def for_attempts([], _viewer), do: []

  def for_attempts(attempts, viewer) when is_list(attempts) do
    by_attempt = Traces.for_assignments(Enum.map(attempts, & &1.id))

    attempts
    |> Enum.flat_map(fn attempt ->
      by_attempt
      |> Map.get(attempt.id, [])
      |> Enum.map(&project(&1, attempt, viewer))
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Projects one trace of one attempt for `viewer`, or `nil` at `dark`.

  The tier is the lower of the uploader's consent and the attempt's own
  effective tier, and the projection carries the tier it was taken at so a
  reader can tell a withheld field from an absent one.
  """
  @spec project(Trace.t(), Assignment.t(), map()) :: projection() | nil
  def project(%Trace{} = trace, %Assignment{} = attempt, viewer) do
    tier = effective_tier(trace, attempt, viewer)

    case WorkDisclosure.project(@family, source(trace), tier) do
      nil ->
        nil

      fields ->
        fields
        |> Map.put(:assignment_id, attempt.id)
        |> Map.put(:tier, tier)
    end
  end

  @doc """
  The tier both gates admit for `trace` on `attempt`, for `viewer`.

  Consent is a ceiling: `Transparency.effective_tier/2` clamps the uploader's
  own tier by the viewer's, and the attempt's tier clamps it again. The result
  is never higher than either input, so a reader admitted to a wide attempt
  still gets nothing from a `dark` trace, and a reader of a widely consented
  trace still gets nothing from an attempt they may not read.
  """
  @spec effective_tier(Trace.t(), Assignment.t(), map()) :: atom()
  def effective_tier(%Trace{visibility: visibility}, %Assignment{} = attempt, viewer) do
    lower(
      Transparency.effective_tier(visibility, viewer),
      WorkDisclosure.effective_tier(attempt, viewer)
    )
  end

  defp lower(left, right) do
    if rank(left) <= rank(right), do: left, else: right
  end

  defp rank(:dark), do: 0
  defp rank(:pulse), do: 1
  defp rank(:ledger), do: 2
  defp rank(:glass), do: 3
  defp rank(_unknown), do: 0

  # The two derived fields, read out of the document that is never returned.
  # `step_count` counts what ATIF calls steps; a document that carries none, or
  # carries something other than a list where steps go, reports zero rather
  # than raising, because an uploader's malformed document must not break an
  # issue page.
  defp source(%Trace{} = trace) do
    document = trace.document || %{}

    %{
      id: trace.id,
      schema_version: schema_version(document),
      step_count: step_count(document),
      recorded_at: trace.inserted_at,
      digest: trace.digest,
      byte_size: trace.byte_size
    }
  end

  defp schema_version(document) do
    case Map.get(document, "schema_version") do
      version when is_binary(version) -> version
      _absent -> nil
    end
  end

  defp step_count(document) do
    case Map.get(document, "steps") do
      steps when is_list(steps) -> length(steps)
      _absent -> 0
    end
  end
end
