import CoderCopy from "./coder_copy"
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/openagents"
import topbar from "../vendor/topbar"
import posthog from "posthog-js"
import VoiceController from "./voice_controller"
import PacedTranscript from "./paced_transcript"
import DocsSidebar from "./docs_sidebar"

// Browser analytics (docs/2026-08-21-posthog-integration-runbook.md). The
// root layout carries the boot configuration and the session identity as data
// attributes; when capture is unconfigured nothing initializes and no request
// to PostHog is made.
const initAnalytics = () => {
  const attributes = document.body?.dataset
  if (!attributes || attributes.posthogEnabled !== "true") return
  if (!attributes.posthogToken) return

  posthog.init(attributes.posthogToken, {
    api_host: attributes.posthogApiHost || "https://us.i.posthog.com",
    defaults: "2026-05-30",
    autocapture: true,
    // Pageviews are captured explicitly: once for the initial load here, then
    // one per LiveView navigation. Automatic history tracking would double
    // count against the phx:navigate listener.
    capture_pageview: false,
    // Error tracking and session replay are separate, unapproved decisions.
    capture_exceptions: false,
    disable_session_recording: true,
    // Lets server-side events link back to the browser session. Hostname only.
    tracing_headers: [window.location.hostname],
  })

  posthog.capture("$pageview", { $current_url: window.location.href })

  window.addEventListener("phx:navigate", ({ detail: { href } }) => {
    posthog.capture("$pageview", { $current_url: href })
  })

  const distinctId = attributes.posthogDistinctId
  if (distinctId && !sessionStorage.getItem("posthog:identified")) {
    posthog.identify(distinctId, {
      github_login: attributes.posthogLogin || undefined,
    })
    sessionStorage.setItem("posthog:identified", "true")
  }
}

initAnalytics()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, VoiceController, PacedTranscript, DocsSidebar, CoderCopy},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
