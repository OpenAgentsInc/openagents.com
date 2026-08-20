defmodule OpenAgentsWeb.FormSubmitButtonsTest do
  @moduledoc """
  Every button that is meant to submit a form must say so.

  `OpenAgentsWeb.UI.button/1` defaults to `type="button"`, which is the right
  default -- a button outside a form that submits one by accident is worse than
  one that does nothing. But it means a call site inside a form has to opt in,
  and eight of them had not: creating an issue, a milestone, a label, a
  project, a project item, and two comment forms all rendered a primary button
  that did nothing at all when clicked.

  The suite could not catch it. `render_submit/1` submits the form directly and
  never touches the button, so every one of those flows was covered by a
  passing test while being completely broken in a browser. This test reads the
  templates instead, which is the only place the defect is visible.
  """

  use ExUnit.Case, async: true

  @form_pattern ~r/<\.form\b.*?<\/\.form>/s
  @button_pattern ~r/<\.button\b[^>]*?>/s

  test "no button inside a submitting form is left as type=button" do
    offenders =
      templates()
      |> Enum.flat_map(&offenders_in/1)
      |> Enum.sort()

    assert offenders == [],
           """
           These buttons sit inside a form that submits, but carry no `type`,
           so `UI.button/1` renders them as `type="button"` and clicking them
           does nothing:

           #{Enum.map_join(offenders, "\n", fn {file, tag} -> "  #{file}\n    #{tag}" end)}

           Add `type="submit"`. If the button is meant to run a `phx-click`
           rather than submit, it is already correct -- give it a `phx-click`
           and this test will leave it alone.
           """
  end

  defp templates do
    Path.wildcard("lib/openagents_web/**/*.ex") ++ Path.wildcard("lib/openagents_web/**/*.heex")
  end

  defp offenders_in(path) do
    source = File.read!(path)

    @form_pattern
    |> Regex.scan(source)
    |> Enum.map(&hd/1)
    |> Enum.filter(&submitting?/1)
    |> Enum.flat_map(fn form ->
      @button_pattern
      |> Regex.scan(form)
      |> Enum.map(&hd/1)
      |> Enum.filter(&needs_type?/1)
      |> Enum.map(&{path, squeeze(&1)})
    end)
  end

  # A form with neither a `phx-submit` nor an `action` is not going anywhere,
  # so a button inside it is not a submit button.
  defp submitting?(form),
    do: String.contains?(form, "phx-submit") or String.contains?(form, "action=")

  defp needs_type?(tag) do
    # A `phx-click` button is a control, not a submit.
    # A button rendered as a link is an anchor and submits nothing.
    not String.contains?(tag, "type=") and
      not String.contains?(tag, "phx-click") and
      not Enum.any?(~w(navigate href patch), &String.contains?(tag, &1))
  end

  defp squeeze(tag), do: tag |> String.split() |> Enum.join(" ")
end
