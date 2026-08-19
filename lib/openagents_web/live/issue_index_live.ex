defmodule OpenAgentsWeb.IssueIndexLive do
  @moduledoc """
  Lists issues for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_scope, socket.assigns[:current_scope])}
  end

  def handle_params(%{"owner" => owner, "repo" => repo} = params, _url, socket) do
    state = params["state"] || "open"
    issues = Issues.list_issues(state: state)
    open_count = Issues.list_issues(state: "open") |> length()
    closed_count = Issues.list_issues(state: "closed") |> length()

    socket =
      socket
      |> assign(:owner, owner)
      |> assign(:repo, repo)
      |> assign(:state, state)
      |> assign(:open_count, open_count)
      |> assign(:closed_count, closed_count)
      |> assign(:issues_count, length(issues))
      |> stream(:issues, issues, reset: true)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header
        owner={@owner}
        repo={@repo}
        active="issues"
        open_count={@open_count}
        closed_count={@closed_count}
      />

      <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
        <div class="flex flex-wrap items-center gap-3 p-4 border-b border-base-300">
          <div class="flex items-center gap-1">
            <.link
              patch={~p"/#{@owner}/#{@repo}/issues?state=open"}
              class={[
                "btn btn-sm btn-ghost gap-1",
                @state == "open" && "btn-active"
              ]}
            >
              <.icon name="hero-exclamation-circle" class="size-4 text-success" />
              <span class="font-semibold">{@open_count}</span> Open
            </.link>
            <.link
              patch={~p"/#{@owner}/#{@repo}/issues?state=closed"}
              class={[
                "btn btn-sm btn-ghost gap-1",
                @state == "closed" && "btn-active"
              ]}
            >
              <.icon name="hero-check-circle" class="size-4 text-base-content/50" />
              <span class="font-semibold">{@closed_count}</span> Closed
            </.link>
          </div>

          <div class="flex-1 min-w-[12rem]">
            <label class="input input-sm input-ghost w-full max-w-xs flex items-center gap-2">
              <.icon name="hero-magnifying-glass" class="size-4 text-base-content/50" />
              <input
                type="text"
                placeholder="Search or filter results..."
                class="grow bg-transparent outline-none"
              />
            </label>
          </div>

          <div class="flex items-center gap-1">
            <button class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-tag" class="size-4" /> Labels
            </button>
            <button class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-flag" class="size-4" /> Milestones
            </button>
            <button class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-user" class="size-4" /> Assignees
            </button>
            <button class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-bars-arrow-down" class="size-4" /> Sort
            </button>
          </div>

          <.link navigate={~p"/#{@owner}/#{@repo}/issues/new"} class="btn btn-primary btn-sm">
            New issue
          </.link>
        </div>

        <%= if @issues_count == 0 do %>
          <div class="p-8 text-center">
            <.icon
              name="hero-clipboard-document-list"
              class="size-12 mx-auto mb-3 text-base-content/30"
            />
            <h3 class="text-lg font-medium mb-1">
              No {if(@state == "open", do: "open", else: "closed")} issues
            </h3>
            <p class="text-sm text-base-content/70">
              Issues will show up here once they are created.
            </p>
          </div>
        <% else %>
          <div id="issues" phx-update="stream" class="divide-y divide-base-300">
            <div
              :for={{id, issue} <- @streams.issues}
              id={id}
              class="p-4 hover:bg-base-200"
            >
              <div class="flex items-start gap-4">
                <.icon
                  name={
                    if(issue.state == "open",
                      do: "hero-exclamation-circle",
                      else: "hero-check-circle"
                    )
                  }
                  class={[
                    "size-5 shrink-0",
                    issue.state == "open" && "text-success",
                    issue.state == "closed" && "text-base-content/50"
                  ]}
                />
                <div class="flex-1 min-w-0">
                  <h3 class="font-semibold text-base">
                    <.link
                      navigate={~p"/#{@owner}/#{@repo}/issues/#{issue.number}"}
                      class="link link-primary"
                    >
                      {issue.title}
                    </.link>
                    <span class="text-base-content/50 font-normal text-sm ml-1">
                      #{issue.number}
                    </span>
                  </h3>
                  <p class="text-sm text-base-content/70 mt-1">
                    Opened on {Calendar.strftime(issue.inserted_at, "%b %d, %Y")} by {(issue.user &&
                                                                                         issue.user[
                                                                                           "login"
                                                                                         ]) ||
                      "anonymous"}
                    <%= if issue.comments > 0 do %>
                      <span class="inline-flex items-center gap-1 ml-2">
                        <.icon name="hero-chat-bubble-left" class="size-4" />
                        {issue.comments}
                      </span>
                    <% end %>
                  </p>
                  <div class="flex flex-wrap gap-1 mt-2">
                    <%= for label <- issue.labels || [] do %>
                      <span
                        class="badge badge-sm"
                        style={"background-color: ##{label["color"]}; color: #000;"}
                      >
                        {label["name"]}
                      </span>
                    <% end %>
                  </div>
                </div>
                <div class="flex -space-x-2 shrink-0">
                  <%= for assignee <- issue.assignees || [] do %>
                    <div class="avatar avatar-placeholder" title={assignee["login"]}>
                      <div class="bg-neutral text-neutral-content w-6 h-6 rounded-full flex items-center justify-center text-xs">
                        {assignee["login"] |> String.first() |> String.upcase()}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
