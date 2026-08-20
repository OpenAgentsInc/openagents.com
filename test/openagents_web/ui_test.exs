defmodule OpenAgentsWeb.UITest do
  @moduledoc """
  Contract tests for Sarah's interface primitives.

  These assert the rules `DESIGN.md` and `INVARIANTS.md` place on the component
  library itself, so a surface cannot inherit a violation from a primitive.
  """

  use ExUnit.Case, async: true
  @moduletag :skip
  import ExUnit.CaptureIO
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import OpenAgentsWeb.SarahUI

  describe "button/1" do
    test "defaults to a primary control and omits unset variant attributes" do
      assigns = %{}

      html = rendered_to_string(~H"<.button>SEND</.button>")

      assert html =~ ~s(class="btn)
      assert html =~ ~s(data-variant="primary")
      assert html =~ ~s(type="button")
      assert html =~ "SEND"
      refute html =~ "data-size"
      refute html =~ "data-tone"
    end

    test "renders each variant and size as a data attribute" do
      for variant <- [
            :primary,
            :secondary,
            :outline,
            :ghost,
            :destructive,
            :chip,
            :notched,
            :link
          ] do
        assigns = %{variant: variant}
        html = rendered_to_string(~H"<.button variant={@variant}>GO</.button>")
        assert html =~ ~s(data-variant="#{variant}")
      end

      for size <- [:xs, :sm, :lg] do
        assigns = %{size: size}
        html = rendered_to_string(~H"<.button size={@size}>GO</.button>")
        assert html =~ ~s(data-size="#{size}")
      end
    end

    test "carries a destructive tone on inline actions" do
      assigns = %{}

      html = rendered_to_string(~H"<.button variant={:link} tone={:danger}>FORGET</.button>")

      assert html =~ ~s(data-variant="link")
      assert html =~ ~s(data-tone="danger")
    end

    test "renders an anchor with the same treatment when given a destination" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.button variant={:chip} size={:xs} href="/data/export/atif" download>EXPORT</.button>|
        )

      assert html =~ "<a"
      assert html =~ ~s(href="/data/export/atif")
      assert html =~ "download"
      assert html =~ ~s(data-variant="chip")
      assert html =~ ~s(data-size="xs")
      refute html =~ "<button"
    end

    test "passes through disabled, submit type, and popover wiring" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button type="submit" disabled popovertarget="account-menu" popovertargetaction="toggle">
          SEND
        </.button>
        """)

      assert html =~ ~s(type="submit")
      assert html =~ "disabled"
      assert html =~ ~s(popovertarget="account-menu")
      assert html =~ ~s(popovertargetaction="toggle")
    end

    test "offers no icon-only size, because DESIGN.md forbids icon-only controls" do
      warning =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule OpenAgentsWeb.UITest.IconSize do
            use Phoenix.Component
            import OpenAgentsWeb.SarahUI

            def render(assigns), do: ~H"<.button size={:icon}>X</.button>"
          end
          """)
        end)

      assert warning =~ ~s(attribute "size")
      purge(OpenAgentsWeb.UITest.IconSize)
    end

    test "rejects an unknown variant at compile time" do
      warning =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule OpenAgentsWeb.UITest.BogusVariant do
            use Phoenix.Component
            import OpenAgentsWeb.SarahUI

            def render(assigns), do: ~H"<.button variant={:bogus}>X</.button>"
          end
          """)
        end)

      # `mix precommit` compiles with --warnings-as-errors, so this is a build failure.
      assert warning =~ ~s(attribute "variant")
      assert warning =~ "primary"
      purge(OpenAgentsWeb.UITest.BogusVariant)
    end
  end

  describe "text_button/1" do
    test "renders a button when it has no destination" do
      assigns = %{}

      html = rendered_to_string(~H"<.text_button>LOAD EARLIER MESSAGES</.text_button>")

      assert html =~ "<button"
      assert html =~ ~s(data-variant="link")
      assert html =~ "LOAD EARLIER MESSAGES"
      refute html =~ "<a"
    end

    test "renders an anchor when given a destination, so exports read as actions" do
      assigns = %{}

      html =
        rendered_to_string(~H|<.text_button href="/memory/export" download>EXPORT</.text_button>|)

      assert html =~ "<a"
      assert html =~ ~s(href="/memory/export")
      assert html =~ "download"
      assert html =~ ~s(data-variant="link")
    end

    test "carries a destructive tone" do
      assigns = %{}

      html = rendered_to_string(~H"<.text_button tone={:danger}>FORGET RECORD</.text_button>")

      assert html =~ ~s(data-tone="danger")
    end
  end

  describe "input/1, textarea/1, label/1, field/1" do
    test "input renders name, value, and validation passthrough" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.input id="memory-claim-1" name="claim" value="likes tea" maxlength="500" required />|
        )

      assert html =~ ~s(class="input)
      assert html =~ ~s(id="memory-claim-1")
      assert html =~ ~s(name="claim")
      assert html =~ ~s(value="likes tea")
      assert html =~ ~s(maxlength="500")
      assert html =~ "required"
    end

    test "textarea renders its value as content, not as an attribute" do
      assigns = %{}

      html =
        rendered_to_string(~H|<.textarea id="chat_message" name="chat[message]" value="draft" />|)

      assert html =~ ~s(class="textarea)
      assert html =~ ">draft</textarea>"
    end

    test "label binds to its control and field wraps the group" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.field>
          <.label for="memory-claim-1">Correct this memory</.label>
          <.input id="memory-claim-1" name="claim" />
        </.field>
        """)

      assert html =~ ~s(class="field)
      assert html =~ ~s(class="label)
      assert html =~ ~s(for="memory-claim-1")
    end
  end

  describe "alert/1" do
    test "danger alerts announce assertively and others politely" do
      assigns = %{}

      danger = rendered_to_string(~H|<.alert variant={:danger}>Broken</.alert>|)
      info = rendered_to_string(~H|<.alert variant={:info}>Saved</.alert>|)

      assert danger =~ ~s(role="alert")
      assert danger =~ ~s(data-variant="danger")
      assert info =~ ~s(role="status")
    end

    test "an explicit role wins over the variant default" do
      assigns = %{}

      html = rendered_to_string(~H|<.alert variant={:danger} role="status">Quiet</.alert>|)

      assert html =~ ~s(role="status")
    end

    test "renders a label and an action slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.alert label="ERROR" variant={:danger} appearance={:row}>
          Sarah could not accept that message.
          <:action><.text_button>CLOSE</.text_button></:action>
        </.alert>
        """)

      assert html =~ "ERROR"
      assert html =~ "data-title"
      assert html =~ ~s(data-appearance="row")
      assert html =~ "CLOSE"
    end

    test "box is the default appearance and stays inline" do
      assigns = %{}

      html = rendered_to_string(~H|<.alert>Notice</.alert>|)

      refute html =~ "data-appearance"
      refute html =~ "toast"
    end
  end

  describe "badge/1 and card/1" do
    test "badge carries reserved semantic color alongside its words" do
      assigns = %{}

      html = rendered_to_string(~H|<.badge variant={:success}>ACTIVE</.badge>|)

      assert html =~ ~s(data-variant="success")
      assert html =~ "ACTIVE"
    end

    test "card exposes record state and a danger variant without becoming a box" do
      assigns = %{}

      html =
        rendered_to_string(~H|<.card id="memory-record-1" state="active">Claim</.card>|)

      assert html =~ "<article"
      assert html =~ ~s(id="memory-record-1")
      assert html =~ ~s(data-state="active")

      danger = rendered_to_string(~H|<.card variant={:danger}>Confirm</.card>|)
      assert danger =~ ~s(data-variant="danger")
    end
  end

  describe "avatar/1" do
    test "renders a validated image with safe loading defaults" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.avatar src="https://avatars.githubusercontent.com/u/1" alt="GitHub avatar for @a" />|
        )

      assert html =~ ~s(class="avatar)
      assert html =~ ~s(src="https://avatars.githubusercontent.com/u/1")
      assert html =~ ~s(alt="GitHub avatar for @a")
      assert html =~ ~s(referrerpolicy="no-referrer")
      assert html =~ ~s(loading="lazy")
    end

    test "falls back to an initial with an accessible name when there is no image" do
      assigns = %{}

      html = rendered_to_string(~H|<.avatar fallback="S" label="SYSTEM" />|)

      assert html =~ ">S<"
      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="SYSTEM")
      refute html =~ "<img"
    end

    test "renders sizes and the accent tone" do
      assigns = %{}

      assert rendered_to_string(~H|<.avatar size={:sm} fallback="A" />|) =~ ~s(data-size="sm")
      assert rendered_to_string(~H|<.avatar size={:lg} fallback="A" />|) =~ ~s(data-size="lg")

      assert rendered_to_string(~H|<.avatar tone={:accent} fallback="A" />|) =~
               ~s(data-tone="accent")
    end
  end

  describe "item/1" do
    test "renders only a public label, status, and executor disclosure" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.item
          id="tool-activity-7"
          status="succeeded"
          label="Searched this conversation"
          detail="EXECUTOR / first-party"
        />
        """)

      assert html =~ ~s(id="tool-activity-7")
      assert html =~ ~s(data-status="succeeded")
      assert html =~ "Searched this conversation"
      assert html =~ "EXECUTOR / first-party"
    end

    test "its indicator is decorative because the row already states the label" do
      assigns = %{}

      html = rendered_to_string(~H|<.item status="running" label="Reading context" />|)

      assert html =~ ~s(aria-hidden="true")
    end

    test "accepts no attribute that could carry a private tool payload" do
      # INVARIANTS.md UI-002: arguments, results, errors, provider identifiers,
      # and recall content must never reach the browser. The component's
      # signature is the enforcement point.
      declared =
        OpenAgentsWeb.SarahUI.__components__()
        |> Map.fetch!(:item)
        |> Map.fetch!(:attrs)
        |> Enum.map(& &1.name)

      assert Enum.sort(declared) == [:class, :detail, :id, :label, :rest, :status]

      for forbidden <- [:arguments, :result, :error, :payload, :provider_response_id, :content] do
        refute forbidden in declared
      end
    end
  end

  describe "frame/1" do
    test "renders decorative corner strokes around its content" do
      assigns = %{}

      html = rendered_to_string(~H|<.frame>Statement</.frame>|)

      assert html =~ ~s(class="frame)
      assert html =~ ~s(data-variant="corners")
      assert html =~ "Statement"
    end

    test "carries no state and needs no measurement" do
      # The port's whole point: Arwes needs a measured element to resolve its
      # percentage path expressions, and this does not.
      assigns = %{}

      html = rendered_to_string(~H|<.frame>x</.frame>|)

      refute html =~ "<svg"
      refute html =~ "<canvas"
      refute html =~ "style="
    end
  end

  describe "empty/1, kbd/1, menu/1" do
    test "empty states name what is missing and how it appears" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.empty id="memory-empty" title="No profile memories yet">Ask Sarah to remember.</.empty>|
        )

      assert html =~ ~s(id="memory-empty")
      assert html =~ "No profile memories yet"
      assert html =~ "Ask Sarah to remember."
    end

    test "kbd states a key name as text" do
      assigns = %{}

      html = rendered_to_string(~H|<.kbd>ENTER</.kbd>|)

      assert html =~ "<kbd"
      assert html =~ ~s(class="kbd)
      assert html =~ ">ENTER</kbd>"
    end

    test "menu uses the native popover API and needs no JavaScript" do
      assigns = %{}

      html = rendered_to_string(~H|<.menu id="account-menu" label="Account">LOG OUT</.menu>|)

      assert html =~ ~s(id="account-menu")
      assert html =~ ~s(popover="auto")
      assert html =~ ~s(role="menu")
      refute html =~ "data-popover"
      refute html =~ "basecoat"
    end
  end

  describe "audio_player/1" do
    test "uses the browser's own transport rather than a scripted one" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.audio_player id="call-audio" src="/admin/recordings/abc/audio" label="Call with @octocat" />|
        )

      assert html =~ "<audio"
      assert html =~ ~s(id="call-audio")
      assert html =~ "controls"
      # Native controls are already keyboard operable and already announced; a
      # hand-rolled transport would have to re-earn both.
      refute html =~ "phx-hook"
      refute html =~ "<button"
    end

    test "requires a name, because a page of recordings is a page of identical players" do
      declared =
        OpenAgentsWeb.SarahUI.__components__()
        |> Map.fetch!(:audio_player)
        |> Map.fetch!(:attrs)

      label = Enum.find(declared, &(&1.name == :label))
      source = Enum.find(declared, &(&1.name == :src))

      assert label.required
      assert source.required
    end

    test "loads metadata only, so opening the panel does not pull every recording" do
      assigns = %{}

      html = rendered_to_string(~H|<.audio_player src="/a" label="Call" />|)

      assert html =~ ~s(preload="metadata")
      refute html =~ "autoplay"
    end
  end

  describe "status_indicator/1" do
    test "requires a label so color never carries state alone" do
      declared =
        OpenAgentsWeb.SarahUI.__components__()
        |> Map.fetch!(:status_indicator)
        |> Map.fetch!(:attrs)

      label = Enum.find(declared, &(&1.name == :label))

      assert label.required
    end

    test "announces its state when it is the only statement of it" do
      assigns = %{}

      html = rendered_to_string(~H|<.status_indicator state="connected" label="Connected" />|)

      assert html =~ ~s(data-state="connected")
      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="Connected")
    end

    test "hides from assistive technology when adjacent text repeats it" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<.status_indicator state="listening" label="Listening" decorative />|
        )

      assert html =~ ~s(aria-hidden="true")
      refute html =~ ~s(role="img")
    end
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end
end
