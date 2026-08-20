defmodule OpenAgentsWeb.VoiceSpikeLive do
  @moduledoc false

  use OpenAgentsWeb, :openagents_live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Sarah Voice Transport Spike")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="voice-spike" class="app-shell">
        <header class="command-bar">
          <div class="brand-lockup"><span class="brand-name">SARAH / VOICE SPIKE</span></div>
        </header>
        <section
          id="voice-spike-controller"
          phx-hook=".VoiceSpike"
          phx-update="ignore"
          class="transcript"
        >
          <p id="voice-spike-status" role="status" aria-live="polite">IDLE</p>
          <button id="voice-spike-start" type="button" class="send-action">START SPIKE</button>
          <button id="voice-spike-end" type="button" class="text-action" disabled>END</button>
          <pre id="voice-spike-events" aria-label="Provider event summary"></pre>
        </section>
      </main>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".VoiceSpike">
        export default {
          mounted() {
            this.status = this.el.querySelector("#voice-spike-status")
            this.events = this.el.querySelector("#voice-spike-events")
            this.start = this.el.querySelector("#voice-spike-start")
            this.end = this.el.querySelector("#voice-spike-end")
            this.start.addEventListener("click", () => this.connect())
            this.end.addEventListener("click", () => this.endCall())
          },
          destroyed() { this.disconnect("ENDED") },
          async connect() {
            if (this.peer) return
            this.start.disabled = true
            this.setStatus("REQUESTING MICROPHONE")
            try {
              this.media = await navigator.mediaDevices.getUserMedia({audio: true})
              this.peer = new RTCPeerConnection()
              this.audio = document.createElement("audio")
              this.audio.autoplay = true
              this.peer.ontrack = event => { this.audio.srcObject = event.streams[0] }
              this.media.getTracks().forEach(track => this.peer.addTrack(track, this.media))
              this.channel = this.peer.createDataChannel("oai-events")
              this.channel.addEventListener("message", event => this.recordEvent(event.data))
              this.channel.addEventListener("open", () => this.setStatus("CONNECTED"))
              this.setStatus("CREATING OFFER")
              const offer = await this.peer.createOffer()
              await this.peer.setLocalDescription(offer)
              const csrf = document.querySelector("meta[name='csrf-token']").content
              const response = await fetch("/voice/calls", {
                method: "POST",
                headers: {"content-type": "application/sdp", "x-csrf-token": csrf},
                body: this.peer.localDescription.sdp
              })
              if (!response.ok) throw new Error(`call admission ${response.status}`)
              await this.peer.setRemoteDescription({type: "answer", sdp: await response.text()})
              this.end.disabled = false
            } catch (error) {
              this.events.textContent = error instanceof Error ? error.message : "connection failed"
              this.disconnect("FAILED")
            }
          },
          recordEvent(raw) {
            try {
              const event = JSON.parse(raw)
              this.events.textContent = `${event.type || "unknown"}\n${this.events.textContent}`.slice(0, 2000)
            } catch (_error) {
              this.events.textContent = "invalid provider event"
            }
          },
          async endCall() {
            const csrf = document.querySelector("meta[name='csrf-token']").content
            try {
              await fetch("/voice/calls", {
                method: "DELETE",
                headers: {"x-csrf-token": csrf}
              })
            } finally {
              this.disconnect("ENDED")
            }
          },
          disconnect(status) {
            if (this.channel) this.channel.close()
            if (this.peer) this.peer.close()
            if (this.media) this.media.getTracks().forEach(track => track.stop())
            if (this.audio) this.audio.srcObject = null
            this.channel = null
            this.peer = null
            this.media = null
            this.audio = null
            if (this.status) this.setStatus(status)
            if (this.start) this.start.disabled = false
            if (this.end) this.end.disabled = true
          },
          setStatus(status) { this.status.textContent = status }
        }
      </script>
    </Layouts.app>
    """
  end
end
