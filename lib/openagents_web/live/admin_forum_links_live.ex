defmodule OpenAgentsWeb.AdminForumLinksLive do
  @moduledoc "Operator surface for approving or rejecting legacy identity claims."
  use OpenAgentsWeb, :live_view

  import Ecto.Query, warn: false

  alias OpenAgents.Forum
  alias OpenAgents.Repo

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :links, pending_links())}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    link = Repo.get!(Forum.ActorLink, id)
    {:ok, _} = Forum.approve_actor_link(link)

    {:noreply, socket |> assign(:links, pending_links()) |> put_flash(:info, "Claim approved")}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    link = Repo.get!(Forum.ActorLink, id)
    {:ok, _} = Forum.reject_actor_link(link)

    {:noreply, socket |> assign(:links, pending_links()) |> put_flash(:info, "Claim rejected")}
  end

  defp pending_links do
    Repo.all(
      from l in Forum.ActorLink,
        where: l.status == "pending",
        order_by: [asc: l.inserted_at]
    )
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <h1 class="text-2xl font-bold mb-4">Legacy identity claims</h1>

      <%= if @links == [] do %>
        <div class="alert" data-variant="info" role="status">
          <.icon name="info-circle" class="size-5" />
          <section>No pending claims.</section>
        </div>
      <% else %>
        <div class="space-y-3" id="pending-claims">
          <%= for link <- @links do %>
            <div class="card !m-0 flex items-center justify-between gap-3">
              <div>
                <code class="text-sm">{link.actor_ref}</code>
                <p class="text-xs text-muted-foreground mt-1">account {link.user_id}</p>
              </div>
              <div class="flex gap-2">
                <button
                  class="btn"
                  data-variant="primary"
                  data-size="sm"
                  phx-click="approve"
                  phx-value-id={link.id}
                >Approve</button>
                <button
                  class="btn"
                  data-variant="ghost"
                  data-size="sm"
                  data-tone="danger"
                  phx-click="reject"
                  phx-value-id={link.id}
                >Reject</button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
