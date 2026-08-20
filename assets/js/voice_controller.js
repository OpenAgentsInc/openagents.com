import {
  ACTIVE_SERVER_STATES,
  READY_SERVER_STATES,
  TERMINAL_SERVER_STATES,
  admissionErrorMessage,
  closeVoiceResources,
  microphoneErrorMessage,
  microphoneMayTransmit,
} from "./voice_state.mjs"
import {CallRecorder, recordingMayStart, supportedRecordingMimeType} from "./voice_recording.mjs"

const VoiceController = {
  mounted() {
    this.destroyedFlag = false
    this.localPhase = "idle"
    this.userMuted = false
    this.playbackBlocked = false
    this.peerReconnectTimer = null
    this.readinessTimer = null
    this.peer = null
    this.channel = null
    this.media = null
    this.recorder = null
    this.recordingMimeType = supportedRecordingMimeType()
    this.reportedClientEvents = new Set()

    this.remoteNoticeShown = false

    this.bindElements()
    this.bindEvents()
    this.readServerState()

    if (ACTIVE_SERVER_STATES.has(this.serverStatus)) {
      this.observeRemoteSession()
    } else {
      this.setStatus("VOICE READY", "idle")
      this.updateControls()
    }
  },

  updated() {
    this.bindElements()
    this.readServerState()

    // A LiveView patch re-renders the indicator as hidden; the recorder's last
    // reported state wins over the server's static markup.
    if (this.recordingState) this.reflectRecordingState(this.recordingState)

    if (this.localPhase === "idle" && ACTIVE_SERVER_STATES.has(this.serverStatus)) {
      this.observeRemoteSession()
      return
    }

    if (TERMINAL_SERVER_STATES.has(this.serverStatus)) {
      const status = this.serverStatus === "ended" ? this.endedStatusLabel() : "VOICE SESSION FAILED — START VOICE AGAIN"

      if (this.hasLocalSession()) {
        this.shutdownLocal(status, this.serverStatus)
        return
      }

      if (this.remoteNoticeShown) {
        this.remoteNoticeShown = false
        this.setStatus(status, this.serverStatus)
        this.updateControls()
        return
      }
    }

    if (this.serverStatus === "reconnecting" && this.hasLocalSession()) {
      this.applyMicrophoneState(false)
      this.setStatus("RECONNECTING VOICE — MICROPHONE PAUSED", "reconnecting")
    } else {
      this.maybeBecomeReady()
      this.reflectServerActivity()
      this.startRecording(this.remoteRecordingStream)
    }

    this.updateControls()
  },

  destroyed() {
    this.destroyedFlag = true
    this.removeWindowEvents()

    if (this.hasLocalSession()) {
      this.endServerSession({keepalive: true}).catch(() => {})
    }

    this.shutdownLocal(null, "idle")
  },

  bindElements() {
    this.statusElement = this.el.querySelector("#voice-status")
    this.indicator = this.el.querySelector("#voice-indicator")
    this.startButton = this.el.querySelector("#voice-start")
    this.muteButton = this.el.querySelector("#voice-mute")
    this.interruptButton = this.el.querySelector("#voice-interrupt")
    this.unlockButton = this.el.querySelector("#voice-unlock")
    this.endButton = this.el.querySelector("#voice-end")
    this.audio = this.el.querySelector("#voice-output")
    this.recordingIndicator = this.el.querySelector("#voice-recording-indicator")
  },

  bindEvents() {
    this.onStart = () => this.startVoice()
    this.onMute = () => this.toggleMute()
    this.onInterrupt = () => this.interruptSarah()
    this.onUnlock = () => this.unlockPlayback()
    this.onEnd = () => this.endVoice()
    this.onPageExit = () => this.pageExit()
    this.onOffline = () => this.failVoice("NETWORK OFFLINE — VOICE ENDED; TYPED CHAT REMAINS AVAILABLE")

    this.startButton.addEventListener("click", this.onStart)
    this.muteButton.addEventListener("click", this.onMute)
    this.interruptButton.addEventListener("click", this.onInterrupt)
    this.unlockButton.addEventListener("click", this.onUnlock)
    this.endButton.addEventListener("click", this.onEnd)
    window.addEventListener("pagehide", this.onPageExit)
    window.addEventListener("phx:disconnected", this.onPageExit)
    window.addEventListener("offline", this.onOffline)
  },

  removeWindowEvents() {
    window.removeEventListener("pagehide", this.onPageExit)
    window.removeEventListener("phx:disconnected", this.onPageExit)
    window.removeEventListener("offline", this.onOffline)
  },

  // A host-ended call must say why, never present as a silent disconnect.
  endedStatusLabel() {
    if (this.serverEndReason === "usage_budget_reached") {
      return "VOICE ENDED — SESSION BUDGET REACHED; START VOICE AGAIN OR CONTINUE IN TEXT"
    }
    if (this.serverEndReason === "session_timeout") {
      return "VOICE ENDED — SESSION TIME LIMIT REACHED; START VOICE AGAIN"
    }
    return "VOICE ENDED"
  },

  readServerState() {
    this.serverStatus = this.el.dataset.serverStatus || "idle"
    this.serverEndReason = this.el.dataset.serverEndReason || null
    this.serverGeneration = this.el.dataset.serverGeneration || null
    this.textTurnActive = this.el.dataset.textTurnActive === "true"
    this.recordingEnabled = this.el.dataset.recordingEnabled === "true"
    this.recordingTimesliceMs = Number(this.el.dataset.recordingTimesliceMs || 5000)
  },

  observeRemoteSession() {
    this.remoteNoticeShown = true
    this.setStatus("VOICE ACTIVE IN ANOTHER TAB — PRESS END VOICE TO STOP IT", "reconnecting")
    this.updateControls()
  },

  async startVoice() {
    if (this.hasLocalSession() || this.localPhase === "requesting" || this.textTurnActive) return

    if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia || !window.RTCPeerConnection) {
      this.localPhase = "failed"
      this.setStatus("VOICE NEEDS A SECURE, SUPPORTED BROWSER — USE TYPED CHAT", "failed")
      this.updateControls()
      return
    }

    this.localPhase = "requesting"
    this.reportedClientEvents.clear()
    this.userMuted = false
    this.playbackBlocked = false
    this.setStatus("REQUESTING MICROPHONE ACCESS", "requesting")
    this.updateControls()

    try {
      this.media = await navigator.mediaDevices.getUserMedia({
        audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true},
        video: false,
      })

      this.applyMicrophoneState(false)
      this.buildPeerConnection()
      this.setStatus("CONNECTING VOICE — MICROPHONE PAUSED", "connecting")

      const offer = await this.peer.createOffer()
      await this.peer.setLocalDescription(offer)

      const response = await fetch("/voice/calls", {
        method: "POST",
        headers: {
          "content-type": "application/sdp",
          "x-csrf-token": this.csrfToken(),
        },
        body: this.peer.localDescription.sdp,
      })

      if (!response.ok) {
        const payload = await response.json().catch(() => ({}))
        throw {kind: "admission", status: response.status, code: payload.error}
      }

      await this.peer.setRemoteDescription({type: "answer", sdp: await response.text()})
      this.localPhase = "connecting"
      this.readinessTimer = window.setTimeout(() => {
        this.failVoice("VOICE CONNECTION TIMED OUT — TRY AGAIN")
      }, 15_000)
      this.maybeBecomeReady()
    } catch (error) {
      const message =
        error?.kind === "admission"
          ? admissionErrorMessage(error.status, error.code)
          : microphoneErrorMessage(error)

      this.failVoice(message)
    }
  },

  buildPeerConnection() {
    this.peer = new RTCPeerConnection()
    this.channel = this.peer.createDataChannel("oai-events")

    for (const track of this.media.getTracks()) this.peer.addTrack(track, this.media)

    this.channel.addEventListener("open", () => this.maybeBecomeReady())
    this.channel.addEventListener("close", () => {
      if (this.localPhase === "ready") this.failVoice("VOICE CONTROL CHANNEL CLOSED — START AGAIN")
    })

    this.peer.addEventListener("track", event => {
      this.audio.srcObject = event.streams[0]
      this.reportClientEvent("first_remote_track", {once: true}).catch(() => {})
      this.tryPlayback()
      // Both sides of the call exist together only once Sarah's track arrives,
      // but the track can land before the server generation has reached the
      // DOM, so the stream is kept for `updated()` to retry against.
      this.remoteRecordingStream = event.streams[0]
      this.startRecording(this.remoteRecordingStream)
    })

    this.peer.addEventListener("connectionstatechange", () => this.peerStateChanged())
  },

  peerStateChanged() {
    if (!this.peer) return

    switch (this.peer.connectionState) {
      case "connected":
        this.clearPeerReconnectTimer()
        this.reportClientEvent("peer_connected").catch(() => {})
        this.maybeBecomeReady()
        break
      case "disconnected":
        this.reportClientEvent("peer_disconnected").catch(() => {})
        this.applyMicrophoneState(false)
        this.setStatus("RECONNECTING VOICE — MICROPHONE PAUSED", "reconnecting")
        this.clearPeerReconnectTimer()
        this.peerReconnectTimer = window.setTimeout(() => {
          this.failVoice("VOICE CONNECTION LOST — START AGAIN")
        }, 5_000)
        break
      case "failed":
        this.failVoice("VOICE CONNECTION LOST — START AGAIN")
        break
      default:
        break
    }
  },

  maybeBecomeReady() {
    if (!this.peer || !this.channel) return

    const ready = microphoneMayTransmit({
      localPhase: "ready",
      serverStatus: this.serverStatus,
      peerConnectionState: this.peer.connectionState,
      channelState: this.channel.readyState,
      userMuted: false,
      playbackBlocked: this.playbackBlocked,
    })

    if (!ready) return

    this.clearReadinessTimer()
    this.localPhase = "ready"
    this.applyMicrophoneState(!this.userMuted)
    this.reflectServerActivity()
    this.updateControls()
  },

  reflectServerActivity() {
    if (this.localPhase !== "ready") return

    if (this.userMuted) {
      this.setStatus("MICROPHONE MUTED", "muted")
    } else if (this.serverStatus === "responding") {
      this.setStatus("SARAH SPEAKING — SPEAK OR PRESS INTERRUPT", "speaking")
    } else if (this.serverStatus === "interrupted") {
      this.setStatus("INTERRUPTING SARAH", "interrupted")
    } else {
      this.setStatus("LISTENING", "listening")
    }
  },

  async tryPlayback() {
    try {
      await this.audio.play()
      this.playbackBlocked = false
      this.reportClientEvent("playback_started", {once: true}).catch(() => {})
      this.maybeBecomeReady()
    } catch (_error) {
      this.playbackBlocked = true
      this.applyMicrophoneState(false)
      this.setStatus("AUDIO PLAYBACK BLOCKED — ENABLE AUDIO TO CONTINUE", "blocked")
      this.updateControls()
    }
  },

  async unlockPlayback() {
    try {
      await this.audio.play()
      this.playbackBlocked = false
      this.maybeBecomeReady()
    } catch (_error) {
      this.setStatus("AUDIO IS STILL BLOCKED — CHECK BROWSER SOUND PERMISSIONS", "failed")
    }

    this.updateControls()
  },

  toggleMute() {
    if (!this.hasLocalSession()) return
    this.userMuted = !this.userMuted
    this.applyMicrophoneState(this.localPhase === "ready" && !this.userMuted)
    this.reflectServerActivity()
    this.updateControls()
  },

  async interruptSarah() {
    if (this.serverStatus !== "responding" || !this.hasLocalSession()) return

    this.interruptButton.disabled = true
    this.setStatus("INTERRUPTING SARAH", "interrupted")

    try {
      const response = await fetch("/voice/calls/interrupt", {
        method: "POST",
        headers: {"x-csrf-token": this.csrfToken()},
      })

      if (!response.ok) throw new Error("interrupt failed")
      this.reportClientEvent("interrupt_acknowledged").catch(() => {})
    } catch (_error) {
      this.setStatus("SARAH COULD NOT BE INTERRUPTED — END VOICE IF NEEDED", "failed")
    }

    this.updateControls()
  },

  async endVoice() {
    if (!this.hasLocalSession() && !ACTIVE_SERVER_STATES.has(this.serverStatus)) return

    this.remoteNoticeShown = false
    this.localPhase = "ending"
    this.applyMicrophoneState(false)
    this.setStatus("ENDING VOICE", "ending")
    this.updateControls()

    try {
      await this.reportClientEvent("client_ended")
      await this.endServerSession()
      this.serverStatus = "ended"
      this.shutdownLocal("VOICE ENDED", "ended")
    } catch (_error) {
      this.shutdownLocal("VOICE ENDED LOCALLY — SERVER CONFIRMATION UNAVAILABLE", "failed")
    }
  },

  pageExit() {
    if (!this.hasLocalSession()) return
    this.applyMicrophoneState(false)
    this.endServerSession({keepalive: true}).catch(() => {})
    this.shutdownLocal(null, "idle")
  },

  failVoice(message) {
    if (this.localPhase === "ending" || this.localPhase === "failed") return

    const shouldNotify = this.hasLocalSession()
    if (shouldNotify) {
      this.reportClientEvent("client_failed", {keepalive: true}).catch(() => {})
      this.endServerSession({keepalive: true}).catch(() => {})
    }
    this.shutdownLocal(message, "failed")
  },

  async endServerSession({keepalive = false} = {}) {
    const response = await fetch("/voice/calls", {
      method: "DELETE",
      headers: {"x-csrf-token": this.csrfToken()},
      keepalive,
    })

    if (!response.ok) throw new Error("voice end failed")
  },

  // Recording is disclosed before the microphone opens and is never allowed to
  // affect the call: an unsupported browser, a blocked AudioContext, or a refused
  // upload all end in an unrecorded conversation rather than a failed one.
  startRecording(remoteStream) {
    const mayStart = recordingMayStart({
      enabled: this.recordingEnabled,
      mimeType: this.recordingMimeType,
      hasMicrophone: Boolean(this.media),
      hasRemoteStream: Boolean(remoteStream),
      generation: this.serverGeneration,
      alreadyStarted: Boolean(this.recorder),
    })

    if (!mayStart) return

    this.recorder = new CallRecorder({
      microphone: this.media,
      remoteStream,
      generation: this.serverGeneration,
      timesliceMs: this.recordingTimesliceMs,
      mimeType: this.recordingMimeType,
      upload: options => this.uploadRecordingChunk(options),
      finalize: options => this.finalizeRecording(options),
      onStateChange: state => this.reflectRecordingState(state),
    })

    this.recorder.start()
  },

  async uploadRecordingChunk({blob, sequence, generation, mimeType}) {
    const response = await fetch("/voice/calls/recording", {
      method: "POST",
      headers: {
        "content-type": mimeType,
        "x-csrf-token": this.csrfToken(),
        "x-voice-generation": String(generation),
        "x-voice-recording-sequence": String(sequence),
      },
      body: blob,
    })

    if (!response.ok) throw new Error(`recording chunk refused: ${response.status}`)
  },

  async finalizeRecording({status, generation, durationMs}) {
    await fetch("/voice/calls/recording/complete", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": this.csrfToken(),
        "x-voice-generation": String(generation),
      },
      body: JSON.stringify({status, duration_ms: durationMs}),
      keepalive: true,
    })
  },

  stopRecording(status) {
    if (!this.recorder) return

    const recorder = this.recorder
    this.recorder = null
    recorder.stop({status}).catch(() => {})
  },

  reflectRecordingState(state) {
    this.recordingState = state
    this.el.dataset.recordingState = state
    if (this.recordingIndicator) this.recordingIndicator.hidden = state !== "recording"
  },

  async reportClientEvent(kind, {once = false, keepalive = false} = {}) {
    if (!ACTIVE_SERVER_STATES.has(this.serverStatus) && !this.hasLocalSession()) return
    if (once && this.reportedClientEvents.has(kind)) return
    if (once) this.reportedClientEvents.add(kind)

    const response = await fetch("/voice/telemetry", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": this.csrfToken(),
      },
      body: JSON.stringify({kind}),
      keepalive,
    })

    if (!response.ok && response.status !== 429) throw new Error("voice telemetry failed")
  },

  shutdownLocal(message, state) {
    this.clearReadinessTimer()
    this.clearPeerReconnectTimer()

    // Stopped before the tracks are torn out from under it, so the tail slice and
    // the finalize both leave with keepalive on the way out.
    this.stopRecording(state === "failed" ? "failed" : "complete")

    closeVoiceResources({
      channel: this.channel,
      peer: this.peer,
      media: this.media,
      audio: this.audio,
    })

    this.channel = null
    this.peer = null
    this.media = null
    this.remoteRecordingStream = null
    this.userMuted = false
    this.playbackBlocked = false
    this.localPhase = state === "failed" ? "failed" : "idle"

    if (message && !this.destroyedFlag) this.setStatus(message, state)
    if (!this.destroyedFlag) this.updateControls()
  },

  applyMicrophoneState(enabled) {
    if (!this.media) return

    const mayTransmit =
      enabled &&
      microphoneMayTransmit({
        localPhase: this.localPhase,
        serverStatus: this.serverStatus,
        peerConnectionState: this.peer?.connectionState,
        channelState: this.channel?.readyState,
        userMuted: this.userMuted,
        playbackBlocked: this.playbackBlocked,
      })

    for (const track of this.media.getAudioTracks()) track.enabled = mayTransmit
  },

  updateControls() {
    if (!this.startButton) return

    const localSession = this.hasLocalSession()
    const serverSession = ACTIVE_SERVER_STATES.has(this.serverStatus)
    const busy = ["requesting", "connecting", "ending"].includes(this.localPhase)

    this.startButton.hidden = localSession || serverSession || busy
    this.startButton.disabled = this.textTurnActive || busy
    this.muteButton.hidden = !localSession
    this.muteButton.disabled =
      this.localPhase !== "ready" ||
      this.playbackBlocked ||
      !READY_SERVER_STATES.has(this.serverStatus)
    this.muteButton.setAttribute(
      "aria-label",
      this.userMuted ? "Unmute microphone" : "Mute microphone"
    )
    this.muteButton.setAttribute("aria-pressed", String(this.userMuted))
    this.muteButton.toggleAttribute("data-muted", this.userMuted)
    this.interruptButton.hidden = !localSession
    this.interruptButton.disabled = this.serverStatus !== "responding"
    this.unlockButton.hidden = !this.playbackBlocked
    this.endButton.hidden = !localSession && !serverSession
    this.endButton.disabled = this.localPhase === "ending"
  },

  setStatus(message, state) {
    if (this.statusElement && this.statusElement.textContent !== message) {
      this.statusElement.textContent = message
    }
    if (this.indicator) this.indicator.dataset.state = state
    this.el.dataset.clientState = state
  },

  hasLocalSession() {
    return Boolean(this.peer || this.media || this.channel)
  },

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']").content
  },

  clearReadinessTimer() {
    if (this.readinessTimer) window.clearTimeout(this.readinessTimer)
    this.readinessTimer = null
  },

  clearPeerReconnectTimer() {
    if (this.peerReconnectTimer) window.clearTimeout(this.peerReconnectTimer)
    this.peerReconnectTimer = null
  },
}

export default VoiceController
