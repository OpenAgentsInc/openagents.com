defmodule OpenAgentsWeb.IssueShowLive do
  @moduledoc """
  Shows a single issue, its metadata, and its comment thread.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues
  alias OpenAgents.Issues.Comment

  def mount(%{"owner" => owner, "repo" => repo, "number" => number}, _session, socket) do
    issue = Issues.get_issue_by_number!(String.to_integer(number))
    comments = Issues.list_comments(issue.id)

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:owner, owner)
     |> assign(:repo, repo)
     |> assign(:issue, issue)
     |> assign(:comments, comments)
     |> assign(:editing, false)
     |> assign(:form, to_form(Issues.change_issue(issue)))
     |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))}
  end

  def handle_event("toggle_edit", _params, socket) do
    issue = socket.assigns.issue

    socket =
      socket
      |> assign(:editing, !socket.assigns.editing)
      |> assign(:form, to_form(Issues.change_issue(issue)))

    {:noreply, socket}
  end

  def handle_event("save", %{"issue" => issue_params}, socket) do
    issue = socket.assigns.issue
    title = issue_params["title"]
    body = issue_params["body"]

    case Issues.update_issue(issue, %{"title" => title, "body" => body}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:issue, updated)
         |> assign(:editing, false)
         |> put_flash(:info, "Issue updated")
         |> assign(:form, to_form(Issues.change_issue(updated)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("close", _params, socket) do
    issue = socket.assigns.issue

    {:ok, updated} =
      Issues.update_issue(issue, %{
        "state" => "closed",
        "state_reason" => "completed"
      })

    {:noreply,
     socket
     |> assign(:issue, updated)
     |> put_flash(:info, "Issue closed")}
  end

  def handle_event("reopen", _params, socket) do
    issue = socket.assigns.issue
    {:ok, updated} = Issues.update_issue(issue, %{"state" => "open"})

    {:noreply,
     socket
     |> assign(:issue, updated)
     |> put_flash(:info, "Issue reopened")}
  end

  def handle_event("add_comment", %{"comment" => %{"body" => body}}, socket) do
    issue = socket.assigns.issue

    case Issues.create_comment(%{
           issue_id: issue.id,
           body: body,
           user: %{"login" => "anonymous"}
         }) do
      {:ok, comment} ->
        {:noreply,
         socket
         |> assign(:comments, socket.assigns.comments ++ [comment])
         |> assign(:comment_form, to_form(Comment.changeset(%Comment{}, %{})))
         |> assign(:issue, %{issue | comments: issue.comments + 1})
         |> put_flash(:info, "Comment added")}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @editing do %>
        <.form
          for={@form}
          id="issue-edit-form"
          phx-submit="save"
          class="card bg-base-100 p-4 border border-base-300 mb-6"
        >
          <.input field={@form[:title]} label="Title" />
          <.input field={@form[:body]} type="textarea" label="Body" />
          <div class="card-actions justify-end mt-2 gap-2">
            <button type="button" class="btn btn-ghost" phx-click="toggle_edit">
              Cancel
            </button>
            <.button variant="primary">Save</.button>
          </div>
        </.form>
      <% else %>
        <div class="flex flex-col md:flex-row md:items-start md:justify-between gap-4 mb-6">
          <div class="flex-1">
            <h1 class="text-3xl font-bold mb-2">
              {@issue.title}
              <span class="text-base-content/50 text-xl font-normal">
                #{@issue.number}
              </span>
            </h1>
            <div class="flex items-center gap-2 mb-3">
              <span class={[
                "badge",
                @issue.state == "open" && "badge-success",
                @issue.state == "closed" && "badge-ghost"
              ]}>
                {@issue.state}
              </span>
              <p class="text-sm text-base-content/70">
                Opened on {Calendar.strftime(@issue.inserted_at, "%b %d, %Y")} by {(@issue.user &&
                                                                                      @issue.user[
                                                                                        "login"
                                                                                      ]) ||
                  "anonymous"}
              </p>
            </div>
          </div>
          <div class="flex gap-2 shrink-0">
            <button :if={@issue.state == "open"} class="btn btn-sm btn-success" phx-click="close">
              Close issue
            </button>
            <button :if={@issue.state == "closed"} class="btn btn-sm btn-ghost" phx-click="reopen">
              Reopen issue
            </button>
            <button class="btn btn-sm btn-ghost" phx-click="toggle_edit">
              Edit
            </button>
          </div>
        </div>
      <% end %>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <div class="lg:col-span-3 space-y-6">
          <div class="card bg-base-100 border border-base-300 p-4">
            <p class="whitespace-pre-wrap text-base-content/90">
              {@issue.body || "No description provided."}
            </p>
          </div>

          <h2 class="text-xl font-bold">Comments</h2>

          <div class="space-y-4">
            <%= for comment <- @comments do %>
              <div class="card bg-base-100 border border-base-300 p-4">
                <div class="flex items-center gap-2 mb-2">
                  <div class="avatar avatar-placeholder">
                    <div class="bg-neutral text-neutral-content w-8 h-8 rounded-full flex items-center justify-center text-sm font-semibold">
                      {(comment.user && comment.user["login"] |> String.first() |> String.upcase()) ||
                        "?"}
                    </div>
                  </div>
                  <span class="font-semibold text-sm">
                    {(comment.user && comment.user["login"]) || "anonymous"}
                  </span>
                  <span class="text-sm text-base-content/50">
                    {Calendar.strftime(comment.created_at, "%b %d, %Y %H:%M")}
                  </span>
                </div>
                <p class="whitespace-pre-wrap text-base-content/90">
                  {comment.body}
                </p>
              </div>
            <% end %>
          </div>

          <.form
            for={@comment_form}
            id="comment-form"
            phx-submit="add_comment"
            class="card bg-base-100 border border-base-300 p-4"
          >
            <.input field={@comment_form[:body]} type="textarea" label="Write a comment" />
            <div class="card-actions justify-end mt-2">
              <.button variant="primary">Comment</.button>
            </div>
          </.form>
        </div>

        <div class="space-y-4">
          <%= if @issue.labels != [] do %>
            <div>
              <h3 class="font-semibold text-sm text-base-content/70 mb-2">Labels</h3>
              <div class="flex flex-wrap gap-1">
                <%= for label <- @issue.labels do %>
                  <span
                    class="badge badge-sm"
                    style={"background-color: ##{label["color"]}; color: #000;"}
                  >
                    {label["name"]}
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @issue.assignees != [] do %>
            <div>
              <h3 class="font-semibold text-sm text-base-content/70 mb-2">Assignees</h3>
              <div class="flex -space-x-2">
                <%= for assignee <- @issue.assignees do %>
                  <div class="avatar avatar-placeholder" title={assignee["login"]}>
                    <div class="bg-neutral text-neutral-content w-7 h-7 rounded-full flex items-center justify-center text-xs font-semibold">
                      {assignee["login"] |> String.first() |> String.upcase()}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @issue.milestone do %>
            <div>
              <h3 class="font-semibold text-sm text-base-content/70 mb-2">Milestone</h3>
              <.link
                navigate={~p"/#{@owner}/#{@repo}/milestones"}
                class="badge badge-ghost badge-sm"
              >
                {@issue.milestone["title"]}
              </.link>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
