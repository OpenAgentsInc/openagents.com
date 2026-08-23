defmodule OpenAgents.Forge.Assignments do
  @moduledoc """
  Durable issue-to-Box assignments and their least-privilege Git credentials.

  Assignment credentials are digest-only and authenticate as an `:assignment`
  forge principal. Their repository and branch scope is read from the durable
  assignment snapshot, never from request metadata.
  """

  import Ecto.Query

  alias OpenAgents.Agents
  alias OpenAgents.Agents.Agent
  alias OpenAgents.Box.ConversationBox
  alias OpenAgents.BoxRuns
  alias OpenAgents.Forge.{Assignment, AssignmentCredential, AssignmentCredentialVault}
  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Repo
  alias OpenAgents.Conversations
  alias OpenAgents.Repositories.Repository

  @prefix "oa_assignment_"
  @terminal_states ~w(completed failed cancelled)

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
      case report_claim(assignment) do
        {:ok, _comment} ->
          start_target(assignment, target, target_kind, plaintext, attrs, owner, conversation)

        {:error, reason} ->
          _ = finish(assignment, "failed", nil, "claim_event_failed")
          {:error, reason}
      end
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
  @spec attempts_for_issue(Issue.t() | integer()) :: [map()]
  def attempts_for_issue(%Issue{id: id}), do: attempts_for_issue(id)

  def attempts_for_issue(issue_id) when is_integer(issue_id) do
    Assignment
    |> where([assignment], assignment.issue_id == ^issue_id)
    |> order_by([assignment], asc: assignment.admitted_at, asc: assignment.id)
    |> Repo.all()
    |> Enum.map(&attempt_summary/1)
  end

  @doc """
  Attempts for a whole page of issues, keyed by issue id.

  One query for the page, the way `Issues.dependency_graph/1` reads
  prerequisites, so listing issues does not cost one query per row. Every
  issue in `issues` appears in the result, with `[]` when it has no attempt.
  """
  @spec attempts_for_issues([Issue.t()]) :: %{integer() => [map()]}
  def attempts_for_issues(issues) when is_list(issues) do
    ids = Enum.map(issues, & &1.id)
    base = Map.new(ids, &{&1, []})

    Assignment
    |> where([assignment], assignment.issue_id in ^ids)
    |> order_by([assignment], asc: assignment.admitted_at, asc: assignment.id)
    |> Repo.all()
    |> Enum.reduce(base, fn assignment, acc ->
      Map.update(acc, assignment.issue_id, [attempt_summary(assignment)], fn existing ->
        existing ++ [attempt_summary(assignment)]
      end)
    end)
  end

  @doc """
  The bounded projection of one attempt.

  It carries only what the claim and result comments already publish on the
  issue: the target kind, the branch, the exact commit, the terminal state,
  and the timestamps. The conversation, the prompt, the credential, and the
  work job's report stay out, because they belong to the requesting account
  rather than to everyone who can read the issue.
  """
  @spec attempt_summary(Assignment.t()) :: map()
  def attempt_summary(%Assignment{} = assignment) do
    %{
      id: assignment.id,
      target_kind: assignment.target_kind,
      state: assignment.state,
      branch: assignment.branch,
      terminal_branch: assignment.terminal_branch,
      terminal_commit: assignment.terminal_commit,
      failure_reason: assignment.failure_reason,
      admitted_at: assignment.admitted_at,
      started_at: assignment.started_at,
      finished_at: assignment.finished_at
    }
  end

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
         %AssignmentCredential{} = credential <-
           Repo.one(
             from c in AssignmentCredential,
               where: c.id == ^uuid,
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
        _ = report(updated)
        if updated.state in ["failed", "cancelled"], do: _ = report_release(updated)
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

  @doc "Returns the assignment credential metadata without exposing its secret."
  def credential(%Assignment{id: id}) do
    Repo.one(from c in AssignmentCredential, where: c.assignment_id == ^id)
  end

  @doc "Reports the terminal result once on the issue timeline."
  def report(%Assignment{} = assignment) do
    issue = Repo.get!(Issue, assignment.issue_id)

    body =
      [
        "#{target_label(assignment)} assignment finished.",
        "Branch: `#{assignment.terminal_branch || assignment.branch}`.",
        "Commit: `#{assignment.terminal_commit || "none reported"}`.",
        "Result: `#{assignment.state}`.",
        if(assignment.failure_reason, do: "Reason: `#{assignment.failure_reason}`.", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Issues.create_comment(issue, %{body: body}, author(assignment.requesting_principal))
  end

  @doc "Reports the release of a failed or cancelled issue claim."
  def report_release(%Assignment{} = assignment) do
    issue = Repo.get!(Issue, assignment.issue_id)

    body =
      [
        "#{target_label(assignment)} assignment claim released.",
        "Branch: `#{assignment.branch}`.",
        "Assignment: `#{assignment.id}`."
      ]
      |> Enum.join("\n")

    Issues.create_comment(issue, %{body: body}, author(assignment.requesting_principal))
  end

  @doc "Reports the claim before the Box run starts."
  def report_claim(%Assignment{} = assignment) do
    issue = Repo.get!(Issue, assignment.issue_id)

    body =
      [
        "#{target_label(assignment)} assignment claimed.",
        "Branch: `#{assignment.branch}`.",
        "Assignment: `#{assignment.id}`."
      ]
      |> Enum.join("\n")

    Issues.create_comment(issue, %{body: body}, author(assignment.requesting_principal))
  end

  defp persist_assignment(target_kind, target, repository, issue, branch, principal, attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      id = Ecto.UUID.generate()
      deadline = deadline(attrs, now)
      secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      plaintext = @prefix <> id <> "." <> secret

      {credential_delivery_status, credential_delivery_reason} =
        credential_delivery(target_kind, target)

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
          credential_delivery_reason: credential_delivery_reason
        })
        |> Repo.insert!()

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

  defp deadline(attrs, now) do
    configured = attrs[:deadline_at] || attrs["deadline_at"]
    ttl = Application.get_env(:openagents, :box_api, [])[:ttl_seconds] || 3_600
    maximum = DateTime.add(now, ttl, :second)

    if match?(%DateTime{}, configured) and DateTime.compare(configured, maximum) == :lt,
      do: configured,
      else: maximum
  end

  defp claim_error(changeset) do
    if Enum.any?(changeset.errors, fn {field, _} -> field == :issue_id end),
      do: :assignment_issue_claimed,
      else: :assignment_box_busy
  end

  defp usable?(%AssignmentCredential{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp usable?(_), do: false

  defp author(%{"actor_type" => "agent", "actor_id" => id}), do: Repo.get!(Agent, id)
  defp author(_), do: nil
  defp target_label(%Assignment{target_kind: "computer"}), do: "Computer"
  defp target_label(_), do: "Box"
  defp digest(value), do: :crypto.hash(:sha256, value)
end
