defmodule OpenAgentsWeb.AdminScvAccountsLive do
  @moduledoc "Operator-only connection surface for individual Codex accounts used by SCVs."

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.SCV.CodexAccounts

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      if connected?(socket), do: CodexAccounts.subscribe()

      {:ok,
       socket
       |> assign(:page_title, "Operator · SCV Codex accounts")
       |> assign(:codex_enabled, CodexAccounts.enabled?())
       |> assign(:pending, nil)
       |> assign(:form, to_form(%{"label" => ""}, as: :account))
       |> load_accounts()}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("connect_account", %{"account" => attributes}, socket) do
    with true <- Accounts.admin?(socket.assigns.current_user),
         {:ok, _account, _attempt, ceremony} <-
           CodexAccounts.start_device_login(socket.assigns.current_user, attributes) do
      {:noreply,
       socket
       |> assign(:pending, ceremony)
       |> assign(:form, to_form(%{"label" => ""}, as: :account))
       |> put_flash(:info, "Codex supplied a one-time device code.")
       |> load_accounts()}
    else
      false ->
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("cancel_login", _params, socket) do
    if Accounts.admin?(socket.assigns.current_user) do
      result =
        case socket.assigns.pending do
          %{attempt_id: attempt_id} ->
            CodexAccounts.cancel_device_login(socket.assigns.current_user, attempt_id)

          nil ->
            {:error, :login_not_found}
        end

      socket =
        case result do
          :ok -> socket |> assign(:pending, nil) |> put_flash(:info, "Codex login cancelled.")
          {:error, reason} -> put_flash(socket, :error, error_message(reason))
        end

      {:noreply, load_accounts(socket)}
    else
      {:noreply, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:scv_codex_accounts, {:account_ready, account_id}}, socket) do
    pending = clear_pending(socket.assigns.pending, account_id)

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> put_flash(:info, "Codex account connected and verified for SCVs.")
     |> load_accounts()}
  end

  def handle_info({:scv_codex_accounts, {:account_failed, account_id, code}}, socket) do
    pending = clear_pending(socket.assigns.pending, account_id)

    {:noreply,
     socket
     |> assign(:pending, pending)
     |> put_flash(:error, error_message(code))
     |> load_accounts()}
  end

  def handle_info({:scv_codex_accounts, {:account_cancelled, account_id}}, socket) do
    {:noreply,
     socket
     |> assign(:pending, clear_pending(socket.assigns.pending, account_id))
     |> load_accounts()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_accounts(socket), do: assign(socket, :accounts, CodexAccounts.list_accounts())

  defp clear_pending(%{account_id: account_id}, account_id), do: nil
  defp clear_pending(pending, _account_id), do: pending

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="admin-scv-accounts-page" class="app-shell admin-shell">
        <Layouts.command_bar aria_label="SCV Codex account settings" current_user={@current_user}>
          <:lockup>
            <.button
              id="return-to-operator"
              variant={:chip}
              size={:xs}
              phx-click={JS.navigate(~p"/admin")}
            >
              <.icon name="arrow-left" /> OPERATOR
            </.button>
          </:lockup>
        </Layouts.command_bar>

        <section class="admin space-y-8" aria-labelledby="scv-codex-heading">
          <header class="admin-heading">
            <h1 id="scv-codex-heading">Codex accounts for SCVs</h1>
            <p>
              Connect an individual Codex account through OpenAI's device flow. OpenAgents
              keeps each account in an isolated app-server runtime and stores no access token
              in the account record.
            </p>
            <div class="admin-totals">
              <.badge variant={if(@codex_enabled, do: :success, else: :warning)}>
                {if(@codex_enabled, do: "DEVICE LOGIN READY", else: "DEVICE LOGIN DISABLED")}
              </.badge>
              <.badge variant={:info}>GPT-5.6 LUNA</.badge>
              <.badge variant={:dim}>NONE OR LOW REASONING</.badge>
            </div>
          </header>

          <.alert :if={!@codex_enabled} id="codex-disabled" variant={:warning}>
            This deployment has not enabled the Codex account runtime.
          </.alert>

          <section :if={@codex_enabled && is_nil(@pending)} aria-labelledby="connect-codex-heading">
            <.card id="connect-codex-account">
              <div class="space-y-5">
                <div class="max-w-2xl space-y-2">
                  <h2 id="connect-codex-heading" class="card-title">Connect an individual account</h2>
                  <p class="text-muted-foreground">
                    Device login must be enabled in your ChatGPT security settings or by your
                    workspace administrator.
                  </p>
                </div>

                <.form
                  for={@form}
                  id="codex-account-form"
                  phx-submit="connect_account"
                  class="flex max-w-2xl flex-col gap-4 sm:flex-row sm:items-end"
                >
                  <.field class="min-w-0 flex-1">
                    <.label for={@form[:label].id}>Account label</.label>
                    <.input
                      field={@form[:label]}
                      type="text"
                      maxlength="80"
                      placeholder="Primary operator account"
                      autocomplete="off"
                    />
                  </.field>
                  <.button id="connect-codex-submit" type="submit" variant={:primary}>
                    CONNECT CODEX
                  </.button>
                </.form>
              </div>
            </.card>
          </section>

          <section :if={@pending} id="codex-device-login" aria-labelledby="device-login-heading">
            <.card>
              <div class="space-y-6">
                <div class="max-w-2xl space-y-2">
                  <div class="flex flex-wrap items-center gap-3">
                    <h2 id="device-login-heading" class="card-title">Finish on OpenAI</h2>
                    <.badge variant={:warning}>WAITING FOR YOU</.badge>
                  </div>
                  <p class="text-muted-foreground">
                    Continue only if you started this Codex connection from this screen. Cancel
                    if another site or person supplied the code.
                  </p>
                </div>

                <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
                  <div>
                    <span class="block text-sm text-muted-foreground">One-time code</span>
                    <code
                      id="codex-device-code"
                      class="mt-1 block select-all text-2xl font-semibold tracking-[0.12em] text-foreground"
                    >{@pending.user_code}</code>
                  </div>
                  <.button
                    id="open-codex-device-login"
                    variant={:primary}
                    href={@pending.verification_url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    OPEN OPENAI DEVICE LOGIN <.icon name="external-link" />
                  </.button>
                </div>

                <p class="text-sm text-muted-foreground">
                  This code expires at {format_timestamp(@pending.expires_at)}.
                </p>

                <.button id="cancel-codex-login" variant={:secondary} phx-click="cancel_login">
                  CANCEL
                </.button>
              </div>
            </.card>
          </section>

          <section aria-labelledby="connected-codex-heading" class="space-y-4">
            <div class="max-w-2xl space-y-2">
              <h2 id="connected-codex-heading">Connected accounts</h2>
              <p class="text-muted-foreground">
                Each row represents one SCV driver identity and one private Codex credential
                generation.
              </p>
            </div>

            <.empty :if={@accounts == []} id="codex-accounts-empty" title="No Codex accounts">
              Connect an individual operator account to create the first SCV driver identity.
            </.empty>

            <ol :if={@accounts != []} id="codex-accounts" class="admin-rows">
              <li :for={account <- @accounts} id={"codex-account-#{account.id}"}>
                <.card>
                  <div class="admin-row">
                    <div class="admin-identity">
                      <span>
                        <strong>{account.label}</strong>
                        <span>{account.account_email || "Account identity pending"}</span>
                      </span>
                    </div>

                    <div class="admin-state">
                      <.badge variant={status_variant(account.status)}>
                        {String.upcase(account.status)}
                      </.badge>
                      <.badge :if={account.plan_type} variant={:dim}>
                        {String.upcase(account.plan_type)}
                      </.badge>
                    </div>

                    <dl class="admin-meta">
                      <div>
                        <dt>Driver</dt>
                        <dd>Codex app-server</dd>
                      </div>
                      <div>
                        <dt>Model</dt>
                        <dd>{model_label(account.available_models)}</dd>
                      </div>
                      <div>
                        <dt>Reasoning</dt>
                        <dd>{reasoning_label(account.reasoning_efforts)}</dd>
                      </div>
                      <div>
                        <dt>Credential generation</dt>
                        <dd>{account.credential_version || "—"}</dd>
                      </div>
                      <div>
                        <dt>Verified</dt>
                        <dd>{format_timestamp(account.last_verified_at)}</dd>
                      </div>
                    </dl>
                  </div>
                </.card>
              </li>
            </ol>
          </section>

          <.alert id="codex-service-accounts-later" variant={:info}>
            <strong>Service accounts come second.</strong> OpenAgents will add them after the
            individual operator flow passes qualification. OpenAI makes service accounts
            available only on pay-as-you-go plans.
          </.alert>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp status_variant("ready"), do: :success
  defp status_variant("pending"), do: :warning
  defp status_variant("failed"), do: :danger
  defp status_variant(_status), do: :dim

  defp model_label(models) do
    if "gpt-5.6-luna" in models, do: "gpt-5.6-luna", else: "Pending"
  end

  defp reasoning_label([]), do: "Pending"
  defp reasoning_label(efforts), do: Enum.join(efforts, " or ")

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp error_message(:account_capacity_reached),
    do: "All configured Codex account slots are occupied."

  defp error_message(:codex_not_enabled), do: "Codex account connections are disabled."
  defp error_message(:login_not_found), do: "No pending Codex login was found."
  defp error_message(:login_not_running), do: "The pending Codex login is no longer running."
  defp error_message(:required_model_unavailable), do: "This account cannot use gpt-5.6-luna."

  defp error_message(reason) when is_binary(reason),
    do: "Codex account connection failed with code #{reason}."

  defp error_message(_reason), do: "Codex account connection failed."
end
