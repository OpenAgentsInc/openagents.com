defmodule OpenAgentsWeb.IssueNewLive do
  @moduledoc """
  Renders a form to create a new issue.

  Filing an issue needs an identity, not a membership: any signed-in person
  can open one on a public repository. Labels and milestones are triage
  decisions, so their pickers appear only for repository members with write
  access.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Labels
  alias OpenAgents.Milestones
  alias OpenAgents.Repositories

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    user = socket.assigns.current_user

    repository =
      try do
        Repositories.get_visible_by_path!(owner, repo, user)
      rescue
        Ecto.NoResultsError -> nil
      end

    if is_nil(repository) or not Repositories.issue_participant?(repository, user) do
      {:ok,
       socket
       |> assign(:current_scope, socket.assigns[:current_scope])
       |> put_flash(:error, "You cannot open an issue on that repository.")
       |> redirect(to: ~p"/")}
    else
      changeset = Issues.change_issue(%Issue{}, %{"title" => "", "body" => ""})
      can_write = Repositories.writable?(repository, user)

      {:ok,
       socket
       |> assign(:current_scope, socket.assigns[:current_scope])
       |> assign(:owner, owner)
       |> assign(:repo, repo)
       |> assign(:repository, repository)
       |> assign(:can_write, can_write)
       |> assign(:form, to_form(changeset))
       |> assign(
         :milestone_options,
         if(can_write,
           do: Enum.map(Milestones.list_milestones(repository), &{&1.title, &1.number}),
           else: []
         )
       )
       |> assign(
         :label_options,
         if(can_write,
           do: Enum.map(Labels.list_labels(repository), &{&1.name, &1.name}),
           else: []
         )
       )}
    end
  end

  def handle_event("save", %{"issue" => issue_params}, socket) do
    title = issue_params["title"]
    body = issue_params["body"]
    milestone = if(socket.assigns.can_write, do: issue_params["milestone"] || "", else: "")
    labels = if(socket.assigns.can_write, do: issue_params["labels"] || [], else: [])

    case Issues.create_issue(
           socket.assigns.repository,
           %{"title" => title, "body" => body},
           socket.assigns.current_user
         ) do
      {:ok, issue} ->
        issue = apply_metadata(issue, labels, milestone)

        {:noreply,
         socket
         |> put_flash(:info, "Issue created")
         |> push_navigate(
           to: ~p"/#{socket.assigns.owner}/#{socket.assigns.repo}/issues/#{issue.number}"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp apply_metadata(issue, labels, milestone) do
    labels = List.wrap(labels) |> Enum.reject(&(&1 == ""))

    issue =
      if labels != [] do
        case Issues.add_labels(issue, labels) do
          {:ok, updated} -> updated
          _error -> issue
        end
      else
        issue
      end

    if milestone != "" do
      milestone_number = String.to_integer(milestone)

      case Issues.set_milestone(issue, milestone_number) do
        {:ok, updated} -> updated
        _error -> issue
      end
    else
      issue
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <h1 class="text-2xl font-bold mb-4">New issue</h1>

      <.form
        for={@form}
        id="new-issue-form"
        phx-submit="save"
        class="card !m-0 space-y-4"
      >
        <.input field={@form[:title]} label="Title" required />
        <.input field={@form[:body]} type="textarea" label="Body" />
        <.input
          :if={@can_write}
          field={@form[:milestone]}
          type="select"
          label="Milestone"
          options={@milestone_options}
          prompt="Select a milestone"
        />
        <.input
          :if={@can_write}
          field={@form[:labels]}
          type="select"
          label="Labels"
          options={@label_options}
          multiple
        />
        <footer class="flex justify-end gap-2">
          <.link navigate={~p"/#{@owner}/#{@repo}/issues"} class="btn" data-variant="ghost">
            Cancel
          </.link>
          <.button type="submit" variant={:primary}>Create issue</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end
end
