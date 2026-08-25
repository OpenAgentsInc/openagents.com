defmodule OpenAgentsWeb.IssueShowLive do
  @moduledoc """
  One issue: its description, its history, and the properties you can change.

  Built from `OpenAgentsWeb.UI.Circle`, so the page and the component library
  cannot drift. Every field it shows or edits is one GitHub already has —
  `state`, `state_reason`, `labels`, `assignees`, `milestone`, `locked`, and
  comments. See `docs/2026-08-20-linear-design-github-shape.md`.

  Two structural decisions:

    * **Reading is the default state.** Editing the title and body is behind
      `Edit`, and everything else is edited in place from the rail, so the page
      is a description of the issue rather than a form that happens to be
      showing one.

    * **The history is one feed.** Comments and state changes interleave in a
      single timeline rather than sitting in separate sections, because they
      answer the same question and their order relative to each other is most
      of the answer.

  This schema has no `issue_events` table, so the events are derived from the
  fields it does store: opened from `inserted_at` and `user`, closed from
  `closed_at` and `state_reason`. That is why a close has no actor — nothing
  records who did it, and naming somebody would be a guess.

  Agent work is derived the same way, from the durable assignments that bound
  an attempt to this issue. The issue remains the requested outcome; the page
  reads the attempt records rather than storing a second copy of them.

  Starting that work is the one write here that leaves this application. It
  reaches `OpenAgents.Forge.Assignments.create/1` — the same admission the API
  route uses — so there is no second executor, no queue, and no second work
  record. The objective is read from the issue rather than typed again, and
  every refusal the context returns is shown as itself rather than as a
  generic failure.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Computer
  alias OpenAgents.Conversations
  alias OpenAgents.Forge.Assignments
  alias OpenAgents.Issues
  alias OpenAgents.Issues.ClosingReferences
  alias OpenAgents.Issues.Comment
  alias OpenAgents.Issues.TaskReferences
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Issues.Activity
  alias OpenAgents.Issues.CompletionClaims
  alias OpenAgents.Issues.WorkScope
  alias OpenAgents.Labels
  alias OpenAgents.Machines
  alias OpenAgents.Markdown
  alias OpenAgents.Milestones
  alias OpenAgents.Notifications
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgents.Transparency.WorkDisclosure
  alias OpenAgentsWeb.LiveRefresh
  alias OpenAgentsWeb.OG
  alias OpenAgentsWeb.RelativeTime
  alias OpenAgentsWeb.UI.Circle

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    repository =
      try do
        Repositories.get_visible_by_path!(owner, repo, socket.assigns.current_user)
      rescue
        Ecto.NoResultsError ->
          raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
      end

    issue = Issues.get_issue_by_number!(repository, String.to_integer(number))

    user = socket.assigns.current_user
    can_write = Repositories.writable?(repository, user)

    # Three topics, because three different writes change this page. The issue
    # topic carries the issue and its timeline; the label and milestone topics
    # carry the pickers, which until now moved only when an issue happened to
    # move as well.
    if connected?(socket) do
      Repositories.subscribe_issues(repository.id)
      Assignments.subscribe_attempts(issue.id)
      Labels.subscribe_labels(repository.id)
      Milestones.subscribe_milestones(repository.id)
    end

    {:ok,
     socket
     |> LiveRefresh.init()
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:current_user, user)
     |> assign(:can_write, can_write)
     |> assign(
       :can_participate,
       Repositories.issue_participant?(repository, user)
     )
     |> assign(:can_edit, can_write || author?(issue, user))
     |> assign(:editing, false)
     |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))
     |> assign_repository_options()
     |> assign(
       :og,
       OG.meta(OG.issue(repository.namespace.slug, repository.name, issue))
     )
     |> load(issue)
     |> assign_work_options()}
  end

  def handle_event("toggle_subscription", _params, socket) do
    with_authority(socket, :can_participate, "You can no longer follow this issue.", fn socket ->
      issue = socket.assigns.issue
      user = socket.assigns.current_user

      result =
        if socket.assigns.subscribed? do
          Notifications.unsubscribe(issue, user)
        else
          Notifications.subscribe(issue, user, "manual")
        end

      case result do
        {:ok, _subscription} -> {:noreply, load(socket, issue)}
        {:error, _reason} -> {:noreply, put_flash(socket, :error, "That did not work.")}
      end
    end)
  end

  def handle_event("toggle_edit", _params, socket) do
    with_authority(socket, :can_edit, "You can no longer edit this issue.", fn socket ->
      issue = socket.assigns.issue

      {:noreply,
       socket
       |> assign(:editing, !socket.assigns.editing)
       |> assign(:form, to_form(Issues.change_issue(issue)))}
    end)
  end

  def handle_event("save", %{"issue" => issue_params}, socket) do
    with_authority(socket, :can_edit, "You can no longer edit this issue.", fn socket ->
      issue = socket.assigns.issue
      attrs = %{"title" => issue_params["title"], "body" => issue_params["body"]}

      case Issues.update_issue(issue, attrs, socket.assigns.current_user) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:editing, false)
           |> put_flash(:info, "Issue updated")
           |> load(updated)}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    end)
  end

  # A viewer without authority who hand-crafts an event gets a refusal rather
  # than a silent success; the UI never shows them the control in the first
  # place.
  def handle_event("close", _params, socket),
    do: with_edit_authority(socket, &set_state(&1, "closed", "completed"))

  def handle_event("reopen", _params, socket),
    do: with_edit_authority(socket, &set_state(&1, "open", nil))

  # The rail's state menu picks a close reason as well as a state, which the
  # header's two buttons cannot. Both end in the same write.
  def handle_event("set_state", %{"state" => "open"}, socket),
    do: with_edit_authority(socket, &set_state(&1, "open", nil))

  def handle_event("set_state", %{"state" => "closed"} = params, socket),
    do: with_edit_authority(socket, &set_state(&1, "closed", params["reason"] || "completed"))

  # The computer decides which working directories and which agents are on
  # offer, so choosing one re-reads both rather than leaving a stale list the
  # admission would refuse a moment later.
  def handle_event("preview_work", %{"work" => params}, socket) do
    {:noreply, assign(socket, :work_form, to_form(work_params(socket, params), as: :work))}
  end

  def handle_event("start_work", %{"work" => params}, socket) do
    with_authority(socket, :can_write, "You can no longer start work on this issue.", fn socket ->
      {:noreply, start_work(socket, params)}
    end)
  end

  def handle_event("cancel_work", _params, socket) do
    with_authority(socket, :can_write, "You cannot cancel work on this issue.", fn socket ->
      {:noreply, cancel_work(socket)}
    end)
  end

  def handle_event("toggle_label", %{"name" => name}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue labels.",
      fn socket ->
        issue = socket.assigns.issue

        {:ok, updated} =
          if Enum.any?(issue.labels || [], &(&1["name"] == name)) do
            Issues.remove_label(issue, name, socket.assigns.current_user)
          else
            Issues.add_labels(issue, [name], socket.assigns.current_user)
          end

        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("toggle_assignee", %{"login" => login}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue assignees.",
      fn socket ->
        issue = socket.assigns.issue

        {:ok, updated} =
          if Enum.any?(issue.assignees || [], &(&1["login"] == login)) do
            Issues.remove_assignees(issue, [login], socket.assigns.current_user)
          else
            Issues.add_assignees(issue, [login], socket.assigns.current_user)
          end

        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("set_milestone", %{"number" => number}, socket) do
    with_authority(
      socket,
      :can_write,
      "Only repository members can change issue milestones.",
      fn socket ->
        {:ok, updated} = Issues.set_milestone(socket.assigns.issue, number_or_nil(number))
        {:noreply, load(socket, updated)}
      end
    )
  end

  def handle_event("add_comment", %{"comment" => %{"body" => body}}, socket) do
    with_authority(socket, :can_participate, "Sign in to comment on this issue.", fn socket ->
      issue = socket.assigns.issue

      if issue.locked do
        {:noreply, put_flash(socket, :error, "This conversation is locked.")}
      else
        case Issues.create_comment(issue, %{body: body}, socket.assigns.current_user) do
          {:ok, _comment} ->
            {:noreply,
             socket
             |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))
             |> put_flash(:info, "Comment added")
             |> load(%{issue | comments: issue.comments + 1})}

          {:error, changeset} ->
            {:noreply, assign(socket, :comment_form, to_form(changeset))}
        end
      end
    end)
  end

  def handle_event(_unsupported_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That issue action is not available.")}
  end

  # Live updates: someone else's write re-reads this issue through the same
  # visibility check the mount used. A burst -- an import walking a repository,
  # or a script closing a milestone's worth of issues -- collapses into one
  # re-read rather than one repaint per row.
  def handle_info({:issues_changed, repository_id}, socket)
      when repository_id == socket.assigns.repository.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :issue, &refresh_panel/2)}

  def handle_info({:issues_changed, _other_repository}, socket), do: {:noreply, socket}

  def handle_info({message, repository_id}, socket)
      when message in [:labels_changed, :milestones_changed] and
             repository_id == socket.assigns.repository.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :pickers, &refresh_panel/2)}

  def handle_info({message, _other_repository}, socket)
      when message in [:labels_changed, :milestones_changed],
      do: {:noreply, socket}

  # An attempt moved. The message carries the issue id and nothing else, so
  # this re-reads through `refresh_panel/2` — which re-resolves the repository
  # for this viewer and rebuilds the attempts at this viewer's rung — rather
  # than assigning anything the announcement handed it.
  def handle_info({:attempts_changed, issue_id}, socket)
      when issue_id == socket.assigns.issue.id,
      do: {:noreply, LiveRefresh.mark_stale(socket, :issue, &refresh_panel/2)}

  def handle_info({:attempts_changed, _other_issue}, socket), do: {:noreply, socket}

  # The clock, not a poll. It re-reads nothing: elapsed time is `now` minus the
  # attempt's own start, and the attempt itself moves only when its topic says
  # so. The timer stops itself when the attempt ends.
  def handle_info(:attempt_tick, socket) do
    if socket.assigns[:live_attempt] do
      {:noreply, socket |> assign(:now, DateTime.utc_now()) |> schedule_tick()}
    else
      {:noreply, assign(socket, :ticking?, false)}
    end
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, LiveRefresh.run(socket, &refresh_panel/2)}

  defp refresh_panel(socket, :issue) do
    socket = refresh_authority(socket)
    load(socket, socket.assigns.issue)
  end

  # A label or a milestone written elsewhere re-reads the pickers, and reads
  # the authority that decides whether to offer them in the same call, so the
  # two cannot disagree. It leaves the timeline alone: nothing about the issue
  # moved.
  defp refresh_panel(socket, :pickers), do: refresh_authority(socket)

  defp author?(%Issue{author_user_id: author_id}, %OpenAgents.Accounts.User{id: user_id})
       when is_binary(author_id),
       do: author_id == user_id

  defp author?(_issue, _user), do: false

  defp set_state(socket, state, reason) do
    attrs = %{"state" => state, "state_reason" => reason}

    {:ok, updated} =
      Issues.update_issue(socket.assigns.issue, attrs, socket.assigns.current_user)

    flash = if state == "closed", do: "Issue closed", else: "Issue reopened"

    {:noreply,
     socket
     |> put_flash(:info, flash)
     |> load(updated)}
  end

  defp with_edit_authority(socket, operation) do
    with_authority(socket, :can_edit, "You can no longer change this issue's state.", operation)
  end

  defp with_authority(socket, permission, message, operation) do
    socket = refresh_authority(socket)

    if socket.assigns[permission] do
      operation.(socket)
    else
      {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp refresh_authority(socket) do
    user = socket.assigns.current_user

    visible_repository = Repositories.get_visible_repository(socket.assigns.repository.id, user)
    repository = visible_repository || socket.assigns.repository
    visible? = not is_nil(visible_repository)
    can_write = visible? and Repositories.writable?(repository, user)
    can_participate = visible? and Repositories.issue_participant?(repository, user)
    issue = Issues.get_issue!(socket.assigns.repository, socket.assigns.issue.id)
    can_edit = can_write || (can_participate and author?(issue, user))

    socket
    |> assign(:repository, repository)
    |> assign(:issue, issue)
    |> assign(:can_write, can_write)
    |> assign(:can_participate, can_participate)
    |> assign(:can_edit, can_edit)
    |> assign(:editing, socket.assigns.editing and can_edit)
    |> assign_repository_options()
    |> assign_work_options()
  end

  # The pickers the editor offers. They were read at mount and never again, so
  # a label or a milestone created in another tab was missing from this page
  # until it was reloaded, and a viewer whose write access was revoked kept
  # being offered the assignable list. They are read beside the authority that
  # decides whether to offer them at all, so the two cannot disagree.
  defp assign_repository_options(socket) do
    %{repository: repository, can_write: can_write} = socket.assigns

    socket
    |> assign(:repo_labels, if(can_write, do: Labels.list_labels(repository), else: []))
    |> assign(
      :repo_milestones,
      if(can_write, do: Milestones.list_milestones(repository), else: [])
    )
    |> assign(
      :assignable,
      if(can_write, do: Repositories.list_assignable_users(repository), else: [])
    )
  end

  defp agent_options(computers, computer_id) do
    computers |> Enum.find(&(&1.id == computer_id)) |> acp_agents() |> Enum.map(&{&1, &1})
  end

  defp root_options(computers, computer_id) do
    case Enum.find(computers, &(&1.id == computer_id)) do
      %{roots: roots} when is_list(roots) -> Enum.map(roots, &{&1, &1})
      _absent -> []
    end
  end

  # ── starting bounded agent work ─────────────────────────────────────────

  # Everything the start control offers, read beside the authority that
  # decides whether to offer it at all. A viewer without write access is
  # offered nothing, and a computer that went offline between renders is not
  # in the list — and would still be refused by name if it were.
  defp assign_work_options(socket, params \\ %{}) do
    computers = eligible_computers(socket.assigns)

    socket
    |> assign(:work_computers, computers)
    |> assign(
      :work_form,
      to_form(work_params(computers, socket.assigns.issue, params), as: :work)
    )
  end

  defp eligible_computers(%{can_write: true, current_user: %{id: user_id}}) do
    user_id
    |> Machines.list_machines()
    |> Enum.filter(&startable?/1)
  end

  defp eligible_computers(_assigns), do: []

  # A computer can take this work only if it is connected, has somewhere it is
  # allowed to work, and runs an agent that can be named. Offering one that
  # fails any of the three would produce a refusal a person cannot act on.
  defp startable?(machine) do
    machine.status == "active" and Computer.online?(machine.id) and
      machine.roots not in [nil, []] and acp_agents(machine) != []
  end

  defp acp_agents(%{last_probe: %{"acp_agents" => agents}}) when is_list(agents) do
    for agent <- agents, is_map(agent), is_binary(agent["id"]), agent["id"] != "", do: agent["id"]
  end

  defp acp_agents(_machine), do: []

  defp work_params(socket_or_computers, params_or_issue, params \\ nil)

  defp work_params(%Phoenix.LiveView.Socket{} = socket, params, nil),
    do: work_params(socket.assigns.work_computers, socket.assigns.issue, params)

  defp work_params(computers, issue, params) do
    params = params || %{}
    computer = chosen_computer(computers, params["computer_id"])

    %{
      "computer_id" => computer && computer.id,
      "agent_id" => chosen(acp_agents(computer), params["agent_id"]),
      "cwd" => chosen(computer && computer.roots, params["cwd"]),
      "branch" => branch_or_default(params["branch"], issue)
    }
  end

  defp chosen_computer(computers, id) do
    Enum.find(computers, &(&1.id == id)) || List.first(computers)
  end

  defp chosen(nil, _requested), do: nil
  defp chosen([], _requested), do: nil
  defp chosen(values, requested), do: if(requested in values, do: requested, else: hd(values))

  # The branch is never the default or a protected one — `Assignments` refuses
  # both — so the suggestion names the issue it is for.
  defp branch_or_default(branch, _issue) when is_binary(branch) and branch != "", do: branch
  defp branch_or_default(_branch, issue), do: WorkScope.branch(issue)

  # The one attempt that may be live per issue, per
  # `forge_assignments_one_active_issue_index`. Naming it is what turns a
  # 409 into something a person can read.
  defp live_attempt(attempts) do
    Enum.find(attempts, &(&1.state in ["admitted", "running"]))
  end

  defp start_work(socket, params) do
    %{issue: issue, repository: repository, current_user: user} = socket.assigns
    params = work_params(socket, params)

    with {:ok, computer} <- chosen_or_refuse(socket.assigns.work_computers, params["computer_id"]),
         {:ok, conversation} <- Conversations.ensure_conversation(user) do
      attrs = %{
        "target_kind" => "computer",
        "machine_id" => computer.id,
        "conversation_id" => conversation.id,
        "repository_id" => repository.id,
        "issue_number" => issue.number,
        "branch" => params["branch"],
        "agent_id" => params["agent_id"],
        "cwd" => params["cwd"],
        "prompt" => WorkScope.objective(issue, params["branch"]),
        "requesting_user" => user,
        "requesting_principal" => user
      }

      case Assignments.create(attrs) do
        {:ok, _assignment, _credential} ->
          socket
          |> put_flash(:info, "Work started on #{computer.name}, on branch #{params["branch"]}.")
          |> assign_work_options()
          |> load(Issues.get_issue!(repository, issue.id))

        {:error, reason} ->
          socket
          |> put_flash(:error, refusal(reason, socket))
          |> assign_work_options(params)
      end
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, refusal(reason, socket))
        |> assign_work_options(params)
    end
  end

  defp chosen_or_refuse(computers, id) do
    case Enum.find(computers, &(&1.id == id)) do
      nil -> {:error, :machine_offline}
      computer -> {:ok, computer}
    end
  end

  # The objective comes from the issue, not from free text typed beside it, so
  # what the agent was asked to do and what the issue asked for cannot drift.
  # Every refusal the admission already returns, said as itself. A generic
  # failure here would hide the one fact that tells someone what to do next.
  defp refusal(:assignment_issue_claimed, socket) do
    case live_attempt(socket.assigns[:attempts] || []) do
      %{branch: branch} when is_binary(branch) ->
        "Work is already running on this issue, on branch #{branch}. " <>
          "One attempt may be live at a time."

      _none ->
        "Work is already running on this issue. One attempt may be live at a time."
    end
  end

  defp refusal(:assignment_box_busy, _socket), do: "That computer is already running work."
  defp refusal(:assignment_machine_busy, _socket), do: "That computer is already running work."

  defp refusal(:machine_offline, _socket),
    do: "That computer is not connected. Connect it and try again."

  defp refusal(:machine_revoked, _socket), do: "That computer's access was revoked."
  defp refusal(:machine_not_found, _socket), do: "That computer is no longer paired."

  defp refusal(:protected_branch, _socket),
    do: "That branch is protected. Agent work needs a branch of its own."

  defp refusal(:invalid_assignment_branch, _socket), do: "That is not a usable branch name."

  defp refusal(:repository_not_writable, _socket),
    do: "You can no longer start work on this repository."

  defp refusal(:agent_not_available, _socket),
    do: "That computer is not running the agent you chose."

  defp refusal(:cwd_not_allowed, _socket),
    do: "That working directory is outside what the computer allows."

  defp refusal(:computer_controller_disabled, _socket),
    do: "Starting work on a computer is turned off on this deployment."

  defp refusal(:invalid_delegation_request, _socket),
    do: "This issue does not describe enough to work on. Add a description first."

  defp refusal(:conversation_not_found, _socket),
    do: "Your account has no conversation to run this work in."

  defp refusal(reason, _socket) when is_atom(reason),
    do: "Work was refused: #{reason |> Atom.to_string() |> String.replace("_", " ")}."

  defp refusal(_reason, _socket), do: "Work was refused."

  # The control is hidden without write authority and the event is refused
  # without it too: `Assignments.cancel/2` reads the authority from the
  # attempt's own repository, so a socket that kept a stale `can_write` cannot
  # end anybody's work.
  defp cancel_work(socket) do
    case live_attempt(socket.assigns[:attempts] || []) do
      %{id: id} ->
        case Assignments.cancel(id, socket.assigns.current_user) do
          {:ok, _assignment} ->
            socket
            |> put_flash(:info, "Work cancelled.")
            |> load(socket.assigns.issue)

          {:error, reason} ->
            put_flash(socket, :error, cancel_refusal(reason))
        end

      nil ->
        put_flash(socket, :error, "No work is running on this issue.")
    end
  end

  defp cancel_refusal(:assignment_not_live), do: "That work already finished."
  defp cancel_refusal(:assignment_not_found), do: "That work no longer exists."

  defp cancel_refusal(:repository_not_writable),
    do: "You cannot cancel work on this repository."

  defp cancel_refusal(_reason), do: "Work could not be cancelled."

  defp schedule_tick(socket) do
    Process.send_after(self(), :attempt_tick, 1_000)
    socket
  end

  # How long the live attempt has been running, from the fields `pulse`
  # already publishes. A reader who cannot see the branch can still see this.
  defp elapsed(%{} = attempt, %DateTime{} = now) do
    case attempt[:started_at] || attempt[:admitted_at] do
      %DateTime{} = start -> humanize_seconds(max(DateTime.diff(now, start, :second), 0))
      _unknown -> nil
    end
  end

  defp elapsed(_attempt, _now), do: nil

  defp humanize_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  defp humanize_seconds(seconds) when seconds < 3_600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp humanize_seconds(seconds), do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  # One place rebuilds everything derived from the issue, so a write cannot
  # leave the timeline describing the previous version of the page.
  defp load(socket, issue) do
    comments = Issues.list_comments(issue)
    # An issue can become a pull request while the page is open, and the badge
    # that says so was read at mount only.

    # The page reads attempts at the rung this reader is on, from the same
    # schedule and the same viewer descriptor the API uses. That is what makes
    # "the same viewer gets the same answer on the page and in the API" a
    # property of one function rather than of two lists kept in step by hand.
    attempts =
      Assignments.attempts_for_issue(
        issue,
        WorkDisclosure.viewer(socket.assigns.repository, socket.assigns.current_user)
      )

    references = ClosingReferences.for_issue(issue)
    syncs = TaskReferences.for_issue(issue)
    base = "/#{socket.assigns.owner}/#{socket.assigns.repo}"

    socket
    |> assign(:issue, issue)
    |> assign(:comments, comments)
    |> assign(:attempts, attempts)
    |> assign(:live_attempt, live_attempt(attempts))
    |> assign(:pull_request_state, pull_request_state(issue))
    |> assign(:form, to_form(Issues.change_issue(issue)))
    |> assign(:events, timeline(issue, comments, attempts, references, syncs, base))
    |> assign(:subscribed?, subscribed?(issue, socket.assigns.current_user))
    |> assign(:activity, Activity.for_issue(issue, socket.assigns.current_user))
    |> assign(:claims, CompletionClaims.for_issue(issue))
    |> assign(:scope, WorkScope.for_issue(issue))
    |> assign(:now, DateTime.utc_now())
    |> arm_tick()
  end

  # ── the evidence a reader can act on ────────────────────────────────────
  #
  # The page shows the same assembly the activity endpoint returns, read
  # through the same functions with the same viewer, so the two cannot come
  # apart. Nothing here is a second store: releases are computed from the
  # commit graph, receipts are reached from the issue's own closing
  # references, traces are projected through their own two gates, and the
  # verdict is the row `OUTCOME-001` already wrote.

  defp released_in(%{releases: %{released_in: %{} = release}}), do: release
  defp released_in(_activity), do: nil

  defp receipt_families(%{receipts: receipts}) do
    receipts
    |> Enum.frequencies_by(& &1.family)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp receipt_families(_activity), do: []

  defp visible_traces(%{traces: traces}) when is_list(traces), do: traces
  defp visible_traces(_activity), do: []

  # The verdict a reader needs is the most recent one. Earlier verdicts stay on
  # the record and are read through the API; repeating every attempt's grade in
  # the rail would bury the one that decided whether the issue closed.
  defp latest_claim([]), do: nil
  defp latest_claim(claims), do: List.last(claims)

  defp claim_tone(%{state: "accepted"}), do: "success"
  defp claim_tone(%{state: "not_applicable"}), do: "muted"
  defp claim_tone(_claim), do: "warning"

  defp claim_sentence(%{state: "accepted", closed: true}),
    do: "An accepted outcome closed this issue."

  defp claim_sentence(%{state: "accepted"}),
    do:
      "An outcome was accepted. This repository has not opted in to verified closing, " <>
        "so the issue stays open for a person to decide."

  defp claim_sentence(%{state: "not_applicable"}),
    do: "Graded as outside the gate: human work, or a repository with agents disabled."

  defp claim_sentence(%{state: state}), do: "The last claim graded #{state}."

  defp short_sha(sha) when is_binary(sha), do: binary_part(sha, 0, min(byte_size(sha), 7))
  defp short_sha(_sha), do: ""

  defp section_word(:acceptance_criteria), do: "acceptance criteria"
  defp section_word(:success_metrics), do: "success metrics"
  defp section_word(section), do: to_string(section)

  # The clock is armed only while an attempt is live, so an issue nobody is
  # working on costs no timer at all, and only on the transition into a live
  # attempt, so a re-read cannot stack timers.
  defp arm_tick(socket) do
    live? = not is_nil(socket.assigns[:live_attempt])
    ticking? = socket.assigns[:ticking?] == true

    cond do
      live? and not ticking? and connected?(socket) ->
        socket |> assign(:ticking?, true) |> schedule_tick()

      not live? ->
        assign(socket, :ticking?, false)

      true ->
        socket
    end
  end

  defp subscribed?(_issue, nil), do: false
  defp subscribed?(issue, user), do: Notifications.subscribed?(issue, user)

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      wide
    >
      <Circle.issue_detail>
        <:heading>
          <.form
            :if={@editing}
            for={@form}
            id="issue-edit-form"
            phx-submit="save"
            class="issue-editor"
          >
            <.input field={@form[:title]} label="Title" />
            <.input field={@form[:body]} type="textarea" label="Body" />
            <footer class="issue-editor__foot">
              <button type="button" class="btn" data-variant="ghost" phx-click="toggle_edit">
                Cancel
              </button>
              <.button type="submit" variant={:primary}>Save</.button>
            </footer>
          </.form>

          <div :if={!@editing} class="issue-heading">
            <h1 class="issue-heading__title">
              {@issue.title}
              <span class="issue-heading__number">#{@issue.number}</span>
            </h1>
            <p class="issue-heading__meta">
              <%!-- A pull request is one of these rows, so this page can be
              reached for a number that proposes a change to code. It says so
              with the pull request's own glyph and state, and links to the
              surface that can review it, rather than drawing the issue circle
              over it (#120). --%>
              <Circle.pull_request_state
                :if={@pull_request_state}
                id="issue-pull-request-state"
                state={@pull_request_state}
                show_label
              />
              <Circle.issue_state
                :if={!@pull_request_state}
                state={@issue.state}
                reason={@issue.state_reason}
                show_label
              />
              <span :if={@pull_request_state} class="issue-heading__dot" aria-hidden="true">·</span>
              <.link
                :if={@pull_request_state}
                id="issue-pull-request-link"
                navigate={~p"/#{@owner}/#{@repo}/pulls/#{@issue.number}"}
                class="btn"
                data-variant="link"
              >
                Pull request
              </.link>
              <span class="issue-heading__dot" aria-hidden="true">·</span>
              <span>
                {author(@issue)} opened this {relative(@issue.inserted_at)} ago
              </span>
              <span :if={@issue.comments > 0} class="issue-heading__dot" aria-hidden="true">·</span>
              <span :if={@issue.comments > 0}>
                {@issue.comments} {ngettext_comments(@issue.comments)}
              </span>
            </p>
            <div class="issue-heading__actions">
              <button
                :if={@can_edit and @issue.state == "open"}
                class="btn"
                data-variant="primary"
                data-size="sm"
                phx-click="close"
              >
                Close issue
              </button>
              <button
                :if={@can_edit and @issue.state == "closed"}
                class="btn"
                data-variant="ghost"
                data-size="sm"
                phx-click="reopen"
              >
                Reopen issue
              </button>
              <button
                :if={@can_edit}
                class="btn"
                data-variant="ghost"
                data-size="sm"
                phx-click="toggle_edit"
              >
                <.icon name="edit" /> Edit
              </button>
            </div>
          </div>
        </:heading>

        <:rail>
          <Circle.properties_panel :if={@can_write}>
            <:group heading="State">
              <Circle.field_menu id="issue-state-menu" label="Change the state of this issue">
                <:trigger>
                  <Circle.issue_state
                    state={@issue.state}
                    reason={@issue.state_reason}
                    show_label
                  />
                </:trigger>
                <Circle.field_menu_item
                  :for={{label, state, reason} <- state_options()}
                  label={label}
                  mode={:choice}
                  selected={@issue.state == state and close_reason(@issue) == reason}
                  closes="issue-state-menu"
                  on_select={JS.push("set_state", value: %{state: state, reason: reason})}
                >
                  <:glyph><Circle.issue_state state={state} reason={reason} /></:glyph>
                </Circle.field_menu_item>
              </Circle.field_menu>
            </:group>

            <:group heading="Assignees">
              <Circle.assignee
                :for={assignee <- @issue.assignees}
                name={assignee["login"]}
                show_name
                size={:sm}
              />
              <span :if={@issue.assignees == []} class="properties-panel__none">No one assigned</span>
              <Circle.field_menu id="issue-assignee-menu" label="Assign this issue" align={:end}>
                <:trigger><.icon name="user-add" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  :for={user <- @assignable}
                  label={user.github_login}
                  selected={assigned?(@issue, user.github_login)}
                  on_select={JS.push("toggle_assignee", value: %{login: user.github_login})}
                >
                  <:glyph><Circle.assignee name={user.github_login} size={:sm} /></:glyph>
                </Circle.field_menu_item>
                <p :if={@assignable == []} class="properties-panel__none">
                  Nobody in this repository can be assigned yet.
                </p>
              </Circle.field_menu>
            </:group>

            <:group heading="Labels">
              <Circle.issue_label
                :for={label <- @issue.labels}
                name={label["name"]}
                tone={label_tone(label["color"])}
              />
              <span :if={@issue.labels == []} class="properties-panel__none">None yet</span>
              <Circle.field_menu
                id="issue-label-menu"
                label="Change the labels on this issue"
                align={:end}
              >
                <:trigger><.icon name="tag" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  :for={label <- @repo_labels}
                  label={label.name}
                  selected={labelled?(@issue, label.name)}
                  on_select={JS.push("toggle_label", value: %{name: label.name})}
                >
                  <:glyph>
                    <span class="issue-label__dot" data-tone={label_tone(label.color)} />
                  </:glyph>
                </Circle.field_menu_item>
                <p :if={@repo_labels == []} class="properties-panel__none">
                  This repository has no labels yet.
                </p>
              </Circle.field_menu>
            </:group>

            <:group heading="Milestone">
              <.link
                :if={@issue.milestone}
                navigate={~p"/#{@owner}/#{@repo}/milestones"}
                class="properties-panel__link"
              >
                <.icon name="flag" /> {@issue.milestone["title"]}
              </.link>
              <span :if={!@issue.milestone} class="properties-panel__none">No milestone</span>
              <Circle.field_menu id="issue-milestone-menu" label="Set the milestone" align={:end}>
                <:trigger><.icon name="edit-pencil" class="properties-panel__add" /></:trigger>
                <Circle.field_menu_item
                  label="No milestone"
                  mode={:choice}
                  selected={is_nil(@issue.milestone)}
                  closes="issue-milestone-menu"
                  on_select={JS.push("set_milestone", value: %{number: ""})}
                />
                <Circle.field_menu_item
                  :for={milestone <- @repo_milestones}
                  label={milestone.title}
                  icon="flag"
                  mode={:choice}
                  selected={milestoned?(@issue, milestone.number)}
                  closes="issue-milestone-menu"
                  on_select={JS.push("set_milestone", value: %{number: milestone.number})}
                />
              </Circle.field_menu>
            </:group>
          </Circle.properties_panel>

          <%!-- Outside the properties panel too, and for the opposite
          reason: everything in that panel edits the issue record, and this
          starts an execution somewhere else. Starting and cancelling need
          write authority, which `Assignments.create/1` and
          `Assignments.cancel/2` re-check server-side, so each control is
          hidden and its event is refused rather than only hidden. That a live
          attempt exists, and how long it has run, is not a write and is shown
          to any reader who reached the issue. --%>
          <section :if={@can_write or @live_attempt} id="issue-work" class="properties-panel__group">
            <h3 class="properties-panel__heading">Agent work</h3>

            <%!-- The bound an attempt inherits, said before anyone starts one.
            An unscoped issue is worth naming here rather than at grading time:
            `OUTCOME-001` refuses a claim against it, so the sentence is what
            turns a later `incomplete` into something a person could have
            fixed first. See `OpenAgents.Issues.WorkScope`. --%>
            <p :if={@can_write} class="properties-panel__none" id="issue-work-bound">
              <%= if @scope.scoped? do %>
                This issue states every section an accepted outcome needs, so an attempt on it
                runs for up to an hour.
              <% else %>
                This issue does not state its {Enum.map_join(
                  @scope.missing_sections,
                  ", ",
                  &section_word/1
                )}, so no claim against it can be accepted and an attempt runs for {div(
                  @scope.wall_clock_ms,
                  60_000
                )} minutes.
              <% end %>
            </p>

            <div :if={@live_attempt} id="issue-work-live">
              <p class="properties-panel__none">
                Work is <span id="issue-work-state">{@live_attempt.state}</span>{live_attempt_branch(
                  @live_attempt
                )}, for <span id="issue-work-elapsed">{elapsed(@live_attempt, @now)}</span>.
                One attempt may be live on an issue at a time.
              </p>
              <.button
                :if={@can_write}
                id="issue-work-cancel"
                variant={:ghost}
                size={:sm}
                data-tone="danger"
                phx-click="cancel_work"
              >
                Cancel work
              </.button>
            </div>

            <p
              :if={@can_write and is_nil(@live_attempt) and @work_computers == []}
              class="properties-panel__none"
              id="issue-work-unavailable"
            >
              No connected computer can take this work. Pair one, keep it online, and give it a
              working directory and an agent.
            </p>

            <.form
              :if={@can_write and is_nil(@live_attempt) and @work_computers != []}
              for={@work_form}
              id="issue-work-form"
              phx-change="preview_work"
              phx-submit="start_work"
            >
              <.input
                field={@work_form[:computer_id]}
                type="select"
                label="Computer"
                options={Enum.map(@work_computers, &{&1.name, &1.id})}
              />
              <.input
                field={@work_form[:agent_id]}
                type="select"
                label="Agent"
                options={agent_options(@work_computers, @work_form[:computer_id].value)}
              />
              <.input
                field={@work_form[:cwd]}
                type="select"
                label="Working directory"
                options={root_options(@work_computers, @work_form[:computer_id].value)}
              />
              <.input field={@work_form[:branch]} type="text" label="Branch" />
              <p class="properties-panel__none">
                The objective is read from this issue. The agent may write only this branch, and
                its credential expires with the attempt.
              </p>
              <.button id="issue-work-start" variant={:primary} size={:sm} type="submit">
                Start work
              </.button>
            </.form>
          </section>

          <%!-- What happened to this issue, as records rather than as prose.
          Every line is reachable through
          `GET /api/v1/repos/:owner/:repo/issues/:n/activity` for the same
          reader, because both read `OpenAgents.Issues.Activity` with the same
          viewer. The section is absent when the issue has no evidence at all,
          rather than present and empty. --%>
          <section
            :if={
              released_in(@activity) || receipt_families(@activity) != [] ||
                visible_traces(@activity) != [] || latest_claim(@claims)
            }
            id="issue-evidence"
            class="properties-panel__group"
          >
            <h3 class="properties-panel__heading">Evidence</h3>

            <p :if={claim = latest_claim(@claims)} id="issue-evidence-claim">
              <.badge data-tone={claim_tone(claim)}>{claim.state}</.badge>
              <span class="properties-panel__none">{claim_sentence(claim)}</span>
            </p>

            <p :if={release = released_in(@activity)} id="issue-evidence-release">
              <span class="properties-panel__none">
                Shipped in the release at <code>{short_sha(release.sha)}</code>, promoted {Calendar.strftime(
                  release.promoted_at,
                  "%Y-%m-%d"
                )}.
              </span>
            </p>

            <p
              :for={{family, count} <- receipt_families(@activity)}
              id={"issue-evidence-receipt-#{family}"}
              class="properties-panel__none"
            >
              {count} {family} {if count == 1, do: "receipt", else: "receipts"}
            </p>

            <%!-- An issue says a trajectory exists. It never shows one: the
            steps carry prompts, tool arguments, and tool results, which the
            repository's own gate exists to withhold. See
            `OpenAgents.Issues.TraceDisclosure`. --%>
            <p
              :for={trace <- visible_traces(@activity)}
              id={"issue-evidence-trace-#{trace.id}"}
              class="properties-panel__none"
            >
              An agent trajectory of {trace.step_count} {if trace.step_count == 1,
                do: "step",
                else: "steps"} was recorded<%= if trace[:digest] do %>
                , as <code>{short_sha(String.replace_prefix(trace.digest, "sha256:", ""))}</code>
              <% end %>. Its
              contents are not published here.
            </p>
          </section>

          <%!-- Outside the properties panel on purpose. Everything in that
          panel changes the issue and needs a writable membership; following an
          issue changes only what reaches your own inbox, so it is offered to
          anyone who may take part in the conversation. --%>
          <section :if={@can_participate} class="properties-panel__group">
            <h3 class="properties-panel__heading">Notifications</h3>
            <p class="properties-panel__none">
              {if @subscribed?,
                do: "You get comments on this issue.",
                else: "You do not get comments on this issue."}
            </p>
            <.button
              id="issue-subscription-toggle"
              variant={:ghost}
              size={:sm}
              phx-click="toggle_subscription"
            >
              {if @subscribed?, do: "Unsubscribe", else: "Subscribe"}
            </.button>
          </section>
        </:rail>

        <section class="issue-body">
          <div :if={@issue.body} class="timeline-comment__body !p-0">
            {Markdown.to_html(@issue.body)}
          </div>
          <p :if={!@issue.body} class="properties-panel__none">No description provided.</p>
        </section>

        <Circle.timeline>
          <%= for event <- @events do %>
            <Circle.timeline_comment
              :if={event.kind == :comment}
              id={"comment-#{event.id}"}
              author={event.actor}
              at={event.at}
              badge={event.badge}
            >
              {Markdown.to_html(event.body)}
            </Circle.timeline_comment>
            <Circle.timeline_event
              :if={event.kind == :event}
              actor={event.actor}
              text={event.text}
              icon={event.icon}
              tone={event.tone}
              at={event.at}
            />
            <Circle.timeline_event
              :if={event.kind == :commit}
              id={"closing-reference-#{event.id}"}
              actor={event.actor}
              text={event.text}
              icon={event.icon}
              tone={event.tone}
              at={event.at}
            >
              <.text_button navigate={event.commit_path}>
                <code>{event.short_sha}</code>
              </.text_button>
            </Circle.timeline_event>
          <% end %>
        </Circle.timeline>

        <.alert :if={@issue.locked} variant={:warning} appearance={:notice}>
          This conversation is locked{if @issue.locked_reason, do: " as #{@issue.locked_reason}"}.
        </.alert>

        <.alert
          :if={!@can_participate and !@issue.locked}
          variant={:info}
          appearance={:notice}
          id="sign-in-to-comment"
        >
          <.link navigate={~p"/"} class="font-medium underline">
            Sign in with GitHub
          </.link>
          to comment on this issue.
        </.alert>

        <.form
          :if={@can_participate and !@issue.locked}
          for={@comment_form}
          id="comment-form"
          phx-submit="add_comment"
        >
          <Circle.comment_composer id="issue-composer" author={viewer(@current_user)}>
            <.input
              field={@comment_form[:body]}
              type="textarea"
              label="Comment"
              placeholder="Leave a comment"
            />
            <:hint>Markdown is supported.</:hint>
            <:actions>
              <.button type="submit" variant={:primary} size={:sm}>Comment</.button>
            </:actions>
          </Circle.comment_composer>
        </.form>
      </Circle.issue_detail>
    </Layouts.app>
    """
  end

  # ── the derived history ────────────────────────────────────────────────────

  # GitHub's timeline is an endpoint backed by an event log. This schema has no
  # such table, so the feed is assembled from the columns that do exist. The
  # result is honest but partial: a label added and removed leaves no trace,
  # and a close records when but not who.
  defp timeline(issue, comments, attempts, references, syncs, base) do
    opened = %{
      kind: :event,
      actor: author(issue),
      text: "opened this issue",
      icon: "plus-circle",
      tone: :neutral,
      at: stamp(issue.inserted_at),
      sort: issue.inserted_at
    }

    commented =
      Enum.map(comments, fn comment ->
        login = actor_label(comment.user)

        %{
          kind: :comment,
          id: comment.id,
          actor: login,
          badge: if(login == author(issue), do: "Author"),
          body: comment.body,
          at: stamp(comment.created_at),
          sort: comment.created_at
        }
      end)

    # A close that arrived from a commit names the commit, the pusher, and the
    # push. The derived close below cannot name any of those, so where a
    # commit did the closing that entry stands in for it rather than beside
    # it.
    referenced =
      Enum.map(references, fn reference ->
        %{
          kind: :commit,
          id: reference.id,
          actor: reference_actor(reference),
          text: reference_text(reference),
          icon: if(reference.closed, do: "octicon-issue-closed", else: "commit"),
          tone: if(reference.closed, do: :success, else: :neutral),
          at: stamp(reference.inserted_at),
          sort: reference.inserted_at,
          short_sha: String.slice(reference.commit_sha, 0, 7),
          commit_path: "#{base}/commit/#{reference.commit_sha}"
        }
      end)

    closed_by_commit? = Enum.any?(references, & &1.closed)

    closed =
      if issue.state == "closed" and not closed_by_commit? and issue.closed_at do
        [
          %{
            kind: :event,
            actor: nil,
            text: close_text(issue),
            icon: close_icon(issue),
            tone: close_tone(issue),
            at: stamp(issue.closed_at),
            sort: issue.closed_at
          }
        ]
      else
        []
      end

    Enum.sort_by(
      [opened | commented] ++
        referenced ++
        closed ++
        attempt_events(attempts) ++
        sync_events(syncs),
      & &1.sort,
      DateTime
    )
  end

  # An edit the forge made on its own. It carries the system as its actor
  # rather than the person whose close triggered it: they closed an issue,
  # they did not touch this one.
  defp sync_events(syncs) do
    Enum.map(syncs, fn sync ->
      %{
        kind: :event,
        id: sync.id,
        actor: "system",
        text: sync_text(sync),
        icon: if(sync.checked, do: "check-circle", else: "circle"),
        tone: :neutral,
        at: stamp(sync.inserted_at),
        sort: sync.inserted_at
      }
    end)
  end

  defp sync_text(%{checked: true, reference_number: number}),
    do: "checked the task for ##{number}"

  defp sync_text(%{reference_number: number}), do: "unchecked the task for ##{number}"

  # An attempt produces at most two events: it started, and it ended. Both
  # read from `forge_assignments`, so an attempt that never finished shows as
  # started and nothing more rather than as a silent gap.
  defp attempt_events(attempts) do
    Enum.flat_map(attempts, fn attempt ->
      started_at = attempt[:started_at] || attempt[:admitted_at]

      start =
        if started_at do
          [
            %{
              kind: :event,
              actor: nil,
              text: attempt_start_text(attempt),
              icon: "play",
              tone: :neutral,
              at: stamp(started_at),
              sort: started_at
            }
          ]
        else
          []
        end

      finish =
        if attempt[:finished_at] do
          [
            %{
              kind: :event,
              actor: nil,
              text: attempt_finish_text(attempt),
              icon: attempt_icon(attempt),
              tone: attempt_tone(attempt),
              at: stamp(attempt[:finished_at]),
              sort: attempt[:finished_at]
            }
          ]
        else
          []
        end

      start ++ finish
    end)
  end

  # A projection at `pulse` carries no branch and no revision, so every clause
  # that names one matches on a key that may be absent rather than on a struct
  # field that is always there. The sentence a reader gets is shorter, never
  # wrong: an anonymous reader of a public repository is told that work started
  # and how it ended, and is not told the ref it ran on.
  defp attempt_start_text(%{target_kind: "computer", branch: branch}),
    do: "started work on a computer, on branch #{branch}"

  defp attempt_start_text(%{branch: branch}), do: "started work on a box, on branch #{branch}"

  defp attempt_start_text(%{target_kind: "computer"}), do: "started work on a computer"

  defp attempt_start_text(_attempt), do: "started work on a box"

  defp attempt_finish_text(%{state: "completed", terminal_commit: commit})
       when is_binary(commit),
       do: "finished this work at #{String.slice(commit, 0, 7)}"

  defp attempt_finish_text(%{state: "completed"}), do: "finished this work"

  defp attempt_finish_text(%{state: "cancelled"}), do: "cancelled this work"

  defp attempt_finish_text(%{failure_reason: reason}) when is_binary(reason),
    do: "stopped this work: #{reason}"

  defp attempt_finish_text(_attempt), do: "stopped this work"

  defp live_attempt_branch(%{branch: branch}) when is_binary(branch),
    do:
      Phoenix.HTML.raw(
        " on branch <code>#{Phoenix.HTML.html_escape(branch) |> Phoenix.HTML.safe_to_string()}</code>"
      )

  defp live_attempt_branch(_attempt), do: ""

  defp attempt_icon(%{state: "completed"}), do: "check-circle"
  defp attempt_icon(_attempt), do: "x-circle-filled"

  defp attempt_tone(%{state: "completed"}), do: :success
  defp attempt_tone(%{state: "cancelled"}), do: :neutral
  defp attempt_tone(_attempt), do: :danger

  # The principal is recorded on the row; the login is what a reader
  # recognizes. Falling back to the principal is honest rather than blank.
  defp reference_actor(%{closed_by_user: %{github_login: login}}) when is_binary(login), do: login
  defp reference_actor(reference), do: reference.principal

  defp reference_text(%{closed: true}), do: "closed this as completed in"
  defp reference_text(_reference), do: "referenced this in"

  defp close_text(%{state_reason: "not_planned"}), do: "closed this as not planned"
  defp close_text(%{state_reason: "duplicate"}), do: "closed this as a duplicate"
  defp close_text(_issue), do: "closed this as completed"

  defp close_icon(%{state_reason: reason}) when reason in ["not_planned", "duplicate"],
    do: "x-circle-filled"

  defp close_icon(_issue), do: "octicon-issue-closed"

  defp close_tone(%{state_reason: reason}) when reason in ["not_planned", "duplicate"],
    do: :danger

  defp close_tone(_issue), do: :success

  # ── GitHub's fields, read the way this interface reads them ────────────────

  # The three states this application can express. `duplicate` is a valid
  # GitHub close reason and is rendered when it arrives from the API, but it is
  # not offered here: the menu that sets it has nowhere to record which issue
  # it duplicates, and a duplicate that does not say of what is worse than a
  # plain close.
  defp state_options do
    [
      {"Open", "open", nil},
      {"Closed as completed", "closed", "completed"},
      {"Closed as not planned", "closed", "not_planned"}
    ]
  end

  defp close_reason(%{state: "closed", state_reason: reason}), do: reason || "completed"
  defp close_reason(_issue), do: nil

  # `JS.push` sends a number as a number and a form sends it as a string, so
  # the handler takes whichever arrives rather than making the call sites agree.
  defp number_or_nil(""), do: nil
  defp number_or_nil(number) when is_integer(number), do: number
  defp number_or_nil(number) when is_binary(number), do: String.to_integer(number)

  defp assigned?(issue, login), do: Enum.any?(issue.assignees || [], &(&1["login"] == login))
  defp labelled?(issue, name), do: Enum.any?(issue.labels || [], &(&1["name"] == name))
  defp milestoned?(%{milestone: %{"number" => n}}, number), do: n == number
  defp milestoned?(_issue, _number), do: false

  defp author(issue), do: actor_label(issue.user)

  defp login(%{} = user), do: user["login"] || user[:login] || "anonymous"
  defp login(_user), do: "anonymous"

  defp actor_label(%{"agent" => true} = user), do: "#{login(user)} (agent)"
  defp actor_label(user), do: login(user)

  defp viewer(%{github_login: login}) when is_binary(login), do: login
  defp viewer(_user), do: nil

  defp ngettext_comments(1), do: "comment"
  defp ngettext_comments(_count), do: "comments"

  # A GitHub label carries a hex colour chosen by whoever made it. Rendering it
  # would put a second palette on the page, and dropping it would make every
  # label grey. So the hue is read and mapped to the nearest tone on our
  # ladder: the author's intent survives -- red means broken, green means new
  # -- while the values stay ours.
  defp label_tone(color) when is_binary(color) do
    case Integer.parse(String.trim_leading(color, "#"), 16) do
      {value, _rest} -> hue_tone(value)
      :error -> :neutral
    end
  end

  defp label_tone(_color), do: :neutral

  defp hue_tone(value) do
    r = div(value, 65_536)
    g = value |> div(256) |> rem(256)
    b = rem(value, 256)
    high = Enum.max([r, g, b])
    low = Enum.min([r, g, b])

    # A grey label is as deliberate a choice as a red one, so anything close to
    # the diagonal stays neutral rather than being forced into a hue.
    if high == 0 or (high - low) / high < 0.2 do
      :neutral
    else
      r |> hue(g, b, high, low) |> tone_for_hue()
    end
  end

  defp hue(r, g, b, high, low) do
    delta = high - low

    sextant =
      cond do
        high == r -> wrap((g - b) / delta)
        high == g -> (b - r) / delta + 2
        true -> (r - g) / delta + 4
      end

    sextant * 60
  end

  # The red sextant straddles zero: a value of -0.5 is 330 degrees, not -30.
  defp wrap(sextant) when sextant < 0, do: sextant + 6
  defp wrap(sextant), do: sextant

  defp tone_for_hue(h) when h < 20 or h >= 340, do: :danger
  defp tone_for_hue(h) when h < 70, do: :warning
  defp tone_for_hue(h) when h < 170, do: :success
  defp tone_for_hue(h) when h < 260, do: :info
  defp tone_for_hue(_h), do: :primary

  # `nil` for a plain issue, the pull request's state for a row a pull request
  # is built on. One query per page view, at mount, beside the issue it marks.
  defp pull_request_state(issue) do
    [issue]
    |> PullRequests.markers_by_issue_id()
    |> Map.get(issue.id)
    |> then(&(&1 && &1.state))
  end

  defp stamp(at), do: RelativeTime.ago(at)

  defp relative(at), do: RelativeTime.since(at)
end
