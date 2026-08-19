defmodule OpenAgentsWeb.IssueNewLive do
  @moduledoc """
  Renders a form to create a new issue.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Issue
  alias OpenAgents.Labels
  alias OpenAgents.Milestones

  def mount(%{"owner" => owner, "repo" => repo}, _session, socket) do
    changeset = Issues.change_issue(%Issue{}, %{"title" => "", "body" => ""})

    socket =
      socket
      |> assign(:current_scope, nil)
      |> assign(:owner, owner)
      |> assign(:repo, repo)
      |> assign(:form, to_form(changeset))
      |> assign(
        :milestone_options,
        Enum.map(Milestones.list_milestones(), &{&1.title, &1.number})
      )
      |> assign(
        :label_options,
        Enum.map(Labels.list_labels(), &{&1.name, &1.name})
      )

    {:ok, socket}
  end

  def handle_event("save", %{"issue" => issue_params}, socket) do
    title = issue_params["title"]
    body = issue_params["body"]
    milestone = issue_params["milestone"] || ""
    labels = issue_params["labels"] || []

    case Issues.create_issue(%{
           "title" => title,
           "body" => body
         }) do
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

    if labels != [] do
      Issues.add_labels(issue, labels)
    end

    if milestone != "" do
      milestone_number = String.to_integer(milestone)
      Issues.set_milestone(issue, milestone_number)
    end

    issue
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="issues" />

      <h1 class="text-2xl font-bold mb-4">New issue</h1>

      <.form
        for={@form}
        id="new-issue-form"
        phx-submit="save"
        class="card bg-base-100 border border-base-300 p-4 space-y-4"
      >
        <.input field={@form[:title]} label="Title" required />
        <.input field={@form[:body]} type="textarea" label="Body" />
        <.input
          field={@form[:milestone]}
          type="select"
          label="Milestone"
          options={@milestone_options}
          prompt="Select a milestone"
        />
        <.input
          field={@form[:labels]}
          type="select"
          label="Labels"
          options={@label_options}
          multiple
        />
        <div class="card-actions justify-end gap-2">
          <.link navigate={~p"/#{@owner}/#{@repo}/issues"} class="btn btn-ghost">
            Cancel
          </.link>
          <.button variant="primary">Create issue</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
