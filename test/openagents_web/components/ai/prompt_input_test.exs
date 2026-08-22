defmodule OpenAgentsWeb.AI.PromptInputTest do
  @moduledoc """
  What the composer must keep true after a port from React.

  These check the three things a screenshot cannot: that the four submit
  statuses each render a different control with a different accessible name,
  that the textarea is actually bound to the form field rather than to a loose
  string, and that every list has words for the case where it is empty. The
  class assertions are deliberately narrow — one or two utilities per element,
  the ones that carry the geometry AI Elements was ported for — so that
  restyling does not break the suite but losing the layout does.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias OpenAgentsWeb.AI.PromptInput

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp count(html, selector) do
    html |> query(selector) |> LazyHTML.to_tree() |> length()
  end

  defp attribute(html, selector, name) do
    html |> query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp text(html, selector) do
    html |> query(selector) |> LazyHTML.text() |> String.trim()
  end

  # `render_component/2` has no sugar for slots, so a slot is a one-element
  # list holding a function that returns already-safe markup. That lets one
  # component's rendered output be nested inside another's.
  defp slot(markup, name \\ :inner_block) do
    [%{__slot__: name, inner_block: fn _changed, _arg -> {:safe, markup} end}]
  end

  defp form, do: Phoenix.Component.to_form(%{"message" => "Hello there"}, as: :chat)

  describe "prompt_input/1" do
    test "renders a form driven by the given to_form assign" do
      html =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          inner_block: slot("<span>body</span>")
        )

      assert count(html, "form#composer") == 1
      assert attribute(html, "form#composer", "phx-hook") =~ ".PromptInput"
      assert attribute(html, "form#composer", "data-file-input") == "composer-files"
      assert attribute(html, "form#composer", "data-submit-on-enter") == "true"
      assert attribute(html, "form#composer", "data-dragging") == "false"
    end

    test "carries the hidden file input the drop and paste affordances write to" do
      html =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          accept: "image/*",
          inner_block: slot("<span>body</span>")
        )

      assert attribute(html, "input#composer-files", "type") == "file"
      assert attribute(html, "input#composer-files", "accept") == "image/*"
      assert attribute(html, "input#composer-files", "aria-label") == "Upload files"
      assert attribute(html, "input#composer-files", "class") == "hidden"
    end

    test "wraps its children in the input group that carries the focus ring" do
      html =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          inner_block: slot("<span>body</span>")
        )

      group = attribute(html, "[data-slot=input-group]", "class")
      assert group =~ "group/input-group"
      assert group =~ "has-[>textarea]:h-auto"
      assert group =~ "has-[[data-slot=input-group-control]:focus-visible]:border-ring"
      assert group =~ "overflow-hidden"
    end

    test "publishes the backspace event only when the caller asks for one" do
      without =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          inner_block: slot("<span>body</span>")
        )

      assert attribute(without, "form#composer", "data-backspace-event") == nil

      with_event =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          backspace_event: "remove_last_attachment",
          inner_block: slot("<span>body</span>")
        )

      assert attribute(with_event, "form#composer", "data-backspace-event") ==
               "remove_last_attachment"
    end

    test "shows the drop overlay markup only when the slot is given" do
      html =
        render_component(&PromptInput.prompt_input/1,
          id: "composer",
          for: form(),
          inner_block: slot("<span>body</span>"),
          drop_overlay: slot("Drop files here", :drop_overlay)
        )

      assert text(html, "[aria-hidden=true]") == "Drop files here"

      assert attribute(html, "[aria-hidden=true]", "class") =~
               "group-data-[dragging=true]/prompt-input:flex"
    end
  end

  describe "prompt_input_textarea/1" do
    test "takes its id, name, and value from a form field" do
      html = render_component(&PromptInput.prompt_input_textarea/1, field: form()[:message])

      assert attribute(html, "textarea", "id") == "chat_message"
      assert attribute(html, "textarea", "name") == "chat[message]"
      assert text(html, "textarea") == "Hello there"
    end

    test "is the input group's control and flattens the vendored textarea chrome" do
      html = render_component(&PromptInput.prompt_input_textarea/1, field: form()[:message])

      assert attribute(html, "textarea", "data-slot") == "input-group-control"

      class = attribute(html, "textarea", "class")
      assert class =~ "textarea"
      assert class =~ "field-sizing-content"
      assert class =~ "max-h-48"
      assert class =~ "min-h-16"
      assert class =~ "border-0"
      assert class =~ "bg-transparent"
      assert class =~ "shadow-none"
    end

    test "keeps AI Elements' placeholder and accepts an explicit id" do
      html =
        render_component(&PromptInput.prompt_input_textarea/1, field: form()[:message], id: "ask")

      assert attribute(html, "textarea", "id") == "ask"
      assert attribute(html, "textarea", "placeholder") == "What would you like to know?"
    end

    test "works without a form field, for a caller holding its own value" do
      html =
        render_component(&PromptInput.prompt_input_textarea/1,
          id: "ask",
          name: "message",
          value: "raw"
        )

      assert attribute(html, "textarea", "name") == "message"
      assert text(html, "textarea") == "raw"
    end
  end

  describe "prompt_input_submit/1" do
    test "ready offers the enter glyph and submits the form" do
      html = render_component(&PromptInput.prompt_input_submit/1, id: "send", status: :ready)

      assert attribute(html, "#send", "type") == "submit"
      assert attribute(html, "#send", "aria-label") == "Submit"
      assert attribute(html, "#send", "data-status") == "ready"
      assert count(html, "[data-icon=arrow-curved-left]") == 1
    end

    test "submitted spins and renames itself Stop" do
      html = render_component(&PromptInput.prompt_input_submit/1, id: "send", status: :submitted)

      assert attribute(html, "#send", "aria-label") == "Stop"
      assert attribute(html, "#send", "data-status") == "submitted"
      assert attribute(html, "[data-icon=spin]", "class") =~ "animate-spin"
    end

    test "streaming offers the stop glyph" do
      html = render_component(&PromptInput.prompt_input_submit/1, id: "send", status: :streaming)

      assert attribute(html, "#send", "aria-label") == "Stop"
      assert attribute(html, "#send", "data-status") == "streaming"
      assert count(html, "[data-icon=stop]") == 1
    end

    test "error offers the cross and still submits, so a retry is one press" do
      html = render_component(&PromptInput.prompt_input_submit/1, id: "send", status: :error)

      assert attribute(html, "#send", "type") == "submit"
      assert attribute(html, "#send", "aria-label") == "Submit"
      assert attribute(html, "#send", "data-status") == "error"
      assert count(html, "[data-icon=x]") == 1
    end

    test "stops being a submit button once a stop action exists" do
      html =
        render_component(&PromptInput.prompt_input_submit/1,
          id: "send",
          status: :streaming,
          on_stop: "stop_turn"
        )

      assert attribute(html, "#send", "type") == "button"
      assert attribute(html, "#send", "phx-click") == "stop_turn"
    end

    test "a stop action does nothing while the composer is ready" do
      html =
        render_component(&PromptInput.prompt_input_submit/1,
          id: "send",
          status: :ready,
          on_stop: "stop_turn"
        )

      assert attribute(html, "#send", "type") == "submit"
      assert attribute(html, "#send", "phx-click") == nil
    end
  end

  describe "toolbar parts" do
    test "the header sits above the control and the footer below it" do
      header = render_component(&PromptInput.prompt_input_header/1, inner_block: slot("chips"))
      footer = render_component(&PromptInput.prompt_input_footer/1, inner_block: slot("tools"))

      assert attribute(header, "[data-slot=input-group-addon]", "data-align") == "block-end"
      assert attribute(header, "[data-slot=input-group-addon]", "class") =~ "order-first"
      assert attribute(footer, "[data-slot=input-group-addon]", "class") =~ "justify-between"
      refute attribute(footer, "[data-slot=input-group-addon]", "class") =~ "order-first"
    end

    test "the toolbar is the footer under the name AI Elements uses" do
      toolbar = render_component(&PromptInput.prompt_input_toolbar/1, inner_block: slot("tools"))

      assert attribute(toolbar, "[data-slot=input-group-addon]", "class") =~ "justify-between"
    end

    test "tools hold a tight run of controls" do
      html = render_component(&PromptInput.prompt_input_tools/1, inner_block: slot("controls"))

      assert attribute(html, "div", "class") =~ "flex min-w-0 items-center gap-1"
    end
  end

  describe "prompt_input_button/1" do
    test "defaults to the ghost icon control the composer chrome is made of" do
      html = render_component(&PromptInput.prompt_input_button/1, inner_block: slot("x"))

      assert attribute(html, "button", "data-variant") == "ghost"
      assert attribute(html, "button", "type") == "button"
      assert attribute(html, "button", "class") =~ "size-8"
    end

    test "the tooltip becomes a title, because there is no tooltip primitive here" do
      html =
        render_component(&PromptInput.prompt_input_button/1,
          tooltip: "Add files",
          size: :sm,
          inner_block: slot("x")
        )

      assert attribute(html, "button", "title") == "Add files"
      assert attribute(html, "button", "class") =~ "h-8"
    end
  end

  describe "the action menu" do
    test "the trigger points at the menu it opens" do
      html =
        render_component(&PromptInput.prompt_input_action_menu_trigger/1,
          menu: "composer-actions"
        )

      assert attribute(html, "button", "popovertarget") == "composer-actions"
      assert attribute(html, "button", "aria-label") == "Open composer actions"
      assert count(html, "[data-icon=plus]") == 1
    end

    test "the menu is a native popover with a name" do
      html =
        render_component(&PromptInput.prompt_input_action_menu/1,
          id: "composer-actions",
          inner_block: slot("items")
        )

      assert attribute(html, "#composer-actions", "popover") == "auto"
      assert attribute(html, "#composer-actions", "role") == "menu"
      assert attribute(html, "#composer-actions", "aria-label") == "Composer actions"
    end

    test "adding attachments is a label bound to the composer's file input" do
      html = render_component(&PromptInput.prompt_input_action_add_attachments/1, for: "composer")

      assert attribute(html, "label", "for") == "composer-files"
      assert attribute(html, "label", "role") == "menuitem"
      assert text(html, "label") == "Add photos or files"
    end

    test "taking a screenshot stays a button, because capture needs a gesture" do
      html = render_component(&PromptInput.prompt_input_action_add_screenshot/1, [])

      assert attribute(html, "button", "role") == "menuitem"
      assert count(html, "[data-icon=desktop]") == 1
    end
  end

  describe "prompt_input_model_select/1" do
    test "is one native select rather than four Radix parts" do
      html =
        render_component(&PromptInput.prompt_input_model_select/1,
          id: "model",
          name: "chat[model]",
          inner_block: slot(~s(<option value="a">A</option>))
        )

      assert attribute(html, "select#model", "name") == "chat[model]"
      assert attribute(html, "select#model", "aria-label") == "Model"
      assert attribute(html, "select#model", "class") =~ "hover:bg-muted"
      refute attribute(html, "select#model", "class") =~ "hover:bg-accent"
    end

    test "an item is an option that can be preselected" do
      html =
        render_component(&PromptInput.prompt_input_model_select_item/1,
          value: "sonnet",
          selected: true,
          inner_block: slot("Sonnet")
        )

      assert attribute(html, "option", "value") == "sonnet"
      assert attribute(html, "option", "selected") == ""
      assert text(html, "option") == "Sonnet"
    end
  end

  describe "attachments" do
    test "a populated list holds one item per attachment" do
      items =
        render_component(&PromptInput.attachment/1,
          id: "attachment-1",
          inner_block: slot("one")
        ) <>
          render_component(&PromptInput.attachment/1,
            id: "attachment-2",
            inner_block: slot("two")
          )

      html = render_component(&PromptInput.attachments/1, id: "files", inner_block: slot(items))

      assert count(html, "[data-slot=attachment]") == 2
      assert attribute(html, "#files", "data-variant") == "grid"
      assert attribute(html, "#files", "class") =~ "ml-auto w-fit"
    end

    test "an empty list says so rather than rendering an unexplained gap" do
      html = render_component(&PromptInput.attachment_empty/1, id: "files-empty")

      assert text(html, "#files-empty") == "No attachments"
      assert attribute(html, "#files-empty", "class") =~ "text-muted-foreground"
    end

    test "the list variant stacks and the grid variant wraps" do
      list = render_component(&PromptInput.attachments/1, variant: :list, inner_block: slot(""))
      grid = render_component(&PromptInput.attachments/1, variant: :grid, inner_block: slot(""))

      assert attribute(list, "[data-slot=attachments]", "class") =~ "flex-col gap-2"
      assert attribute(grid, "[data-slot=attachments]", "class") =~ "flex-wrap gap-2"
    end

    test "the preview shows an image when it has one and a glyph when it does not" do
      with_image =
        render_component(&PromptInput.attachment_preview/1,
          media_category: :image,
          src: "/uploads/cat.png",
          filename: "cat.png"
        )

      assert attribute(with_image, "img", "src") == "/uploads/cat.png"
      assert attribute(with_image, "img", "alt") == "cat.png"

      without_image = render_component(&PromptInput.attachment_preview/1, media_category: :audio)
      assert count(without_image, "[data-icon=music]") == 1
    end

    test "the name is hidden in the grid variant, where the thumbnail is the item" do
      inline =
        render_component(&PromptInput.attachment_info/1,
          label: "notes.pdf",
          media_type: "application/pdf"
        )

      grid = render_component(&PromptInput.attachment_info/1, label: "notes.pdf", variant: :grid)

      assert text(inline, "[data-slot=attachment-info]") =~ "notes.pdf"
      assert text(inline, "[data-slot=attachment-info]") =~ "application/pdf"
      assert count(grid, "[data-slot=attachment-info]") == 0
    end

    test "remove is named for assistive technology even while hidden from a pointer" do
      html =
        render_component(&PromptInput.attachment_remove/1, id: "drop-1", label: "Remove cat.png")

      assert attribute(html, "#drop-1", "aria-label") == "Remove cat.png"
      assert text(html, ".sr-only") == "Remove cat.png"
      assert attribute(html, "#drop-1", "class") =~ "group-hover/attachment:opacity-100"
      assert attribute(html, "#drop-1", "class") =~ "focus-visible:opacity-100"
    end
  end

  describe "speech_input/1" do
    test "starts silent, names its action, and carries the capture hook" do
      html =
        render_component(&PromptInput.speech_input/1, id: "mic", transcript_event: "transcribed")

      assert attribute(html, "#mic", "phx-hook") =~ ".SpeechInput"
      assert attribute(html, "#mic", "data-recording") == "false"
      assert attribute(html, "#mic", "data-transcript-event") == "transcribed"
      assert attribute(html, "#mic-button", "aria-label") == "Start voice input"
      assert count(html, "[data-icon=mic]") == 1
    end

    test "draws the three staggered rings the source animates while recording" do
      html =
        render_component(&PromptInput.speech_input/1, id: "mic", transcript_event: "transcribed")

      rings = query(html, ".animate-ping") |> LazyHTML.to_tree()
      assert length(rings) == 3

      assert attribute(html, ".animate-ping", "class") =~
               "group-data-[recording=true]/speech:block"
    end
  end

  describe "mic_selector/1" do
    test "hands its options to the hook and tells LiveView not to touch them" do
      html = render_component(&PromptInput.mic_selector/1, id: "mic-device")

      assert attribute(html, "#mic-device", "phx-hook") =~ ".MicSelector"
      assert attribute(html, "#mic-device", "phx-update") == "ignore"
      assert attribute(html, "#mic-device", "aria-label") == "Microphone"
      assert text(html, "#mic-device option") == "Select microphone..."
    end

    test "renders devices the server already knows" do
      html =
        render_component(&PromptInput.mic_selector_item/1,
          value: "device-1",
          inner_block: slot("Built-in microphone")
        )

      assert attribute(html, "option", "value") == "device-1"
      assert text(html, "option") == "Built-in microphone"
    end
  end

  describe "model_selector/1" do
    test "the panel is a named popover carrying the filter hook" do
      html = render_component(&PromptInput.model_selector/1, id: "models", inner_block: slot("x"))

      assert attribute(html, "#models", "popover") == "auto"
      assert attribute(html, "#models", "phx-hook") =~ ".ModelSelectorFilter"
      assert attribute(html, "#models", "aria-label") == "Select a model"
    end

    test "the search field is what the hook reads" do
      html = render_component(&PromptInput.model_selector_input/1, id: "model-search")

      assert attribute(html, "#model-search", "data-slot") == "model-selector-input"
      assert attribute(html, "#model-search", "role") == "combobox"
      assert attribute(html, "#model-search", "autocomplete") == "off"
    end

    test "an item exposes the string the filter matches against" do
      html =
        render_component(&PromptInput.model_selector_item/1,
          id: "model-sonnet",
          value: "anthropic claude sonnet",
          selected: true,
          inner_block: slot("Claude Sonnet")
        )

      assert attribute(html, "#model-sonnet", "role") == "option"
      assert attribute(html, "#model-sonnet", "data-value") == "anthropic claude sonnet"
      assert attribute(html, "#model-sonnet", "aria-selected") == "true"
      assert attribute(html, "#model-sonnet", "data-slot") == "model-selector-item"
    end

    test "the empty state is addressable, because the hook reveals it" do
      html = render_component(&PromptInput.model_selector_empty/1, id: "models-empty")

      assert attribute(html, "#models-empty", "data-slot") == "model-selector-empty"
      assert text(html, "#models-empty") == "No models found."
    end

    test "a logo takes its source from the caller rather than a hardcoded host" do
      html =
        render_component(&PromptInput.model_selector_logo/1,
          src: "/logos/anthropic.svg",
          provider: "Anthropic"
        )

      assert attribute(html, "img", "src") == "/logos/anthropic.svg"
      assert attribute(html, "img", "alt") == "Anthropic logo"
      refute attribute(html, "img", "class") =~ "dark:invert"
    end
  end

  describe "queue" do
    test "a populated queue lists one row per waiting message" do
      rows =
        render_component(&PromptInput.queue_item/1, id: "queued-1", inner_block: slot("one")) <>
          render_component(&PromptInput.queue_item/1, id: "queued-2", inner_block: slot("two"))

      list = render_component(&PromptInput.queue_list/1, id: "queued", inner_block: slot(rows))
      html = render_component(&PromptInput.queue/1, id: "queue", inner_block: slot(list))

      assert count(html, "#queued li") == 2
      assert attribute(html, "#queue", "class") =~ "rounded-xl"
    end

    test "an empty queue says nothing is waiting" do
      html = render_component(&PromptInput.queue_empty/1, id: "queue-empty")

      assert attribute(html, "#queue-empty", "data-slot") == "queue-empty"
      assert text(html, "#queue-empty") == "Nothing queued"
    end

    test "an empty queue accepts the caller's own words" do
      html =
        render_component(&PromptInput.queue_empty/1,
          id: "queue-empty",
          inner_block: slot("Send a message to start the queue")
        )

      assert text(html, "#queue-empty") == "Send a message to start the queue"
    end

    test "a section is a details element, so it opens without JavaScript" do
      section =
        render_component(&PromptInput.queue_section/1,
          id: "queued-section",
          inner_block: slot("x")
        )

      assert attribute(section, "details#queued-section", "open") == ""
      assert attribute(section, "details#queued-section", "class") =~ "group/queue-section"
    end

    test "the section label states the count beside the word" do
      html = render_component(&PromptInput.queue_section_label/1, label: "queued", count: 3)

      assert text(html, "span span") == "3 queued"

      assert attribute(html, "[data-icon=chevron-down]", "class") =~
               "group-open/queue-section:rotate-0"
    end

    test "a completed item strikes its own text through rather than only dimming it" do
      done =
        render_component(&PromptInput.queue_item_content/1,
          completed: true,
          inner_block: slot("x")
        )

      todo = render_component(&PromptInput.queue_item_content/1, inner_block: slot("x"))

      assert attribute(done, "span", "class") =~ "line-through"
      refute attribute(todo, "span", "class") =~ "line-through"
    end

    test "an item action is named and reachable by keyboard" do
      html =
        render_component(&PromptInput.queue_item_action/1,
          id: "queued-1-remove",
          label: "Remove from queue",
          inner_block: slot("x")
        )

      assert attribute(html, "#queued-1-remove", "aria-label") == "Remove from queue"
      assert attribute(html, "#queued-1-remove", "class") =~ "focus-visible:opacity-100"
    end

    test "an attached file names itself beside the clip" do
      html = render_component(&PromptInput.queue_item_file/1, inner_block: slot("notes.pdf"))

      assert count(html, "[data-icon=paperclip]") == 1
      assert text(html, ".truncate") == "notes.pdf"
    end
  end
end
