import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"

test("destroyed() invokes the same resource cleanup as closeVoiceResources", () => {
  const source = readFileSync(new URL("../js/voice_controller.js", import.meta.url), "utf8")

  assert.match(source, /this\.shutdownLocal\(null,\s*["']idle["']\)/)
  assert.match(
    source,
    /closeVoiceResources\(\{\s*channel:\s*this\.channel,\s*peer:\s*this\.peer,\s*media:\s*this\.media,\s*audio:\s*this\.audio,?\s*\}\)/,
  )
})
