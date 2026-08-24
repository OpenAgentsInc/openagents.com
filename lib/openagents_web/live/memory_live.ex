defmodule OpenAgentsWeb.MemoryLive do
  @moduledoc """
  Memory in your account, as a page.

  It used to be a panel inside the conversation, opened by a sidebar row that
  swapped the transcript out. That made it reachable only from chat, gave it no
  address of its own, and meant the way back out lived in chrome outside the
  thing you were leaving. It is a place, so it has a URL.

  Everything here is scoped to the signed-in account's own memory owner.
  Correction supersedes rather than overwrites: the previous wording is kept,
  because a memory system that silently rewrites its own history cannot be
  audited by the person it is about.

  Destructive actions confirm inline and state their exact breadth -- one
  record, one category, or the whole account -- since "forget" covering three
  different scopes behind one word is how someone deletes more than they meant.
  """

  use OpenAgentsWeb, :live_view

  alias OpenAgents.Accounts
  alias OpenAgents.Analytics
  alias OpenAgents.Conversations
  alias OpenAgents.DataRights
  alias OpenAgents.ProfileMemory
  alias OpenAgents.Voice.Recordings

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok, conversation} = Conversations.ensure_conversation(current_user)
    owner = Conversations.get_conversation_owner!(conversation)

    if connected?(socket) do
      :ok = ProfileMemory.subscribe(owner)

      Analytics.capture("memory_viewed", Analytics.distinct_id(current_user))
    end

    {:ok,
     socket
     |> assign(:page_title, "Memory")
     |> assign(:memory_owner, owner)
     |> assign(:memory_records, [])
     |> assign(:memory_status, nil)
     |> assign(:pending_memory_action, nil)
     |> assign(:reset_enabled?, DataRights.reset_enabled?())
     |> assign(:leaderboard_opted_out?, current_user.public_leaderboard_opted_out)
     |> assign(:recording_config, Recordings.config())
     |> assign(:privacy_delete_form, to_form(%{"confirmation" => ""}, as: :privacy))
     |> reload_memory()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_sections={assigns[:sidebar_sections]}
      current_scope={@current_scope}
      title="Memory"
      wide
    >
      <.memory_manager
        memory_records={@memory_records}
        memory_status={@memory_status}
        pending_memory_action={@pending_memory_action}
        privacy_delete_form={@privacy_delete_form}
        recording_config={@recording_config}
        leaderboard_opted_out?={@leaderboard_opted_out?}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("correct_memory", %{"record_id" => record_id, "claim" => claim}, socket) do
    owner = socket.assigns.memory_owner

    result =
      with {:ok, record} <- ProfileMemory.get(owner, record_id),
           true <- record.status == "active",
           {:ok, _corrected} <-
             ProfileMemory.correct(owner, record.id, record.generation, %{
               category: record.category,
               claim: claim,
               creator: "user_explicit",
               owner_asserted: true,
               sources: [],
               provenance: %{
                 "operation" => "first_party_ui_correction",
                 "supersedes_record_id" => record.id
               }
             }) do
        :ok
      else
        false -> {:error, :memory_not_active}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, memory_result(socket, result, "Memory corrected and previous wording retained.")}
  end

  def handle_event("request_memory_forget", params, socket) do
    case pending_action(socket.assigns.memory_owner, params) do
      {:ok, pending} ->
        {:noreply,
         socket
         |> assign(:pending_memory_action, pending)
         |> assign(:memory_status, nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, :memory_status, {:error, "That memory is no longer active."})}
    end
  end

  # The public board is the one projection that leaves the account boundary, so
  # the account it is about decides whether it appears there. The control states
  # the current publication state rather than a bare toggle, since "leaderboard"
  # on its own does not say which way it is set.
  def handle_event("set_leaderboard_visibility", %{"opted_out" => opted_out}, socket)
      when opted_out in ["true", "false"] do
    opted_out? = opted_out == "true"

    case Accounts.set_public_leaderboard_opt_out(socket.assigns.current_user, opted_out?) do
      {:ok, user} ->
        message =
          if opted_out?,
            do: "Your account no longer appears on the public leaderboard.",
            else: "Your account appears on the public leaderboard again."

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:leaderboard_opted_out?, user.public_leaderboard_opted_out)
         |> assign(:memory_status, {:ok, message})}

      {:error, _changeset} ->
        {:noreply,
         assign(
           socket,
           :memory_status,
           {:error, "Sarah could not change your leaderboard preference. Try again."}
         )}
    end
  end

  def handle_event("cancel_memory_action", _params, socket) do
    {:noreply, assign(socket, :pending_memory_action, nil)}
  end

  def handle_event(
        "confirm_memory_forget",
        _params,
        %{assigns: %{pending_memory_action: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("confirm_memory_forget", _params, socket) do
    pending = socket.assigns.pending_memory_action
    result = ProfileMemory.forget_active(socket.assigns.memory_owner, pending.selector)

    message =
      case result do
        {:ok, %{disposition: "already_absent"}} ->
          "Those memories were already absent."

        {:ok, %{records: records}} ->
          "Forgot #{length(records)} memory record(s) in this account."

        {:error, _reason} ->
          "Sarah could not forget that selection. Refresh and try again."
      end

    status = if match?({:ok, _result}, result), do: :ok, else: :error

    {:noreply,
     socket
     |> assign(:pending_memory_action, nil)
     |> assign(:memory_status, {status, message})
     |> reload_memory()}
  end

  # Another tab correcting or forgetting a record must be reflected here: the
  # records are one account's, not one socket's.
  @impl true
  def handle_info({:profile_memory_updated, _result}, socket) do
    {:noreply, reload_memory(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload_memory(socket) do
    case ProfileMemory.export(socket.assigns.memory_owner) do
      {:ok, export} -> assign(socket, :memory_records, export["records"])
      {:error, _reason} -> assign(socket, :memory_status, {:error, "Memory is unavailable."})
    end
  end

  defp memory_result(socket, :ok, message) do
    socket
    |> assign(:memory_status, {:ok, message})
    |> reload_memory()
  end

  defp memory_result(socket, {:error, reason}, _message) do
    assign(socket, :memory_status, {:error, memory_error(reason)})
  end

  defp pending_action(owner, %{"kind" => "record", "id" => record_id}) do
    with {:ok, record} <- ProfileMemory.get(owner, record_id),
         true <- record.status == "active" do
      {:ok,
       %{
         label: ~s(Forget "#{record.claim}"?),
         selector: %{
           "mode" => "record",
           "record_id" => record.id,
           "expected_generation" => record.generation
         }
       }}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp pending_action(_owner, %{"kind" => "category", "category" => category})
       when category in ~w(name role project preference constraint other) do
    {:ok,
     %{
       label: "Forget every active #{category} memory in this account?",
       selector: %{"mode" => "category", "category" => category}
     }}
  end

  defp pending_action(_owner, %{"kind" => "all"}) do
    {:ok,
     %{
       label: "Forget every active profile memory in this account?",
       selector: %{"mode" => "all"}
     }}
  end

  defp pending_action(_owner, _params), do: {:error, :invalid_action}

  defp memory_error(:duplicate_memory), do: "That exact memory is already active."

  defp memory_error(:memory_conflict_requires_correction),
    do: "That category has a conflicting active memory."

  defp memory_error(:invalid_claim), do: "Enter a non-empty correction under 500 bytes."

  defp memory_error({:memory_policy_rejected, _reason}),
    do: "That correction was refused by the memory privacy policy."

  defp memory_error(_reason), do: "Sarah could not update that memory. Refresh and try again."

  defp memory_date(nil), do: "DATE UNAVAILABLE"
  defp memory_date(timestamp), do: String.slice(timestamp, 0, 10)

  defp memory_status_variant({:error, _message}), do: :danger
  defp memory_status_variant(_status), do: :success

  defp memory_badge_variant("active"), do: :success
  defp memory_badge_variant(_status), do: :default

  attr :memory_records, :list, required: true
  attr :memory_status, :any, default: nil
  attr :pending_memory_action, :any, default: nil
  attr :privacy_delete_form, :any, required: true
  attr :recording_config, :map, required: true
  attr :leaderboard_opted_out?, :boolean, required: true

  defp memory_manager(assigns) do
    ~H"""
    <section id="memory-manager" class="memory-manager" aria-labelledby="memory-heading">
      <header class="memory-header">
        <div>
          <h1 id="memory-heading">Memory in your account</h1>
          <p>
            These records follow your authenticated Sarah account across browsers. Logging
            out removes this browser's access; server records follow the documented
            retention lifecycle.
          </p>
        </div>
        <div class="memory-header__actions">
          <%!-- The way out of a panel belongs in the panel. This used to be a
          sidebar row, which meant leaving depended on chrome outside the thing
          you were leaving. Memory is a place with its own URL, so the way back
          navigates to the conversation rather than toggling a panel. --%>
          <.text_button
            id="toggle-memory"
            navigate={~p"/sarah"}
            aria-label="Return to conversation"
          >
            <.icon name="arrow-left" /> Return to conversation
          </.text_button>
          <.text_button id="export-all-data" href="/data/export" download>
            <.icon name="download" /> Export ALL DATA
          </.text_button>
          <.text_button id="export-memory" href="/memory/export" download>
            <.icon name="download" /> Export Memory ONLY
          </.text_button>
          <%!-- The two exports above are scoped to Sarah's one conversation.
          Forum posts, threads, push receipts, deployments, Box work,
          computers, and agent links key on the account instead, so they leave
          through their own document (EXIT-001). --%>
          <.text_button id="export-account-data" href="/data/export/account" download>
            <.icon name="download" /> Export Forge and Forum Data
          </.text_button>
          <.text_button
            id="forget-all-memory"
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="all"
            disabled={not Enum.any?(@memory_records, &(&1["status"] == "active"))}
          >
            <.icon name="trash" /> FORGET ALL ACTIVE
          </.text_button>
        </div>
      </header>

      <.alert
        :if={@memory_status}
        id="memory-status"
        appearance={:row}
        variant={memory_status_variant(@memory_status)}
      >
        {elem(@memory_status, 1)}
      </.alert>

      <.card
        :if={@pending_memory_action}
        id="memory-confirmation"
        variant={:danger}
        aria-labelledby="memory-confirmation-heading"
      >
        <header>
          <h2 id="memory-confirmation-heading">Confirm destructive action</h2>
          <p>{@pending_memory_action.label}</p>
          <p>Future snapshots will no longer include the affected active records.</p>
        </header>
        <footer class="memory-confirmation__actions">
          <.button
            id="confirm-memory-forget"
            size={:sm}
            variant={:destructive}
            phx-click="confirm_memory_forget"
          >
            <.icon name="trash" /> CONFIRM FORGET
          </.button>
          <.button
            id="cancel-memory-action"
            size={:sm}
            variant={:secondary}
            phx-click="cancel_memory_action"
          >
            KEEP Memory
          </.button>
        </footer>
      </.card>

      <.empty :if={@memory_records == []} id="memory-empty" title="No profile memories yet">
        Sarah automatically remembers lasting facts you share in conversation, like
        your name, role, projects, and preferences. Memory belongs to your Sarah account.
      </.empty>

      <div :if={@memory_records != []} id="memory-records" class="memory-records">
        <.memory_record :for={record <- @memory_records} record={record} />
      </div>

      <.card id="leaderboard-preference" aria-labelledby="leaderboard-preference-heading">
        <header>
          <h2 id="leaderboard-preference-heading">Public leaderboard</h2>
          <p>
            The public leaderboard publishes a rank, your GitHub login, name, avatar, and one
            token total. It publishes nothing else about your account.
          </p>
          <p id="leaderboard-preference-state">
            <%= if @leaderboard_opted_out? do %>
              Your account is withheld from the board.
            <% else %>
              Your account appears on the board when its token total is above zero.
            <% end %>
          </p>
        </header>
        <footer>
          <.button
            id="toggle-leaderboard-preference"
            size={:sm}
            variant={:secondary}
            phx-click="set_leaderboard_visibility"
            phx-value-opted_out={to_string(not @leaderboard_opted_out?)}
          >
            <%= if @leaderboard_opted_out? do %>
              SHOW ME ON THE LEADERBOARD
            <% else %>
              HIDE ME FROM THE LEADERBOARD
            <% end %>
          </.button>
        </footer>
      </.card>

      <.card
        id="privacy-controls"
        variant={:danger}
        class="memory-confirmation"
        aria-labelledby="privacy-heading"
      >
        <header>
          <h2 id="privacy-heading">Voice and deletion</h2>
          <p>
            Final and interrupted transcripts remain in this account's conversation.
            Detailed operational voice evidence is purged after 90 days. Export before
            deleting if you want a copy.
          </p>
          <%!-- The recording sentence appears only while recording is on, so this
                surface and the voice control row can never disagree about it. --%>
          <p :if={@recording_config.enabled?} id="privacy-recording">
            Call audio is recorded, stored encrypted, and readable by a Sarah operator.
            It is deleted {@recording_config.retention_days} days after a call ends, and
            deleting your data removes it immediately.
          </p>
        </header>
        <footer>
          <.form
            for={@privacy_delete_form}
            id="delete-data-form"
            action="/data"
            method="delete"
            class="privacy-delete-form"
          >
            <.field>
              <.label for={@privacy_delete_form[:confirmation].id}>
                Type DELETE MY SARAH DATA to delete this account's Sarah conversation,
                transcripts, memory, receipts, and voice records. Minimal GitHub identity and
                access-status data remains so bans and access controls cannot be bypassed. A
                retained GitHub tools grant remains until you use Disconnect GitHub tools in
                the account menu. API tokens remain until you revoke them from API token
                settings.
              </.label>
              <div class="control-row">
                <.input
                  id={@privacy_delete_form[:confirmation].id}
                  name={@privacy_delete_form[:confirmation].name}
                  value={@privacy_delete_form[:confirmation].value}
                  type="text"
                  class="control-row__input"
                  autocomplete="off"
                  required
                />
                <.button id="delete-all-data" type="submit" size={:sm} variant={:destructive}>
                  <.icon name="trash" /> DELETE ALL DATA
                </.button>
              </div>
            </.field>
          </.form>
        </footer>
      </.card>
    </section>
    """
  end

  attr :record, :map, required: true

  defp memory_record(assigns) do
    ~H"""
    <.card
      id={"memory-record-#{@record["id"]}"}
      state={@record["status"]}
      frame={:corners}
      data-status={@record["status"]}
    >
      <div class="memory-record__meta">
        <.badge>{String.upcase(@record["category"])}</.badge>
        <.badge variant={memory_badge_variant(@record["status"])}>
          {String.upcase(@record["status"])}
        </.badge>
        <.badge>
          <time datetime={@record["inserted_at"]}>{memory_date(@record["inserted_at"])}</time>
        </.badge>
      </div>

      <p class="memory-record__claim">{@record["claim"] || "WITHHELD BY PRIVACY POLICY"}</p>

      <dl class="memory-record__sources">
        <div>
          <dt>Scope</dt>
          <dd>This account</dd>
        </div>
        <div>
          <dt>Generation</dt>
          <dd>{@record["generation"]}</dd>
        </div>
        <div>
          <dt>Sources</dt>
          <dd>
            <span :if={@record["sources"] == []}>Explicit account-owner assertion</span>
            <span :for={source <- @record["sources"]}>
              {source["kind"]} / {memory_date(source["observed_at"])}
            </span>
          </dd>
        </div>
      </dl>

      <div :if={@record["status"] == "active"} class="memory-record__controls">
        <form phx-submit="correct_memory" class="memory-correction">
          <input type="hidden" name="record_id" value={@record["id"]} />
          <.field>
            <.label for={"memory-claim-#{@record["id"]}"}>Correct this memory</.label>
            <div class="control-row">
              <.input
                id={"memory-claim-#{@record["id"]}"}
                name="claim"
                type="text"
                value={@record["claim"]}
                class="control-row__input"
                maxlength="500"
                required
              />
              <.button type="submit" size={:sm} variant={:secondary}>SAVE CORRECTION</.button>
            </div>
          </.field>
        </form>
        <div class="memory-record__destructive">
          <.text_button
            id={"forget-record-#{@record["id"]}"}
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="record"
            phx-value-id={@record["id"]}
          >
            <.icon name="trash" /> FORGET RECORD
          </.text_button>
          <.text_button
            id={"forget-category-#{@record["id"]}"}
            tone={:danger}
            phx-click="request_memory_forget"
            phx-value-kind="category"
            phx-value-category={@record["category"]}
          >
            <.icon name="trash" /> FORGET {String.upcase(@record["category"])} CATEGORY
          </.text_button>
        </div>
      </div>
    </.card>
    """
  end
end
