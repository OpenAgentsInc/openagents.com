defmodule OpenAgents.Transparency.WorkDisclosure do
  @moduledoc """
  The field-by-field disclosure schedule for work in progress.

  `OpenAgents.Transparency` fixed four tiers — `dark`, `pulse`, `ledger`,
  `glass` — and `#70` attached them to changelog entries and releases. Those
  are records of work that finished. An attempt, a work job, and a deployment
  receipt describe work someone is doing right now, and the question a tier
  answers for them is not "may this reader see the record" but "which of its
  fields, and why".

  So the unit here is the field, not the record. Each family below names the
  tier that first exposes each field, and a second list names the fields no
  tier exposes at all. A column in neither list is a test failure, which is
  what keeps this a schedule rather than an intention: a new column on
  `forge_assignments`, `work_jobs`, or `issue_evidence` fails
  `OpenAgents.Transparency.WorkDisclosureTest` until somebody decides.

  ## What each rung means here

    * `pulse` — that the work exists, what shape it is, and how it came out.
      A reader learns an attempt ran and finished, or that a deployment
      receipt evaluated something and what its verdict was. Nothing a reader
      learns at `pulse` names a ref, a revision, a receipt, or a place.
    * `ledger` — the content of the result: the branch, the revision, the
      receipt handle, the environment, the counts, the budget. These identify
      or address repository content, so they sit exactly where
      `TRANSPARENCY-001` puts shas, paths, counts, and timings.
    * `glass` — the work job's own output. The report is model-authored prose
      bounded at eight kilobytes that may restate private repository content
      verbatim, so it reaches only the account the work belongs to and an
      operator. `Transparency.effective_tier/2` raises the owner of an
      `ArtifactLink` to `glass`; an attempt with no link has no owner to raise.
    * `dark` — withheld entirely. A revoked link resolves here, and the row
      leaves the projection rather than appearing as an empty shell.

  ## What no tier exposes

  The never list is not a tier-four field waiting for a viewer. It is the set
  of columns whose disclosure would restate, in a place the repository's own
  gate does not cover, something that gate exists to withhold: the prompt and
  the goal (the contents of a repository, retyped), the authority snapshot
  (a machine's roots, working directory, and name), the owner node (an
  internal node name `TRANSPARENCY-001` bans by name), the credential delivery
  fields, and the conversation the work was requested from.

  Repository authority is stronger than every rung of this ladder.
  `OpenAgents.Repositories.readable_by/2` runs first and raises; a tier can
  only narrow what a reader who already passed it sees. A record whose tier is
  `glass` in a repository that went private is invisible, and that is the case
  the proof exercises.
  """

  alias OpenAgents.Accounts
  alias OpenAgents.Repositories
  alias OpenAgents.Transparency
  alias OpenAgents.Transparency.ArtifactLink

  @families ~w(attempt work_job evidence)a

  # ── attempt (forge_assignments) ─────────────────────────────────────────
  #
  # The bounded projection of one attempt. `pulse` says an attempt of a named
  # shape ran and how it ended; `ledger` adds the refs and the revision it
  # produced.
  @attempt %{
    # An opaque handle. It correlates this attempt's own events and names
    # nothing outside the repository the reader already reached.
    id: :pulse,
    # `box` or `computer`. Two structural values that say which execution
    # shape ran, never which box or which computer.
    target_kind: :pulse,
    # The attempt's own lifecycle word. "Work is happening, and it ended this
    # way" is the whole of what `pulse` is for.
    state: :pulse,
    # `user` or `agent`, derived from `requesting_principal`. TRANSPARENCY-001
    # publishes a principal's kind and never its id; the raw map is in the
    # never list below because it carries the id.
    requester_kind: :pulse,
    admitted_at: :pulse,
    started_at: :pulse,
    finished_at: :pulse,
    # A branch is a ref in the repository's namespace, and a caller may name it
    # after the work rather than after the issue. That is repository content.
    branch: :ledger,
    terminal_branch: :ledger,
    # A revision identifies repository content. TRANSPARENCY-001 already puts
    # shas at `:l2`, and putting one here at `pulse` would contradict it.
    terminal_commit: :ledger,
    # The executor's own word about how the run ended — a detail of the result
    # rather than the bare fact that there was one.
    failure_reason: :ledger
  }

  @attempt_never [
    # The prompt's home. A conversation is the requesting account's, not the
    # issue's readers'.
    :conversation_id,
    :conversation_box_id,
    # Names a machine and a run on it. TRANSPARENCY-001 bans internal node
    # names, and a box or computer id is one.
    :machine_id,
    :run_id,
    # The job is projected as its own family, gated on its own fields, rather
    # than handed over as an id that fetches all of them.
    :work_job_id,
    # A bound on the run, published once from the job's budget snapshot rather
    # than twice from two records.
    :deadline_at,
    # Credential metadata. TRANSPARENCY-001 admits no credential at any level.
    :credential_delivery_status,
    :credential_delivery_reason,
    # The reader named both in the URL that got them here. Re-publishing them
    # turns two internal identifiers into public ones for no gain.
    :repository_id,
    :issue_id,
    # The tier is the gate, not a field the gate discloses.
    :transparency_tier,
    :artifact_link_id,
    :inserted_at,
    :updated_at
  ]

  # ── work_job (work_jobs) ────────────────────────────────────────────────
  #
  # The job is the execution behind an attempt. It is the one family with a
  # `glass` rung that carries anything, because it is the one family that
  # stores output.
  @work_job %{
    id: :pulse,
    # Which of five delegation shapes ran.
    kind: :pulse,
    status: :pulse,
    started_at: :pulse,
    completed_at: :pulse,
    # How much work happened. TRANSPARENCY-001 already admits module and node
    # counts at `:l2`, and these are the same class of fact.
    tool_call_count: :ledger,
    continuation_count: :ledger,
    # A bounded typed word about how the run ended.
    error_code: :ledger,
    # Derived from `budget_snapshot`: the wall clock, the report ceiling, and
    # the prompt ceiling. A bound on the run is a fact about the run. The
    # prompt the ceiling applies to is never published.
    budget: :ledger,
    # Model-authored prose, up to eight kilobytes, which may restate private
    # repository content verbatim. Only the account the work belongs to, and
    # an operator.
    report: :glass,
    # Token and cost accounting, which is billing about that account.
    usage: :glass,
    # Which model did that account's work.
    model_id: :glass
  }

  @work_job_never [
    # The issue's own sentence: the contents of a private repository restated
    # in a place the repository's gate does not cover.
    :goal,
    :context_hint,
    :delegation,
    # Carries `roots`, `cwd`, `machine_name`, and `agent_id` — the machine's
    # filesystem shape and the operator's node name.
    :authority_snapshot,
    :machine_id,
    :conversation_id,
    :owner_visitor_id,
    :requesting_tool_step_ref,
    # Handles into the operator's own substrate.
    :instruction_digest,
    :tool_catalog_digest,
    :memory_snapshot_ref,
    :report_message_id,
    # An internal node name, banned by TRANSPARENCY-001 by name.
    :owner_node,
    :generation,
    # `text` or `voice` says how the requester was talking to us, which is
    # conversation metadata about that account.
    :surface,
    :inserted_at,
    :updated_at
  ]

  # ── evidence (issue_evidence) ───────────────────────────────────────────
  #
  # The edge `#148` recorded. `pulse` is exactly the acceptance criterion "a
  # public issue can say that restricted evidence exists": the family and the
  # verdict, without the artifact, the revision, or the place.
  @evidence %{
    id: :pulse,
    # Which of four receipt families evaluated the commit. This is the
    # existence disclosure.
    family: :pulse,
    # The receipt's own terminal word — the outcome, without the artifact.
    result: :pulse,
    # `forge` or `tenant`. Two structural values.
    plane: :pulse,
    # `closing_reference` or `assignment`: how the commit resolved to the
    # issue.
    source: :pulse,
    recorded_at: :pulse,
    # A revision identifies repository content, as on the attempt.
    commit: :ledger,
    # The handle that fetches the receipt. At `pulse` it would be a pointer
    # past the gate.
    receipt_id: :ledger,
    # Names the place bytes reached. On the tenant plane that is a
    # customer-named environment, so a reader learns at `pulse` that a
    # deployment happened and how it came out, and at `ledger` where.
    environment: :ledger
  }

  @evidence_never [
    # Carries a principal's id. TRANSPARENCY-001 publishes kinds, not ids.
    :actor,
    # The attempt publishes its own revision at `ledger` and the edge
    # publishes the commit at `ledger`, so the two join on the revision
    # without a second identifier crossing the gate.
    :assignment_id,
    :repository_id,
    :issue_id,
    :transparency_tier,
    :artifact_link_id
  ]

  # The schema column each projection field is read from. Three fields are not
  # columns: `requester_kind` is the kind half of `requesting_principal`,
  # `budget` is the bounds half of `budget_snapshot`, and the evidence edge
  # renames two columns. Naming the source column is what lets the enumeration
  # be exact — every column of the three tables is either the source of one
  # scheduled field or a member of the never list, never both and never
  # neither.
  @attempt_columns %{requester_kind: :requesting_principal}
  @work_job_columns %{budget: :budget_snapshot}
  @evidence_columns %{commit: :commit_sha, recorded_at: :inserted_at}

  @schedule %{attempt: @attempt, work_job: @work_job, evidence: @evidence}
  @columns %{
    attempt: @attempt_columns,
    work_job: @work_job_columns,
    evidence: @evidence_columns
  }
  @never %{
    attempt: @attempt_never,
    work_job: @work_job_never,
    evidence: @evidence_never
  }

  @doc "The families this schedule covers."
  @spec families() :: [atom()]
  def families, do: @families

  @doc "The whole schedule, as `%{family => %{field => tier}}`."
  @spec schedule() :: %{atom() => %{atom() => atom()}}
  def schedule, do: @schedule

  @doc "The columns of `family` that no tier discloses, in any form."
  @spec never(atom()) :: [atom()]
  def never(family) when family in @families, do: Map.fetch!(@never, family)

  @doc """
  The schema column each scheduled field of `family` is read from.

  A field with no entry is read from the column of the same name.
  """
  @spec source_columns(atom()) :: [atom()]
  def source_columns(family) when family in @families do
    renames = Map.fetch!(@columns, family)

    @schedule
    |> Map.fetch!(family)
    |> Map.keys()
    |> Enum.map(&Map.get(renames, &1, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The tier that first exposes `field` of `family`, or `nil` if none does."
  @spec tier_for(atom(), atom()) :: atom() | nil
  def tier_for(family, field) when family in @families,
    do: @schedule |> Map.fetch!(family) |> Map.get(field)

  @doc """
  The fields of `family` that `tier` admits, in schedule order.

  `dark` admits nothing, which is why a `dark` projection is `nil` rather than
  an empty map: an empty shell would still say the record exists.
  """
  @spec fields_at(atom(), atom()) :: [atom()]
  def fields_at(family, tier) when family in @families do
    @schedule
    |> Map.fetch!(family)
    |> Enum.filter(fn {_field, at} -> Transparency.allows?(at, capability(at), tier) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # `allows?/3` asks whether a tier admits a capability, and the schedule is
  # written in tiers. Mapping each tier back to the capability it is the
  # minimum for keeps one comparison function rather than a second ladder.
  defp capability(:pulse), do: :metadata
  defp capability(:ledger), do: :content
  defp capability(:glass), do: :full
  defp capability(_), do: :full

  @doc """
  The viewer descriptor for `repository` and `user`.

  It carries both halves `OpenAgents.Transparency` needs: `account_id`, which
  `effective_tier/2` compares against an `ArtifactLink`'s owner, and `tier`,
  which clamps everything else down.

  The three rungs are the reader's relationship to the repository, not to the
  record:

    * an operator is `glass`, as `Transparency.viewer_tier/1` already says;
    * a member of the repository is `ledger`, because membership is what
      `Repositories.readable_by/2` admits a private repository's reader on;
    * every other reader who got this far is `pulse`, which on a public
      repository is anonymous traffic and is the only population a tier
      governs that repository authority does not.
  """
  @spec viewer(Repositories.Repository.t(), Accounts.User.t() | nil) :: map()
  def viewer(repository, user) do
    cond do
      is_struct(user, Accounts.User) and Accounts.admin?(user) ->
        %{account_id: user.id, tier: :glass, admin: true}

      is_struct(user, Accounts.User) and Repositories.member?(repository, user) ->
        %{account_id: user.id, tier: :ledger}

      is_struct(user, Accounts.User) ->
        %{account_id: user.id, tier: :pulse}

      true ->
        %{account_id: nil, tier: :pulse}
    end
  end

  @doc """
  The effective tier for one record and one viewer.

  A record that carries a loaded `ArtifactLink` resolves through it, so a
  revoked link is `dark` and the link's owning account is `glass`. A record
  with no link resolves through its own tier column and has no owner to raise:
  an attempt requested by an agent names no account, so nothing about it can
  reach `glass` for anyone but an operator.
  """
  @spec effective_tier(map(), map()) :: atom()
  def effective_tier(record, viewer) do
    case Map.get(record, :artifact_link) do
      %ArtifactLink{} = link -> Transparency.effective_tier(link, viewer)
      _absent -> unlinked_tier(Map.get(record, :transparency_tier), viewer)
    end
  end

  # `Transparency.effective_tier/2` raises an owner *or* an operator to `glass`
  # for a link, and only clamps for a bare tier. A record with no link has no
  # owner, so the owner half has nothing to act on — but an operator is not the
  # record's owner and reaches `glass` either way. Applying that half here is
  # what keeps an agent-requested attempt readable by an operator and by nobody
  # else raised.
  defp unlinked_tier(_tier, %{admin: true}), do: :glass
  defp unlinked_tier(tier, viewer), do: Transparency.effective_tier(tier, viewer)

  @doc """
  Mints the consent-bearing link for one attempt, or `:none`.

  The link exists so `Transparency.effective_tier/2` can do two things a tier
  column alone cannot: raise the account the work belongs to to `glass`, and
  resolve to `dark` the moment `Transparency.revoke/3` stamps it. Its tier is
  `ledger` — the ceiling a repository member already had — and the viewer's own
  relationship to the repository clamps every other reader down from there.

  An attempt an agent requested names no account, so it gets `:none`. That is
  the honest answer rather than a link owned by nobody: with no owner there is
  nothing for `glass` to mean, and the tier column still clamps every reader.
  """
  @spec link_for_attempt(Repositories.Repository.t(), map(), map()) ::
          {:ok, ArtifactLink.t()} | :none | {:error, Ecto.Changeset.t()}
  def link_for_attempt(repository, principal, authority \\ %{})

  def link_for_attempt(%{id: repository_id}, %{"type" => "user", "id" => account_id}, authority)
      when is_binary(account_id) do
    %ArtifactLink{}
    |> ArtifactLink.changeset(%{
      account_id: account_id,
      repository_id: repository_id,
      artifact_type: "attempt",
      artifact_ref: "id",
      tier: "ledger",
      consent: %{"granted_by" => "requesting_principal"},
      authority_snapshot: authority
    })
    |> OpenAgents.Repo.insert()
  end

  def link_for_attempt(_repository, _principal, _authority), do: :none

  @doc """
  Projects `source` for `family` at `tier`, taking each admitted field from
  `source` by its projection name.

  Returns `nil` at `dark`.
  """
  @spec project(atom(), map(), atom()) :: map() | nil
  def project(family, source, tier) when family in @families do
    case fields_at(family, tier) do
      [] -> nil
      fields -> Map.new(fields, fn field -> {field, Map.get(source, field)} end)
    end
  end
end
