defmodule OpenAgentsWeb.DeviceAuthorizationLive do
  @moduledoc "Authenticated review and approval for one CLI device code."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.DeviceAuthorizations

  @impl true
  def mount(params, _session, socket) do
    user_code = params |> Map.get("user_code", "") |> normalize_code()

    {:ok,
     socket
     |> assign(:page_title, "Authorize OpenAgents CLI")
     |> assign(:authorization, DeviceAuthorizations.get_pending_by_user_code(user_code))
     |> assign(:decided, nil)
     |> assign(:form, code_form(user_code))}
  end

  @impl true
  def handle_event("lookup", %{"device" => %{"user_code" => user_code}}, socket) do
    user_code = normalize_code(user_code)

    {:noreply,
     socket
     |> assign(:authorization, DeviceAuthorizations.get_pending_by_user_code(user_code))
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
    <Layouts.app flash={@flash} current_scope={@current_scope} title="Authorize CLI">
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
              <p class="font-medium">Requested access</p>
              <p class="text-sm text-muted-foreground">
                Create and manage repositories as you through <code>forge:write</code>. The CLI never receives your GitHub token.
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

  defp decide(%{assigns: %{authorization: nil}} = socket, _transition, _decision),
    do: {:noreply, put_flash(socket, :error, "This code is invalid or expired.")}

  defp decide(socket, transition, decision) do
    user_code = socket.assigns.form[:user_code].value

    case transition.(user_code, socket.assigns.current_user) do
      {:ok, _authorization} ->
        {:noreply,
         socket
         |> assign(:authorization, nil)
         |> assign(:decided, decision)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:authorization, nil)
         |> put_flash(:error, "This code is invalid or expired.")}
    end
  end

  defp code_form(user_code), do: to_form(%{"user_code" => user_code}, as: :device)

  defp normalize_code(code) when is_binary(code),
    do: code |> String.trim() |> String.upcase()

  defp normalize_code(_code), do: ""
end
