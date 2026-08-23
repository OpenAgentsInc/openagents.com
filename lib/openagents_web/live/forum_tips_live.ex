defmodule OpenAgentsWeb.ForumTipsLive do
  @moduledoc """
  Your tip destination and what arrived at it.

  The page records where you want tips to go and lists the settlements you can
  check in your own wallet. The forum holds nothing here, so there is no
  balance to withdraw — only payment hashes to verify.
  """
  use OpenAgentsWeb, :live_view

  alias OpenAgents.Forum.Tips

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:current_scope, socket.assigns[:current_scope])
     |> assign(:destination, Tips.active_destination(user.id))
     |> assign(:export, Tips.withdrawal_export(user.id))
     |> assign(:form, destination_form())}
  end

  def handle_event("save_destination", %{"destination" => params}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      user_id: user.id,
      kind: params["kind"],
      destination: params["destination"],
      label: params["label"]
    }

    case Tips.register_destination(attrs) do
      {:ok, destination} ->
        {:noreply,
         socket
         |> assign(:destination, destination)
         |> assign(:export, Tips.withdrawal_export(user.id))
         |> assign(:form, destination_form())
         |> put_flash(:info, "Destination saved. Tips go straight to your wallet.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :destination))}
    end
  end

  def handle_event("toggle_accepting", _params, socket) do
    case socket.assigns.destination do
      nil ->
        {:noreply, put_flash(socket, :error, "Add a destination first")}

      destination ->
        {:ok, updated} = Tips.set_accepting_tips(destination, not destination.accepting_tips)

        {:noreply,
         socket
         |> assign(:destination, updated)
         |> put_flash(
           :info,
           if(updated.accepting_tips, do: "Tips are on", else: "Tips are off")
         )}
    end
  end

  def handle_event("retire_destination", _params, socket) do
    case socket.assigns.destination do
      nil ->
        {:noreply, socket}

      destination ->
        {:ok, _retired} = Tips.retire_destination(destination)

        {:noreply,
         socket
         |> assign(:destination, nil)
         |> assign(:export, Tips.withdrawal_export(socket.assigns.current_user.id))
         |> put_flash(:info, "Destination retired")}
    end
  end

  defp destination_form do
    to_form(%{"kind" => "bolt12", "destination" => "", "label" => ""}, as: :destination)
  end

  defp kind_options do
    [
      {"Bolt 12 offer", "bolt12"},
      {"Lightning address or LNURL", "lnurl"},
      {"On-chain address", "onchain"}
    ]
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/forum"} class="text-sm text-muted-foreground hover:text-foreground">
          Forum
        </.link>
        <span class="text-muted-foreground">/</span>
        <h1 class="text-2xl font-bold">Tips</h1>
      </div>

      <section class="card !mx-0 !mt-0 mb-6">
        <header class="mb-2">
          <h2 class="text-lg font-semibold">Your destination</h2>
          <p class="text-sm text-muted-foreground">
            Tips are paid to a wallet you control. OpenAgents stores where to send sats,
            never a key or a seed, so it can neither hold nor spend them.
          </p>
        </header>

        <%= if @destination do %>
          <dl class="grid grid-cols-2 gap-2 text-sm mb-3" id="tip-destination">
            <dt class="text-muted-foreground">Kind</dt>
            <dd>{@destination.kind}</dd>
            <dt class="text-muted-foreground">Fingerprint</dt>
            <dd class="font-mono">{@destination.fingerprint}</dd>
            <dt class="text-muted-foreground">Accepting tips</dt>
            <dd>{if @destination.accepting_tips, do: "yes", else: "no"}</dd>
          </dl>
          <div class="flex gap-2">
            <.button variant={:secondary} phx-click="toggle_accepting" id="toggle-accepting">
              {if @destination.accepting_tips, do: "Stop accepting tips", else: "Accept tips"}
            </.button>
            <.button variant={:ghost} tone={:danger} phx-click="retire_destination">
              Retire destination
            </.button>
          </div>
        <% end %>

        <.form
          for={@form}
          id="tip-destination-form"
          phx-submit="save_destination"
          class="mt-4 space-y-3"
        >
          <.input field={@form[:kind]} type="select" label="Kind" options={kind_options()} required />
          <.input
            field={@form[:destination]}
            label="Destination"
            placeholder="lno1… , you@example.com, or bc1…"
            required
          />
          <.input field={@form[:label]} label="Label" placeholder="Phone wallet" />
          <footer class="flex justify-end">
            <.button type="submit" variant={:primary}>
              {if @destination, do: "Replace destination", else: "Save destination"}
            </.button>
          </footer>
        </.form>
      </section>

      <section class="card !mx-0">
        <header class="mb-2">
          <h2 class="text-lg font-semibold">Settlements</h2>
          <p class="text-sm text-muted-foreground">
            {@export.received_sats} sats received, {@export.refunded_sats} sats refunded.
            Check each payment hash in your own wallet.
          </p>
        </header>

        <%= if @export.settlements == [] do %>
          <p class="text-sm text-muted-foreground">No tips yet.</p>
        <% else %>
          <table class="table" id="tip-settlements">
            <thead>
              <tr>
                <th>Sats</th>
                <th>State</th>
                <th>Payment hash</th>
                <th>Settled</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={settlement <- @export.settlements}>
                <td>{settlement.amount_sats}</td>
                <td>{settlement.state}</td>
                <td class="font-mono text-xs">{settlement.payment_hash}</td>
                <td>
                  {settlement.settled_at &&
                    Calendar.strftime(settlement.settled_at, "%b %d, %Y %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
