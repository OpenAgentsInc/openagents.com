const CoderCopy = {
  mounted() {
    this.onClick = () => this.copy()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  copy() {
    const text = this.el.dataset.copyText || "curl -fsSL https://openagents.com/install.sh | sh"
    const hintEl = document.getElementById("copy-hint")

    // The hint sits inside a box drawn in text, so the confirmation has to
    // occupy exactly the columns the command did or the frame loses a side
    // for two seconds. Centred by measurement rather than by hand-counted
    // spaces, which is what went stale the last time the command changed.
    const centre = (label, width) => {
      const pad = Math.max(0, width - label.length)
      const left = Math.floor(pad / 2)
      return " ".repeat(left) + label + " ".repeat(pad - left)
    }

    const flashCopied = () => {
      if (hintEl) {
        const width = text.length + 2
        hintEl.textContent = centre("copied to clipboard!", width)
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
