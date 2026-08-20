defmodule OpenAgentsWeb.UIGalleryLive do
  @moduledoc """
  Development-only gallery of `OpenAgentsWeb.UI` in every variant and state.

  Routed only when `:dev_routes` is enabled, and behind the same authentication
  as every other protected surface. It is a verification surface, not a product
  surface: nothing here may be linked from the product, and `INVARIANTS.md`
  UI-001 still forbids navigation chrome in the shipped interface.

  Check this page after re-vendoring Basecoat or editing
  `assets/css/openagents.css` — the shared corner radius, the sanctioned depth
  tokens, reserved semantic colors, Geist rendering rather than a system
  fallback, and a visible focus ring on every control.
  """

  use OpenAgentsWeb, :openagents_live_view

  @statuses ~w(idle connected requested running succeeded failed cancelled interrupted refused unavailable)
  @voice_states ~w(idle requesting connecting listening speaking interrupted reconnecting muted blocked failed ending)

  # The glyphs the product actually renders. The vendored set is large; a
  # gallery that dumps all 755 stops being a review surface.
  @icons_in_use ~w(
    arrow-up stop history memory-on-remember arrow-left chevron-down logout
    download trash x mic mic-off sound-on-read-out-loud-speaker x-circle
    enter-login
  )

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "UI gallery",
       statuses: @statuses,
       voice_states: @voice_states,
       icons: @icons_in_use,
       icon_count: OpenAgentsWeb.Icons.count()
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main
        id="ui-gallery"
        class="mx-auto flex h-dvh w-full max-w-[1040px] flex-col overflow-y-auto border-x border-[var(--line)] bg-[var(--ink-surface)]"
      >
        <header class="command-bar">
          <div class="brand-lockup"><span class="brand-name">SARAH</span></div>
          <div class="command-controls">
            <div class="system-state">
              <.status_indicator state="connected" label="Connected" decorative />
              <span>UI GALLERY / DEVELOPMENT ONLY</span>
            </div>
          </div>
        </header>

        <section>
          <.section title="Button variants">
            <.button
              :for={variant <- [:primary, :secondary, :outline, :ghost, :destructive]}
              variant={variant}
            >
              {variant |> to_string() |> String.upcase()}
            </.button>
          </.section>

          <.section title="Button sizes">
            <.button :for={size <- [:xs, :sm, :default, :lg]} size={size} variant={:outline}>
              {size |> to_string() |> String.upcase()}
            </.button>
          </.section>

          <.section title="Disabled">
            <.button disabled>PRIMARY</.button>
            <.button variant={:outline} disabled>OUTLINE</.button>
            <.button variant={:destructive} disabled>DESTRUCTIVE</.button>
          </.section>

          <.section title="Inline actions">
            <.text_button>LOAD EARLIER MESSAGES</.text_button>
            <.text_button tone={:danger}>FORGET RECORD</.text_button>
            <.text_button href="/memory/export" download>EXPORT MEMORY</.text_button>
          </.section>

          <.section title="Status indicators">
            <span :for={state <- @statuses} class="flex items-center gap-2">
              <.status_indicator state={state} label={state} decorative />
              <.badge variant={:dim}>{String.upcase(state)}</.badge>
            </span>
          </.section>

          <.section title="Voice states">
            <span :for={state <- @voice_states} class="flex items-center gap-2">
              <.status_indicator state={state} label={state} decorative />
              <.badge variant={:dim}>{String.upcase(state)}</.badge>
            </span>
          </.section>

          <.section title="Badges">
            <.badge
              :for={variant <- [:default, :info, :success, :warning, :danger, :dim]}
              variant={variant}
            >
              {variant |> to_string() |> String.upcase()}
            </.badge>
          </.section>

          <.section title="Avatars">
            <.avatar fallback="S" label="SYSTEM" />
            <.avatar size={:sm} fallback="Y" label="YOU" />
            <.avatar size={:lg} fallback="S" label="SARAH" tone={:accent} />
          </.section>

          <.section title={"Icons in use (#{@icon_count} vendored)"}>
            <span :for={name <- @icons} class="flex items-center gap-2">
              <.icon name={name} class="text-base" />
              <.badge variant={:dim}>{name}</.badge>
            </span>
          </.section>

          <.section title="Icons at control scale">
            <.button><.icon name="arrow-up" /></.button>
            <.button variant={:outline}><.icon name="mic" /> START VOICE</.button>
            <.button variant={:destructive} size={:sm}><.icon name="trash" /> FORGET</.button>
            <.text_button><.icon name="history" /> LOAD EARLIER MESSAGES</.text_button>
          </.section>

          <.section title="Notched action">
            <.button variant={:notched} size={:lg}>LOG IN WITH GITHUB</.button>
            <.button variant={:notched}>PRIMARY ACTION</.button>
            <.button variant={:notched} disabled>DISABLED</.button>
          </.section>

          <.section title="Frame">
            <.frame class="max-w-sm">
              <p class="m-0 text-[var(--text-muted)]">Corner frame, ported from Arwes.</p>
            </.frame>
          </.section>

          <.section title="Audio player">
            <%!-- Native controls in the OpenAgents box. The source is deliberately
                  absent: this is a look at the transport's chrome in the dark
                  theme, not a playback test. --%>
            <.audio_player class="max-w-sm" src="" label="Recording of a voice call" />
          </.section>

          <.section title="Keys">
            <span><.kbd>ENTER</.kbd>
            TO SEND /
            <.kbd>SHIFT+ENTER</.kbd>
            FOR A NEW LINE</span>
          </.section>
        </section>

        <section>
          <.alert appearance={:row} label="NOTICE">A row alert sits inline in the shell.</.alert>
          <.alert appearance={:row} variant={:danger} label="ATTENTION">
            A destructive row alert.
          </.alert>

          <div class="grid gap-4 border-b border-[var(--line)] p-5">
            <.alert
              :for={variant <- [:info, :success, :warning, :danger]}
              variant={variant}
              label={variant |> to_string() |> String.upcase()}
            >
              A boxed notice with a dismiss action.
              <:action><.text_button>CLOSE</.text_button></:action>
            </.alert>

            <.alert appearance={:notice} variant={:danger} label="LOGIN INTERRUPTED">
              A bordered notice carrying prose on the authentication boundary.
            </.alert>
          </div>

          <.item status="running" label="Searching this conversation" />
          <.item status="succeeded" label="Read exact context" detail="EXECUTOR / first-party" />
          <.item status="failed" label="Tool run did not complete" detail="EXECUTOR / first-party" />
          <.item status="refused" label="Out of scope for this account" />

          <.event_header id="gallery-event-succeeded" status="succeeded" title="ls -la docs">
            <p>Bounded durable details render here on expansion.</p>
          </.event_header>
          <.event_header
            id="gallery-event-failed"
            status="failed"
            title="cat missing-file"
            status_note="FAILED"
          >
            <p>Bounded durable error details render here on expansion.</p>
          </.event_header>
          <.event_header id="gallery-event-rollup" status="succeeded" title="Worked for 3m 7s">
            <:chips>
              <.badge variant={:success}>4 SUCCEEDED</.badge>
            </:chips>
            <p>The deep-work report renders here on expansion.</p>
          </.event_header>

          <.card state="active">
            <header>
              <h2>Active card</h2>
              <p>A softened panel with room around it, not a bubble.</p>
            </header>
            <footer>
              <.button size={:sm} variant={:secondary}>SAVE CORRECTION</.button>
              <.text_button tone={:danger}>FORGET RECORD</.text_button>
            </footer>
          </.card>

          <.card variant={:danger}>
            <header>
              <h2>Confirm destructive action</h2>
              <p>Destructive confirmation stays inline. There is no modal.</p>
            </header>
            <footer>
              <.button size={:sm} variant={:destructive}>CONFIRM FORGET</.button>
              <.button size={:sm} variant={:secondary}>KEEP MEMORY</.button>
            </footer>
          </.card>

          <.empty title="No profile memories yet">
            Ask Sarah to remember a bounded preference or fact.
          </.empty>

          <div class="grid gap-4 border-b border-[var(--line)] p-5">
            <.field>
              <.label for="gallery-input">Correct this memory</.label>
              <.input id="gallery-input" name="claim" value="Prefers concise answers" maxlength="500" />
            </.field>

            <.field>
              <.label for="gallery-textarea">Message Sarah</.label>
              <.textarea id="gallery-textarea" name="message" placeholder="Message Sarah" rows="2" />
            </.field>

            <.field>
              <.label for="gallery-disabled">Disabled control</.label>
              <.input id="gallery-disabled" name="disabled" value="Unavailable" disabled />
            </.field>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div class="border-b border-[var(--line)] p-5">
      <h2 class="mb-3 text-[0.68rem] tracking-[0.08em] text-[var(--text-dim)]">{@title}</h2>
      <div class="flex flex-wrap items-center gap-3">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
