defmodule OpenAgentsWeb.CoderLive do
  @moduledoc """
  The install command, on a terminal-shaped page that copies it when clicked.

  It carried a link to a `webtui.css` that was never added, so the page asked
  for a stylesheet that 404s and the root layout grew an `@extra_css` hatch to
  let it. Both are gone: this repository has one component system, and a page
  that needs a second one needs a decision rather than an escape hatch. The
  colours come from the CSS variables that system already defines, with literal
  fallbacks, which is what the page was really relying on.
  """
  use OpenAgentsWeb, :live_view

  @cmd "npm i -g @openagentsinc/cli"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "OpenAgents Coder")
     |> assign(:cmd, @cmd)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="coder-viewport"
      phx-hook="CoderCopy"
      data-copy-text={@cmd}
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
        >
          <span style="color: var(--foreground2, #666);">┌──────────────────</span> OpenAgents <span style="color: var(--foreground2, #666);">───────────────────┐</span>
          <span style="color: var(--foreground2, #666);">│</span>0001110110010001100001010010001010000100001011000<span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│                                                 │</span>
          <span style="color: var(--foreground2, #666);">│</span>     <span class="font-bold text-cyan-400" style="color: #56b6c2;">██████╗ ██████╗ ██████╗ ███████╗██████╗</span>     <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>    <span class="font-bold text-cyan-400" style="color: #56b6c2;">██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗</span>    <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>    <span class="font-bold text-cyan-400" style="color: #56b6c2;">██║     ██║   ██║██║  ██║█████╗  ██████╔╝</span>    <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>    <span class="font-bold text-cyan-400" style="color: #56b6c2;">██║     ██║   ██║██║  ██║██╔══╝  ██╔══██╗</span>    <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>    <span class="font-bold text-cyan-400" style="color: #56b6c2;">╚██████╗╚██████╔╝██████╔╝███████╗██║  ██║</span>    <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>     <span class="font-bold text-cyan-400" style="color: #56b6c2;">╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝</span>    <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│                                                 │</span>
          <span style="color: var(--foreground2, #666);">│</span>   <span id="copy-hint" style="color: var(--foreground1, #ccc);"> <%= @cmd %> </span>   <span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">│</span>1111100010110000010100000000000010001001100011101<span style="color: var(--foreground2, #666);">│</span>
          <span style="color: var(--foreground2, #666);">└─────────────────────────────────────────────────┘</span>
        </pre>
      </div>
    </div>
    """
  end
end
