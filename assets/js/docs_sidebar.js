const DocsSidebar = {
  mounted() {
    this.desktop = window.matchMedia("(min-width: 1024px)")
    this.onClick = event => this.handleClick(event)
    this.onKeydown = event => this.handleKeydown(event)
    this.onBreakpointChange = () => this.restoreForViewport()

    this.el.addEventListener("click", this.onClick)
    window.addEventListener("keydown", this.onKeydown)
    this.desktop.addEventListener("change", this.onBreakpointChange)
    this.restoreForViewport()
  },

  updated() {
    this.applyState(this.open)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("keydown", this.onKeydown)
    this.desktop.removeEventListener("change", this.onBreakpointChange)
    document.body.classList.remove("docs-sidebar-open")
  },

  handleClick(event) {
    if (event.target.closest("[data-docs-sidebar-toggle]")) {
      const opening = !this.open
      this.applyState(opening, opening ? {focusSidebar: true} : {restoreFocus: true})
      return
    }

    if (event.target.closest("#docs-sidebar-scrim")) {
      this.applyState(false, {restoreFocus: true})
      return
    }

    if (!this.desktop.matches && event.target.closest("#docs-sidebar a")) {
      this.applyState(false)
    }
  },

  handleKeydown(event) {
    if (event.key === "Escape" && this.open && !this.desktop.matches) {
      this.applyState(false, {restoreFocus: true})
    }
  },

  restoreForViewport() {
    this.applyState(this.desktop.matches)
  },

  applyState(open, options = {}) {
    const sidebar = this.el.querySelector("#docs-sidebar")
    const toggles = this.el.querySelectorAll("[data-docs-sidebar-toggle]")
    const expandToggle = this.el.querySelector("#docs-sidebar-expand-toggle")
    const scrim = this.el.querySelector("#docs-sidebar-scrim")
    if (!sidebar || toggles.length === 0 || !expandToggle || !scrim) return

    this.open = open
    this.el.dataset.sidebarInitialized = "true"
    this.el.dataset.sidebarOpen = open ? "true" : "false"
    sidebar.setAttribute("aria-hidden", open ? "false" : "true")
    sidebar.inert = !open
    toggles.forEach(toggle => toggle.setAttribute("aria-expanded", open ? "true" : "false"))
    scrim.setAttribute("aria-hidden", open ? "false" : "true")
    document.body.classList.toggle("docs-sidebar-open", open && !this.desktop.matches)

    if (options.focusSidebar && !this.desktop.matches) {
      window.requestAnimationFrame(() => {
        sidebar.querySelector("button, a, summary")?.focus()
      })
    } else if (options.restoreFocus) {
      expandToggle.focus()
    }
  }
}

export default DocsSidebar
