const CoderCopy = {
  mounted() {
    this.onClick = () => this.copy()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  copy() {
    const text = this.el.dataset.copyText || "npm i -g @openagentsinc/cli"
    const hintEl = document.getElementById("copy-hint")

    const flashCopied = () => {
      if (hintEl) {
        hintEl.textContent = "    copied to clipboard!     "
        clearTimeout(this._timeout)
        this._timeout = setTimeout(() => {
          hintEl.textContent = " " + text + " "
        }, 2000)
      }
    }

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(flashCopied).catch(() => {
        this.fallbackCopy(text, flashCopied)
      })
    } else {
      this.fallbackCopy(text, flashCopied)
    }
  },

  fallbackCopy(text, cb) {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.style.position = "fixed"
    ta.style.top = "0"
    ta.style.left = "0"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    try {
      document.execCommand("copy")
      cb()
    } catch (e) {
      console.error("Copy failed", e)
    }
    document.body.removeChild(ta)
  }
}

export default CoderCopy
