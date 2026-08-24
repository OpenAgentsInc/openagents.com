defmodule OpenAgents.Issues.Evidence do
  @moduledoc """
  Bind an issue to the receipts that evaluated the exact commit its work
  produced.

  The commit-to-receipt chain was already complete before this module existed,
  and already joined — by sha, never by issue. `OpenAgents.Forge.receipts_for/2`
  returns every push, build, target, and deploy receipt for a sha, and
  `changelog_entries` carries four receipt ids in one row. What none of them
  carried was an issue. This module adds that one edge and nothing else.

  ## Two directions that meet

  Evidence arrives in either order, and neither order is wrong:

    * a **receipt** lands for a commit that an issue already claims, and
    * an **attempt** reports the revision it produced for a commit whose
      receipts already exist.

  So there are two entry points. `record/1` is the receipt side: given a
  receipt, it finds the issues that claim its commit and appends one row for
  each. `bind_attempt/1` is the attempt side: given a finished attempt with a
  terminal commit, it sweeps the receipt tables for that exact sha and appends
  whatever already exists. Both are idempotent against the same unique index,
  so the two directions meeting in the middle writes one row, not two.

  Neither direction scans a window. `Forge.receipts_for/2` and the changelog's
  receipt index scan bounded windows and honestly return empty for an older
  commit; this module queries `{repo, sha}` and `{repository_id, commit_sha}`
  through indexes, so a commit's age never changes the answer.

  ## Which issues claim a commit

  Two sources, and no third. There is no second commit-to-issue extractor here:

    * `issue_closing_references` — the authoritative half. `#130` reads the
      trailer, verifies the pusher can write the issue, and requires the commit
      to be reachable from the default branch before recording anything.
      `OpenAgents.Forge.CommitReferences` is the one reader of commit prose in
      this application and stays that way.
    * `forge_assignments.terminal_commit` — the attempt's own self-report of
      the revision it produced. Weaker, because it is the executor's claim
      rather than a merge, and recorded as such in `source`.

  A commit claimed by both records once, attributed to the trailer, because the
  merge is the stronger fact.

  ## What it refuses

  A receipt is evidence for the commit and the environment it names, and for no
  other. `record/1` re-reads the receipt row and refuses a caller that names a
  different commit (`:evidence_commit_mismatch`) or a different environment
  (`:evidence_environment_mismatch`). A receipt id from one family looked up in
  another family's table is not found, which is why a push receipt can never be
  recorded as a deployment receipt.

  Nothing here deletes. A failed build, a reverted deployment, a cancelled
  attempt, and a superseded run all keep their edge, with the receipt's own
  terminal word in `result`. An issue's history is what happened, not what
  worked.
  """

  import Ecto.Query

  require Logger

  alias OpenAgents.Deployments.CheckResult
  alias OpenAgents.Deployments.Request, as: DeploymentRequest
  alias OpenAgents.Deployments.Run, as: DeploymentRun
  alias OpenAgents.Forge.{Assignment, BuildReceipt, DeployReceipt, PushReceipt}
  alias OpenAgents.Forge.ReceiptRepository
  alias OpenAgents.Issues.{ClosingReference, CompletionClaims, EvidenceEntry, Issue}
  alias OpenAgents.Repo
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Transparency.WorkDisclosure

  # See `OpenAgents.Forge.Assignments`: an internal caller reads the record,
  # not a projection of it. Every reader-facing surface passes a real viewer.
  @unclamped %{account_id: nil, tier: :glass, admin: true}

  # The forge release plane converges one fleet. Naming it rather than leaving
  # it blank is what lets the environment refusal mean something on both planes.
  @fleet "fleet"

  # No one commit carries more evidence than this. The cap bounds the work one
  # receipt can ask of the issue tracker when a commit closes many issues.
  @claimant_limit 64

  @doc """
  Append the evidence one receipt gives every issue that claims its commit.

  `attrs` names the `:family`, the `:receipt_id`, and the `:actor`. The commit,
  the repository, the plane, the environment, and the result are read from the
  receipt row itself, so a caller cannot relabel evidence by asserting them.
  Pass `:commit_sha` or `:environment` to assert what the receipt should say,
  and the call is refused when it says otherwise.

  Returns `{:ok, entries}` with the rows this call wrote, which is `[]` when no
  issue claims the commit and when every edge already existed.
  """
  @spec record(map()) :: {:ok, [EvidenceEntry.t()]} | {:error, atom()}
  def record(attrs) when is_map(attrs) do
    with {:ok, family} <- family(attrs),
         {:ok, receipt_id} <- receipt_id(attrs),
         {:ok, facts} <- receipt_facts(family, receipt_id),
         :ok <- assert_commit(facts, attrs[:commit_sha] || attrs["commit_sha"]),
         :ok <- assert_environment(facts, attrs[:environment] || attrs["environment"]) do
      {:ok, append(facts, actor(attrs))}
    end
  end

  @doc """
  Append the evidence that already exists for a finished attempt's revision.

  An attempt reports the exact commit it produced; that commit may already have
  been pushed, built, qualified, and deployed. This sweeps each receipt family
  by `{repo, sha}` and records what it finds, so an attempt that finishes after
  its receipts does not lose them.

  Never raises and never fails the attempt that called it. An assignment that
  finished is finished whether or not its evidence could be written.
  """
  @spec bind_attempt(Assignment.t()) :: [EvidenceEntry.t()]
  def bind_attempt(%Assignment{terminal_commit: commit} = assignment)
      when is_binary(commit) do
    case Repo.get(Repository, assignment.repository_id) do
      %Repository{} = repository -> sweep(repository, commit, assignment)
      nil -> []
    end
  rescue
    error ->
      Logger.warning(
        "issue_evidence_attempt_bind_failed code=#{OpenAgents.OperationalLog.code(error)}"
      )

      []
  end

  def bind_attempt(%Assignment{}), do: []

  @doc """
  The evidence recorded against one issue, oldest first.

  The issue is the requested outcome and never becomes a work record. This
  reads edges, so an issue with no evidence returns an empty list rather than
  an absent fact.
  """
  @spec for_issue(Issue.t() | integer(), map()) :: [map()]
  def for_issue(issue_id, viewer \\ @unclamped)

  def for_issue(%Issue{id: id}, viewer), do: for_issue(id, viewer)

  def for_issue(issue_id, viewer) when is_integer(issue_id) do
    EvidenceEntry
    |> where([entry], entry.issue_id == ^issue_id)
    |> order_by([entry], asc: entry.inserted_at, asc: entry.id)
    |> preload(:artifact_link)
    |> Repo.all()
    |> Enum.map(&summary(&1, viewer))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Evidence for a whole page of issues, keyed by issue id.

  One query for the page, the way `OpenAgents.Forge.Assignments.attempts_for_issues/1`
  reads attempts, so listing issues does not cost one query per row. Every issue
  in `issues` appears in the result, with `[]` when it has no evidence.
  """
  @spec for_issues([Issue.t()], map()) :: %{integer() => [map()]}
  def for_issues(issues, viewer \\ @unclamped) when is_list(issues) do
    ids = Enum.map(issues, & &1.id)
    base = Map.new(ids, &{&1, []})

    EvidenceEntry
    |> where([entry], entry.issue_id in ^ids)
    |> order_by([entry], asc: entry.inserted_at, asc: entry.id)
    |> preload(:artifact_link)
    |> Repo.all()
    |> Enum.reduce(base, fn entry, acc ->
      case summary(entry, viewer) do
        nil -> acc
        projection -> Map.update(acc, entry.issue_id, [projection], &(&1 ++ [projection]))
      end
    end)
  end

  @doc """
  The bounded projection of one evidence edge, at the tier `viewer` is
  admitted to.

  `pulse` is the acceptance criterion "a public issue can say that restricted
  evidence exists": the family and the receipt's own verdict, without the
  revision, the receipt handle, or the environment those bytes reached.
  `ledger` adds those three. Which field sits on which rung is decided in
  `OpenAgents.Transparency.WorkDisclosure` and read from there, never restated
  here.

  Nothing about the execution appears at any rung. The work job's report, the
  attempt's prompt, and the credential are in that schedule's never list, not
  on a rung nobody has reached yet.
  """
  @spec summary(EvidenceEntry.t(), map()) :: map() | nil
  def summary(entry, viewer \\ @unclamped)

  def summary(%EvidenceEntry{} = entry, viewer) do
    WorkDisclosure.project(
      :evidence,
      %{
        id: entry.id,
        commit: entry.commit_sha,
        family: entry.family,
        receipt_id: entry.receipt_id,
        plane: entry.plane,
        environment: entry.environment,
        result: entry.result,
        source: entry.source,
        recorded_at: entry.inserted_at
      },
      WorkDisclosure.effective_tier(entry, viewer)
    )
  end

  # ── receipt-side entry points ───────────────────────────────────────────

  @doc "Record a completed or failed forge build receipt as evidence."
  @spec record_build(BuildReceipt.t()) :: [EvidenceEntry.t()]
  def record_build(%BuildReceipt{id: id}), do: soft_record(%{family: "build", receipt_id: id})

  @doc "Record an immutable forge deployment receipt as evidence."
  @spec record_deploy(DeployReceipt.t()) :: [EvidenceEntry.t()]
  def record_deploy(%DeployReceipt{id: id}),
    do: soft_record(%{family: "deployment", receipt_id: id})

  @doc "Record a published qualification receipt as evidence."
  @spec record_check_result(CheckResult.t()) :: [EvidenceEntry.t()]
  def record_check_result(%CheckResult{id: id}),
    do: soft_record(%{family: "qualification", receipt_id: id})

  @doc "Record a terminal tenant deployment run as evidence."
  @spec record_deployment_run(DeploymentRun.t()) :: [EvidenceEntry.t()]
  def record_deployment_run(%DeploymentRun{id: id}),
    do: soft_record(%{family: "deployment", receipt_id: id})

  @doc """
  Record a push receipt as evidence for one issue the push's commit closed.

  `OpenAgents.Issues.ClosingReferences` calls this while it records the
  reference, which is the one moment the issue, the commit, the repository, and
  the push receipt are all in hand. Reading them back later would need a window
  scan; writing them here does not.
  """
  @spec record_push(Repository.t(), Issue.t(), String.t(), binary() | nil, String.t()) ::
          [EvidenceEntry.t()]
  def record_push(%Repository{} = repository, %Issue{} = issue, commit_sha, receipt_id, actor)
      when is_binary(commit_sha) and is_binary(receipt_id) and is_binary(actor) do
    insert(%{
      repository_id: repository.id,
      issue_id: issue.id,
      commit_sha: commit_sha,
      family: "push",
      receipt_id: receipt_id,
      plane: "forge",
      environment: nil,
      result: nil,
      actor: actor,
      source: "closing_reference",
      assignment_id: nil
    })
  end

  # A push whose receipt row was lost between the WAL ack and the insert has no
  # receipt to point at. `reconcile_receipts/1` re-derives the receipt and
  # reaches here again with it.
  def record_push(_repository, _issue, _commit_sha, _receipt_id, _actor), do: []

  # ── internals ───────────────────────────────────────────────────────────

  defp soft_record(attrs) do
    case record(attrs) do
      {:ok, entries} ->
        entries

      # A receipt whose `repo` string names no tracked repository, and a
      # receipt id that is not in its family's table, are both ordinary: the
      # forge builds and deploys artifacts this tracker has no repository for.
      # Only a caller asserting the wrong commit or environment is worth a
      # warning, because that is a bug rather than a gap.
      {:error, reason}
      when reason in [:evidence_repository_not_resolved, :evidence_receipt_not_found] ->
        Logger.debug("issue_evidence_not_recorded reason=#{reason}")
        []

      {:error, reason} ->
        Logger.warning("issue_evidence_not_recorded reason=#{reason}")
        []
    end
  rescue
    error ->
      Logger.warning("issue_evidence_failed code=#{OpenAgents.OperationalLog.code(error)}")
      []
  end

  defp family(attrs) do
    case attrs[:family] || attrs["family"] do
      family when family in ["push", "build", "deployment", "qualification"] -> {:ok, family}
      _unnamed -> {:error, :evidence_family_unknown}
    end
  end

  defp receipt_id(attrs) do
    case Ecto.UUID.cast(attrs[:receipt_id] || attrs["receipt_id"]) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :evidence_receipt_not_found}
    end
  end

  defp actor(attrs), do: to_string(attrs[:actor] || attrs["actor"] || "system:forge")

  # Every family resolves to the same shape: the repository the receipt belongs
  # to, the exact commit it evaluated, the plane it lives in, the environment it
  # reached, and its own terminal word.
  defp receipt_facts("push", id) do
    case Repo.get(PushReceipt, id) do
      %PushReceipt{} ->
        # A push receipt carries refs rather than one commit, so it cannot be
        # resolved from the receipt alone. `record_push/5` writes it at the one
        # moment the commit is known.
        {:error, :evidence_push_needs_commit}

      nil ->
        {:error, :evidence_receipt_not_found}
    end
  end

  defp receipt_facts("build", id) do
    case Repo.get(BuildReceipt, id) do
      %BuildReceipt{} = receipt ->
        with %Repository{} = repository <- repository_for(receipt) do
          {:ok,
           %{
             repository: repository,
             commit_sha: receipt.sha,
             family: "build",
             receipt_id: receipt.id,
             plane: "forge",
             environment: nil,
             result: receipt.status
           }}
        else
          _unresolved -> {:error, :evidence_repository_not_resolved}
        end

      nil ->
        {:error, :evidence_receipt_not_found}
    end
  end

  defp receipt_facts("deployment", id) do
    case Repo.get(DeployReceipt, id) do
      %DeployReceipt{} = receipt -> forge_deployment_facts(receipt)
      nil -> tenant_deployment_facts(id)
    end
  end

  defp receipt_facts("qualification", id) do
    case Repo.get(CheckResult, id) do
      %CheckResult{} = result ->
        case Repo.get(Repository, result.repository_id) do
          %Repository{} = repository ->
            {:ok,
             %{
               repository: repository,
               commit_sha: result.commit_sha,
               family: "qualification",
               receipt_id: result.id,
               plane: "tenant",
               environment: nil,
               result: result.status
             }}

          nil ->
            {:error, :evidence_repository_not_resolved}
        end

      nil ->
        {:error, :evidence_receipt_not_found}
    end
  end

  defp forge_deployment_facts(%DeployReceipt{} = receipt) do
    case repository_for(receipt) do
      %Repository{} = repository ->
        {:ok,
         %{
           repository: repository,
           commit_sha: receipt.sha,
           family: "deployment",
           receipt_id: receipt.id,
           plane: "forge",
           environment: @fleet,
           result: receipt.result
         }}

      nil ->
        {:error, :evidence_repository_not_resolved}
    end
  end

  defp tenant_deployment_facts(id) do
    query =
      from run in DeploymentRun,
        join: request in DeploymentRequest,
        on: request.id == run.deployment_request_id,
        join: repository in Repository,
        on: repository.id == run.repository_id,
        left_join: environment in assoc(run, :environment),
        where: run.id == ^id,
        select: {run, request.commit_sha, repository, environment.name}

    case Repo.one(query) do
      {%DeploymentRun{} = run, commit_sha, %Repository{} = repository, environment} ->
        {:ok,
         %{
           repository: repository,
           commit_sha: commit_sha,
           family: "deployment",
           receipt_id: run.id,
           plane: "tenant",
           environment: environment,
           result: run.state
         }}

      _missing ->
        {:error, :evidence_receipt_not_found}
    end
  end

  defp assert_commit(_facts, nil), do: :ok

  defp assert_commit(%{commit_sha: actual}, asserted) when is_binary(asserted) do
    if String.downcase(asserted) == String.downcase(to_string(actual)),
      do: :ok,
      else: {:error, :evidence_commit_mismatch}
  end

  defp assert_commit(_facts, _asserted), do: {:error, :evidence_commit_mismatch}

  defp assert_environment(_facts, nil), do: :ok

  defp assert_environment(%{environment: actual}, asserted) when is_binary(asserted) do
    if asserted == actual, do: :ok, else: {:error, :evidence_environment_mismatch}
  end

  defp assert_environment(_facts, _asserted), do: {:error, :evidence_environment_mismatch}

  defp append(facts, actor) do
    facts.repository
    |> claimants(facts.commit_sha)
    |> Enum.flat_map(fn {issue_id, source, assignment_id} ->
      insert(%{
        repository_id: facts.repository.id,
        issue_id: issue_id,
        commit_sha: facts.commit_sha,
        family: facts.family,
        receipt_id: facts.receipt_id,
        plane: facts.plane,
        environment: facts.environment,
        result: facts.result,
        actor: actor,
        source: source,
        assignment_id: assignment_id
      })
    end)
  end

  # The two sources, in priority order. A commit claimed by a trailer and by an
  # attempt records once, as `closing_reference`, because a merge is a stronger
  # fact than an executor's self-report.
  defp claimants(%Repository{id: repository_id}, commit_sha) do
    referenced =
      Repo.all(
        from reference in ClosingReference,
          where:
            reference.repository_id == ^repository_id and
              reference.commit_sha == ^commit_sha,
          select: reference.issue_id,
          limit: @claimant_limit
      )
      |> Enum.map(&{&1, "closing_reference", nil})

    claimed = MapSet.new(referenced, fn {issue_id, _source, _assignment} -> issue_id end)

    reported =
      Repo.all(
        from assignment in Assignment,
          where:
            assignment.repository_id == ^repository_id and
              assignment.terminal_commit == ^commit_sha,
          select: {assignment.issue_id, assignment.id},
          limit: @claimant_limit
      )
      |> Enum.reject(fn {issue_id, _id} -> MapSet.member?(claimed, issue_id) end)
      |> Enum.uniq_by(fn {issue_id, _id} -> issue_id end)
      |> Enum.map(fn {issue_id, assignment_id} -> {issue_id, "assignment", assignment_id} end)

    Enum.take(referenced ++ reported, @claimant_limit)
  end

  # Replay is a no-op in two layers. The read answers the ordinary second
  # arrival — a reconciled receipt, a re-presented commit — without touching
  # the row it finds. `on_conflict: :nothing` answers the concurrent one,
  # because a constraint error raised inside `ClosingReferences`' transaction
  # would roll back the close it guards rather than skipping the edge.
  defp insert(attrs) do
    if recorded?(attrs) do
      []
    else
      %EvidenceEntry{}
      |> EvidenceEntry.changeset(inherit_link(attrs))
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:issue_id, :commit_sha, :family, :receipt_id]
      )
      |> case do
        {:ok, %EvidenceEntry{} = entry} ->
          # A receipt that disagrees with an accepted claim's evidence marks
          # that claim contradicted. It never reopens the issue and never
          # fails the receipt that produced it; #150 owns that rule.
          _ = note_contradiction(entry)
          [entry]

        {:error, _changeset} ->
          []
      end
    end
  end

  # An edge an attempt produced consents on the attempt's link, not on one of
  # its own. The attempt is where a person chose to start work and where a
  # revocation has to bite: revoking the attempt's link must take its receipts
  # with it, and a second link per edge would leave them behind.
  defp inherit_link(%{assignment_id: id} = attrs) when is_binary(id) do
    case Repo.one(
           from a in Assignment,
             where: a.id == ^id,
             select: {a.artifact_link_id, a.transparency_tier}
         ) do
      {link_id, tier} when is_binary(tier) ->
        attrs |> Map.put(:artifact_link_id, link_id) |> Map.put(:transparency_tier, tier)

      _absent ->
        attrs
    end
  end

  defp inherit_link(attrs), do: attrs

  defp note_contradiction(%EvidenceEntry{} = entry) do
    CompletionClaims.note_evidence(entry)
  rescue
    error ->
      Logger.warning(
        "issue_evidence_contradiction_failed code=#{OpenAgents.OperationalLog.code(error)}"
      )

      :ok
  end

  defp recorded?(attrs) do
    Repo.exists?(
      from entry in EvidenceEntry,
        where:
          entry.issue_id == ^attrs.issue_id and
            entry.commit_sha == ^String.downcase(attrs.commit_sha) and
            entry.family == ^attrs.family and
            entry.receipt_id == ^attrs.receipt_id
    )
  end

  # A receipt written since #181 carries `repository_id`, so the evidence chain
  # no longer depends on a name resolving to exactly one repository. The string
  # is read only for a row the backfill could not settle, and there it keeps the
  # old refusal: two candidates record nothing rather than guessing which issue
  # the receipt belongs to.
  defp repository_for(%{repository_id: repository_id}) when is_binary(repository_id) do
    Repo.get(Repository, repository_id)
  end

  defp repository_for(%{repo: repo}), do: repository_by_name(repo)

  defp repository_by_name(repo) when is_binary(repo) do
    ReceiptRepository.resolve(repo)
  end

  defp repository_by_name(_repo), do: nil

  defp sweep(%Repository{} = repository, commit_sha, %Assignment{} = assignment) do
    # A receipt that names this repository is matched by its key. The string is
    # the fallback for a row the backfill could not settle, and restricting it
    # to this repository's own keys keeps a receipt for another repository's
    # identical sha out of the answer.
    keys = OpenAgents.Forge.Pushes.receipt_repo_keys(repository.storage_key)

    builds =
      BuildReceipt
      |> ReceiptRepository.scope(repository, keys)
      |> where([build], build.sha == ^commit_sha)
      |> select([build], build.id)
      |> limit(@claimant_limit)
      |> Repo.all()
      |> Enum.map(&%{family: "build", receipt_id: &1})

    deploys =
      DeployReceipt
      |> ReceiptRepository.scope(repository, keys)
      |> where([deploy], deploy.sha == ^commit_sha)
      |> select([deploy], deploy.id)
      |> limit(@claimant_limit)
      |> Repo.all()
      |> Enum.map(&%{family: "deployment", receipt_id: &1})

    checks =
      Repo.all(
        from result in CheckResult,
          where: result.repository_id == ^repository.id and result.commit_sha == ^commit_sha,
          select: result.id,
          limit: @claimant_limit
      )
      |> Enum.map(&%{family: "qualification", receipt_id: &1})

    actor = assignment_actor(assignment)

    (builds ++ deploys ++ checks)
    |> Enum.flat_map(&soft_record(Map.put(&1, :actor, actor)))
  end

  defp assignment_actor(%Assignment{requesting_principal: %{"type" => type, "id" => id}})
       when is_binary(type) and is_binary(id),
       do: "#{type}:#{id}"

  defp assignment_actor(%Assignment{}), do: "system:forge"
end
