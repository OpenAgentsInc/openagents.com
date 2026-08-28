defmodule OpenAgentsWeb.CoderLive do
  @moduledoc """
  The install command, on a terminal-shaped page that copies it when clicked.

  It carried a link to a `webtui.css` that was never added, so the page asked
  for a stylesheet that 404s and the root layout grew an `@extra_css` hatch to
  let it. Both are gone: this repository has one component system, and a page
  that needs a second one needs a decision rather than an escape hatch. The
  colours come from the CSS variables that system already defines, with literal
  fallbacks, which is what the page was really relying on.

  The command it prints is the installer. `@openagentsinc/cli` is a different
  program answering to the same name, and this page was the last surface still
  handing it out.

  The frame is built rather than typed, and the command sets its width rather
  than being fitted into it. Typed, it was significant whitespace inside a
  template: the box was drawn for a 49-column interior, the command row came to
  35, and the box had been rendering with one short side since long before the
  command changed. `phx-no-format` does not save a typed box either — the HEEx
  formatter re-indents the text inside a multi-line tag whichever way that
  attribute is set, which puts four spaces down the left of every row but the
  first. Composed here, the padding is arithmetic against one interior width and
  the template holds a single interpolation.
  """
  use OpenAgentsWeb, :live_view

  @cmd OpenAgentsWeb.CliInstall.unix()
  @windows_cmd OpenAgentsWeb.CliInstall.windows()

  # Three spaces between the frame and the hint, and the hint carries one space
  # of its own on each side, which is the gap the copy confirmation replaces.
  @outer 3
  @interior @outer + String.length(@cmd) + 2 + @outer

  # The wordmark and the two noise rows were drawn for a 49-column interior.
  # Each keeps the padding it was drawn with and gains the difference.
  @drawn_for 49
  @side div(@interior - @drawn_for, 2)

  @wordmark [
    {5, "██████╗ ██████╗ ██████╗ ███████╗██████╗", 5},
    {4, "██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗", 4},
    {4, "██║     ██║   ██║██║  ██║█████╗  ██████╔╝", 4},
    {4, "██║     ██║   ██║██║  ██║██╔══╝  ██╔══██╗", 4},
    {4, "╚██████╗╚██████╔╝██████╔╝███████╗██║  ██║", 4},
    {5, "╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝", 4}
  ]

  @noise_top "000111011001000110000101001000101000010000101100010110010"
  @noise_bottom "111110001011000001010000000000001000100110001110101101001"

  @dim ~s|<span style="color: var(--foreground2, #666);">|
  @cyan ~s|<span class="font-bold text-cyan-400" style="color: #56b6c2;">|
  @close "</span>"

  @title " OpenAgents "
  @rule @interior - String.length(@title)

  @frame Enum.join(
           [
             @dim <>
               "┌" <>
               String.duplicate("─", div(@rule, 2)) <>
               @close <>
               @title <>
               @dim <> String.duplicate("─", @rule - div(@rule, 2)) <> "┐" <> @close,
             @dim <> "│" <> @close <> @noise_top <> @dim <> "│" <> @close,
             @dim <> "│" <> String.duplicate(" ", @interior) <> "│" <> @close
           ] ++
             Enum.map(@wordmark, fn {lead, glyphs, trail} ->
               @dim <>
                 "│" <>
                 @close <>
                 String.duplicate(" ", lead + @side) <>
                 @cyan <>
                 glyphs <>
                 @close <>
                 String.duplicate(" ", trail + @side) <> @dim <> "│" <> @close
             end) ++
             [
               @dim <> "│" <> String.duplicate(" ", @interior) <> "│" <> @close,
               @dim <>
                 "│" <>
                 @close <>
                 String.duplicate(" ", @outer) <>
                 ~s|<span id="copy-hint" style="color: var(--foreground1, #ccc);"> | <>
                 @cmd <>
                 " " <>
                 @close <>
                 String.duplicate(" ", @outer) <> @dim <> "│" <> @close,
               @dim <> "│" <> @close <> @noise_bottom <> @dim <> "│" <> @close,
               @dim <> "└" <> String.duplicate("─", @interior) <> "┘" <> @close
             ],
           "\n"
         )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "OpenAgents Coder")
     |> assign(:cmd, @cmd)
     |> assign(:windows_cmd, @windows_cmd)
     |> assign(:frame, @frame)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="coder-viewport"
      phx-hook="CoderCopy"
      data-copy-text={@cmd}
      data-unix-command={@cmd}
      data-windows-command={@windows_cmd}
      class="min-h-screen w-full flex flex-col items-center justify-center p-4 select-none cursor-pointer"
      style="background-color: var(--background0, #000); color: var(--foreground0, #fff); font-family: var(--font-family, monospace); -webkit-user-select: none; user-select: none;"
    >
      <div
        class="inline-block text-center select-none font-mono text-sm sm:text-base leading-tight"
        style="-webkit-user-select: none; user-select: none; color: var(--foreground0, #fff);"
      >
        <pre
          class="font-mono text-xs sm:text-sm md:text-base leading-none select-none pointer-events-none"
          style="margin: 0; color: var(--foreground0, #fff); -webkit-user-select: none; user-select: none;"
        >{raw(@frame)}</pre>
      </div>
    </div>
    """
  end
end
