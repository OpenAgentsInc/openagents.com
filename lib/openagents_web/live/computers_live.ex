defmodule OpenAgentsWeb.ComputersLive do
  @moduledoc """
  Approve controller pairing codes and manage this account's paired computers.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Computer
  alias OpenAgents.Machines
  alias OpenAgents.Machines.Machine
  alias OpenAgents.Repositories

  @presence_refresh_ms 15_000

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> stream_configure(:computers, dom_id: &"computer-#{&1.id}")
      |> assign(:page_title, "Computers · Sarah")
      |> assign(:controller_enabled?, Computer.enabled?())
      |> assign(:pairing_form, to_form(%{"code" => prefilled_code(params)}, as: :pairing))
      |> assign(:pairing_error, nil)
      |> assign(:operation_success, nil)
      |> assign(:subscribed_computer_ids, MapSet.new())
      |> assign(:presence, %{})
      |> assign(:computer_count, 0)
      |> assign(:grant_form, to_form(%{}, as: :grant))
      |> assign(:grantable_repositories, [])
      |> assign(:repository_grants, %{})
      |> load_computers()

    if connected?(socket), do: schedule_presence_refresh()
    {:ok, socket}
  end

  # A pairing link may carry its code, the way `/device` does. Without this the
  # code has to be read off the agent's terminal and retyped, and three pairing
  # attempts expired unapproved because of it. Only the shape a code can have is
  # accepted, so a crafted link cannot put arbitrary text in the field.
  defp prefilled_code(params) when is_map(params) do
    case params["user_code"] || params["code"] do
      code when is_binary(code) ->
        normalized = code |> String.trim() |> String.upcase()
        if Regex.match?(~r/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/, normalized), do: normalized, else: ""

      _ ->
        ""
    end
  end

  defp prefilled_code(_), do: ""

  @impl true
  def handle_event("approve_pairing", _params, %{assigns: %{controller_enabled?: false}} = socket) do
    {:noreply,
     socket
     |> assign(:operation_success, nil)
     |> assign(:pairing_error, "Computer pairing is currently unavailable.")}
  end

  def handle_event(
        "approve_pairing",
        %{"pairing" => pairing_params},
        socket
      ) do
    code = Map.get(pairing_params, "code", "")
    enabled = Map.get(pairing_params, "scoped_forge_credentials_enabled", false)

    case Machines.approve_pairing(socket.assigns.current_user, code,
           scoped_forge_credentials_enabled: enabled in ["true", true, "1"]
         ) do
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
         |> load_computers()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, pairing_error(reason))}
    end
  end

  def handle_event(
        "update_scoped_forge_credentials",
        %{"id" => machine_id, "enabled" => enabled},
        socket
      ) do
    enabled = enabled in ["true", true, "1"]

    case Machines.update_scoped_forge_credentials(
           socket.assigns.current_user,
           machine_id,
           enabled
         ) do
      {:ok, machine} ->
        {:noreply,
         socket
         |> assign(:pairing_error, nil)
         |> assign(:operation_success, %{
           id: "credentials-policy-success",
           label: "POLICY UPDATED",
           message:
             "Scoped forge credentials are now #{if(enabled, do: "allowed", else: "disabled")} for \"#{machine.name}\"."
         })
         |> load_computers()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, "Computer not found.")}
    end
  end

  # Repository access for a computer. `repository_machine_grants` is the only
  # thing `OpenAgents.Forge.GitHTTP` consults for a `{:machine, id}` principal,
  # and until this event existed nothing wrote a row, so every Git request a
  # paired computer made answered `404 unknown repository` (#182).
  #
  # Neither identifier selects anything on its own: `OpenAgents.Repositories`
  # resolves the computer through the acting account and the repository through
  # that account's administering membership, so a foreign computer, a
  # repository this account does not administer, and an identifier that names
  # nothing are one refusal (IDENTITY-002).
  def handle_event(
        "grant_repository_access",
        %{"grant" => %{"machine_id" => machine_id, "repository_id" => repository_id} = params},
        socket
      ) do
    operations = if params["operations"] == "write", do: ~w(read write), else: ~w(read)

    case Repositories.grant_machine_access(
           socket.assigns.current_user,
           machine_id,
           repository_id,
           operations
         ) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(:pairing_error, nil)
         |> assign(:operation_success, %{
           id: "repository-grant-success",
           label: "REPOSITORY GRANTED",
           message:
             "The computer can now #{Enum.join(grant.operations, " and ")} that repository over Git."
         })
         |> load_computers()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, grant_error(reason))}
    end
  end

  def handle_event(
        "revoke_repository_access",
        %{"id" => machine_id, "repository-id" => repository_id},
        socket
      ) do
    case Repositories.revoke_machine_access(
           socket.assigns.current_user,
           machine_id,
           repository_id
         ) do
      {:ok, _grant} ->
        {:noreply,
         socket
         |> assign(:pairing_error, nil)
         |> assign(:operation_success, %{
           id: "repository-grant-revoked",
           label: "REPOSITORY WITHDRAWN",
           message: "That computer can no longer reach the repository over Git."
         })
         |> load_computers()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operation_success, nil)
         |> assign(:pairing_error, grant_error(reason))}
    end
  end

  def handle_event("revoke_computer", %{"id" => machine_id}, socket) do
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
         |> load_computers()}

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
         |> stream_insert(:computers, machine)}

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
     |> stream_insert(:computers, machine)}
  end

  def handle_info({:machine_updated, %Machine{}}, socket), do: {:noreply, socket}

  def handle_info({:machine_revoked, machine_id}, socket) do
    case Machines.get_machine(socket.assigns.current_user.id, machine_id) do
      {:ok, machine} ->
        presence_map = Map.put(socket.assigns.presence, machine.id, false)

        {:noreply,
         socket
         |> assign(:presence, presence_map)
         |> stream_insert(:computers, machine)}

      {:error, :machine_not_found} ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh_computer_presence, socket) do
    schedule_presence_refresh()
    {:noreply, load_computers(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_computers(socket) do
    user = socket.assigns.current_user
    machines = Machines.list_machines(user.id)
    socket = subscribe_to_computers(socket, machines)

    presence =
      Map.new(machines, fn machine ->
        {machine.id, machine.status == "active" and Computer.online?(machine.id)}
      end)

    # The grants render inside the stream, so they are reloaded and the stream
    # is reset together — an assign that changes streamed content and is not
    # re-streamed with it goes stale on the client.
    grants = Map.new(machines, &{&1.id, Repositories.list_machine_grants(user, &1.id)})

    socket
    |> assign(:presence, presence)
    |> assign(:computer_count, length(machines))
    |> assign(:grantable_repositories, Repositories.list_grantable_repositories(user))
    |> assign(:repository_grants, grants)
    |> stream(:computers, machines, reset: true)
  end

  defp subscribe_to_computers(socket, machines) do
    if connected?(socket) do
      subscribed = socket.assigns.subscribed_computer_ids
      machine_ids = MapSet.new(machines, & &1.id)

      machine_ids
      |> MapSet.difference(subscribed)
      |> Enum.each(&Computer.subscribe/1)

      assign(socket, :subscribed_computer_ids, MapSet.union(subscribed, machine_ids))
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

  defp grant_error(:machine_not_owned), do: "Computer not found."
  defp grant_error(:repository_not_allowed), do: "You do not administer that repository."
  defp grant_error(:grant_not_found), do: "That computer has no access to that repository."
  defp grant_error(_reason), do: "Repository access could not be changed."

  defp grants_for(grants, machine), do: Map.get(grants, machine.id, [])

  defp operations_label(operations) do
    if "write" in operations, do: "Read and write", else: "Read only"
  end

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
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={assigns[:current_scope]}
      title="Computers"
    >
      <main id="computers-page" class="app-shell computers-shell">
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
                    Run <code>oa computer pair</code> on the computer, then enter its one-time
                    code. Codes expire after ten minutes.
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
                <.field class="computers-pairing__field">
                  <label>
                    <input
                      type="checkbox"
                      name="pairing[scoped_forge_credentials_enabled]"
                      value="true"
                    /> Allow scoped forge credentials on this computer
                  </label>
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
                <.badge variant={:dim}>{@computer_count} total</.badge>
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
                  :for={{dom_id, machine} <- @streams.computers}
                  id={dom_id}
                  class="computer-card"
                  state={machine.status}
                  data-computer-id={machine.id}
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

                  <section
                    :if={machine.status == "active"}
                    id={"repository-access-#{machine.id}"}
                    class="computer-card__repositories"
                    aria-label={"Repository access for #{machine.name}"}
                  >
                    <h4>Repository access</h4>
                    <p>
                      A computer reaches the forge over Git with its own credential. It can read
                      or write only the repositories granted here.
                    </p>

                    <ul
                      :if={grants_for(@repository_grants, machine) != []}
                      class="computer-card__grants"
                    >
                      <li
                        :for={grant <- grants_for(@repository_grants, machine)}
                        id={"grant-#{machine.id}-#{grant.repository_id}"}
                      >
                        <span class="computer-card__grant-name">
                          {grant.repository.owner}/{grant.repository.name}
                        </span>
                        <.badge variant={:dim}>{operations_label(grant.operations)}</.badge>
                        <.text_button
                          id={"revoke-grant-#{machine.id}-#{grant.repository_id}"}
                          tone={:danger}
                          phx-click="revoke_repository_access"
                          phx-value-id={machine.id}
                          phx-value-repository-id={grant.repository_id}
                          phx-disable-with="Withdrawing…"
                        >
                          Withdraw
                        </.text_button>
                      </li>
                    </ul>

                    <p
                      :if={grants_for(@repository_grants, machine) == []}
                      class="computer-card__grants-empty"
                    >
                      No repositories granted. Git requests from this computer are refused.
                    </p>

                    <.form
                      :if={@grantable_repositories != []}
                      for={@grant_form}
                      id={"repository-grant-form-#{machine.id}"}
                      class="computer-card__grant-form"
                      phx-submit="grant_repository_access"
                    >
                      <input type="hidden" name="grant[machine_id]" value={machine.id} />
                      <.input
                        id={"grant-repository-#{machine.id}"}
                        name="grant[repository_id]"
                        value=""
                        type="select"
                        label="Repository"
                        prompt="Choose a repository"
                        options={
                          Enum.map(
                            @grantable_repositories,
                            &{"#{&1.owner}/#{&1.name}", &1.id}
                          )
                        }
                        required
                      />
                      <.input
                        id={"grant-operations-#{machine.id}"}
                        name="grant[operations]"
                        value="read"
                        type="select"
                        label="Access"
                        options={[{"Read only", "read"}, {"Read and write", "write"}]}
                      />
                      <.button
                        id={"grant-repository-submit-#{machine.id}"}
                        type="submit"
                        phx-disable-with="Granting…"
                      >
                        Grant access
                      </.button>
                    </.form>
                  </section>

                  <footer :if={machine.status == "active"} class="computer-card__actions">
                    <p>Revoking closes its connection and can stop work currently running there.</p>
                    <.text_button
                      id={"credentials-policy-#{machine.id}"}
                      phx-click="update_scoped_forge_credentials"
                      phx-value-id={machine.id}
                      phx-value-enabled={
                        if(machine.scoped_forge_credentials_enabled, do: "false", else: "true")
                      }
                      phx-disable-with="Updating…"
                    >
                      {if(machine.scoped_forge_credentials_enabled,
                        do: "Disable scoped forge credentials",
                        else: "Allow scoped forge credentials"
                      )}
                    </.text_button>
                    <.text_button
                      id={"revoke-#{machine.id}"}
                      tone={:danger}
                      phx-click="revoke_computer"
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
