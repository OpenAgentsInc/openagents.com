defmodule OpenAgentsWeb.ComputersLive do
  @moduledoc """
  Approve controller pairing codes and manage this account's paired computers.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Computer
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine

  @presence_refresh_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:machines, dom_id: &"computer-#{&1.id}")
      |> assign(:page_title, "Computers · Sarah")
      |> assign(:controller_enabled?, Computer.enabled?())
      |> assign(:pairing_form, to_form(%{"code" => ""}, as: :pairing))
      |> assign(:pairing_error, nil)
      |> assign(:operation_success, nil)
      |> assign(:subscribed_machine_ids, MapSet.new())
      |> assign(:presence, %{})
      |> assign(:machine_count, 0)
      |> load_machines()

    if connected?(socket), do: schedule_presence_refresh()
    {:ok, socket}
  end

  @impl true
  def handle_event("approve_pairing", _params, %{assigns: %{controller_enabled?: false}} = socket) do
    {:noreply,
     socket
     |> assign(:operation_success, nil)
     |> assign(:pairing_error, "Computer pairing is currently unavailable.")}
  end

  def handle_event("approve_pairing", %{"pairing" => %{"code" => code}}, socket) do
    case Machines.approve_pairing(socket.assigns.current_user, code) do
      {:ok, machine} ->
        {:noreply,
         socket
         |> assign(:pairing_error, nil)
         |> assign(:operation_success, %{
           id: "pairing-success",
           label: "PAIRED",
           message:
             "Computer \"#{machine.name}\" paired. It will appear online after the controller connects."
         })
         |> assign(:pairing_form, to_form(%{"code" => ""}, as: :pairing))
         |> load_machines()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, pairing_error(reason))}
    end
  end

  def handle_event("revoke_machine", %{"id" => machine_id}, socket) do
    case Machines.revoke_machine(socket.assigns.current_user, machine_id) do
      {:ok, machine} ->
        {:noreply,
         socket
         |> assign(:operation_success, %{
           id: "revocation-success",
           label: "REVOKED",
           message:
             "Access for \"#{machine.name}\" was revoked. Any active connection was closed."
         })
         |> assign(:pairing_error, nil)
         |> load_machines()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, "Computer not found.")}
    end
  end

  @impl true
  def handle_info({:computer_presence, machine_id, presence}, socket)
      when presence in [:online, :offline] do
    case Machines.get_machine(socket.assigns.current_user.id, machine_id) do
      {:ok, machine} ->
        presence_map = Map.put(socket.assigns.presence, machine_id, presence == :online)

        {:noreply,
         socket
         |> assign(:presence, presence_map)
         |> stream_insert(:machines, machine)}

      {:error, :machine_not_found} ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:machine_updated, %Machine{user_id: user_id} = machine},
        %{assigns: %{current_user: %{id: user_id}}} = socket
      ) do
    presence_map = Map.put(socket.assigns.presence, machine.id, Computer.online?(machine.id))

    {:noreply,
     socket
     |> assign(:presence, presence_map)
     |> stream_insert(:machines, machine)}
  end

  def handle_info({:machine_updated, %Machine{}}, socket), do: {:noreply, socket}

  def handle_info({:machine_revoked, machine_id}, socket) do
    case Machines.get_machine(socket.assigns.current_user.id, machine_id) do
      {:ok, machine} ->
        presence_map = Map.put(socket.assigns.presence, machine.id, false)

        {:noreply,
         socket
         |> assign(:presence, presence_map)
         |> stream_insert(:machines, machine)}

      {:error, :machine_not_found} ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh_computer_presence, socket) do
    schedule_presence_refresh()
    {:noreply, load_machines(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_machines(socket) do
    machines = Machines.list_machines(socket.assigns.current_user.id)
    socket = subscribe_to_machines(socket, machines)

    presence =
      Map.new(machines, fn machine ->
        {machine.id, machine.status == "active" and Computer.online?(machine.id)}
      end)

    socket
    |> assign(:presence, presence)
    |> assign(:machine_count, length(machines))
    |> stream(:machines, machines, reset: true)
  end

  defp subscribe_to_machines(socket, machines) do
    if connected?(socket) do
      subscribed = socket.assigns.subscribed_machine_ids
      machine_ids = MapSet.new(machines, & &1.id)

      machine_ids
      |> MapSet.difference(subscribed)
      |> Enum.each(&Computer.subscribe/1)

      assign(socket, :subscribed_machine_ids, MapSet.union(subscribed, machine_ids))
    else
      socket
    end
  end

  defp schedule_presence_refresh do
    Process.send_after(self(), :refresh_computer_presence, @presence_refresh_ms)
  end

  defp pairing_error(:pairing_not_found), do: "No pairing found for that code."
  defp pairing_error(:pairing_expired), do: "That pairing code expired. Start over on the CLI."
  defp pairing_error(:pairing_consumed), do: "That pairing code was already used."
  defp pairing_error(:too_many_machines), do: "Computer limit reached. Revoke one to free a slot."
  defp pairing_error(_reason), do: "Pairing failed."

  defp online?(machine, presence) do
    machine.status == "active" and Map.get(presence, machine.id, false)
  end

  defp credential_variant("active"), do: :success
  defp credential_variant(_status), do: :warning

  defp policy_label(tier), do: String.upcase(tier) <> " POLICY"

  defp root_label([]), do: "No approved roots"
  defp root_label([_root]), do: "1 approved root"
  defp root_label(roots), do: "#{length(roots)} approved roots"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="computers-page" class="app-shell computers-shell">
        <Layouts.command_bar aria_label="Sarah computers" current_user={@current_user}>
          <:lockup>
            <.button
              id="return-to-conversation"
              variant={:chip}
              size={:xs}
              phx-click={JS.navigate(~p"/chat")}
            >
              <.icon name="arrow-left" /> RETURN TO CONVERSATION
            </.button>
          </:lockup>
        </Layouts.command_bar>

        <section id="computers-manager" class="computers" aria-label="Paired computers">
          <div class="computers__inner">
            <header class="computers-heading">
              <span class="computers-heading__kicker">YOUR DEVICES</span>
              <h1>Computers</h1>
              <p>
                Give Sarah a governed connection to computers you control. Pairing authorizes
                the declared policy; live presence tells you whether that controller is reachable now.
              </p>
            </header>

            <.card :if={@controller_enabled?} id="pairing-card" class="computers-pairing">
              <div class="computers-pairing__intro">
                <span class="computers-pairing__icon"><.icon name="terminal-lg" /></span>
                <div>
                  <h2>Pair a computer</h2>
                  <p>
                    Run <code>sarah-computer-controller pair</code> on the computer, then enter
                    its one-time code. Codes expire after ten minutes.
                  </p>
                </div>
              </div>

              <.form
                for={@pairing_form}
                id="pairing-form"
                class="computers-pairing__form"
                phx-submit="approve_pairing"
              >
                <.field class="computers-pairing__field">
                  <.label for={@pairing_form[:code].id}>Pairing code</.label>
                  <.input
                    id={@pairing_form[:code].id}
                    name={@pairing_form[:code].name}
                    value={@pairing_form[:code].value}
                    placeholder="ABCD-EFGH"
                    autocomplete="off"
                    maxlength="9"
                    required
                  />
                </.field>
                <.button id="approve-pairing" type="submit" phx-disable-with="Pairing…">
                  Approve pairing
                </.button>
              </.form>
            </.card>

            <.alert
              :if={!@controller_enabled?}
              id="computer-controller-disabled"
              variant={:warning}
              appearance={:notice}
              label="PAIRING UNAVAILABLE"
            >
              <p>
                New pairing codes are disabled in this environment. Existing computers remain
                visible and can still be revoked.
              </p>
            </.alert>

            <div class="computers-notices" aria-live="polite">
              <.alert
                :if={@pairing_error}
                id="pairing-error"
                variant={:danger}
                appearance={:notice}
                label="ATTENTION"
              >
                <p>{@pairing_error}</p>
              </.alert>

              <.alert
                :if={@operation_success}
                id={@operation_success.id}
                variant={:success}
                appearance={:notice}
                label={@operation_success.label}
              >
                <p>{@operation_success.message}</p>
              </.alert>
            </div>

            <section class="computers-list-section" aria-labelledby="computers-list-heading">
              <header class="computers-list-heading">
                <div>
                  <h2 id="computers-list-heading">Paired computers</h2>
                  <p>Credential access and live presence are shown separately.</p>
                </div>
                <.badge variant={:dim}>{@machine_count} total</.badge>
              </header>

              <div id="computers-list" class="computers-list" phx-update="stream">
                <.empty
                  id="computers-empty"
                  class={["hidden", "only:block"]}
                  title="No computers paired"
                >
                  Run the controller on a computer you trust, then approve its one-time code here.
                </.empty>

                <.card
                  :for={{dom_id, machine} <- @streams.machines}
                  id={dom_id}
                  class="computer-card"
                  state={machine.status}
                  data-machine-id={machine.id}
                  data-presence={if(online?(machine, @presence), do: "online", else: "offline")}
                >
                  <div class="computer-card__top">
                    <div class="computer-card__identity">
                      <span class="computer-card__glyph"><.icon name="desktop" /></span>
                      <div>
                        <h3 title={machine.name}>{machine.name}</h3>
                        <span class="computer-card__presence">
                          <.status_indicator
                            state={
                              if(online?(machine, @presence), do: "connected", else: "unavailable")
                            }
                            label={if(online?(machine, @presence), do: "Online", else: "Offline")}
                            decorative
                          />
                          {if(online?(machine, @presence), do: "Online", else: "Offline")}
                        </span>
                      </div>
                    </div>

                    <div class="computer-card__badges">
                      <.badge variant={credential_variant(machine.status)}>
                        {String.upcase(machine.status)} ACCESS
                      </.badge>
                      <.badge variant={:dim}>{policy_label(machine.tier)}</.badge>
                    </div>
                  </div>

                  <dl class="computer-card__facts">
                    <div>
                      <dt>Platform</dt>
                      <dd>{machine.platform || "Not reported"}</dd>
                    </div>
                    <div>
                      <dt>Controller</dt>
                      <dd>{machine.agent_version || "Not reported"}</dd>
                    </div>
                    <div id={"computer-agent-#{machine.id}"}>
                      <dt>Codex</dt>
                      <dd>{codex_runtime(machine.last_probe)}</dd>
                    </div>
                    <div>
                      <dt>Scope</dt>
                      <dd>{root_label(machine.roots)}</dd>
                    </div>
                    <div>
                      <dt>Last seen</dt>
                      <dd>
                        <time
                          :if={machine.last_seen_at}
                          datetime={DateTime.to_iso8601(machine.last_seen_at)}
                        >
                          {Calendar.strftime(machine.last_seen_at, "%Y-%m-%d %H:%M UTC")}
                        </time>
                        <span :if={!machine.last_seen_at}>Never connected</span>
                      </dd>
                    </div>
                  </dl>

                  <footer :if={machine.status == "active"} class="computer-card__actions">
                    <p>Revoking closes its connection and can stop work currently running there.</p>
                    <.text_button
                      id={"revoke-#{machine.id}"}
                      tone={:danger}
                      phx-click="revoke_machine"
                      phx-value-id={machine.id}
                      phx-disable-with="Revoking…"
                      data-confirm={"Revoke access for #{machine.name}? Running work on this computer may stop."}
                    >
                      Revoke access
                    </.text_button>
                  </footer>
                </.card>
              </div>
            </section>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp codex_runtime(%{"acp_agents" => agents}) when is_list(agents) do
    case Enum.find(agents, &(is_map(&1) and &1["id"] == "codex")) do
      %{} = agent ->
        [agent["model"], agent["reasoning_effort"], agent["mode"]]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> case do
          [] -> "Adapter defaults"
          values -> Enum.join(values, " · ")
        end

      nil ->
        "Not available"
    end
  end

  defp codex_runtime(_probe), do: "Not reported"
end
