// Reveals a live voice transcript at roughly spoken pace instead of the
// faster rate provider text deltas arrive at. The full accumulated text is
// carried on data-content; this hook owns the element's text content. Reveal
// progress is remembered per provider item so the reveal continues smoothly
// when the ephemeral live row is replaced by the durable message row.
const TICK_MILLISECONDS = 48
const revealedByItem = new Map()

const PacedTranscript = {
  mounted() {
    this.shown = revealedByItem.get(this.itemId()) || 0
    this.sync()
    this.timer = setInterval(() => {
      const full = this.el.dataset.content || ""
      if (this.shown < full.length) {
        this.shown += 1
        revealedByItem.set(this.itemId(), this.shown)
        if (revealedByItem.size > 64) {
          revealedByItem.delete(revealedByItem.keys().next().value)
        }
      }
      this.sync()
    }, TICK_MILLISECONDS)
  },

  updated() {
    this.sync()
  },

  destroyed() {
    clearInterval(this.timer)
  },

  itemId() {
    return this.el.dataset.itemId || this.el.id
  },

  sync() {
    const full = this.el.dataset.content || ""
    if (this.shown > full.length) this.shown = full.length
    const next = full.slice(0, this.shown)
    if (this.el.textContent !== next) this.el.textContent = next
  }
}

export default PacedTranscript
