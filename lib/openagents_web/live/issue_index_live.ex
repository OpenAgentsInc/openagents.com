defmodule OpenAgentsWeb.IssueIndexLive do
  @moduledoc """
  Lists issues for a repository.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Issues

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_scope, nil)}
  end

  def handle_params(%{"owner" => owner, "repo" => repo} = params, _url, socket) do
    state = params["state"] || "open"
    issues = Issues.list_issues(state: state)

    socket =
      socket
      |> assign(:owner, owner)
      |> assign(:repo, repo)
      |> assign(:state, state)
      |> assign(:open_count, Issues.list_issues(state: "open") |> length())
      |> assign(:closed_count, Issues.list_issues(state: "closed") |> length())
      |> stream(:issues, issues, reset: true)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.repo_header owner={@owner} repo={@repo} active="issues" />

      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Issues</h1>
        <.link navigate={~p"/#{@owner}/#{@repo}/issues/new"} class="btn btn-primary btn-sm">
          New issue
        </.link>
      </div>

      <div class="tabs tabs-boxed mb-4">
        <.link
          patch={~p"/#{@owner}/#{@repo}/issues?state=open"}
          class={["tab", @state == "open" && "tab-active"]}
        >
          Open {@open_count}
        </.link>
        <.link
          patch={~p"/#{@owner}/#{@repo}/issues?state=closed"}
          class={["tab", @state == "closed" && "tab-active"]}
        >
          Closed {@closed_count}
        </.link>
      </div>

      <div id="issues" phx-update="stream" class="space-y-2">
        <div
          :for={{id, issue} <- @streams.issues}
          id={id}
          class="card card-compact bg-base-100 border border-base-300 hover:bg-base-200"
        >
          <div class="card-body flex-row items-start gap-4">
            <.icon
              name={
                if(issue.state == "open", do: "hero-exclamation-circle", else: "hero-check-circle")
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
                                                                                     ]) || "anonymous"}
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

      <%= if @streams.issues == [] do %>
        <div class="alert alert-info mt-4">
          <.icon name="hero-information-circle" class="size-5" />
          <span>No {if(@state == "open", do: "open", else: "closed")} issues.</span>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
