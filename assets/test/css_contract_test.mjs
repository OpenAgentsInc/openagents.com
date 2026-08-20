import assert from "node:assert/strict"
import {execFileSync} from "node:child_process"
import {readFileSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {resolve} from "node:path"
import test from "node:test"
import {fileURLToPath} from "node:url"

const assetsDir = resolve(fileURLToPath(new URL("..", import.meta.url)))
const projectDir = resolve(assetsDir, "..")

test("the compiled cascade preserves every governed button variant", () => {
  const output = resolve(tmpdir(), `openagents-css-contract-${process.pid}.css`)

  try {
    execFileSync(
      "mix",
      ["tailwind", "openagents", "--minify", `--output=${output}`],
      {cwd: projectDir, encoding: "utf8", stdio: "pipe"},
    )

    const css = readFileSync(output, "utf8")
    const basecoatGeometry = css.indexOf(".btn{")
    const governedBase = css.indexOf("border-radius:var(--radius-md)")
    const variants = [
      "primary",
      "secondary",
      "outline",
      "ghost",
      "chip",
      "destructive",
      "notched",
      "link",
    ]

    assert.ok(basecoatGeometry >= 0, "compiled CSS is missing Basecoat button geometry")
    assert.ok(governedBase > basecoatGeometry, "the OpenAgents style pack must follow Basecoat")

    for (const variant of variants) {
      const selector = `.btn[data-variant=${variant}]`
      assert.ok(css.indexOf(selector) > governedBase, `${selector} must follow the shared button rule`)
    }

    assert.doesNotMatch(css, /\.btn-(primary|secondary|ghost|error|success|warning|info)\b/)
    assert.doesNotMatch(css, /--color-base-(100|200|300|content)\b/)
    assert.doesNotMatch(css, /data-theme|prefers-color-scheme/)
  } finally {
    rmSync(output, {force: true})
  }
})

test("the source imports only the owned component stack", () => {
  const source = readFileSync(resolve(assetsDir, "css/app.css"), "utf8")
  const stylePack = source.indexOf('@import "./openagents.css"')

  assert.ok(stylePack >= 0)
  assert.ok(source.indexOf("components/button.css") < stylePack)
  assert.doesNotMatch(source, /@import[^;]*(basecoat\.css|basecoat-base\.css|basecoat-components\.css)/)
  assert.doesNotMatch(source, /basecoat.*\.js|initAll|MutationObserver/)
})
