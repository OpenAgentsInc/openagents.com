defmodule OpenAgentsWeb.DeviceAuthorizationLive do
  @moduledoc "Authenticated review and approval for one CLI device code."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.{ApiTokens, DeviceAuthorizations}

  @impl true
  def mount(params, _session, socket) do
    user_code = params |> Map.get("user_code", "") |> normalize_code()

    {:ok,
     socket
     |> assign(:page_title, "Authorize OpenAgents CLI")
     |> assign_authorization(DeviceAuthorizations.get_pending_by_user_code(user_code))
     |> assign(:decided, nil)
     |> assign(:form, code_form(user_code))}
  end

  @impl true
  def handle_event("lookup", %{"device" => %{"user_code" => user_code}}, socket) do
    user_code = normalize_code(user_code)

    {:noreply,
     socket
     |> assign_authorization(DeviceAuthorizations.get_pending_by_user_code(user_code))
     |> assign(:decided, nil)
     |> assign(:form, code_form(user_code))}
  end

  def handle_event("approve", _params, socket) do
    decide(socket, &DeviceAuthorizations.approve/2, :approved)
  end

  def handle_event("deny", _params, socket) do
    decide(socket, &DeviceAuthorizations.deny/2, :denied)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Authorize CLI"
      sidebar_sections={assigns[:sidebar_sections]}
    >
      <main id="device-authorization" class="mx-auto w-full max-w-xl space-y-8 px-4 py-12">
        <.header>
          Authorize OpenAgents CLI
          <:subtitle>
            Confirm that the code in your browser matches the code shown in your terminal.
          </:subtitle>
        </.header>

        <.alert :if={@decided == :approved} id="device-approved" variant={:success}>
          Authorization approved. Return to your terminal to finish signing in.
        </.alert>

        <.alert :if={@decided == :denied} id="device-denied" variant={:warning}>
          Authorization denied. You can close this page.
        </.alert>

        <.card :if={is_nil(@decided)}>
          <.form for={@form} id="device-code-form" phx-submit="lookup" class="space-y-4">
            <.input
              field={@form[:user_code]}
              label="Code from your terminal"
              placeholder="ABCD-EFGH"
              maxlength="9"
              autocomplete="one-time-code"
              required
            />
            <.button id="review-device-code" type="submit" variant={:secondary}>
              Review code
            </.button>
          </.form>
        </.card>

        <.alert
          :if={is_nil(@decided) and @form[:user_code].value != "" and is_nil(@authorization)}
          id="device-code-invalid"
          variant={:danger}
        >
          This code is invalid or expired. Start a new login from the CLI.
        </.alert>

        <.card :if={@authorization && is_nil(@decided)} id="device-authorization-review">
          <div class="space-y-5">
            <div>
              <p class="text-sm text-muted-foreground">Terminal code</p>
              <code class="text-2xl font-semibold tracking-widest">{@form[:user_code].value}</code>
            </div>
            <div>
              <%!-- Approving is a grant, and a grant with no named grantee is a
              reflex rather than a decision. The CLI is what this application
              knows is asking: it is the only client that mints a device
              authorization, and `DeviceAuthorizations.claim/3` names the token
              it walks away with "OpenAgents CLI". Which computer it is running
              on is not recorded, so this does not claim to say. --%>
              <p class="font-medium">The OpenAgents CLI is asking to act as you</p>
              <p class="mt-1 text-sm text-muted-foreground">
                Approving gives it these permissions, and no others:
              </p>
              <ul class="mt-2 space-y-1 text-sm text-muted-foreground">
                <li :for={scope <- @authorization.scopes} class="flex items-baseline gap-2">
                  <code>{scope}</code>
                  <span>{scope_description(scope)}</span>
                </li>
              </ul>
              <p :if={@privileged?} class="mt-3 text-sm font-medium text-foreground">
                This request includes operator authority over the OpenAgents fleet. Authorize it
                only if you started this login yourself.
              </p>
              <p class="mt-3 text-sm text-muted-foreground">
                The CLI never receives your GitHub token. This request expires {expires_in(
                  @authorization
                )}; after that the terminal has to ask again.
              </p>
            </div>
            <div class="flex flex-wrap justify-end gap-3">
              <.button id="deny-device" phx-click="deny" variant={:secondary}>Deny</.button>
              <.button id="approve-device" phx-click="approve">Authorize CLI</.button>
            </div>
          </div>
        </.card>
      </main>
    </Layouts.app>
    """
  end

  defp assign_authorization(socket, authorization) do
    socket
    |> assign(:authorization, authorization)
    |> assign(:privileged?, authorization != nil and ApiTokens.privileged?(authorization.scopes))
  end

  defp decide(%{assigns: %{authorization: nil}} = socket, _transition, _decision),
    do: {:noreply, put_flash(socket, :error, "This code is invalid or expired.")}

  defp decide(socket, transition, decision) do
    user_code = socket.assigns.form[:user_code].value

    case transition.(user_code, socket.assigns.current_user) do
      {:ok, _authorization} ->
        {:noreply,
         socket
         |> assign_authorization(nil)
         |> assign(:decided, decision)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign_authorization(nil)
         |> put_flash(:error, "This code is invalid or expired.")}
    end
  end

  defp code_form(user_code), do: to_form(%{"user_code" => user_code}, as: :device)

  # Rendered once at mount and not counted down. A ticking clock would make the
  # page a timer, and the window is ten minutes: what the reader needs is that
  # there is one, not the second it lands on.
  defp expires_in(%{expires_at: expires_at}) do
    case DateTime.diff(expires_at, DateTime.utc_now(), :second) do
      seconds when seconds <= 60 -> "in under a minute"
      seconds -> "in about #{div(seconds + 30, 60)} minutes"
    end
  end

  defp scope_description("forge:write"),
    do: "Create and manage repositories, issues, and pull requests as you."

  defp scope_description("deployments:promote"),
    do: "Promote a pushed commit as the OpenAgents fleet target."

  defp scope_description("deployments:write"), do: "Deploy a repository you can write to."
  defp scope_description("chat:account"), do: "Read and write your account chat."
  defp scope_description("box:control"), do: "Start and stop Boxes in your conversations."
  defp scope_description("computer:control"), do: "Control the Computers you have connected."
  defp scope_description(_scope), do: "Scoped access to one OpenAgents surface."

  defp normalize_code(code) when is_binary(code),
    do: code |> String.trim() |> String.upcase()

  defp normalize_code(_code), do: ""
end
