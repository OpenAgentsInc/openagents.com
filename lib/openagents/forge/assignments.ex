defmodule OpenAgents.Forge.Assignments do
  @moduledoc """
  Durable issue-to-Box assignments and their least-privilege Git credentials.

  Assignment credentials are digest-only and authenticate as an `:assignment`
  forge principal. Their repository and branch scope is read from the durable
  assignment snapshot, never from request metadata.

  ## The issue is the bound

  `create/1` is the one admission point for agent work on an issue, reached by
  the issue page and by `POST /api/v1/.../assignments` alike, so it is where
  `OpenAgents.Issues.WorkScope` applies. The objective and the wall clock come
  from the issue: a caller that supplies neither gets the issue's, and a caller
  that supplies a deadline may narrow the issue's bound but never widen it.
  Bounded work means bounded by the requested outcome, not by whoever asked for
  it.
  """

  import Ecto.Query

  alias OpenAgents.Agents
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.BoxRuns
  alias OpenAgents.Forge.{Assignment, AssignmentCredential, AssignmentCredentialVault}
  alias OpenAgents.Issues.{Evidence, Issue, WorkScope}
  alias OpenAgents.Repo
  alias OpenAgents.Conversations
  alias OpenAgents.Repositories.Repository
  alias OpenAgents.Transparency.WorkDisclosure
  alias OpenAgents.Work.Job

  @prefix "oa_assignment_"
  @terminal_states ~w(completed failed cancelled)

  # A caller that names no viewer is an internal caller: the executor, the
  # janitor, the reconciler. They read the record, not a projection of it, so
  # nothing is clamped. Every surface a reader reaches passes a real viewer
  # from `WorkDisclosure.viewer/2`, and the surface enumeration proves it.
  @unclamped %{account_id: nil, tier: :glass, admin: true}

  @doc "Creates an assignment, claims its issue, mints its credential, and starts its run."
  @spec create(map()) :: {:ok, Assignment.t(), String.t()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    with {:ok, target_kind} <- target_kind(attrs),
         {:ok, owner} <- owner(attrs, target_kind),
         {:ok, conversation} <- owned_conversation(attrs, owner),
         {:ok, target} <- owned_target(attrs, conversation.id, target_kind, owner),
         {:ok, repository} <- repository(attrs),
         {:ok, issue} <- issue(repository, attrs),
         {:ok, branch} <- branch(repository, attrs),
         {:ok, principal} <- principal(attrs, target_kind),
         :ok <-
           writable?(
             repository,
             attrs[:requesting_user] || attrs["requesting_user"],
             principal,
             target_kind
           ),
         {:ok, assignment, plaintext} <-
           persist_assignment(target_kind, target, repository, issue, branch, principal, attrs) do
      _ = announce(assignment)

      start_target(
        assignment,
        target,
        target_kind,
        plaintext,
        scoped(attrs, issue, assignment.branch),
        owner,
        conversation
      )
    end
  end

  # The issue writes the objective when the caller does not. A caller that
  # supplies one is still bounded — by the branch its credential is scoped to,
  # by the repository the issue lives in, and by the wall clock `deadline/3`
  # already took from the issue — but the common case is that nobody should be
  # composing a second version of what the issue already says.
  #
  # The branch comes from the persisted attempt rather than from the request,
  # because that is the ref the credential was minted for. A prompt that named
  # any other would be telling an agent to push where it cannot.
  defp scoped(attrs, issue, branch) do
    case attrs[:prompt] || attrs["prompt"] do
      prompt when is_binary(prompt) and prompt != "" -> attrs
      _absent -> Map.put(attrs, "prompt", WorkScope.objective(issue, branch))
    end
  end

  defp start_target(assignment, box, "box", plaintext, attrs, _owner, _conversation) do
    case BoxRuns.start_run(
           box.conversation_id,
           box.box_id,
           %{"type" => "assignment", "id" => assignment.id},
           command(attrs),
           idempotency_key(attrs),
           assignment_credential: plaintext
         ) do
      {:ok, run} ->
        assignment =
          case Repo.get!(Assignment, assignment.id) do
            %Assignment{} = current when current.state in @terminal_states ->
              current

            %Assignment{} = current ->
              current
              |> Assignment.changeset(%{
                run_id: run.id,
                state: "running",
                started_at: DateTime.utc_now()
              })
              |> Repo.update!()
          end

        _ = announce(assignment)
        {:ok, assignment, plaintext}

      {:error, reason} ->
        _ = finish(assignment, "failed", nil, inspect(reason))
        {:error, reason}
    end
  end

  defp start_target(assignment, machine, "computer", plaintext, attrs, owner, conversation) do
    if assignment.credential_delivery_status == "enabled",
      do: AssignmentCredentialVault.put(assignment.id, plaintext)

    assignment =
      assignment
      |> Assignment.changeset(%{state: "running", started_at: DateTime.utc_now()})
      |> Repo.update!()

    _ = announce(assignment)

    params = %{
      "prompt" => attrs[:prompt] || attrs["prompt"] || "",
      "cwd" => attrs[:cwd] || attrs["cwd"] || "",
      "agent_id" => attrs[:agent_id] || attrs["agent_id"],
      "assignment_id" => assignment.id,
      "assignment_branch" => assignment.branch,
      "assignment_repository_id" => assignment.repository_id,
      "timeout_ms" =>
        max(DateTime.diff(assignment.deadline_at, DateTime.utc_now(), :millisecond), 1_000)
    }

    case OpenAgents.ComputerAgentJobs.start(owner, machine, conversation, params) do
      {:ok, job} ->
        {:ok, record_work_job(assignment, job.id), plaintext}

      {:error, reason} ->
        AssignmentCredentialVault.delete(assignment.id)
        _ = finish(assignment, "failed", nil, inspect(reason))
        {:error, reason}
    end
  end

  # The work job carries execution: its steps, its report, its budget. The
  # assignment carries the attempt: which issue, which repository, which
  # branch, under whose authority. Recording the job id here makes the join
  # typed and queryable in both directions without moving either record.
  defp record_work_job(%Assignment{} = assignment, job_id) do
    assignment
    |> Assignment.changeset(%{work_job_id: job_id})
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, _changeset} -> assignment
    end
  end

  @doc """
  Every recorded execution attempt for `issue`, oldest first.

  The issue is the requested outcome and never becomes a work record. This
  reads the attempts that already exist in `forge_assignments`, so an issue
  with no agent work returns an empty list rather than an absent fact.
  """
  @spec attempts_for_issue(Issue.t() | integer(), map()) :: [map()]
  def attempts_for_issue(issue_id, viewer \\ @unclamped)

  def attempts_for_issue(%Issue{id: id}, viewer), do: attempts_for_issue(id, viewer)

  def attempts_for_issue(issue_id, viewer) when is_integer(issue_id) do
    issue_id
    |> attempt_records_for_issue()
    |> Enum.map(&attempt_summary(&1, viewer))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The attempt rows for `issue`, oldest first, with their consent links loaded.

  Unprojected, so a caller that has to clamp a *different* record against an
  attempt's real tier can do so. Every caller that shows an attempt to a reader
  still goes through `attempt_summary/2`; this exists for records that hang off
  an attempt and carry a second gate of their own, such as an ATIF trace.
  """
  @spec attempt_records_for_issue(Issue.t() | integer()) :: [Assignment.t()]
  def attempt_records_for_issue(%Issue{id: id}), do: attempt_records_for_issue(id)

  def attempt_records_for_issue(issue_id) when is_integer(issue_id) do
    Assignment
    |> where([assignment], assignment.issue_id == ^issue_id)
    |> order_by([assignment], asc: assignment.admitted_at, asc: assignment.id)
    |> preload([:artifact_link, :work_job])
    |> Repo.all()
  end

  @doc """
  Attempts for a whole page of issues, keyed by issue id.

  One query for the page, the way `Issues.dependency_graph/1` reads
  prerequisites, so listing issues does not cost one query per row. Every
  issue in `issues` appears in the result, with `[]` when it has no attempt.
  """
  @spec attempts_for_issues([Issue.t()], map()) :: %{integer() => [map()]}
  def attempts_for_issues(issues, viewer \\ @unclamped) when is_list(issues) do
    ids = Enum.map(issues, & &1.id)
    base = Map.new(ids, &{&1, []})

    Assignment
    |> where([assignment], assignment.issue_id in ^ids)
    |> order_by([assignment], asc: assignment.admitted_at, asc: assignment.id)
    |> preload([:artifact_link, :work_job])
    |> Repo.all()
    |> Enum.reduce(base, fn assignment, acc ->
      case attempt_summary(assignment, viewer) do
        nil -> acc
        summary -> Map.update(acc, assignment.issue_id, [summary], &(&1 ++ [summary]))
      end
    end)
  end

  @doc """
  The bounded projection of one attempt, at the tier `viewer` is admitted to.

  Which field each rung first exposes is decided once, in
  `OpenAgents.Transparency.WorkDisclosure`, and this function only reads that
  schedule. It cannot publish a column the schedule has not classified, and it
  returns `nil` at `dark`, so a revoked link removes the attempt from the
  timeline rather than leaving an empty shell that still says it existed.

  The attempt's own job is projected beside it as its own family, so the
  report reaches the account the work belongs to and nobody else, rather than
  travelling on the attempt's tier.
  """
  @spec attempt_summary(Assignment.t(), map()) :: map() | nil
  def attempt_summary(assignment, viewer \\ @unclamped)

  def attempt_summary(%Assignment{} = assignment, viewer) do
    tier = WorkDisclosure.effective_tier(assignment, viewer)

    case WorkDisclosure.project(:attempt, attempt_source(assignment), tier) do
      nil -> nil
      projection -> Map.put(projection, :work_job, work_job_summary(assignment, tier))
    end
  end

  defp attempt_source(%Assignment{} = assignment) do
    assignment
    |> Map.from_struct()
    |> Map.put(:requester_kind, requester_kind(assignment.requesting_principal))
  end

  # TRANSPARENCY-001 publishes a principal's kind and never its id. The
  # narration comment `#147` retires published the agent itself; this publishes
  # that an agent asked, which is the half that contract admits.
  defp requester_kind(%{"type" => type}) when type in ["user", "agent"], do: type
  defp requester_kind(_), do: nil

  defp work_job_summary(%Assignment{work_job: %Job{} = job}, tier) do
    job
    |> Map.from_struct()
    |> Map.put(:budget, budget_bounds(job.budget_snapshot))
    |> then(&WorkDisclosure.project(:work_job, &1, tier))
  end

  defp work_job_summary(%Assignment{}, _tier), do: nil

  # The bounds, never the snapshot. `maximum_prompt_bytes` is a ceiling on a
  # prompt no tier publishes, which is why the ceiling is safe and the prompt
  # is not.
  defp budget_bounds(snapshot) when is_map(snapshot) do
    Map.take(snapshot, ["wall_clock_ms", "maximum_report_bytes", "maximum_prompt_bytes"])
  end

  defp budget_bounds(_snapshot), do: %{}

  defp target_kind(attrs) do
    case attrs[:target_kind] || attrs["target_kind"] do
      nil ->
        if attrs[:machine_id] || attrs["machine_id"], do: {:ok, "computer"}, else: {:ok, "box"}

      "box" ->
        {:ok, "box"}

      "computer" ->
        {:ok, "computer"}

      _ ->
        {:error, :invalid_assignment_target}
    end
  end

  @doc "Authenticates an assignment credential and returns its scoped principal."
  @spec authenticate(String.t()) :: {:ok, map()} | {:error, :invalid_assignment_credential}
  def authenticate(@prefix <> rest = plaintext) when byte_size(plaintext) < 240 do
    with [id, secret] <- String.split(rest, ".", parts: 2),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         true <- byte_size(secret) in 40..100,
         # The uuid in the token is the *assignment* id: `persist_assignment/7`
         # generates one id, uses it as the assignment's primary key, and
         # embeds it in the plaintext. The credential row carries its own
         # autogenerated key and is reached through `assignment_id`, which is
         # what `credential/1` has always done. Reading it by `c.id` asked for
         # a row that cannot exist, so no minted credential ever
         # authenticated. `forge_assignment_credentials` has a unique index on
         # `assignment_id`, so `Repo.one` here cannot see two rows.
         %AssignmentCredential{} = credential <-
           Repo.one(
             from c in AssignmentCredential,
               where: c.assignment_id == ^uuid,
               preload: [assignment: [:repository]]
           ),
         true <- Plug.Crypto.secure_compare(credential.token_digest, digest(plaintext)),
         true <- usable?(credential),
         %Assignment{state: state} = assignment when state in ["admitted", "running"] <-
           credential.assignment do
      {:ok,
       %{
         kind: :assignment,
         id: assignment.id,
         assignment_id: assignment.id,
         repository_id: credential.repository_id,
         branch: credential.branch,
         credential_id: credential.id
       }}
    else
      _ -> {:error, :invalid_assignment_credential}
    end
  end

  def authenticate(_), do: {:error, :invalid_assignment_credential}

  @doc "Revokes the credential and releases the issue claim for a terminal assignment."
  @spec finish(Assignment.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Assignment.t()} | {:error, term()}
  def finish(%Assignment{} = assignment, state, commit \\ nil, reason \\ nil)
      when state in @terminal_states do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        current =
          Repo.one!(from a in Assignment, where: a.id == ^assignment.id, lock: "FOR UPDATE")

        if Assignment.terminal?(current) do
          {:already_finished, current}
        else
          updated =
            current
            |> Assignment.changeset(%{
              state: state,
              terminal_branch: assignment.branch,
              terminal_commit: commit,
              failure_reason: reason,
              finished_at: now
            })
            |> Repo.update!()

          Repo.update_all(
            from(c in AssignmentCredential, where: c.assignment_id == ^current.id),
            set: [revoked_at: now, updated_at: now]
          )

          AssignmentCredentialVault.delete(current.id)

          {:finished, updated}
        end
      end)

    case result do
      {:ok, {:finished, updated}} ->
        # The attempt reports the exact revision it produced. Receipts for that
        # revision may already exist, so bind them now rather than waiting for
        # a receipt that already landed. Never load-bearing: an attempt that
        # finished is finished whether or not its evidence could be written.
        _ = Evidence.bind_attempt(updated)
        _ = announce(updated)
        {:ok, updated}

      {:ok, {:already_finished, current}} ->
        {:ok, current}

      error ->
        error
    end
  end

  @doc "Finishes every active Computer assignment bound to a revoked computer."
  def finish_for_machine(machine_id, reason \\ "machine_revoked") when is_binary(machine_id) do
    Repo.all(
      from assignment in Assignment,
        where:
          assignment.machine_id == ^machine_id and
            assignment.state in ["admitted", "running"]
    )
    |> Enum.each(fn assignment ->
      _ = finish(assignment, "failed", nil, reason)
    end)

    :ok
  end

  @doc "Revokes credentials and finishes active assignments past their deadline."
  def expire do
    now = DateTime.utc_now()

    Repo.all(
      from assignment in Assignment,
        where:
          assignment.state in ["admitted", "running"] and
            assignment.deadline_at <= ^now
    )
    |> Enum.each(fn assignment ->
      _ = finish(assignment, "failed", nil, "assignment_expired")
    end)

    :ok
  end

  @doc """
  Subscribes the caller to the attempts on one issue.

  The topic carries announcements, not rows. A subscriber is told that the
  attempts on an issue moved and re-reads them through its own authorized
  read, so a message can never hand anybody an attempt their repository
  membership — or their transparency tier — would have withheld.
  """
  @spec subscribe_attempts(integer()) :: :ok | {:error, term()}
  def subscribe_attempts(issue_id) when is_integer(issue_id),
    do: Phoenix.PubSub.subscribe(OpenAgents.PubSub, attempts_topic(issue_id))

  @doc "Unsubscribes the caller from the attempts on one issue."
  @spec unsubscribe_attempts(integer()) :: :ok
  def unsubscribe_attempts(issue_id) when is_integer(issue_id),
    do: Phoenix.PubSub.unsubscribe(OpenAgents.PubSub, attempts_topic(issue_id))

  @doc """
  Announces that the attempts on an issue moved.

  The message is `{:attempts_changed, issue_id}` and carries nothing else. Not
  the state, not the branch, not the attempt: every one of those is disclosed
  at a rung, and a message carrying one would carry it past the gate that
  decides the rung.
  """
  @spec announce(Assignment.t()) :: :ok
  def announce(%Assignment{issue_id: issue_id}) when is_integer(issue_id),
    do:
      Phoenix.PubSub.broadcast(
        OpenAgents.PubSub,
        attempts_topic(issue_id),
        {:attempts_changed, issue_id}
      )

  def announce(%Assignment{}), do: :ok

  defp attempts_topic(issue_id), do: "issue_attempts:#{issue_id}"

  @doc """
  Cancels a live attempt on behalf of a viewer with write authority.

  The authority is read from the attempt's own repository rather than from
  whatever the caller believes about itself, so a stale socket assign cannot
  cancel anybody's work. It reaches `finish/1` — the one terminal path — so a
  cancelled attempt revokes its credential, releases its issue claim, and binds
  its evidence exactly as a failure does.
  """
  @spec cancel(String.t(), OpenAgents.Accounts.User.t() | nil) ::
          {:ok, Assignment.t()} | {:error, atom()}
  def cancel(assignment_id, user) when is_binary(assignment_id) do
    case Repo.get(Assignment, assignment_id) do
      nil ->
        {:error, :assignment_not_found}

      %Assignment{} = assignment ->
        cond do
          Assignment.terminal?(assignment) ->
            {:error, :assignment_not_live}

          not writable_by?(assignment, user) ->
            {:error, :repository_not_writable}

          true ->
            finish(assignment, "cancelled", nil, "cancelled_by_viewer")
        end
    end
  end

  def cancel(_assignment_id, _user), do: {:error, :assignment_not_found}

  defp writable_by?(%Assignment{repository_id: repository_id}, user) do
    case Repo.get(Repository, repository_id) do
      %Repository{} = repository -> OpenAgents.Repositories.writable?(repository, user)
      nil -> false
    end
  end

  @doc "Returns the assignment credential metadata without exposing its secret."
  def credential(%Assignment{id: id}) do
    Repo.one(from c in AssignmentCredential, where: c.assignment_id == ^id)
  end

  defp persist_assignment(target_kind, target, repository, issue, branch, principal, attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      id = Ecto.UUID.generate()
      deadline = deadline(attrs, issue, now)
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      plaintext = @prefix <> id <> "." <> secret

      {credential_delivery_status, credential_delivery_reason} =
        credential_delivery(target_kind, target)

      # `forge_assignments_one_active_issue_index` is a real refusal, not a
      # crash: an issue that already has a live attempt must come back as
      # `:assignment_issue_claimed` so a caller can say which attempt holds it.
      # `Repo.insert!` raised on that constraint instead, which left
      # `claim_error/1` unreachable for the case it was written for.
      assignment =
        %Assignment{id: id}
        |> Assignment.changeset(%{
          conversation_box_id: if(target_kind == "box", do: target.id),
          machine_id: if(target_kind == "computer", do: target.id),
          conversation_id: attrs[:conversation_id] || attrs["conversation_id"],
          repository_id: repository.id,
          issue_id: issue.id,
          requesting_principal: principal,
          branch: branch,
          deadline_at: deadline,
          admitted_at: now,
          target_kind: target_kind,
          credential_delivery_status: credential_delivery_status,
          credential_delivery_reason: credential_delivery_reason,
          artifact_link_id:
            case WorkDisclosure.link_for_attempt(repository, principal, %{
                   "branch" => branch,
                   "target_kind" => target_kind
                 }) do
              {:ok, link} -> link.id
              :none -> nil
              {:error, changeset} -> Repo.rollback(changeset)
            end
        })
        |> Repo.insert()
        |> case do
          {:ok, inserted} -> inserted
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %AssignmentCredential{}
      |> AssignmentCredential.changeset(%{
        assignment_id: assignment.id,
        token_digest: digest(plaintext),
        last_four: String.slice(secret, -4, 4),
        repository_id: repository.id,
        branch: branch,
        expires_at: deadline
      })
      |> Repo.insert!()

      {assignment, plaintext}
    end)
    |> case do
      {:ok, {assignment, plaintext}} ->
        {:ok, assignment, plaintext}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, claim_error(changeset)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credential_delivery("box", _target), do: {"not_applicable", nil}

  defp credential_delivery("computer", %OpenAgents.Machines.Machine{
         scoped_forge_credentials_enabled: true
       }),
       do: {"enabled", nil}

  defp credential_delivery("computer", _target),
    do: {"refused", "computer_scoped_forge_credentials_not_enabled"}

  defp owned_target(attrs, conversation_id, "box", _owner), do: owned_box(attrs, conversation_id)
  defp owned_target(attrs, _conversation_id, "computer", owner), do: owned_machine(attrs, owner)

  defp owned_box(%{"conversation_id" => conversation_id, "box_id" => box_id}),
    do: box_record(conversation_id, box_id)

  defp owned_box(%{conversation_id: conversation_id, box_id: box_id}),
    do: box_record(conversation_id, box_id)

  defp owned_box(_), do: {:error, :box_not_owned}

  defp owned_box(attrs, conversation_id) do
    attrs
    |> Map.put("conversation_id", conversation_id)
    |> owned_box()
  end

  defp owned_machine(attrs, owner) do
    machine_id = attrs[:machine_id] || attrs["machine_id"]

    case OpenAgents.Machines.get_machine(owner.id, machine_id) do
      {:ok, %OpenAgents.Machines.Machine{status: "active"} = machine} ->
        if OpenAgents.Computer.online?(machine.id),
          do: {:ok, machine},
          else: {:error, :machine_offline}

      {:ok, _machine} ->
        {:error, :machine_revoked}

      error ->
        error
    end
  end

  defp owner(attrs, target_kind) do
    case attrs[:requesting_user] || attrs["requesting_user"] do
      %OpenAgents.Accounts.User{} = user ->
        {:ok, user}

      _ ->
        case attrs[:requesting_principal] || attrs["requesting_principal"] do
          %Agent{} = agent ->
            case Agents.control_owner(agent, target_kind) do
              %OpenAgents.Accounts.User{} = user -> {:ok, user}
              _ -> {:error, :conversation_not_found}
            end

          _ ->
            {:error, :conversation_not_found}
        end
    end
  end

  defp owned_conversation(attrs, owner) do
    case Conversations.get_conversation_for_user(
           owner,
           attrs["conversation_id"] || attrs[:conversation_id]
         ) do
      nil -> {:error, :conversation_not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp box_record(conversation_id, box_id) do
    case Repo.one(
           from b in ConversationBox,
             where: b.conversation_id == ^conversation_id and b.box_id == ^box_id
         ) do
      %ConversationBox{stopped_at: nil} = box -> {:ok, box}
      %ConversationBox{} -> {:error, :box_stopped}
      nil -> {:error, :box_not_owned}
    end
  end

  defp repository(attrs) do
    id = attrs[:repository_id] || attrs["repository_id"]

    case Repo.get(Repository, id) do
      %Repository{lifecycle_state: "ready"} = repo -> {:ok, repo}
      _ -> {:error, :repository_not_found}
    end
  end

  defp issue(%Repository{id: repository_id}, attrs) do
    id = attrs[:issue_id] || attrs["issue_id"]
    number = attrs[:issue_number] || attrs["issue_number"]

    issue =
      cond do
        is_binary(id) ->
          Repo.get_by(Issue, id: id, repository_id: repository_id)

        is_integer(number) ->
          Repo.get_by(Issue, number: number, repository_id: repository_id)

        is_binary(number) ->
          with {n, ""} <- Integer.parse(number),
               do: Repo.get_by(Issue, number: n, repository_id: repository_id)

        true ->
          nil
      end

    case issue do
      %Issue{} = value -> {:ok, value}
      nil -> {:error, :issue_not_found}
    end
  end

  defp writable?(
         %Repository{} = repository,
         %OpenAgents.Accounts.User{} = user,
         _principal,
         _target_kind
       ) do
    if OpenAgents.Repositories.writable?(repository, user),
      do: :ok,
      else: {:error, :repository_not_writable}
  end

  defp writable?(repository, _user, %{"type" => "agent", "id" => id}, target_kind) do
    case Repo.get(Agent, id) |> Agents.control_owner(target_kind) do
      %OpenAgents.Accounts.User{} = user ->
        writable?(repository, user, %{"type" => "user"}, target_kind)

      _ ->
        {:error, :repository_not_writable}
    end
  end

  defp writable?(_, _, _, _), do: {:error, :repository_not_writable}

  defp branch(%Repository{default_branch: default_branch, protected_branches: protected}, attrs) do
    branch = attrs[:branch] || attrs["branch"]

    cond do
      not is_binary(branch) or branch == "" ->
        {:error, :invalid_assignment_branch}

      branch == default_branch or branch in ["main", "master"] or branch in (protected || []) ->
        {:error, :protected_branch}

      String.starts_with?(branch, ["-", "."]) or
          String.contains?(branch, ["..", "@{", "\\", " ", "~", "^", ":", "?", "*", "["]) ->
        {:error, :invalid_assignment_branch}

      true ->
        {:ok, branch}
    end
  end

  defp principal(attrs, target_kind) do
    case attrs[:requesting_principal] || attrs["requesting_principal"] do
      %Agent{} = agent ->
        if granted?(agent, target_kind),
          do:
            {:ok,
             %{
               "type" => "agent",
               "id" => agent.id,
               "actor_type" => "agent",
               "actor_id" => agent.id
             }},
          else: {:error, grant_error(target_kind)}

      %OpenAgents.Accounts.User{id: id} ->
        {:ok, %{"type" => "user", "id" => id, "actor_type" => "user", "actor_id" => id}}

      %{"type" => type, "id" => id} when type in ["user", "agent"] and is_binary(id) ->
        {:ok, %{"type" => type, "id" => id, "actor_type" => type, "actor_id" => id}}

      %{type: type, id: id} when type in [:user, :agent] and is_binary(id) ->
        type = Atom.to_string(type)
        {:ok, %{"type" => type, "id" => id, "actor_type" => type, "actor_id" => id}}

      _ ->
        {:error, :invalid_principal}
    end
  end

  defp granted?(agent, target_kind) do
    case Agents.control_owner(agent, target_kind) do
      %OpenAgents.Accounts.User{} = owner ->
        Agents.control_granted_by?(agent, owner, target_kind)

      _ ->
        false
    end
  end

  defp grant_error("box"), do: :agent_box_control_forbidden
  defp grant_error("computer"), do: :agent_computer_control_forbidden

  defp command(attrs), do: attrs[:command] || attrs["command"] || "true"

  defp idempotency_key(attrs),
    do: attrs[:idempotency_key] || attrs["idempotency_key"] || Ecto.UUID.generate()

  # Three ceilings, and the deadline is the earliest of them: the deployment's
  # own TTL, the wall clock the issue's scope buys, and whatever the caller
  # asked for. A caller may narrow — a short run on a well-understood issue is
  # a reasonable thing to ask for — and a caller may not widen, because then
  # the bound would come from whoever pressed the button rather than from the
  # outcome that was requested.
  defp deadline(attrs, issue, now) do
    configured = attrs[:deadline_at] || attrs["deadline_at"]
    ttl = Application.get_env(:openagents, :box_api, [])[:ttl_seconds] || 3_600

    maximum =
      earlier(
        DateTime.add(now, ttl, :second),
        DateTime.add(now, WorkScope.wall_clock_ms(issue), :millisecond)
      )

    if match?(%DateTime{}, configured) and DateTime.compare(configured, maximum) == :lt,
      do: configured,
      else: maximum
  end

  defp earlier(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)

  defp claim_error(changeset) do
    if Enum.any?(changeset.errors, fn {field, _} -> field == :issue_id end),
      do: :assignment_issue_claimed,
      else: :assignment_box_busy
  end

  defp usable?(%AssignmentCredential{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp usable?(_), do: false

  defp digest(value), do: :crypto.hash(:sha256, value)
end
