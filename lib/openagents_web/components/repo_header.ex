defmodule OpenAgentsWeb.Components.RepoHeader do
  @moduledoc """
  Renders a GitHub-style repository header and subnavigation.
  """
  use OpenAgentsWeb, :html

  attr :owner, :string, required: true
  attr :repo, :string, required: true
  attr :active, :string, default: "issues"

  def repo_header(assigns) do
    ~H"""
    <div class="border-b border-base-300 pb-4 mb-6">
      <div class="flex flex-wrap items-center gap-3 mb-3">
        <div class="avatar avatar-placeholder">
          <div class="bg-primary text-primary-content w-10 h-10 rounded-full flex items-center justify-center font-semibold">
            {@owner |> String.first() |> String.upcase()}
          </div>
        </div>
        <div class="text-sm breadcrumbs">
          <ul>
            <li>
              <.link navigate={~p"/"} class="link link-primary">
                {@owner}
              </.link>
            </li>
            <li class="font-semibold">{@repo}</li>
          </ul>
        </div>
        <span class="badge badge-sm badge-ghost">Public</span>
      </div>
      <div class="tabs tabs-bordered">
        <.link
          patch={~p"/#{@owner}/#{@repo}/issues"}
          class={["tab", @active == "issues" && "tab-active"]}
        >
          Issues
        </.link>
        <.link
          patch={~p"/#{@owner}/#{@repo}/labels"}
          class={["tab", @active == "labels" && "tab-active"]}
        >
          Labels
        </.link>
        <.link
          patch={~p"/#{@owner}/#{@repo}/milestones"}
          class={["tab", @active == "milestones" && "tab-active"]}
        >
          Milestones
        </.link>
        <.link
          patch={~p"/#{@owner}/#{@repo}/projects"}
          class={["tab", @active == "projects" && "tab-active"]}
        >
          Projects
        </.link>
      </div>
    </div>
    """
  end
end
