export const ACTIVE_SERVER_STATES = new Set([
  "connecting",
  "listening",
  "responding",
  "interrupted",
  "reconnecting",
])

export const READY_SERVER_STATES = new Set(["listening", "responding", "interrupted"])
export const TERMINAL_SERVER_STATES = new Set(["ended", "failed"])

export const microphoneErrorMessage = error => {
  switch (error?.name) {
    case "NotAllowedError":
    case "SecurityError":
      return "MICROPHONE ACCESS DENIED — ALLOW ACCESS AND TRY AGAIN"
    case "NotFoundError":
    case "DevicesNotFoundError":
      return "NO MICROPHONE FOUND — CONNECT A DEVICE AND TRY AGAIN"
    case "NotReadableError":
    case "TrackStartError":
      return "MICROPHONE UNAVAILABLE — CLOSE OTHER AUDIO APPS AND TRY AGAIN"
    case "AbortError":
      return "MICROPHONE START WAS INTERRUPTED — TRY AGAIN"
    default:
      return "VOICE COULD NOT START — TYPED CHAT IS STILL AVAILABLE"
  }
}

export const admissionErrorMessage = (status, code) => {
  if (status === 409 && code === "text_turn_in_progress") {
    return "WAIT FOR THE CURRENT TEXT RESPONSE BEFORE STARTING VOICE"
  }

  if (status === 409) return "ANOTHER VOICE SESSION IS ACTIVE — END IT AND TRY AGAIN"
  if (status === 429) return "VOICE START LIMIT REACHED — WAIT A MINUTE AND TRY AGAIN"
  if (status === 503) return "VOICE IS TEMPORARILY UNAVAILABLE — USE TYPED CHAT"
  if (status === 502) return "THE VOICE PROVIDER DID NOT CONNECT — TRY AGAIN"
  return "VOICE CONNECTION FAILED — TYPED CHAT IS STILL AVAILABLE"
}

export const microphoneMayTransmit = ({
  localPhase,
  serverStatus,
  peerConnectionState,
  channelState,
  userMuted,
  playbackBlocked,
}) => {
  return (
    localPhase === "ready" &&
    READY_SERVER_STATES.has(serverStatus) &&
    peerConnectionState === "connected" &&
    channelState === "open" &&
    !userMuted &&
    !playbackBlocked
  )
}

export const closeVoiceResources = ({channel, peer, media, audio}) => {
  if (channel) channel.close()
  if (peer) peer.close()
  if (media) {
    for (const track of media.getTracks()) track.stop()
  }
  if (audio) audio.srcObject = null
}
