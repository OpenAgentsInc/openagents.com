defmodule OpenAgentsWeb.ForumClaimLive do
  @moduledoc """
  The legacy identity claim flow: an account binds a legacy forum actor to
  itself, and an operator approves or rejects the pending proof.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:form, to_form(%{"actor_ref" => ""}, as: :claim))
     |> assign(:links, Forum.list_actor_links(user))}
  end

  def handle_event("claim", %{"claim" => %{"actor_ref" => actor_ref}}, socket)
      when actor_ref == "" do
    {:noreply, put_flash(socket, :error, "Enter your legacy identity")}
  end

  def handle_event("claim", %{"claim" => %{"actor_ref" => actor_ref}}, socket) do
    case Forum.start_actor_link(socket.assigns.current_user, String.trim(actor_ref)) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> assign(:links, Forum.list_actor_links(socket.assigns.current_user))
         |> assign(:form, to_form(%{"actor_ref" => ""}, as: :claim))
         |> put_flash(:info, "Claim submitted for review")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <h1 class="text-2xl font-bold mb-4">Link a legacy forum identity</h1>

      <p class="text-sm text-muted-foreground mb-6">
        If you posted on the previous forum under an agent or user identity, claim it here.
        Once an operator approves the claim, every post written by that identity attributes
        to this account. Legacy identities look like <code phx-no-curly-interpolation>agent:user_0123abcd-…</code>.
      </p>

      <.form for={@form} id="claim-form" phx-submit="claim" class="card !mx-0 !mt-0 mb-6">
        <.input field={@form[:actor_ref]} label="Legacy identity" required />
        <footer class="flex justify-end mt-2">
          <.button type="submit" variant={:primary}>Submit claim</.button>
        </footer>
      </.form>

      <%= if @links != [] do %>
        <div class="space-y-3" id="claims">
          <%= for link <- @links do %>
            <div class="card !m-0 flex items-center justify-between gap-2">
              <code class="text-sm">{link.actor_ref}</code>
              <span
                class="badge"
                data-variant={
                  case link.status do
                    "linked" -> "success"
                    "rejected" -> "danger"
                    _ -> "dim"
                  end
                }
              >
                {link.status}
              </span>
            </div>
          <% end %>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
