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
      <div class="bg-background border border-border rounded-lg overflow-hidden">
        <div class="flex flex-wrap items-center gap-3 p-4 border-b border-border">
          <div class="flex items-center gap-1">
            <%!-- These two are the current filter, so the selected one carries
            `aria-current` and the accent tone rather than a pressed-button
            class; the style pack has no active state for a link. --%>
            <.link
              patch={~p"/#{@owner}/#{@repo}/issues?state=open"}
              class={["btn gap-1", @state == "open" && "text-foreground font-semibold"]}
              data-variant="ghost"
              data-size="sm"
              aria-current={@state == "open" && "page"}
            >
              <.icon name="warning" class="size-4 text-success" />
              <span class="font-semibold">{@open_count}</span> Open
            </.link>
            <.link
              patch={~p"/#{@owner}/#{@repo}/issues?state=closed"}
              class={["btn gap-1", @state == "closed" && "text-foreground font-semibold"]}
              data-variant="ghost"
              data-size="sm"
              aria-current={@state == "closed" && "page"}
            >
              <.icon name="check-circle" class="size-4 text-muted-foreground" />
              <span class="font-semibold">{@closed_count}</span> Closed
            </.link>
          </div>

          <div class="flex-1 min-w-[12rem]">
            <label class="input w-full max-w-xs flex items-center gap-2">
              <.icon name="search" class="size-4 text-muted-foreground" />
              <input
                type="text"
                placeholder="Search or filter results..."
                class="grow bg-transparent outline-none"
              />
            </label>
          </div>

          <div class="flex items-center gap-1">
            <button class="btn gap-1" data-variant="ghost" data-size="sm">
              <.icon name="tag" class="size-4" /> Labels
            </button>
            <button class="btn gap-1" data-variant="ghost" data-size="sm">
              <.icon name="flag" class="size-4" /> Milestones
            </button>
            <button class="btn gap-1" data-variant="ghost" data-size="sm">
              <.icon name="user" class="size-4" /> Assignees
            </button>
            <button class="btn gap-1" data-variant="ghost" data-size="sm">
              <.icon name="filter" class="size-4" /> Sort
            </button>
          </div>

          <.link
            navigate={~p"/#{@owner}/#{@repo}/issues/new"}
            class="btn"
            data-variant="primary"
            data-size="sm"
          >
            New issue
          </.link>
        </div>

        <%= if @issues_count == 0 do %>
          <div class="p-8 text-center">
            <.icon
              name="clipboard"
              class="size-12 mx-auto mb-3 text-muted-foreground/50"
            />
            <h3 class="text-lg font-medium mb-1">
              No {if(@state == "open", do: "open", else: "closed")} issues
            </h3>
            <p class="text-sm text-muted-foreground">
              Issues will show up here once they are created.
            </p>
          </div>
        <% else %>
          <div id="issues" phx-update="stream" class="divide-y divide-border">
            <div
              :for={{id, issue} <- @streams.issues}
              id={id}
              class="p-4 hover:bg-card"
            >
              <div class="flex items-start gap-4">
                <.icon
                  name={
                    if(issue.state == "open",
                      do: "warning",
                      else: "check-circle"
                    )
                  }
                  class={[
                    "size-5 shrink-0",
                    issue.state == "open" && "text-success",
                    issue.state == "closed" && "text-muted-foreground"
                  ]}
                />
                <div class="flex-1 min-w-0">
                  <h3 class="font-semibold text-base">
                    <.link
                      navigate={~p"/#{@owner}/#{@repo}/issues/#{issue.number}"}
                      class="btn px-0 text-base font-semibold"
                      data-variant="link"
                    >
                      {issue.title}
                    </.link>
                    <span class="text-muted-foreground font-normal text-sm ml-1">
                      #{issue.number}
                    </span>
                  </h3>
                  <p class="text-sm text-muted-foreground mt-1">
                    Opened on {Calendar.strftime(issue.inserted_at, "%b %d, %Y")} by {(issue.user &&
                                                                                         issue.user[
                                                                                           "login"
                                                                                         ]) ||
                      "anonymous"}
                    <%= if issue.comments > 0 do %>
                      <span class="inline-flex items-center gap-1 ml-2">
                        <.icon name="comment" class="size-4" />
                        {issue.comments}
                      </span>
                    <% end %>
                  </p>
                  <div class="flex flex-wrap gap-1 mt-2">
                    <%= for label <- issue.labels || [] do %>
                      <span
                        class="badge rounded-full px-2 py-0.5"
                        style={"background-color: ##{label["color"]}; color: #000;"}
                      >
                        {label["name"]}
                      </span>
                    <% end %>
                  </div>
                </div>
                <div class="avatar-group shrink-0">
                  <%= for assignee <- issue.assignees || [] do %>
                    <span class="avatar size-6" title={assignee["login"]}>
                      <span class="!text-xs">
                        {assignee["login"] |> String.first() |> String.upcase()}
                      </span>
                    </span>
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
