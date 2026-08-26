defmodule OpenAgentsWeb.RepositoryIndexLive do
  @moduledoc """
  Every repository the signed-in account can reach, and what each one is doing.

  Three things beyond the name. **Updated time**, because a list of thirty
  repositories sorted by name gives no sense of which ones are alive.
  **Provenance**, because an imported repository is a one-time copy of a GitHub
  repository (REPOSITORY-001) and a reader who does not know that will expect
  it to keep up with the source. **Progress**, because provisioning is the one
  moment a repository exists but cannot be cloned, and a badge reading
  `provisioning` says only that, not whether the copy has started, how many
  attempts it has taken, or why it stopped.

  Progress is read from the two durable receipts — the provisioning outbox row
  and the import row — and refreshed over PubSub rather than by polling: the
  provisioner and the importer already commit those transitions, so announcing
  them costs one message per transition instead of one query per second per
  open browser. DATA-001 holds; the message carries an id, and this view
  re-reads through its own visibility predicate.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Repositories

  @per_page 20

  # `<name>` and `<owner>/<repo>` are placeholders the reader substitutes, so
  # they are interpolated rather than written into the template, where the HEEx
  # parser would read them as tags.
  @cli_steps [
    %{command: "npm i -g @openagentsinc/cli", note: "install"},
    %{command: "openagents auth login", note: "sign in"},
    %{command: "openagents repo create <name>", note: "create"},
    %{command: "openagents repo clone <owner>/<repo>", note: "clone"},
    %{command: "openagents repo import <owner>/<repo>", note: "import once"},
    %{command: "openagents auth setup-git --local", note: "authenticate git"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {repositories, more?} =
      Repositories.list_visible_repositories_page(
        socket.assigns.current_user,
        @per_page,
        nil
      )

    socket =
      if connected?(socket) do
        :ok = Repositories.subscribe_repository_changes()
        socket
      else
        socket
      end

    {:ok,
     socket
     |> assign(:page_title, "Repositories")
     |> assign(:repository_cursor, cursor(List.last(repositories)))
     |> assign(:repositories_more?, more?)
     |> assign(:watching, MapSet.new())
     |> assign(:cli_steps, @cli_steps)
     |> assign(:clone_url_shape, OpenAgentsWeb.Endpoint.url() <> "/<owner>/<name>.git")
     |> stream(:repositories, repositories)
     |> watch(repositories)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {repositories, more?} =
      Repositories.list_visible_repositories_page(
        socket.assigns.current_user,
        @per_page,
        socket.assigns.repository_cursor
      )

    {:noreply,
     socket
     |> assign(
       :repository_cursor,
       cursor(List.last(repositories)) || socket.assigns.repository_cursor
     )
     |> assign(:repositories_more?, more?)
     |> stream(:repositories, repositories)
     |> watch(repositories)}
  end

  @impl true
  def handle_info({:repository_provisioning, repository_id}, socket) do
    case Repositories.get_visible_repository(repository_id, socket.assigns.current_user) do
      nil ->
        {:noreply, unwatch(socket, repository_id)}

      repository ->
        socket = stream_insert(socket, :repositories, repository)

        # Nothing else will ever move, so stop listening. This is what bounds
        # the subscription set: a page left open overnight holds topics only
        # for repositories still doing something.
        if repository.lifecycle_state == "provisioning" do
          {:noreply, socket}
        else
          {:noreply, unwatch(socket, repository_id)}
        end
    end
  end

  def handle_info({:repository_changed, repository_id}, socket) do
    socket = watch_id(socket, repository_id)

    case Repositories.get_visible_repository(repository_id, socket.assigns.current_user) do
      nil ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:repositories, "repositories-#{repository_id}")
         |> unwatch(repository_id)}

      repository ->
        socket = stream_insert(socket, :repositories, repository)

        if repository.lifecycle_state == "provisioning" do
          {:noreply, socket}
        else
          {:noreply, unwatch(socket, repository_id)}
        end
    end
  end

  # Subscribing only to repositories that can still change. A ready repository
  # never transitions again, and a list of a hundred of them would otherwise
  # open a hundred topics that never carry a message.
  defp watch(socket, repositories) do
    if connected?(socket) do
      Enum.reduce(repositories, socket, fn repository, socket ->
        if repository.lifecycle_state == "provisioning" and
             repository.id not in socket.assigns.watching do
          watch_id(socket, repository.id)
        else
          socket
        end
      end)
    else
      socket
    end
  end

  defp watch_id(socket, repository_id) do
    if connected?(socket) and repository_id not in socket.assigns.watching do
      :ok = Repositories.subscribe_provisioning(repository_id)
      assign(socket, :watching, MapSet.put(socket.assigns.watching, repository_id))
    else
      socket
    end
  end

  defp unwatch(socket, repository_id) do
    if repository_id in socket.assigns.watching do
      :ok = Repositories.unsubscribe_provisioning(repository_id)
      assign(socket, :watching, MapSet.delete(socket.assigns.watching, repository_id))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Repositories"
      sidebar_sections={assigns[:sidebar_sections]}
      wide
    >
      <main id="repository-index" class="mx-auto w-full max-w-6xl space-y-6 px-4 py-10">
        <.header>
          Repositories
          <:subtitle>Create an OpenAgents repository or copy one from GitHub once.</:subtitle>
          <:actions>
            <.button
              id="import-repository"
              navigate={~p"/repositories/import/github"}
              variant={:secondary}
            >
              Import from GitHub
            </.button>
            <.button id="new-repository" navigate={~p"/repositories/new"}>New repository</.button>
          </:actions>
        </.header>

        <.cli_panel steps={@cli_steps} clone_url_shape={@clone_url_shape} />

        <div
          id="repositories"
          phx-update="stream"
          class="divide-y divide-border overflow-hidden rounded-lg border border-border bg-card"
        >
          <.empty id="repositories-empty" class="hidden only:block" title="No repositories yet">
            Create an empty repository or import a GitHub repository as a one-time copy.
          </.empty>

          <.repository_row
            :for={{id, repository} <- @streams.repositories}
            id={id}
            repository={repository}
          />
        </div>

        <div :if={@repositories_more?} class="flex justify-center">
          <.button id="repositories-load-more" phx-click="load_more" variant={:secondary}>
            Load more
          </.button>
        </div>
      </main>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :repository, :map, required: true

  defp repository_row(assigns) do
    assigns =
      assigns
      |> assign(:source, import_source(assigns.repository))
      |> assign(:stage, provisioning_stage(assigns.repository))

    ~H"""
    <div id={@id} class="space-y-1 px-4 py-3">
      <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <.link
          navigate={~p"/#{@repository.namespace.slug}/#{@repository.name}"}
          class="truncate font-semibold text-foreground hover:underline"
        >
          <span class="font-normal text-muted-foreground">{@repository.namespace.slug}/</span>{@repository.name}
        </.link>
        <.badge variant={:dim}>{@repository.visibility}</.badge>
        <%!-- A mirror in a list of owned repositories is the easiest place to
        misread one for the other, so the row says which it is. --%>
        <.badge :if={@repository.upstream_url} id={"#{@id}-mirror"} variant={:dim}>
          upstream mirror
        </.badge>
        <.badge :if={@repository.lifecycle_state != "ready"} variant={state_variant(@repository)}>
          {@repository.lifecycle_state}
        </.badge>
        <span
          id={"#{@id}-updated"}
          class="ml-auto shrink-0 text-xs text-muted-foreground"
        >
          Updated {relative_time(@repository.updated_at)}
        </span>
      </div>

      <p :if={@repository.description} class="text-sm text-muted-foreground">
        {@repository.description}
      </p>

      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
        <span>
          default branch <code class="text-foreground">{@repository.default_branch}</code>
        </span>
        <span :if={@source} aria-hidden="true">·</span>
        <%!-- REPOSITORY-001: the snapshot was copied once and is never
        resynchronized, so the row says so rather than implying a mirror. --%>
        <span
          :if={@source && @repository.upstream_url}
          id={"#{@id}-provenance"}
          data-source={@source}
        >
          One-way mirror of <code class="text-foreground">{@repository.upstream_url}</code>,
          licensed {@repository.upstream_license}
        </span>
        <span
          :if={@source && is_nil(@repository.upstream_url)}
          id={"#{@id}-provenance"}
          data-source={@source}
        >
          Imported once from GitHub, from <code class="text-foreground">{@source}</code>
        </span>
      </div>

      <p
        :if={@stage}
        id={"#{@id}-stage"}
        data-state={@stage.state}
        class="flex flex-wrap items-center gap-2 text-xs text-muted-foreground"
      >
        <.status_indicator state={@stage.state} label={@stage.label} decorative />
        <span class="text-foreground">{@stage.label}</span>
        <span :if={@stage.attempt}>attempt {@stage.attempt}</span>
        <code :if={@stage.code} class="text-foreground">{@stage.code}</code>
      </p>
    </div>
    """
  end

  attr :steps, :list, required: true
  attr :clone_url_shape, :string, required: true

  # Secondary rather than dismissible: a native `<details>` needs no JavaScript,
  # is keyboard operable, reports its own state, and costs one closed line to a
  # reader who already has the CLI.
  defp cli_panel(assigns) do
    ~H"""
    <details id="repository-cli" class="overflow-hidden rounded-lg border border-border bg-card">
      <summary class="flex cursor-pointer items-center gap-2 px-4 py-3 text-sm font-medium text-foreground">
        <.icon name="terminal" /> Connect the CLI
      </summary>

      <div class="space-y-3 border-t border-border px-4 py-3">
        <p class="text-sm text-muted-foreground">
          The <code class="text-foreground">openagents</code>
          command creates, clones, and imports these repositories from a terminal.
          Clone URLs are <code class="text-foreground">{@clone_url_shape}</code>.
          <.link navigate={~p"/docs/openagents-cli"} class="text-foreground underline">
            Read the CLI guide.
          </.link>
        </p>

        <ul class="space-y-2">
          <li
            :for={{step, index} <- Enum.with_index(@steps)}
            class="flex items-center gap-2"
            id={"repository-cli-step-#{index}"}
          >
            <code class="min-w-0 flex-1 truncate rounded-md bg-muted px-2 py-1 text-xs text-foreground">
              {step.command}
            </code>
            <span class="hidden shrink-0 text-xs text-muted-foreground sm:inline">
              {step.note}
            </span>
            <.copy_button id={"repository-cli-copy-#{index}"} text={step.command} label="Copy" />
          </li>
        </ul>
      </div>
    </details>
    """
  end

  defp state_variant(%{lifecycle_state: "failed"}), do: :danger
  defp state_variant(_repository), do: :info

  # The GitHub repository this one was copied from, or nil when it was created
  # empty. Only a `github_import` repository has a source to state.
  defp import_source(%{provisioning_kind: "github_import"} = repository) do
    case receipt(repository.repository_import) do
      %{source_full_name: source} when is_binary(source) -> source
      _absent -> nil
    end
  end

  defp import_source(_repository), do: nil

  # What the repository is doing, read from the durable receipts rather than
  # from the lifecycle word alone.
  defp provisioning_stage(%{lifecycle_state: "failed"} = repository) do
    %{
      state: "failed",
      label: "Provisioning failed",
      attempt: attempt_count(repository),
      code:
        repository.provision_error_code || import_error_code(repository) || "provisioning_failed"
    }
  end

  defp provisioning_stage(%{lifecycle_state: "provisioning"} = repository) do
    %{
      state: "running",
      label: stage_label(repository),
      attempt: attempt_count(repository),
      code: import_error_code(repository) || outbox_error_code(repository)
    }
  end

  defp provisioning_stage(_repository), do: nil

  defp stage_label(repository) do
    case {outbox_state(repository), repository.provisioning_kind} do
      {"running", "github_import"} -> import_label(repository)
      {"running", _kind} -> "Creating repository storage"
      {"completed", _kind} -> "Finishing"
      {"failed", _kind} -> "Waiting to retry"
      {_pending_or_absent, "github_import"} -> "Queued to copy from GitHub"
      {_pending_or_absent, _kind} -> "Queued"
    end
  end

  defp import_label(repository) do
    case import_state(repository) do
      "running" -> "Copying the GitHub snapshot"
      "completed" -> "Storing the copied snapshot"
      "failed" -> "Waiting to retry the copy"
      _pending_or_absent -> "Starting the copy from GitHub"
    end
  end

  defp attempt_count(repository) do
    case receipt(repository.provisioning_outbox) do
      %{attempt_count: count} when is_integer(count) and count > 1 -> count
      _first_or_absent -> nil
    end
  end

  defp outbox_state(repository) do
    case receipt(repository.provisioning_outbox) do
      %{state: state} -> state
      nil -> nil
    end
  end

  defp outbox_error_code(repository) do
    case receipt(repository.provisioning_outbox) do
      %{error_code: code} -> code
      nil -> nil
    end
  end

  defp import_state(repository) do
    case receipt(repository.repository_import) do
      %{state: state} -> state
      nil -> nil
    end
  end

  defp import_error_code(repository) do
    case receipt(repository.repository_import) do
      %{error_code: code} -> code
      nil -> nil
    end
  end

  defp receipt(%Ecto.Association.NotLoaded{}), do: nil
  defp receipt(receipt), do: receipt

  # Coarse on purpose: a list wants "roughly when", not arithmetic.
  defp relative_time(nil), do: "recently"

  defp relative_time(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 60 -> "just now"
      s when s < 3_600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3_600)}h ago"
      s when s < 2_592_000 -> "#{div(s, 86_400)}d ago"
      s -> "#{div(s, 2_592_000)}mo ago"
    end
  end

  defp relative_time(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> relative_time()

  defp cursor(nil), do: nil

  defp cursor(repository) do
    {repository.namespace.slug_key, repository.name_key, repository.id}
  end
end
