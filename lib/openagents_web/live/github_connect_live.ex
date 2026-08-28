defmodule OpenAgentsWeb.GitHubConnectLive do
  @moduledoc """
  Connects the signed-in account's GitHub grant to the repository tools.

  Two ways in, one decision. Arriving plain, the page explains what is asked
  and offers the connect button. Arriving with `?code=` from `openagents auth
  connect-github`, it also shows the terminal code awaiting the same button —
  approving is the connect itself, so there is no second confirmation to
  mistake for the grant.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.DeviceAuthorizations

  @impl true
  def mount(params, _session, socket) do
    code = params |> Map.get("code", "") |> normalize_code()

    {:ok,
     socket
     |> assign(:page_title, "Connect GitHub")
     |> assign(:device_code, code)
     |> assign(:authorization, authorization_for(code))
     |> assign(:connected_login, connected_login(socket))}
  end

  @impl true
  def handle_event("set-code", %{"code" => code}, socket) do
    code = normalize_code(code)

    {:noreply,
     socket
     |> assign(:device_code, code)
     |> assign(:authorization, authorization_for(code))}
  end

  defp authorization_for(""), do: nil

  defp authorization_for(code) do
    DeviceAuthorizations.get_pending_github_connect(code)
  end

  defp connected_login(socket) do
    case socket.assigns.current_user do
      %{github_token_scopes: scopes, github_login: login} when is_binary(login) ->
        if OpenAgents.GitHubOAuth.required_scopes_present?(scopes), do: login, else: nil

      _other ->
        nil
    end
  end

  defp normalize_code(code) when is_binary(code), do: String.trim(code)
  defp normalize_code(_other), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Connect GitHub"
      sidebar_sections={assigns[:sidebar_sections]}
    >
      <main id="github-connect" class="mx-auto w-full max-w-2xl space-y-8 px-4 py-12">
        <.header>
          Connect GitHub
          <:subtitle>
            Authorize OpenAgents to read and create repositories on your behalf.
          </:subtitle>
        </.header>

        <.alert
          :if={@connected_login}
          id="github-connect-connected"
          variant={:success}
        >
          GitHub is connected as {@connected_login}. Repository operations are enabled.
        </.alert>

        <.alert
          :if={@authorization}
          id="github-connect-terminal"
          variant={:warning}
        >
          A terminal is waiting. Finish connecting below to complete <code>{@device_code}</code>
          {@authorization.device_name &&
            " on \"#{@authorization.device_name}\""} .
        </.alert>

        <.card>
          <div class="space-y-5">
            <div>
              <h3 class="font-medium">What OpenAgents asks GitHub for</h3>
              <ul class="mt-2 space-y-1 text-sm text-muted-foreground">
                <li>
                  <code>repo</code> — read and write every repository your GitHub account
                  can reach, private ones included. GitHub grants this scope to all
                  repositories or none; selecting individual repositories needs a GitHub
                  App, which OpenAgents does not use yet.
                </li>
                <li>
                  <code>read:org</code> — read the organizations you belong to, so OpenAgents
                  can list where you administer a namespace.
                </li>
              </ul>
            </div>

            <p class="text-sm text-muted-foreground">
              OpenAgents retains the token server-side and uses it only for the forge's
              GitHub-backed operations. You can revoke it at any time from the account
              menu.
            </p>

            <div class="flex flex-wrap justify-end gap-3">
              <.form
                for={%{}}
                as={:auth}
                id="github-connect-form"
                action={~p"/auth/github"}
                method="post"
              >
                <input type="hidden" name="auth[mode]" value="repository" />
                <input type="hidden" name="auth[code]" value={@device_code} />
                <.button id="connect-github" type="submit" variant={:primary}>
                  Connect GitHub
                </.button>
              </.form>
            </div>
          </div>
        </.card>
      </main>
    </Layouts.app>
    """
  end
end
