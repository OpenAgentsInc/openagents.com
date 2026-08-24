defmodule OpenAgentsWeb.AdminForumLinksLive do
  @moduledoc """
  Operator surface for approving or rejecting legacy identity claims.

  The claim these two events act on belongs to someone other than the
  operator clicking the button, so the identifier arrives in the event params
  and nothing in the socket narrows it. IDENTITY-002 says a LiveView event
  must not select another user's record on its own authority, and this surface
  satisfies that in two ways rather than one.

  The authority is the `:operator` live session's `:admin_guard` hook, which
  re-reads the acting account and rechecks `OpenAgents.Accounts.admin?/1`
  before every event, so a demoted operator's next click is halted rather than
  served (ADMIN-001).

  The resolution goes through `OpenAgents.Forum`, never through
  `OpenAgents.Repo`. A LiveView that builds its own query is a surface where
  the scope rule is restated from memory; keeping the query in the context
  keeps it in one place. `OpenAgentsWeb.LiveViewScopeTest` enumerates both
  properties over every LiveView in the router.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :links, Forum.list_pending_actor_links())}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    {:noreply, decide(socket, id, &Forum.approve_actor_link/1, "Claim approved")}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    {:noreply, decide(socket, id, &Forum.reject_actor_link/1, "Claim rejected")}
  end

  # A claim that vanished or was already decided is reported, not raised: the
  # operator is looking at a list another operator may have just acted on.
  defp decide(socket, id, transition, confirmation) do
    case Forum.fetch_actor_link(id) do
      {:ok, %Forum.ActorLink{status: "pending"} = link} ->
        {:ok, _decided} = transition.(link)
        socket |> refresh() |> put_flash(:info, confirmation)

      {:ok, %Forum.ActorLink{}} ->
        socket |> refresh() |> put_flash(:info, "That claim was already decided.")

      {:error, :not_found} ->
        socket |> refresh() |> put_flash(:error, "That claim no longer exists.")
    end
  end

  defp refresh(socket), do: assign(socket, :links, Forum.list_pending_actor_links())

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
