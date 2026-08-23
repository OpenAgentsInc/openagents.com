defmodule OpenAgentsWeb.PullRequestShowLive do
  @moduledoc """
  Shows one repository pull request.

  A stacked pull request presents its own layer as the primary review diff
  — the stored boundary OID to the observed head OID — and offers an
  explicit cumulative preview from the current trunk tip. When a parent
  rewrite makes the stored boundary unreachable, the page explains the
  stale boundary and offers a restack action instead of silently rendering
  lower layers inside the layer diff.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Diff
  alias OpenAgents.Forge.Browse
  alias OpenAgents.PullRequests
  alias OpenAgents.Repositories
  alias OpenAgents.Stacks
  alias OpenAgents.Stacks.Restack
  alias OpenAgentsWeb.RepositoryAccess

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    repository = visible_repository!(owner, repo, socket.assigns.current_user)
    pull_request = PullRequests.get_by_number!(repository, String.to_integer(number))

    stack_context =
      case Stacks.review_context(repository, pull_request) do
        {:ok, context} -> context
        {:error, :not_stacked} -> nil
      end

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:repository, repository)
     |> assign(:pull_request, pull_request)
     |> assign(:stack_context, stack_context)
     |> assign(:stack_operation, nil)
     |> assign(
       :can_write,
       Repositories.writable?(repository, socket.assigns.current_user)
     )
     |> assign(
       :diff_readable,
       RepositoryAccess.full_source?(repository, socket.assigns.current_user)
     )}
  end

  def handle_params(params, _uri, socket) do
    view = if params["view"] == "cumulative", do: :cumulative, else: :layer
    {:noreply, socket |> assign(:stack_view, view) |> assign_stack_diff()}
  end

  defp assign_stack_diff(%{assigns: %{stack_context: nil}} = socket) do
    socket |> assign(:diff_files, []) |> assign(:diff_truncated, false)
  end

  defp assign_stack_diff(%{assigns: assigns} = socket) do
    range =
      case assigns.stack_view do
        :cumulative -> assigns.stack_context.cumulative_range
        :layer -> layer_range_if_intact(assigns.stack_context)
      end

    {diff, truncated} =
      with true <- assigns.diff_readable,
           {base, head} <- range,
           {:ok, diff, truncated} <- Browse.diff_range(assigns.repository, base, head) do
        {diff, truncated}
      else
        _unavailable -> {nil, false}
      end

    socket
    |> assign(:diff_files, Diff.parse(diff))
    |> assign(:diff_truncated, truncated)
  end

  defp layer_range_if_intact(%{boundary_state: :stale}), do: nil
  defp layer_range_if_intact(context), do: context.layer_range

  def handle_event("restack", _params, socket) do
    %{assigns: assigns} = socket

    with true <- assigns.can_write and assigns.stack_context != nil,
         {:ok, {operation, _replay_state}} <-
           Restack.request_from_api(
             assigns.repository,
             assigns.stack_context.stack.number,
             %{},
             assigns.current_user,
             Ecto.UUID.generate()
           ) do
      {:noreply,
       socket
       |> assign(:stack_operation, operation)
       |> put_flash(:info, "Stack rebase started.")}
    else
      {:error, {:operation_in_progress, operation_id}} ->
        {:noreply, socket |> load_operation(operation_id) |> refresh_stack()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The stack rebase could not start.")}

      false ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh-operation", _params, socket) do
    case socket.assigns.stack_operation do
      nil -> {:noreply, socket}
      operation -> {:noreply, socket |> load_operation(operation.id) |> refresh_stack()}
    end
  end

  def handle_event("unstack", _params, socket) do
    %{assigns: assigns} = socket

    with true <- assigns.can_write and assigns.stack_context != nil,
         {:ok, _result} <-
           Stacks.unstack_from_api(
             assigns.repository,
             assigns.stack_context.stack.number,
             %{"pull_request" => assigns.pull_request.issue.number},
             assigns.current_user,
             Ecto.UUID.generate()
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "The pull request left the stack.")
       |> refresh_stack()}
    else
      {:error, {:operation_in_progress, operation_id}} ->
        {:noreply, load_operation(socket, operation_id)}

      {:error, :not_stack_top} ->
        {:noreply, put_flash(socket, :error, "Only the top layer can leave the stack.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The pull request could not leave the stack.")}

      false ->
        {:noreply, socket}
    end
  end

  defp load_operation(socket, operation_id) do
    %{assigns: assigns} = socket

    case Restack.get_operation(
           assigns.repository,
           assigns.stack_context.stack.number,
           operation_id
         ) do
      {:ok, operation} -> assign(socket, :stack_operation, operation)
      {:error, _reason} -> socket
    end
  end

  defp refresh_stack(socket) do
    %{assigns: assigns} = socket

    stack_context =
      case Stacks.review_context(assigns.repository, assigns.pull_request) do
        {:ok, context} -> context
        {:error, :not_stacked} -> nil
      end

    socket
    |> assign(:stack_context, stack_context)
    |> assign_stack_diff()
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title={@pull_request.issue.title}
      full_width
    >
      <main id="pull-request-show" class="app-shell code-shell">
        <.repo_view
          owner={@owner}
          repo={@repo}
          visibility={if @repository.visibility == "public", do: :public, else: :private}
        >
          <:tabs>
            <.repo_tabs>
              <:tab icon="code" navigate={~p"/#{@owner}/#{@repo}"}>Code</:tab>
              <:tab icon="empty-circle" navigate={~p"/#{@owner}/#{@repo}/issues"}>Issues</:tab>
              <:tab icon="pull-request-open" navigate={~p"/#{@owner}/#{@repo}/pulls"} current>
                Pull requests
              </:tab>
              <:tab icon="cube" navigate={~p"/#{@owner}/#{@repo}/projects"}>Projects</:tab>
            </.repo_tabs>
          </:tabs>

          <article class="mx-auto w-full max-w-5xl px-4 py-8">
            <div class="flex flex-wrap items-center gap-3">
              <h1 class="text-2xl font-semibold text-foreground">{@pull_request.issue.title}</h1>
              <.badge variant={if(@pull_request.state == "open", do: :success, else: :secondary)}>
                {@pull_request.state}
              </.badge>
            </div>
            <p class="mt-3 text-sm text-muted-foreground">
              #{@pull_request.issue.number} proposes {@pull_request.head_repository.owner}/{@pull_request.head_repository.name}:{@pull_request.head_ref} into {@owner}/{@repo}:{@pull_request.base_ref}.
            </p>
            <div class="mt-8 rounded-xl border border-border bg-card p-6 whitespace-pre-wrap text-foreground">
              {@pull_request.issue.body || "No description provided."}
            </div>

            <section :if={@stack_context} id="stack-review" class="mt-8">
              <div class="flex flex-wrap items-center gap-3">
                <h2 class="text-lg font-semibold text-foreground">
                  Stack #{@stack_context.stack.number} · layer {@stack_context.position} of {@stack_context.size}
                </h2>
                <.badge variant={
                  if(@stack_context.stack.health == "healthy", do: :success, else: :warning)
                }>
                  {@stack_context.stack.health}
                </.badge>
              </div>

              <.stack_map
                id="stack-map"
                number={@stack_context.stack.number}
                trunk={@stack_context.stack.trunk_ref}
                trunk_navigate={~p"/#{@owner}/#{@repo}/tree/#{@stack_context.stack.trunk_ref}"}
                layers={stack_map_layers(@stack_context, @owner, @repo)}
                class="mt-4 max-w-md"
              >
                <:action :if={@can_write}>
                  <.button id="stack-rebase" variant={:outline} size={:sm} phx-click="restack">
                    Rebase the stack
                  </.button>
                  <.button
                    :if={@stack_context.position == @stack_context.size}
                    id="stack-unstack"
                    variant={:outline}
                    size={:sm}
                    phx-click="unstack"
                  >
                    Remove from stack
                  </.button>
                </:action>
              </.stack_map>

              <p id="stack-readiness" class="mt-3 text-sm text-muted-foreground">
                {readiness(@stack_context)}
              </p>

              <.alert
                :if={@stack_operation}
                id="stack-operation-status"
                variant={operation_variant(@stack_operation.state)}
                appearance={:notice}
                label={operation_label(@stack_operation.state)}
                class="mt-4"
              >
                The rebase runs on the server and moves every branch at once when
                it finishes.
                <:action>
                  <.button
                    id="stack-operation-refresh"
                    variant={:outline}
                    size={:sm}
                    phx-click="refresh-operation"
                  >
                    Check progress
                  </.button>
                </:action>
              </.alert>

              <nav class="mt-4 flex gap-2" aria-label="Stack diff views">
                <.button
                  id="stack-view-layer"
                  patch={~p"/#{@owner}/#{@repo}/pulls/#{@pull_request.issue.number}?view=layer"}
                  variant={if @stack_view == :layer, do: :primary, else: :outline}
                  size={:sm}
                >
                  Layer diff
                </.button>
                <.button
                  id="stack-view-cumulative"
                  patch={~p"/#{@owner}/#{@repo}/pulls/#{@pull_request.issue.number}?view=cumulative"}
                  variant={if @stack_view == :cumulative, do: :primary, else: :outline}
                  size={:sm}
                >
                  Cumulative preview
                </.button>
              </nav>

              <p
                :if={@stack_view == :layer}
                id="stack-layer-range"
                class="mt-3 text-sm text-muted-foreground"
              >
                This layer only: {short(elem(@stack_context.layer_range, 0))} → {short(
                  elem(@stack_context.layer_range, 1)
                )}.
              </p>

              <p
                :if={@stack_view == :cumulative and @stack_context.cumulative_range}
                id="stack-cumulative-range"
                class="mt-3 text-sm text-muted-foreground"
              >
                Everything through position {@stack_context.position}: {short(
                  elem(@stack_context.cumulative_range, 0)
                )} → {short(elem(@stack_context.cumulative_range, 1))}.
              </p>

              <.alert
                :if={@stack_view == :layer and @stack_context.boundary_state == :stale}
                id="stack-stale-boundary"
                variant={:warning}
                appearance={:notice}
                label="This layer is based on an outdated parent commit"
                class="mt-4"
              >
                A lower branch was rewritten, so the stored review boundary no longer
                matches the parent branch. Rebase the stack to restore the intended
                review boundary.
                <:action :if={@can_write}>
                  <.button
                    id="stack-restack-action"
                    variant={:outline}
                    size={:sm}
                    phx-click="restack"
                  >
                    Rebase the stack
                  </.button>
                </:action>
              </.alert>

              <div :if={@diff_files != []} class="mt-6 space-y-4">
                <.diff_file :for={file <- @diff_files} file={file} />
              </div>

              <p :if={@diff_truncated} class="mt-3 text-sm text-muted-foreground">
                The diff is truncated.
              </p>
            </section>
          </article>
        </.repo_view>
      </main>
    </Layouts.app>
    """
  end

  defp short(sha), do: String.slice(sha, 0, 12)

  defp stack_map_layers(context, owner, repo) do
    context.stack.entries
    |> Enum.sort_by(& &1.position, :desc)
    |> Enum.map(fn entry ->
      pull_request = entry.pull_request

      %{
        title: pull_request.issue.title,
        number: pull_request.issue.number,
        branch: pull_request.head_ref,
        state: layer_state(pull_request),
        navigate: ~p"/#{owner}/#{repo}/pulls/#{pull_request.issue.number}",
        current: entry.id == context.entry.id
      }
    end)
  end

  defp readiness(context) do
    states = Enum.map(context.stack.entries, &layer_state(&1.pull_request))
    total = length(states)
    draft = Enum.count(states, &(&1 == "draft"))

    cond do
      context.stack.health != "healthy" ->
        "#{layer_count(total)} · the stack needs a rebase before it can merge"

      draft > 0 ->
        "#{total - draft} of #{layer_count(total)} ready · #{draft} still in draft"

      true ->
        "#{layer_count(total)} ready to merge bottom-first"
    end
  end

  defp layer_count(1), do: "1 layer"
  defp layer_count(count), do: "#{count} layers"

  defp operation_variant(state) when state in ["succeeded"], do: :success
  defp operation_variant(state) when state in ["failed", "cancelled"], do: :danger
  defp operation_variant("waiting_for_conflict_resolution"), do: :warning
  defp operation_variant(_state), do: :info

  defp operation_label("pending"), do: "Stack rebase queued"
  defp operation_label("running"), do: "Stack rebase running"
  defp operation_label("waiting_for_conflict_resolution"), do: "Stack rebase paused on a conflict"
  defp operation_label("waiting_for_checks"), do: "Stack rebase waiting for checks"
  defp operation_label("succeeded"), do: "Stack rebase finished"
  defp operation_label("failed"), do: "Stack rebase failed"
  defp operation_label("cancelled"), do: "Stack rebase cancelled"
  defp operation_label(other), do: other

  defp layer_state(pull_request) do
    cond do
      pull_request.merged_at -> "merged"
      pull_request.state == "closed" -> "closed"
      pull_request.draft -> "draft"
      true -> "open"
    end
  end

  defp visible_repository!(owner, repo, user) do
    Repositories.get_visible_by_path!(owner, repo, user)
  rescue
    Ecto.NoResultsError ->
      raise OpenAgentsWeb.PublicNotFoundError, message: "repository not found"
  end
end
