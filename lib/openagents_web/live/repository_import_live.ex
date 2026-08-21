defmodule OpenAgentsWeb.RepositoryImportLive do
  @moduledoc "Imports one accepted GitHub repository snapshot."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.GitHubProjection

  @impl true
  def mount(_params, _session, socket) do
    {repositories, next_page, error} = candidates(socket.assigns.current_user, 1)

    {:ok,
     socket
     |> assign(:page_title, "Import from GitHub")
     |> assign(:source_repositories, repositories)
     |> assign(:next_page, next_page)
     |> assign(:source_error, error)
     |> assign(:form, import_form(repositories))}
  end

  @impl true
  def handle_event("validate", %{"repository_import" => params}, socket) do
    repository =
      Enum.find(socket.assigns.source_repositories, &(&1["full_name"] == params["source"]))

    source_changed? = params["source"] != socket.assigns.form.params["source"]

    params =
      if is_map(repository) and source_changed? do
        params
        |> Map.put("name", repository["name"])
        |> Map.put("private", to_string(repository["private"]))
      else
        params
      end

    {:noreply, assign(socket, :form, to_form(params, as: :repository_import))}
  end

  def handle_event("load-more", _params, %{assigns: %{next_page: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load-more", _params, socket) do
    {repositories, next_page, error} =
      candidates(socket.assigns.current_user, socket.assigns.next_page)

    {:noreply,
     socket
     |> update(:source_repositories, &(&1 ++ repositories))
     |> assign(:next_page, next_page)
     |> assign(:source_error, error)}
  end

  def handle_event("save", %{"repository_import" => params}, socket) do
    with {:ok, source, _github_repository} <-
           GitHubProjection.import_source(socket.assigns.current_user, params["source"]),
         {:ok, result} <- create_import(socket.assigns.current_user, source, params) do
      _result = result

      {:noreply,
       socket
       |> put_flash(:info, "GitHub import accepted as a one-time copy.")
       |> push_navigate(to: ~p"/repositories")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Import from GitHub"
      sidebar_sections={assigns[:sidebar_sections]}
    >
      <main id="repository-import" class="mx-auto w-full max-w-3xl space-y-8 px-4 py-10">
        <.header>
          Import from GitHub
          <:subtitle>
            Copy one accepted snapshot of branches, tags, and Git history into OpenAgents.
          </:subtitle>
        </.header>

        <.alert id="one-time-import" variant={:info} title="This import does not sync">
          GitHub remains unchanged. Later GitHub commits do not update the OpenAgents repository.
        </.alert>

        <.alert :if={@source_error} id="github-import-error" variant={:warning}>
          {@source_error}
        </.alert>

        <.empty
          :if={@source_repositories == [] and is_nil(@source_error)}
          id="github-repositories-empty"
          title="No eligible GitHub repositories"
        >
          You can import repositories from your GitHub user or an organization where you are an administrator.
        </.empty>

        <.card :if={@source_repositories != []}>
          <.form
            for={@form}
            id="repository-import-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.input
              field={@form[:source]}
              type="select"
              label="GitHub repository"
              options={Enum.map(@source_repositories, &{&1["full_name"], &1["full_name"]})}
              required
            />
            <.input field={@form[:name]} label="Destination name" maxlength="64" required />
            <.input field={@form[:private]} type="checkbox" label="Make this repository private" />

            <.alert id="lfs-import-warning" variant={:warning}>
              Git LFS pointer files are copied, but Git LFS objects are not included in this release.
            </.alert>

            <div class="flex flex-wrap justify-between gap-3">
              <.button
                :if={@next_page}
                id="load-more-github-repositories"
                type="button"
                phx-click="load-more"
                variant={:secondary}
              >
                Load more
              </.button>
              <div class="ml-auto flex gap-3">
                <.button navigate={~p"/repositories"} variant={:secondary}>Cancel</.button>
                <.button id="import-github-repository" type="submit">Import repository</.button>
              </div>
            </div>
          </.form>
        </.card>
      </main>
    </Layouts.app>
    """
  end

  defp candidates(user, page) do
    case GitHubProjection.import_candidates(user, page) do
      {:ok, result} ->
        next_page = if result["has_next_page"], do: result["next_page"], else: nil
        {result["items"], next_page, nil}

      {:error, :github_connection_required} ->
        {[], nil, "Connect GitHub before importing a repository."}

      {:error, :github_scope_required} ->
        {[], nil, "Reconnect GitHub with repository and organization access before importing."}

      {:error, _reason} ->
        {[], nil, "GitHub repositories are unavailable right now."}
    end
  end

  defp create_import(user, source, params) do
    attrs = %{
      name: params["name"],
      visibility: if(params["private"] == "true", do: "private", else: "public"),
      default_branch: source.source_default_branch
    }

    result =
      if source.source_owner_id == user.github_id do
        Repositories.create_user_import(user, source, attrs, Ecto.UUID.generate())
      else
        [owner | _name] = String.split(source.source_full_name, "/", parts: 2)

        with {:ok, namespace} <- GitHubProjection.authorized_organization(user, owner) do
          Repositories.create_organization_import(
            user,
            namespace,
            source,
            attrs,
            Ecto.UUID.generate()
          )
        end
      end

    case result do
      {:ok, repository, repository_import, state} ->
        {:ok, {repository, repository_import, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_form([]),
    do: to_form(%{"source" => "", "name" => "", "private" => "true"}, as: :repository_import)

  defp import_form([repository | _rest]) do
    to_form(
      %{
        "source" => repository["full_name"],
        "name" => repository["name"],
        "private" => to_string(repository["private"])
      },
      as: :repository_import
    )
  end

  defp error_message(:source_repository_not_accessible),
    do: "OpenAgents cannot read that GitHub repository."

  defp error_message(:github_scope_required),
    do: "Reconnect GitHub with repository and organization access."

  defp error_message(%Ecto.Changeset{}), do: "Check the destination name, then try again."
  defp error_message(_reason), do: "OpenAgents could not start this GitHub import."
end
