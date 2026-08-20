import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {
  CallRecorder,
  RECORDING_MIME_CANDIDATES,
  recordingMayStart,
  supportedRecordingMimeType,
} from "../js/voice_recording.mjs"

const supported = types => ({isTypeSupported: type => types.includes(type)})

// Fakes rather than mocks: the point is the state machine's ordering and its
// refusal to take a call down, neither of which needs a real AudioContext.
const fakeGraph = () => {
  const node = () => ({connect: () => {}})

  return class FakeAudioContext {
    constructor() {
      this.state = "running"
      this.closed = false
    }

    createMediaStreamDestination() {
      return {stream: "mixed-stream"}
    }

    createChannelMerger() {
      return node()
    }

    createMediaStreamSource() {
      return node()
    }

    close() {
      this.closed = true
      this.state = "closed"
    }
  }
}

// Mirrors the one MediaRecorder behavior the upload ordering depends on:
// stopping flushes a final `dataavailable` and only then reports `onstop`.
class FakeRecorder {
  constructor(stream, options) {
    this.stream = stream
    this.options = options
    this.state = "inactive"
    this.ondataavailable = null
    this.onstop = null
    this.onerror = null
    this.tailSize = 0
  }

  start(timeslice) {
    this.state = "recording"
    this.timeslice = timeslice
  }

  stop() {
    this.state = "inactive"

    setTimeout(() => {
      if (this.tailSize) this.emit(this.tailSize)
      if (this.onstop) this.onstop()
    }, 0)
  }

  emit(size) {
    if (this.ondataavailable) this.ondataavailable({data: {size}})
  }
}

const build = (overrides = {}) => {
  const uploads = []
  const finalizes = []
  let recorder = null

  const call = new CallRecorder({
    microphone: "mic-stream",
    remoteStream: "sarah-stream",
    generation: "3",
    timesliceMs: 5000,
    mimeType: "audio/webm;codecs=opus",
    audioContextClass: fakeGraph(),
    recorderClass: class extends FakeRecorder {
      constructor(...args) {
        super(...args)
        recorder = this
      }
    },
    upload: async options => {
      uploads.push(options)
      if (overrides.uploadFails) throw new Error("refused")
    },
    finalize: async options => finalizes.push(options),
    now: () => 1000,
    ...overrides,
  })

  return {call, uploads, finalizes, recorderRef: () => recorder}
}

test("candidate containers are ordered so Opus in WebM wins when available", () => {
  assert.equal(RECORDING_MIME_CANDIDATES[0], "audio/webm;codecs=opus")
  assert.equal(supportedRecordingMimeType(supported(["audio/mp4"])), "audio/mp4")

  assert.equal(
    supportedRecordingMimeType(supported(["audio/webm", "audio/webm;codecs=opus"])),
    "audio/webm;codecs=opus",
  )
})

test("a browser without MediaRecorder yields no container rather than throwing", () => {
  assert.equal(supportedRecordingMimeType(undefined), null)
  assert.equal(supportedRecordingMimeType({}), null)
})

test("capture requires both audio sources, a container, and a fenced generation", () => {
  const ready = {
    enabled: true,
    mimeType: "audio/webm;codecs=opus",
    hasMicrophone: true,
    hasRemoteStream: true,
    generation: "7",
    alreadyStarted: false,
  }

  assert.equal(recordingMayStart(ready), true)

  for (const missing of [
    {...ready, enabled: false},
    {...ready, mimeType: null},
    {...ready, hasMicrophone: false},
    {...ready, hasRemoteStream: false},
    {...ready, generation: null},
    {...ready, alreadyStarted: true},
  ]) {
    assert.equal(recordingMayStart(missing), false)
  }
})

test("slices upload in order and only advance the sequence on success", async () => {
  const {call, uploads, recorderRef} = build()

  assert.equal(call.start(), true)
  assert.equal(call.capturing, true)

  recorderRef().emit(120)
  recorderRef().emit(240)
  await call.queue

  assert.deepEqual(
    uploads.map(upload => upload.sequence),
    [1, 2],
  )
  assert.equal(call.sequence, 2)
})

test("empty slices are dropped so an idle timeslice cannot burn a sequence number", async () => {
  const {call, uploads, recorderRef} = build()
  call.start()

  recorderRef().emit(0)
  await call.queue

  assert.deepEqual(uploads, [])
  assert.equal(call.sequence, 0)
})

test("a refused upload stops capture, finalizes as failed, and closes the graph", async () => {
  const {call, finalizes, recorderRef} = build({uploadFails: true})
  call.start()
  const context = call.context

  recorderRef().emit(64)
  await call.queue
  // The failure path finalizes on its own; give its promise chain a turn.
  await new Promise(resolve => setTimeout(resolve, 0))

  assert.equal(call.state, "failed")
  assert.equal(call.capturing, false)
  assert.equal(context.closed, true)
  assert.deepEqual(
    finalizes.map(finalize => finalize.status),
    ["failed"],
  )
})

test("a clean stop commits the flushed tail slice before finalizing", async () => {
  let clock = 1000
  const {call, uploads, finalizes, recorderRef} = build({now: () => clock})
  call.start()

  recorderRef().emit(32)
  // The slice MediaRecorder flushes on stop is the end of the conversation; a
  // finalize that raced ahead of it would close the recording one slice short.
  recorderRef().tailSize = 48
  clock = 8500
  await call.stop()

  assert.deepEqual(
    uploads.map(upload => upload.sequence),
    [1, 2],
  )
  assert.deepEqual(finalizes, [{status: "complete", generation: "3", durationMs: 7500}])
  assert.equal(call.state, "complete")
})

test("a finalize that never lands does not throw at the caller", async () => {
  const {call} = build({
    finalize: async () => {
      throw new Error("offline")
    },
  })

  call.start()
  await call.stop()

  assert.equal(call.state, "complete")
})

test("a broken audio graph leaves the call alone instead of raising", () => {
  const {call, finalizes} = build({
    audioContextClass: class {
      constructor() {
        throw new Error("AudioContext blocked")
      }
    },
  })

  assert.equal(call.start(), false)
  assert.equal(call.capturing, false)
  assert.deepEqual(finalizes, [])
})

test("the hook uploads audio with its generation and sequence, never a client session id", () => {
  const source = readFileSync(new URL("../js/voice_controller.js", import.meta.url), "utf8")

  assert.match(source, /["']x-voice-generation["']/)
  assert.match(source, /["']x-voice-recording-sequence["']/)
  assert.doesNotMatch(source, /voice_session_id/)
})

test("a remote track that outruns the server generation is retried from updated()", () => {
  const source = readFileSync(new URL("../js/voice_controller.js", import.meta.url), "utf8")

  // The track event fires during setRemoteDescription, before the LiveView
  // diff delivers data-server-generation, so the hook must keep the stream
  // and attempt recording again on every update.
  assert.match(source, /this\.remoteRecordingStream = event\.streams\[0\]/)
  assert.match(
    source,
    /this\.reflectServerActivity\(\)\s*\n\s*this\.startRecording\(this\.remoteRecordingStream\)/,
  )
})
