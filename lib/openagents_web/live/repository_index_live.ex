defmodule OpenAgentsWeb.RepositoryIndexLive do
  @moduledoc "Lists repositories visible to the signed-in user."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Repositories

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {repositories, more?} =
      Repositories.list_visible_repositories_page(
        socket.assigns.current_user,
        @per_page,
        nil
      )

    {:ok,
     socket
     |> assign(:page_title, "Repositories")
     |> assign(:repository_cursor, cursor(List.last(repositories)))
     |> assign(:repositories_more?, more?)
     |> stream(:repositories, repositories)}
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
     |> stream(:repositories, repositories)}
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
      <main id="repository-index" class="mx-auto w-full max-w-6xl space-y-8 px-4 py-10">
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

        <div id="repositories" phx-update="stream" class="grid gap-4 md:grid-cols-2">
          <.empty
            id="repositories-empty"
            class="hidden only:block md:col-span-2"
            title="No repositories yet"
          >
            Create an empty repository or import a GitHub repository as a one-time copy.
          </.empty>

          <.card :for={{id, repository} <- @streams.repositories} id={id}>
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 space-y-2">
                <.link
                  navigate={~p"/#{repository.namespace.slug}/#{repository.name}"}
                  class="font-semibold text-foreground hover:underline"
                >
                  {repository.namespace.slug}/{repository.name}
                </.link>
                <p :if={repository.description} class="text-sm text-muted-foreground">
                  {repository.description}
                </p>
              </div>
              <.badge variant={status_variant(repository.lifecycle_state)}>
                {repository.lifecycle_state}
              </.badge>
            </div>
            <div class="mt-5 flex flex-wrap gap-2 text-sm text-muted-foreground">
              <span>{repository.visibility}</span>
              <span aria-hidden="true">·</span>
              <span>default branch <code>{repository.default_branch}</code></span>
            </div>
          </.card>
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

  defp status_variant("ready"), do: :success
  defp status_variant("failed"), do: :danger
  defp status_variant(_state), do: :info

  defp cursor(nil), do: nil

  defp cursor(repository) do
    {repository.namespace.slug_key, repository.name_key, repository.id}
  end
end
