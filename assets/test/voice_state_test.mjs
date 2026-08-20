import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

import {
  ACTIVE_SERVER_STATES,
  admissionErrorMessage,
  closeVoiceResources,
  microphoneErrorMessage,
  microphoneMayTransmit,
} from "../js/voice_state.mjs"

test("the browser admission request does not negotiate through Phoenix's HTML accept gate", () => {
  const source = readFileSync(new URL("../js/voice_controller.js", import.meta.url), "utf8")

  assert.doesNotMatch(source, /["']accept["']\s*:\s*["']application\/sdp["']/)
  assert.match(source, /["']content-type["']\s*:\s*["']application\/sdp["']/)
})

test("microphone transmits only after browser and fenced server readiness", () => {
  const ready = {
    localPhase: "ready",
    serverStatus: "listening",
    peerConnectionState: "connected",
    channelState: "open",
    userMuted: false,
    playbackBlocked: false,
  }

  assert.equal(microphoneMayTransmit(ready), true)

  for (const unsafe of [
    {...ready, serverStatus: "connecting"},
    {...ready, serverStatus: "reconnecting"},
    {...ready, peerConnectionState: "disconnected"},
    {...ready, channelState: "closed"},
    {...ready, userMuted: true},
    {...ready, playbackBlocked: true},
  ]) {
    assert.equal(microphoneMayTransmit(unsafe), false)
  }

  assert.equal(ACTIVE_SERVER_STATES.has("reconnecting"), true)
  assert.equal(ACTIVE_SERVER_STATES.has("ended"), false)
})

test("permission, device, rate, and text conflict failures stay actionable", () => {
  assert.match(microphoneErrorMessage({name: "NotAllowedError"}), /ACCESS DENIED/)
  assert.match(microphoneErrorMessage({name: "NotFoundError"}), /NO MICROPHONE/)
  assert.match(admissionErrorMessage(429, "voice_rate_limited"), /WAIT A MINUTE/)
  assert.match(admissionErrorMessage(409, "text_turn_in_progress"), /TEXT RESPONSE/)
  assert.match(admissionErrorMessage(503, "voice_unavailable"), /TYPED CHAT/)
})

test("cleanup closes every media resource and detaches remote audio", () => {
  const calls = []
  const channel = {close: () => calls.push("channel")}
  const peer = {close: () => calls.push("peer")}
  const media = {
    getTracks: () => [
      {stop: () => calls.push("track-one")},
      {stop: () => calls.push("track-two")},
    ],
  }
  const audio = {srcObject: {id: "remote-stream"}}

  closeVoiceResources({channel, peer, media, audio})

  assert.deepEqual(calls, ["channel", "peer", "track-one", "track-two"])
  assert.equal(audio.srcObject, null)
})
