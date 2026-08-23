// The rule this pins is a client rule, and it is the rule the docs and
// component-library sidebars used to break: what the reader collapsed wins,
// and the hook never records a choice on the reader's behalf. The server sends
// the same answer -- see `OpenAgentsWeb.SidebarStateTest` -- but only the
// browser decides what happens after a LiveView update repaints the seed.
import assert from "node:assert/strict"
import {execFileSync} from "node:child_process"
import {readdirSync, readFileSync} from "node:fs"
import {resolve} from "node:path"
import test from "node:test"
import {fileURLToPath} from "node:url"

const assetsDir = resolve(fileURLToPath(new URL("..", import.meta.url)))
const projectDir = resolve(assetsDir, "..")
const mixEnv = process.env.MIX_ENV ?? "test"

// The hook is colocated in `layouts.ex`, so the file to load is the one the
// compiler extracts. Compile first if this clone has not been built yet.
const hookPath = () => {
  const directory = resolve(
    projectDir,
    `_build/${mixEnv}/phoenix-colocated/openagents/OpenAgentsWeb.Layouts`,
  )

  const found = readdirSync(directory)
    .filter(entry => entry.endsWith(".js"))
    .map(entry => resolve(directory, entry))
    .find(path => readFileSync(path, "utf8").includes("sidebar_sections"))

  assert.ok(found, "no colocated hook in layouts.ex maintains sidebar_sections")
  return found
}

const loadHook = async () => {
  try {
    return (await import(hookPath())).default
  } catch (_missingBuild) {
    execFileSync("mix", ["compile"], {
      cwd: projectDir,
      encoding: "utf8",
      env: {...process.env, MIX_ENV: mixEnv},
      stdio: "pipe",
    })
    return (await import(hookPath())).default
  }
}

// Enough of a document for a hook that reads and writes one cookie.
const stubDocument = jar => {
  globalThis.document = {
    get cookie() {
      return Object.entries(jar)
        .map(([key, value]) => `${key}=${value}`)
        .join("; ")
    },
    set cookie(assignment) {
      const [pair] = assignment.split("; ")
      const separator = pair.indexOf("=")
      jar[pair.slice(0, separator)] = pair.slice(separator + 1)
    },
  }
}

const cookieValue = sections => encodeURIComponent(JSON.stringify(sections))

// A `<details>` with a summary and, optionally, the row marking the page the
// reader is on.
const stubSection = ({id, open, active}) => {
  const listeners = {}

  return {
    id,
    open,
    dataset: {},
    addEventListener: (name, handler) => (listeners[name] = handler),
    removeEventListener: name => delete listeners[name],
    querySelector: selector => {
      if (selector === "summary") return {addEventListener() {}, removeEventListener() {}}
      if (selector === "[aria-current]") return active ? {} : null
      return null
    },
    toggle(next) {
      this.open = next
      listeners.toggle?.()
    },
  }
}

const mount = async element => {
  const hook = await loadHook()
  const instance = Object.create(hook)
  instance.el = element
  instance.mounted()
  return instance
}

test("a collapsed section the reader is reading stays collapsed", async () => {
  const jar = {sidebar_sections: cookieValue({"sidebar-section-getting-started": false})}
  stubDocument(jar)

  // Painted open, as a LiveView update repainting the seed would leave it.
  const element = stubSection({id: "sidebar-section-getting-started", open: true, active: true})
  await mount(element)

  assert.equal(element.open, false)
  assert.deepEqual(JSON.parse(decodeURIComponent(jar.sidebar_sections)), {
    "sidebar-section-getting-started": false,
  })
})

test("the seed governs a section the reader has said nothing about", async () => {
  const jar = {}
  stubDocument(jar)

  const element = stubSection({id: "sidebar-section-issues", open: true, active: true})
  await mount(element)

  assert.equal(element.open, true)
  // Silence stays silence: an unwritten cookie is what lets the seed keep
  // deciding, including the seed that opens the section holding the page.
  assert.deepEqual(jar, {})
})

test("turning a caret records the reader's choice", async () => {
  const jar = {}
  stubDocument(jar)

  const element = stubSection({id: "sidebar-section-reference", open: true, active: false})
  await mount(element)
  element.toggle(false)

  assert.deepEqual(JSON.parse(decodeURIComponent(jar.sidebar_sections)), {
    "sidebar-section-reference": false,
  })
})
