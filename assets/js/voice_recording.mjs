// Browser-side capture of a call, because the server never sees the audio.
//
// Media flows browser-to-OpenAI over WebRTC and Phoenix holds only a lifecycle
// sideband, so the only place both sides of a call exist together is here. The
// microphone becomes the left channel and Sarah's track the right, which keeps
// the two voices attributable in one file instead of doubling storage.
//
// Nothing in here may take a call down. Every failure path stops recording,
// reports it, and leaves the conversation running.

export const RECORDING_MIME_CANDIDATES = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4",
  "audio/ogg;codecs=opus",
]

// Safari's WebM support is the weak spot, so the container is discovered rather
// than assumed and the server stores whichever one arrived.
export const supportedRecordingMimeType = (recorder = globalThis.MediaRecorder) => {
  if (!recorder || typeof recorder.isTypeSupported !== "function") return null
  return RECORDING_MIME_CANDIDATES.find(type => recorder.isTypeSupported(type)) || null
}

// Capture is a strict subset of an established call: it needs both audio sources,
// a supported container, and a server generation to fence the upload against. It
// never gates the call itself — a false here means an unrecorded call, not a
// failed one.
export const recordingMayStart = ({
  enabled,
  mimeType,
  hasMicrophone,
  hasRemoteStream,
  generation,
  alreadyStarted,
}) =>
  Boolean(
    enabled &&
      mimeType &&
      hasMicrophone &&
      hasRemoteStream &&
      generation &&
      !alreadyStarted,
  )

export class CallRecorder {
  // `upload` and `finalize` are injected so the state machine can be tested
  // without a network, and so the hook keeps ownership of CSRF and keepalive.
  constructor({
    microphone,
    remoteStream,
    generation,
    timesliceMs,
    upload,
    finalize,
    onStateChange,
    audioContextClass = globalThis.AudioContext,
    recorderClass = globalThis.MediaRecorder,
    mimeType = supportedRecordingMimeType(recorderClass),
    now = () => (globalThis.performance ? globalThis.performance.now() : 0),
  }) {
    this.microphone = microphone
    this.remoteStream = remoteStream
    this.generation = generation
    this.timesliceMs = timesliceMs
    this.upload = upload
    this.finalize = finalize
    this.onStateChange = onStateChange || (() => {})
    this.audioContextClass = audioContextClass
    this.recorderClass = recorderClass
    this.mimeType = mimeType
    this.now = now

    this.state = "idle"
    this.sequence = 0
    this.queue = Promise.resolve()
    this.context = null
    this.destination = null
    this.recorder = null
    this.startedAt = null
  }

  start() {
    if (this.state !== "idle") return false

    try {
      this.context = new this.audioContextClass()
      this.destination = this.context.createMediaStreamDestination()

      // Two mono sources into one stereo stream: mic left, Sarah right.
      const merger = this.context.createChannelMerger(2)
      this.context.createMediaStreamSource(this.microphone).connect(merger, 0, 0)
      this.context.createMediaStreamSource(this.remoteStream).connect(merger, 0, 1)
      merger.connect(this.destination)

      this.recorder = new this.recorderClass(this.destination.stream, {mimeType: this.mimeType})
      this.recorder.ondataavailable = event => this.enqueue(event.data)
      this.recorder.onerror = () => this.fail()
      this.recorder.start(this.timesliceMs)

      this.startedAt = this.now()
      this.setState("recording")
      return true
    } catch (_error) {
      this.fail()
      return false
    }
  }

  // `stopping` still accepts slices: stopping a MediaRecorder flushes one last
  // `dataavailable`, and that tail is exactly the audio a call ends on.
  get accepting() {
    return this.state === "recording" || this.state === "stopping"
  }

  enqueue(blob) {
    if (!blob || !blob.size || !this.accepting) return

    // Slices are only media in order, so uploads are chained rather than raced.
    this.queue = this.queue.then(() => this.send(blob))
  }

  async send(blob) {
    if (!this.accepting) return

    const sequence = this.sequence + 1

    try {
      await this.upload({blob, sequence, generation: this.generation, mimeType: this.mimeType})
      this.sequence = sequence
    } catch (_error) {
      // A refusal is authoritative: a ceiling was reached, the generation is
      // stale, or the window closed. Retrying would only add load.
      this.fail()
    }
  }

  async stop({status = "complete"} = {}) {
    if (this.state !== "recording" && this.state !== "failing") return

    const outcome = this.state === "failing" ? "failed" : status
    this.setState("stopping")

    await this.stopRecorder()

    const durationMs =
      this.startedAt === null ? null : Math.max(0, Math.round(this.now() - this.startedAt))

    // Drained before the finalize, so the recording is closed against the last
    // slice that actually committed rather than ahead of it.
    await this.drainQueue()
    this.closeGraph()
    this.setState(outcome === "failed" ? "failed" : "complete")

    try {
      await this.finalize({status: outcome, generation: this.generation, durationMs})
    } catch (_error) {
      // The retention sweep closes a recording nobody finalized.
    }
  }

  // Resolves once the recorder has flushed, with a ceiling so a recorder that
  // never reports a stop cannot hang the call's shutdown path.
  stopRecorder() {
    return new Promise(resolve => {
      const recorder = this.recorder

      if (!recorder || recorder.state === "inactive") return resolve()

      let settled = false
      const done = () => {
        if (settled) return
        settled = true
        clearTimeout(ceiling)
        resolve()
      }

      const ceiling = setTimeout(done, 2_000)
      recorder.onstop = done

      try {
        recorder.stop()
      } catch (_error) {
        done()
      }
    })
  }

  // The chain can grow while it is being drained, because the flushed tail slice
  // arrives after `stop()`. Drain until it stops growing.
  async drainQueue() {
    let pending

    do {
      pending = this.queue
      await pending.catch(() => {})
    } while (pending !== this.queue)

    this.queue = Promise.resolve()
  }

  fail() {
    if (this.state === "recording") {
      this.setState("failing")
      // Detach first: a stopping recorder can still emit one more slice.
      if (this.recorder) this.recorder.ondataavailable = null
      this.stop({status: "failed"})
    }
  }

  closeGraph() {
    try {
      if (this.context && this.context.state !== "closed") this.context.close()
    } catch (_error) {
      // Closing an already-torn-down context is not an error worth surfacing.
    }

    this.context = null
    this.destination = null
    this.recorder = null
  }

  setState(state) {
    this.state = state
    this.onStateChange(state)
  }

  get capturing() {
    return this.state === "recording"
  }
}
