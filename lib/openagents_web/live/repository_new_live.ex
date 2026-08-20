defmodule OpenAgentsWeb.RepositoryNewLive do
  @moduledoc "Creates an empty repository in an eligible GitHub namespace."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Repositories
  alias OpenAgents.Repositories.GitHubProjection

  @impl true
  def mount(_params, _session, socket) do
    {namespaces, namespace_notice} = namespaces(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "New repository")
     |> assign(:namespaces, namespaces)
     |> assign(:namespace_notice, namespace_notice)
     |> assign(:form, repository_form(hd(namespaces).slug))}
  end

  @impl true
  def handle_event("validate", %{"repository" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :repository))}
  end

  def handle_event("save", %{"repository" => params}, socket) do
    namespace = Enum.find(socket.assigns.namespaces, &(&1.slug == params["namespace"]))

    attrs = %{
      name: params["name"],
      description: params["description"],
      visibility: if(params["private"] == "true", do: "private", else: "public"),
      default_branch: params["default_branch"]
    }

    result = create(socket.assigns.current_user, namespace, attrs)

    case result do
      {:ok, _repository, _state} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository provisioning started.")
         |> push_navigate(to: ~p"/repositories")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} title="New repository">
      <main id="repository-new" class="mx-auto w-full max-w-3xl space-y-8 px-4 py-10">
        <.header>
          New repository
          <:subtitle>
            Create an empty Git repository in a namespace you control through GitHub.
          </:subtitle>
        </.header>

        <.alert :if={@namespace_notice} id="namespace-notice" variant={:warning}>
          {@namespace_notice}
        </.alert>

        <.card>
          <.form
            for={@form}
            id="repository-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.input
              field={@form[:namespace]}
              type="select"
              label="Owner namespace"
              options={Enum.map(@namespaces, &{&1.slug, &1.slug})}
              required
            />
            <.input
              field={@form[:name]}
              label="Repository name"
              pattern="[a-z0-9](?:[a-z0-9_-]|\.(?=[a-z0-9])){0,63}"
              maxlength="64"
              placeholder="my-project"
              required
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              maxlength="350"
              rows="3"
            />
            <.input
              field={@form[:default_branch]}
              label="Default branch"
              maxlength="255"
              required
            />
            <.input field={@form[:private]} type="checkbox" label="Make this repository private" />

            <div class="flex flex-wrap justify-end gap-3">
              <.button navigate={~p"/repositories"} variant={:secondary}>Cancel</.button>
              <.button id="create-repository" type="submit">Create repository</.button>
            </div>
          </.form>
        </.card>
      </main>
    </Layouts.app>
    """
  end

  defp namespaces(user) do
    case GitHubProjection.available_namespaces(user) do
      {:ok, namespaces} ->
        {namespaces, nil}

      {:error, _reason} ->
        {:ok, user_namespace} = Repositories.ensure_user_namespace(user)

        {[user_namespace],
         "Reconnect GitHub with repository and organization access to use organization namespaces."}
    end
  end

  defp create(user, %{kind: "user", owner_user_id: user_id}, attrs) when user_id == user.id,
    do: Repositories.create_user_repository(user, attrs, Ecto.UUID.generate())

  defp create(user, %{kind: "organization", slug: slug}, attrs) do
    with {:ok, namespace} <- GitHubProjection.authorized_organization(user, slug) do
      Repositories.create_organization_repository(user, namespace, attrs, Ecto.UUID.generate())
    end
  end

  defp create(_user, _namespace, _attrs), do: {:error, :namespace_not_allowed}

  defp repository_form(namespace) do
    to_form(
      %{
        "namespace" => namespace,
        "name" => "",
        "description" => "",
        "default_branch" => "main",
        "private" => "true"
      },
      as: :repository
    )
  end

  defp error_message(%Ecto.Changeset{}),
    do: "Check the repository name and branch, then try again."

  defp error_message(:idempotency_conflict),
    do: "This create request conflicts with an earlier request."

  defp error_message(_reason), do: "OpenAgents could not create this repository."
end
