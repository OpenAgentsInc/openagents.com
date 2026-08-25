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
     |> assign(:selectable_scopes, selectable_scopes())
     |> stream(:tokens, tokens)}
  end

  @impl true
  def handle_event("create", %{"api_token" => params}, socket) do
    case ApiTokens.create(socket.assigns.current_user, %{
           "name" => params["name"],
           "scopes" => chosen_scopes(params),
           "lifetime_days" => params["lifetime_days"]
         }) do
      {:ok, token, plaintext} ->
        {:noreply,
         socket
         |> assign(:issued_token, plaintext)
         |> assign(:form, token_form())
         |> stream_insert(:tokens, token, at: 0)}

      {:error, _invalid} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose a name, at least one scope, and a lifetime from 1 to 90 days."
         )}
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
            Create an expiring credential and choose what it may do. Scopes are stored on the
            token, tokens are stored as digests, and the value is shown once.
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
              <.label>Scopes</.label>
              <p class="text-sm text-muted-foreground">
                A token carries exactly what you select here. Selecting less is the safer
                default: a credential that cannot reach a surface cannot be spent on it.
              </p>
              <.input
                :for={scope <- @selectable_scopes}
                field={@form[:"scope_#{scope}"]}
                type="checkbox"
                checked={@form[:"scope_#{scope}"].value == "true"}
                label={scope_label(scope)}
              />
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

  # The scopes an ordinary account may select. Privileged scopes are excluded
  # here as well as refused by `ApiTokens.create/2`: a control this account can
  # tick and the server will always reject is worse than no control at all.
  defp selectable_scopes do
    ApiTokens.allowed_scopes() -- ApiTokens.privileged_scopes()
  end

  # Checkboxes arrive one parameter per scope, so the selection is read back
  # rather than trusted from a list the form could have named freely. An
  # unknown key cannot become a scope this way, and `ApiTokens.create/2`
  # refuses an empty selection.
  defp chosen_scopes(params) do
    Enum.filter(selectable_scopes(), fn scope -> params["scope_#{scope}"] == "true" end)
  end

  defp scope_label("chat:account"), do: "chat:account — account chat and threads"
  defp scope_label("forge:write"), do: "forge:write — push and forge writes"
  defp scope_label("deployments:write"), do: "deployments:write — deployment records"
  defp scope_label("box:control"), do: "box:control — cloud box fleet"
  defp scope_label("computer:control"), do: "computer:control — paired computers"
  defp scope_label(scope), do: scope

  # The two scopes signing in already grants are ticked, so the common case is
  # one click and the rest are a deliberate addition.
  defp token_form do
    defaults =
      Map.new(selectable_scopes(), fn scope ->
        {"scope_#{scope}", to_string(scope in ["chat:account", "forge:write"])}
      end)

    to_form(Map.merge(defaults, %{"name" => "", "lifetime_days" => "30"}), as: :api_token)
  end

  defp format_time(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
