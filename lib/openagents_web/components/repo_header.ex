defmodule OpenAgentsWeb.Components.RepoHeader do
  @moduledoc """
  Renders a GitHub-style repository header and subnavigation.
  """
  use OpenAgentsWeb, :html

  attr :owner, :string, required: true
  attr :repo, :string, required: true
  attr :active, :string, default: "issues"
  attr :open_count, :integer, default: nil
  attr :closed_count, :integer, default: nil

  def repo_header(assigns) do
    ~H"""
    <div class="border-b border-border pb-4 mb-6">
      <div class="flex flex-wrap items-center gap-3 mb-3">
        <span class="avatar size-10 bg-primary text-primary-foreground font-semibold">
          <span>{@owner |> String.first() |> String.upcase()}</span>
        </span>
        <nav class="text-sm" aria-label="Breadcrumb">
          <ol class="flex items-center gap-1">
            <li>
              <.link navigate={~p"/"} class="btn px-0" data-variant="link">{@owner}</.link>
            </li>
            <li aria-hidden="true" class="text-muted-foreground">/</li>
            <li class="font-semibold" aria-current="page">{@repo}</li>
          </ol>
        </nav>
        <span class="badge" data-variant="dim">Public</span>
      </div>
      <%!-- Page navigation, not a tab widget: these are links that change the
      URL, so they carry `aria-current` rather than tab roles, and the selected
      state is the accent underline. --%>
      <nav class="flex gap-1 -mb-4 overflow-x-auto" aria-label={"#{@repo} sections"}>
        <.repo_tab
          patch={~p"/#{@owner}/#{@repo}/issues"}
          selected={@active == "issues"}
          label={"Issues #{if is_integer(@open_count), do: "(#{@open_count})", else: ""}"}
        />
        <.repo_tab
          patch={~p"/#{@owner}/#{@repo}/labels"}
          selected={@active == "labels"}
          label="Labels"
        />
        <.repo_tab
          patch={~p"/#{@owner}/#{@repo}/milestones"}
          selected={@active == "milestones"}
          label="Milestones"
        />
        <.repo_tab
          patch={~p"/#{@owner}/#{@repo}/projects"}
          selected={@active == "projects"}
          label="Projects"
        />
      </nav>
    </div>
    """
  end

  attr :patch, :string, required: true
  attr :selected, :boolean, required: true
  attr :label, :string, required: true

  defp repo_tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      aria-current={@selected && "page"}
      class={[
        "whitespace-nowrap border-b-2 px-3 pb-3 text-sm transition-colors",
        @selected && "border-primary text-foreground font-semibold",
        !@selected && "border-transparent text-muted-foreground hover:text-foreground"
      ]}
    >
      {@label}
    </.link>
    """
  end
end
