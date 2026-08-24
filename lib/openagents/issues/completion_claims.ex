defmodule OpenAgents.Issues.CompletionClaims do
  @moduledoc """
  Store what an attempt claims about an issue, grade it, and close the issue
  only when a narrow rule says the claim entails the outcome.

  ## The gap this closes, and the gap it refuses to close

  `#148` bound an issue to the receipts that evaluated its commit. That answers
  "what evaluated this?" and it does not answer "is this done?". A green build
  on a commit whose message names an issue proves the tree compiles. A
  successful deployment proves bytes reached a host. Neither entails that the
  outcome the issue asked for was produced, and a rule that closed an issue on
  either would file a receipt saying work was verified when nothing verified
  it.

  So no receipt closes an issue here. What closes an issue is a *claim*: an
  assertion that names, for each of the issue's acceptance criteria, the
  evidence that satisfied it. Mapping intent to evidence is the one judgment no
  record can make on its own, which is why it is claimed rather than derived —
  and why the rest is derived rather than claimed.

  ## What the caller supplies, and what it cannot

  The caller supplies exactly one thing: the criterion-to-evidence mapping, and
  optionally the false-green classes it names against its own result, which can
  only make the verdict worse. Everything else is read from records:

    * the **issue's** four required sections, parsed from its body;
    * the **attempt's** five binding fields — issue number, repository,
      authority, budget, revision — from `forge_assignments` and the
      `budget_snapshot` on its `work_jobs` row, never from the request, so the
      attempt cannot claim to be bound to an issue it did not run against;
    * the **verifier**, which is the published check result the evidence
      resolves to. It is admitted because publishing a check result is already
      authority-gated (`OpenAgents.Deployments.Authority`), and it is
      independent of the producer unless the same user both requested the
      attempt and published the check;
    * the **falsifier**, which is the observation that would have made the same
      claim red: the same check name, on the same commit and the same artifact
      digest, reporting `failed`. `deployment_check_results` keys on exactly
      that identity, so the falsifying observation is a row that can exist.

  Producer-verifier separation is always required on this path. An agent
  grading its own work is the hazard the whole contract exists for, so it is
  not a knob.

  ## The closure rule

  An issue closes automatically only when every one of these holds:

    1. The repository opted in twice: `agents_enabled` and
       `verified_closing_enabled` (`OpenAgents.Issues.ClosurePolicy`). Both
       default false, and an absent policy row means the same as both false.
    2. `OpenAgents.AcceptedOutcome.evaluate/1` graded the claim `accepted`.
    3. Every acceptance criterion names an `issue_evidence` edge that is a
       **qualification** receipt for **this issue** at **this exact revision**
       whose status is `succeeded`. An edge in any other family, for any other
       revision, or for any other issue satisfies nothing, so the criterion is
       unevidenced and the claim is `incomplete`.
    4. No evidence edge for this issue at this revision carries a failing
       terminal word in any family. A revision that qualified and then failed
       to build is contradicted, and a person decides.
    5. The issue is open. This path never reopens and never changes a closed
       issue's state.

  ### Why only qualification

  `deployment_check_results` is the only family whose row is a *verdict about
  named bytes*: identity is `{repository, name, commit, artifact digest}`, so a
  green result cannot be replayed onto bytes it never examined, and the
  publisher is an authorized principal that is not the attempt. The other three
  record something real and something else:

    * **push** — that the forge received the bytes. It carries no outcome at
      all; its `result` is null.
    * **build** — that the tree compiles at that commit. Necessary for anything
      to work; sufficient for nothing to be done.
    * **deployment** — that an artifact reached an environment. An operational
      fact about placement, not an observation of behavior.

  All four still *record*: they appear on the issue's evidence chain, they are
  what a person reads, and a failing one in any family blocks the automatic
  close by rule 4. Recording is the broad half; closing is the narrow half.

  ## When a later receipt disagrees

  `note_evidence/1` runs where evidence is written. A failing edge arriving for
  an issue and revision an accepted claim already closed stamps
  `contradicted_at` and names the edge. It does **not** reopen the issue:
  reopening on a later signal is a separate policy with its own failure modes
  (`ISSUE-001` draws the same line for reverts). What it does is stop the
  closure reading as uncontested, and rule 4 stops any further close on that
  revision.

  ## One closer, not two

  `OpenAgents.Issues.ClosingReferences` stays the trailer path and is untouched:
  a person wrote `Closes #N`, the pusher's write authority was checked, and the
  commit was reachable from the default branch. That is a human assertion and it
  stays attributed to that person. This path closes only issues that are still
  open, so a trailer close that already happened is recorded here as a claim
  and moves nothing. Neither path reads commit prose —
  `OpenAgents.Forge.CommitReferences` is still the only reader of that.

  A reader tells the two apart by the record, not by the issue: a person's close
  leaves an `issue_closing_references` row with a `closed_by_user_id`; this one
  leaves an `issue_completion_claims` row whose `closed_by_actor` is the system
  principal `system:accepted-outcome` and never a user id.
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.AcceptedOutcome
  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Forge.Assignment
  alias OpenAgents.Issues
  alias OpenAgents.Issues.{ClosurePolicy, CompletionClaim, EvidenceEntry, Issue}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Work.Job

  # The one actor an automatic close is attributed to. It is not a user id and
  # cannot become one, which is the whole distinction between this close and a
  # person's.
  @closing_actor "system:accepted-outcome"

  # The one family whose receipt can satisfy an acceptance criterion. See the
  # moduledoc: the other three record, they do not qualify.
  @closing_family "qualification"

  # A qualification receipt satisfies a criterion only with this status.
  # `pending` is not a verdict, and `failed` is the opposite of one.
  @qualifying_result "succeeded"

  # Each family's own words for "this did not work", read straight from the
  # schemas that own them: `forge_builds.status`, `forge_deploys.result`,
  # `deployment_runs.state`, and `deployment_check_results.status`. A push
  # receipt has no result, so it can never contradict.
  @failing_results %{
    "push" => [],
    "build" => ~w(failed expired),
    "deployment" => ~w(failed reverted needs_rolling_replace cancelled superseded),
    "qualification" => ~w(failed)
  }

  # The issue-body headings the accepted-outcome contract requires. The match is
  # on the heading text, after the semantic question — "is this claim gradeable
  # at all" — has already been settled by the policy read.
  @section_headings %{
    problem: ["problem"],
    scope: ["scope"],
    acceptance_criteria: ["acceptance criteria"],
    success_metrics: ["success metrics"]
  }

  @type verdict :: {:ok, CompletionClaim.t()} | {:error, atom()}

  @doc "The system principal an automatic close is attributed to."
  @spec closing_actor() :: String.t()
  def closing_actor, do: @closing_actor

  @doc "The one receipt family whose evidence can satisfy an acceptance criterion."
  @spec closing_family() :: String.t()
  def closing_family, do: @closing_family

  @doc "The receipt families that can record evidence but never close an issue."
  @spec recording_only_families() :: [String.t()]
  def recording_only_families,
    do: Enum.reject(EvidenceEntry.families(), &(&1 == @closing_family))

  # ── policy ──────────────────────────────────────────────────────────────

  @doc """
  One repository's closure policy, defaulted rather than absent.

  An unconfigured repository reads as both flags false, which is the same
  answer the stored row with both flags false gives. Nothing distinguishes
  silence from a deliberate no, because nothing should.
  """
  @spec policy(Repository.t() | binary()) :: ClosurePolicy.t()
  def policy(%Repository{id: id}), do: policy(id)

  def policy(repository_id) when is_binary(repository_id) do
    Repo.one(from p in ClosurePolicy, where: p.repository_id == ^repository_id) ||
      %ClosurePolicy{
        repository_id: repository_id,
        agents_enabled: false,
        verified_closing_enabled: false
      }
  end

  @doc "Set one repository's closure policy, attributed to the user who set it."
  @spec set_policy(Repository.t(), map(), OpenAgents.Accounts.User.t() | nil) ::
          {:ok, ClosurePolicy.t()} | {:error, Ecto.Changeset.t()}
  def set_policy(%Repository{id: repository_id}, attrs, actor \\ nil) do
    existing =
      Repo.one(from p in ClosurePolicy, where: p.repository_id == ^repository_id) ||
        %ClosurePolicy{}

    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("repository_id", repository_id)
      |> Map.put("updated_by_user_id", actor && actor.id)

    existing |> ClosurePolicy.changeset(attrs) |> Repo.insert_or_update()
  end

  # ── the claim ───────────────────────────────────────────────────────────

  @doc """
  Grade and store one completion claim for a finished attempt.

  `author` is `:agent` or `:human`. A human's claim is `not_applicable` —
  people close their own issues through the ordinary path, and the contract
  gates agent-authored claims only.

  `attrs` carries `:evidence`, a list of `%{criterion: binary, evidence_id:
  binary}`, and optionally `:false_green_classes`. Nothing else in `attrs` is
  read: the attempt's binding, the verifier, and the falsifier are derived from
  records so that a claim cannot assert its own authority.

  Returns the stored claim. A non-accepted verdict is stored too — a typed
  refusal on the record is the point, not silence.
  """
  @spec submit(Assignment.t(), :agent | :human, map()) :: verdict()
  def submit(%Assignment{} = assignment, author, attrs \\ %{})
      when author in [:agent, :human] do
    with {:ok, assignment} <- terminal_attempt(assignment),
         {:ok, repository} <- fetch(Repository, assignment.repository_id),
         {:ok, issue} <- fetch_issue(assignment.issue_id) do
      revision = String.downcase(assignment.terminal_commit)
      policy = policy(repository)
      references = evidence_references(issue, revision, attrs)

      claim =
        build_claim(
          author,
          policy,
          repository,
          issue,
          assignment,
          revision,
          references,
          attrs
        )

      persist(repository, issue, assignment, revision, AcceptedOutcome.evaluate(claim), policy)
    end
  end

  @doc "The claims recorded against one issue, oldest first."
  @spec for_issue(Issue.t() | integer()) :: [map()]
  def for_issue(%Issue{id: id}), do: for_issue(id)

  def for_issue(issue_id) when is_integer(issue_id) do
    CompletionClaim
    |> where([claim], claim.issue_id == ^issue_id)
    |> order_by([claim], asc: claim.inserted_at, asc: claim.id)
    |> Repo.all()
    |> Enum.map(&summary/1)
  end

  @doc """
  Claims for a whole page of issues, keyed by issue id.

  One query for the page, the way `OpenAgents.Issues.Evidence.for_issues/1`
  reads evidence, so listing issues does not cost one query per row.
  """
  @spec for_issues([Issue.t()]) :: %{integer() => [map()]}
  def for_issues(issues) when is_list(issues) do
    ids = Enum.map(issues, & &1.id)
    base = Map.new(ids, &{&1, []})

    CompletionClaim
    |> where([claim], claim.issue_id in ^ids)
    |> order_by([claim], asc: claim.inserted_at, asc: claim.id)
    |> Repo.all()
    |> Enum.reduce(base, fn claim, acc ->
      Map.update(acc, claim.issue_id, [summary(claim)], &(&1 ++ [summary(claim)]))
    end)
  end

  @doc """
  The bounded projection of one stored claim.

  It carries the verdict, the typed reasons, the criterion names, the public
  receipt references, and the close. It never carries a prompt, a log, a
  private repository name, or a private receipt reference, because the criteria
  it stores were already reduced to that shape by
  `OpenAgents.AcceptedOutcome.public_projection/1` before the row was written.
  """
  @spec summary(CompletionClaim.t()) :: map()
  def summary(%CompletionClaim{} = claim) do
    %{
      id: claim.id,
      revision: claim.revision,
      state: claim.state,
      reasons: claim.reasons,
      criteria: claim.criteria,
      verifier: claim.verifier,
      falsifier: claim.falsifier,
      closed: claim.closed,
      closed_at: claim.closed_at,
      closed_by_actor: claim.closed_by_actor,
      contradicted_at: claim.contradicted_at,
      contradiction_reason: claim.contradiction_reason,
      recorded_at: claim.inserted_at
    }
  end

  @doc """
  Mark the accepted claims one new evidence edge contradicts.

  Called where evidence is written. A failing edge for an issue and revision an
  accepted claim rested on stamps the claim; nothing else moves, and the issue
  is never reopened. Never raises and never fails the receipt that produced it.
  """
  @spec note_evidence(EvidenceEntry.t()) :: :ok
  def note_evidence(%EvidenceEntry{} = entry) do
    if failing?(entry) do
      now = DateTime.utc_now()

      {_count, _rows} =
        CompletionClaim
        |> where([claim], claim.issue_id == ^entry.issue_id)
        |> where([claim], claim.revision == ^String.downcase(entry.commit_sha))
        |> where([claim], claim.state == "accepted" and is_nil(claim.contradicted_at))
        |> Repo.update_all(
          set: [
            contradicted_at: now,
            contradicted_by_evidence_id: entry.id,
            contradiction_reason: "#{entry.family}:#{entry.result}",
            updated_at: now
          ]
        )

      :ok
    else
      :ok
    end
  end

  def note_evidence(_entry), do: :ok

  @doc "Whether one evidence edge carries its family's word for failure."
  @spec failing?(EvidenceEntry.t()) :: boolean()
  def failing?(%EvidenceEntry{family: family, result: result}) when is_binary(result) do
    result in Map.get(@failing_results, family, [])
  end

  def failing?(%EvidenceEntry{}), do: false

  # ── building the claim from records ─────────────────────────────────────

  defp build_claim(author, policy, repository, issue, assignment, revision, references, attrs) do
    %{
      actor: if(author == :agent, do: :agent, else: :human),
      agents_enabled: policy.agents_enabled,
      issue: %{
        number: issue.number,
        repository: "#{repository.owner}/#{repository.name}",
        sections: sections(issue.body)
      },
      attempt: %{
        issue_number: issue.number,
        repository: "#{repository.owner}/#{repository.name}",
        authority: authority(assignment),
        budget: budget(assignment),
        revision: revision
      },
      verification: %{
        verifier: verifier(references, assignment),
        falsifier: falsifier(references),
        terminal_result: terminal_result(references),
        separation_required: true,
        false_green_classes: named_false_greens(attrs)
      },
      evidence:
        Enum.map(references, fn reference ->
          %{
            criterion: reference.criterion,
            receipt: reference.receipt,
            visibility: reference.visibility
          }
        end)
    }
  end

  # The five attempt fields the contract binds come from records, never from
  # the request. Two of them are the issue and the repository, which is why
  # `attempt_not_bound_to_issue` cannot fire on this path: an attempt that ran
  # against another issue is a different `forge_assignments` row and produces a
  # different claim.
  defp authority(%Assignment{requesting_principal: %{"type" => type, "id" => id}})
       when is_binary(type) and is_binary(id),
       do: "#{type}:#{id}"

  defp authority(%Assignment{}), do: nil

  defp budget(%Assignment{work_job_id: nil}), do: nil

  defp budget(%Assignment{work_job_id: job_id}) do
    case Repo.one(from job in Job, where: job.id == ^job_id, select: job.budget_snapshot) do
      snapshot when is_map(snapshot) and map_size(snapshot) > 0 -> snapshot
      _absent -> nil
    end
  end

  # Only edges this issue already owns, at this exact revision, in the one
  # family that qualifies, with the one status that qualifies. A reference to
  # anything else resolves to no receipt, so the criterion it names is
  # unevidenced and the claim is `incomplete` — which is the contract's own way
  # of saying "a build is not a verdict".
  defp evidence_references(%Issue{} = issue, revision, attrs) do
    requested =
      attrs
      |> Map.get(:evidence, Map.get(attrs, "evidence", []))
      |> List.wrap()
      |> Enum.map(&normalize_reference/1)
      |> Enum.reject(&is_nil/1)

    ids = requested |> Enum.map(& &1.evidence_id) |> Enum.reject(&is_nil/1)

    qualifying =
      if ids == [] do
        %{}
      else
        EvidenceEntry
        |> where([entry], entry.id in ^ids)
        |> where([entry], entry.issue_id == ^issue.id)
        |> where([entry], entry.commit_sha == ^revision)
        |> where([entry], entry.family == ^@closing_family)
        |> where([entry], entry.result == ^@qualifying_result)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    Enum.map(requested, fn reference ->
      entry = Map.get(qualifying, reference.evidence_id)

      %{
        criterion: reference.criterion,
        entry: entry,
        receipt: entry && entry.id,
        visibility: visibility(issue)
      }
    end)
  end

  defp normalize_reference(%{} = reference) do
    criterion = reference[:criterion] || reference["criterion"]
    evidence_id = reference[:evidence_id] || reference["evidence_id"]

    case {present(criterion), cast_id(evidence_id)} do
      {nil, _id} -> nil
      {criterion, id} -> %{criterion: criterion, evidence_id: id}
    end
  end

  defp normalize_reference(_reference), do: nil

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  # A public repository's receipt references are publishable; a private
  # repository's are not, and the projection renders them as `:private` without
  # the reference. The visibility is read from the repository rather than from
  # the caller for the same reason everything else here is.
  defp visibility(%Issue{repository_id: repository_id}) do
    case Repo.one(from r in Repository, where: r.id == ^repository_id, select: r.visibility) do
      "public" -> :public
      _private_or_absent -> :private
    end
  end

  # The verifier is the check result the evidence resolves to, never a name the
  # caller supplied. It is admitted because publishing a check result is
  # already authority-gated; it is independent unless the same user both
  # requested the attempt and published the check.
  defp verifier(references, %Assignment{} = assignment) do
    case check_results(references) do
      [] ->
        %{}

      results ->
        %{
          id: results |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort() |> Enum.join(","),
          admitted: true,
          independent_of_producer: Enum.all?(results, &independent?(&1, assignment))
        }
    end
  end

  defp independent?(%CheckResult{published_by_user_id: nil}, %Assignment{}), do: true

  defp independent?(%CheckResult{published_by_user_id: publisher}, %Assignment{} = assignment) do
    authority(assignment) != "user:#{publisher}"
  end

  # What observation would have made this red: the same check name, on the same
  # commit and the same artifact digest, reporting `failed`.
  # `deployment_check_results_identity_index` keys on exactly that tuple, so the
  # falsifying observation is a row that can exist rather than a sentence.
  defp falsifier(references) do
    case check_results(references) do
      [] ->
        nil

      results ->
        results
        |> Enum.map(&"deployment_check_results:#{&1.name}@#{&1.artifact_digest}=failed")
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.join(" ")
        |> String.slice(0, 500)
    end
  end

  defp terminal_result(references) do
    entries = references |> Enum.map(& &1.entry) |> Enum.reject(&is_nil/1)

    if entries != [] and Enum.all?(entries, &(&1.result == @qualifying_result)),
      do: :passed,
      else: :failed
  end

  defp check_results(references) do
    ids =
      references
      |> Enum.map(& &1.entry)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.receipt_id)
      |> Enum.uniq()

    if ids == [], do: [], else: Repo.all(from r in CheckResult, where: r.id in ^ids)
  end

  # Self-reported, and deliberately the one thing a caller may add: naming a
  # false-green class against your own result can only make the verdict worse.
  defp named_false_greens(attrs) do
    attrs
    |> Map.get(:false_green_classes, Map.get(attrs, "false_green_classes", []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in AcceptedOutcome.false_green_classes()))
  end

  # ── issue sections ──────────────────────────────────────────────────────

  # Deterministic parsing of a bounded field, after the question of whether to
  # grade at all has been answered by the stored policy. It reads Markdown ATX
  # headings and nothing else: a section is present when its heading exists and
  # some non-blank line follows it before the next heading.
  defp sections(body) when is_binary(body) do
    lines = String.split(body, ~r/\r?\n/)

    @section_headings
    |> Enum.reduce(%{}, fn {section, headings}, acc ->
      Map.put(acc, section, section_body(lines, headings))
    end)
  end

  defp sections(_body), do: %{}

  defp section_body(lines, headings) do
    lines
    |> Enum.drop_while(&(not heading_matching?(&1, headings)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not heading?(&1)))
    |> Enum.map(&strip_marker/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      content -> content
    end
  end

  # A criterion is the sentence, not the bullet that carries it. An acceptance
  # criterion written `- [ ] the thing` and the same criterion named in a claim
  # have to be the same string, or every criterion would read as unevidenced
  # for a reason that is about Markdown rather than about the work.
  defp strip_marker(line) do
    line
    |> String.trim()
    |> String.replace(~r/\A(?:[-*+]|\d+\.)\s+/, "")
    |> String.replace(~r/\A\[[ xX]\]\s+/, "")
    |> String.trim()
  end

  defp heading?(line), do: Regex.match?(~r/\A\s{0,3}\#{1,6}\s+/, line)

  defp heading_matching?(line, headings) do
    case Regex.run(~r/\A\s{0,3}\#{1,6}\s+(.+?)\s*\#*\s*\z/, line) do
      [_line, text] -> normalize_heading(text) in headings
      nil -> false
    end
  end

  defp normalize_heading(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  # ── storing the verdict, and the close ──────────────────────────────────

  defp persist(repository, issue, assignment, revision, evaluation, policy) do
    projection = AcceptedOutcome.public_projection(evaluation)
    {state, reasons} = verdict(evaluation)
    withheld = if state == "accepted", do: closure_block(issue, revision, policy), else: nil
    close? = state == "accepted" and is_nil(withheld) and issue.state == "open"
    now = DateTime.utc_now()

    attrs = %{
      "repository_id" => repository.id,
      "issue_id" => issue.id,
      "assignment_id" => assignment.id,
      "revision" => revision,
      "state" => state,
      "reasons" => reasons ++ List.wrap(withheld),
      "criteria" => criteria(projection),
      "verifier" => verifier_id(evaluation),
      "falsifier" => falsifier_of(evaluation),
      "closed" => close?,
      "closed_at" => if(close?, do: now),
      "closed_by_actor" => if(close?, do: @closing_actor)
    }

    Repo.transaction(fn ->
      claim =
        case existing(issue, assignment, revision) do
          nil -> %CompletionClaim{}
          %CompletionClaim{} = found -> found
        end
        |> CompletionClaim.changeset(attrs)
        |> Repo.insert_or_update()

      case claim do
        {:ok, stored} -> if close?, do: close(issue, stored), else: stored
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, %CompletionClaim{} = stored} ->
        {:ok, stored}

      {:error, reason} ->
        Logger.warning(
          "issue_completion_claim_failed issue=#{issue.number} code=#{OpenAgents.OperationalLog.code(reason)}"
        )

        {:error, :claim_not_recorded}
    end
  end

  # The close and the record land together. A failure anywhere rolls both back,
  # so a claim can never say it closed an issue that stayed open, which is the
  # same discipline `ClosingReferences` holds for the trailer path.
  defp close(%Issue{} = issue, %CompletionClaim{} = claim) do
    case Issues.update_issue(issue, %{"state" => "closed", "state_reason" => "completed"}, nil) do
      {:ok, _closed} -> claim
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Rule 4. An accepted claim on a revision that also carries a failing receipt
  # in any family records the verdict and withholds the close, because two
  # receipts about the same bytes disagree and no rule here is entitled to pick
  # one.
  defp closure_block(%Issue{} = issue, revision, %ClosurePolicy{} = policy) do
    cond do
      not policy.verified_closing_enabled ->
        "closure_withheld:repository_has_not_opted_in"

      contradicted?(issue, revision) ->
        "closure_withheld:contradicting_evidence"

      issue.state != "open" ->
        "closure_withheld:issue_already_closed"

      true ->
        nil
    end
  end

  defp contradicted?(%Issue{id: issue_id}, revision) do
    EvidenceEntry
    |> where([entry], entry.issue_id == ^issue_id and entry.commit_sha == ^revision)
    |> Repo.all()
    |> Enum.any?(&failing?/1)
  end

  defp existing(%Issue{id: issue_id}, %Assignment{id: assignment_id}, revision) do
    Repo.one(
      from claim in CompletionClaim,
        where:
          claim.issue_id == ^issue_id and claim.assignment_id == ^assignment_id and
            claim.revision == ^revision
    )
  end

  defp verdict({:accepted, _outcome}), do: {"accepted", []}
  defp verdict({:not_applicable, exemption}), do: {"not_applicable", ["#{exemption}"]}

  defp verdict({:not_accepted, type, reasons}),
    do: {"#{type}", Enum.map(reasons, &render_reason/1)}

  defp render_reason({key, detail}) when is_list(detail),
    do: "#{key}:#{Enum.join(Enum.map(detail, &to_string/1), ",")}"

  defp render_reason({key, detail}), do: "#{key}:#{detail}"
  defp render_reason(reason), do: to_string(reason)

  defp criteria(%{criteria: criteria}) when is_list(criteria) do
    Enum.map(criteria, fn item ->
      %{
        "criterion" => to_string(item.criterion),
        "evidence" => if(item.evidence == :private, do: nil, else: to_string(item.evidence)),
        "visibility" => if(item.evidence == :private, do: "private", else: "public")
      }
    end)
  end

  defp criteria(_projection), do: []

  defp verifier_id({:accepted, outcome}),
    do: outcome.verifier && String.slice(outcome.verifier, 0, 200)

  defp verifier_id(_evaluation), do: nil

  defp falsifier_of({:accepted, outcome}), do: outcome.falsifier
  defp falsifier_of(_evaluation), do: nil

  # ── loading ─────────────────────────────────────────────────────────────

  defp terminal_attempt(%Assignment{id: id}) do
    case Repo.get(Assignment, id) do
      %Assignment{terminal_commit: commit} = assignment when is_binary(commit) ->
        if Assignment.terminal?(assignment),
          do: {:ok, assignment},
          else: {:error, :claim_attempt_not_terminal}

      %Assignment{} ->
        {:error, :claim_attempt_has_no_revision}

      nil ->
        {:error, :claim_attempt_not_found}
    end
  end

  defp fetch(schema, id) do
    case id && Repo.get(schema, id) do
      nil -> {:error, :claim_attempt_not_found}
      record -> {:ok, record}
    end
  end

  defp fetch_issue(nil), do: {:error, :claim_attempt_not_found}

  defp fetch_issue(issue_id) do
    case Repo.get(Issue, issue_id) do
      nil -> {:error, :claim_attempt_not_found}
      %Issue{} = issue -> {:ok, issue}
    end
  end
end
