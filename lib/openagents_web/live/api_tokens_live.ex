defmodule OpenAgentsWeb.ApiTokensLive do
  @moduledoc "Owner settings for issuing and revoking scoped API credentials."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.ApiTokens

  @impl true
  def mount(_params, _session, socket) do
    tokens = ApiTokens.list(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "API tokens · OpenAgents")
     |> assign(:issued_token, nil)
     |> assign(:form, token_form())
     |> stream(:tokens, tokens)}
  end

  @impl true
  def handle_event("create", %{"api_token" => params}, socket) do
    case ApiTokens.create(socket.assigns.current_user, %{
           "name" => params["name"],
           "scopes" => ["chat:account", "forge:write"],
           "lifetime_days" => params["lifetime_days"]
         }) do
      {:ok, token, plaintext} ->
        {:noreply,
         socket
         |> assign(:issued_token, plaintext)
         |> assign(:form, token_form())
         |> stream_insert(:tokens, token, at: 0)}

      {:error, _invalid} ->
        {:noreply, put_flash(socket, :error, "Choose a name and a lifetime from 1 to 90 days.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case ApiTokens.revoke(socket.assigns.current_user, id) do
      {:ok, token} -> {:noreply, stream_insert(socket, :tokens, token)}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "API token not found.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
    >
      <main id="api-token-settings" class="mx-auto w-full max-w-4xl space-y-8 px-4 py-10">
        <header class="space-y-2">
          <h1 class="text-3xl font-semibold tracking-tight">API tokens</h1>
          <p class="text-muted-foreground">
            Create an expiring credential for account chat and Forge operations. Tokens carry
            <code>chat:account</code>
            and <code>forge:write</code>, are stored as digests, and are shown once.
          </p>
        </header>

        <.alert
          :if={@issued_token}
          id="issued-api-token"
          variant={:warning}
          title="Copy this token now"
        >
          <p>It cannot be retrieved after this page is refreshed.</p>
          <code class="mt-3 block break-all rounded-md bg-muted p-3 font-mono text-sm">
            {@issued_token}
          </code>
        </.alert>

        <.card>
          <.form for={@form} id="api-token-form" phx-submit="create" class="space-y-4">
            <.field>
              <.label for={@form[:name].id}>Name</.label>
              <.input field={@form[:name]} placeholder="Release CLI" required />
            </.field>
            <.field>
              <.label for={@form[:lifetime_days].id}>Lifetime in days</.label>
              <.input
                field={@form[:lifetime_days]}
                type="number"
                min="1"
                max="90"
                required
              />
            </.field>
            <.button id="create-api-token" type="submit" variant={:primary}>
              Create token
            </.button>
          </.form>
        </.card>

        <section class="space-y-3" aria-labelledby="api-token-list-heading">
          <h2 id="api-token-list-heading" class="text-xl font-semibold">Credentials</h2>
          <div id="api-tokens" phx-update="stream" class="space-y-3">
            <.empty id="api-tokens-empty" title="No API tokens" class="hidden only:block">
              Create one when a CLI needs forge write access.
            </.empty>
            <.card :for={{id, token} <- @streams.tokens} id={id}>
              <div class="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <strong>{token.name}</strong>
                  <p class="text-sm text-muted-foreground">
                    {Enum.join(token.scopes, ", ")} · expires {format_time(token.expires_at)}
                  </p>
                  <.badge :if={token.revoked_at} variant={:danger}>REVOKED</.badge>
                </div>
                <.button
                  :if={is_nil(token.revoked_at)}
                  id={"revoke-api-token-#{token.id}"}
                  phx-click="revoke"
                  phx-value-id={token.id}
                  variant={:destructive}
                  size={:sm}
                >
                  Revoke
                </.button>
              </div>
            </.card>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp token_form do
    to_form(%{"name" => "", "lifetime_days" => "30"}, as: :api_token)
  end

  defp format_time(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
