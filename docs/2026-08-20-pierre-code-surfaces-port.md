# Porting Pierre's code surfaces

*2026-08-20*

This doc explains what Pierre's libraries are, which parts are worth adapting
into `OpenAgentsWeb.UI`, which parts are deliberately not, and what still needs
doing. **The work list at the bottom is the tracker for this effort** — update
it in the same change that lands the work, not afterwards.

## What Pierre is

[`pierrecomputer/pierre`][pierre] is the open-source part of Pierre's stack.
Code.Storage, their product, stays proprietary; what is published are the UI
libraries behind it, under **Apache 2.0**. Read at `ba7d51d2` (2026-08-19),
synced through `~/work/projects/manifest.txt` to
`~/work/projects/repos/pierre`.

The packages that matter to us:

| Package | npm | What it is |
| --- | --- | --- |
| `packages/diffs` | `@pierre/diffs` 1.3.5 | `CodeView`, `FileDiff`, `File`, and virtualized variants |
| `packages/trees` | `@pierre/trees` 1.0.0-beta.6 | `FileTree`, a path-first file tree |
| `packages/theme` | `@pierre/theme` 2.0.0 | Pierre's colour themes, including Shiki grammars |

The components, in their own words:

- **`CodeView`** is the multi-file scroller: one viewport holding mixed file and
  diff items, sticky headers, virtualization, line selection, optional edit
  mode.
- **`FileDiff`** is a single file's split or stacked diff, with Shiki
  highlighting, annotations, and accept/reject hunks.
- **`File`** is a non-diff code view of one blob.
- **`FileTree`** is the sidebar tree, not a blob viewer.

## What "porting" means here

Almost none of the code survives. `packages/diffs/src/components` alone is
**14,627 lines of TypeScript**, and it is React and vanilla TS built on Shiki, a
streaming worker, and a virtualizer. What we take is the **model and the layout
decisions**: how a diff is decomposed into files, hunks, and lines carrying two
line numbers; what a file header holds; how a multi-file view keeps its place.
Those are the expensive parts to get right and they transfer intact.

Apache 2.0 requires the copyright notice be retained where code is used. Since
this is adaptation rather than copying, attribution lives in the moduledoc of
each ported component and here.

Two standing decisions, the same ones taken for the Launch UI adaptation:

- **Our tokens, not their theme.** Pierre ships its own palette and Shiki
  themes. Adopting them would put a second colour system beside the one every
  other surface uses. Every ported value resolves to an existing token.
- **No JavaScript where the server can do it.** These surfaces render from data
  we already have on the server. A diff is decomposed in Elixir and rendered as
  HTML; collapsing uses native `<details>`.

## Where we are starting from

The data layer mostly exists. The presentation does not.

| Surface | Today |
| --- | --- |
| Commit (`/OpenAgentsInc/:repo/commit/:sha`) | The whole unified diff in one `<pre>`. No per-file split, no hunk headers, no add/remove colour, no line numbers. |
| Blob (`/OpenAgentsInc/:repo/blob/:ref/*path`) | File contents in one `<pre><code>`. No line numbers, no line anchors, no highlighting. |
| Repo (`/OpenAgentsInc/:repo`) | Commit list. No file tree, although `Browse.tree/3` already returns `[%{name, kind, size}]`. |
| Compare / pull request | Does not exist. |

`OpenAgents.Forge.Browse` already provides what the first items need:
`diff/2` shells `git diff-tree -p -M --no-color` and caps the output, and
`tree/3` lists a directory at a ref.

## What we are not porting

Stated so nobody re-litigates it later:

- **The virtualizer.** `Virtualizer` (722 lines), `VirtualizedFile` (1,156),
  and `VirtualizedFileDiff` (2,182) are about four thousand lines solving a
  problem we solve server-side by bounding the diff before it is rendered.
- **Edit mode and the editor.** We are building a code *host*, not an editor.
- **`shiki-stream` and the highlighting worker.** Highlighting belongs on the
  server here; see the open decision below.
- **`packages/theme`.** We have a token ladder.
- **`packages/path-store` and `packages/pipes`.** A tree data store we do not
  need, and an unrelated 3D demo.

## Open decision: syntax highlighting

Highlighting is the one item that needs a dependency. `mdex`, already a
dependency, supports server-side highlighting but requires `{:lumis, "~> 0.1"}`
and raises a clear error naming it when absent. That would give highlighted
diffs and blobs with no JavaScript and no Shiki.

Not yet taken. Diff and blob rendering ship unhighlighted first, because the
structure is worth far more than the colour and it is a smaller change to add
highlighting to a correct structure than the reverse.

## Work list

Status is one of **done**, **next**, or **planned**.

### 1. `diff_file/1` — a single file's diff — **done**

Adapted from `FileDiff`. Landed as two pieces:

- `OpenAgents.Diff` parses a unified diff into files, hunks, and lines, each
  line carrying its number on **both** sides. That pairing is the whole reason
  to parse rather than print: the two sides stop agreeing at the first change,
  and a `<pre>` can never say where a line went.
- `OpenAgentsWeb.UI.diff_file/1` renders one file: header with status and
  counts, hunk headers including git's enclosing-function hint, held-back
  add/remove tints, and a link on every new-side line number. Catalogued at
  `/components/openagents-diff-file`.

The commit page uses it in place of the raw `<pre>`, with a totals line
counted from the parsed lines so it describes the diff actually shown even
when the input was truncated. If the parser returns nothing — a shape it has
not seen — the page falls back to the raw text rather than showing a reader
nothing.

Decisions worth keeping:

- **Unified, not split.** A split view needs roughly twice the width to say
  the same thing and collapses badly on a narrow screen. The two number
  gutters carry what split is for.
- **Colour is never the only signal.** The marker column says `+` and `-`, so
  the diff survives greyscale and a reader who cannot separate the tints.
- **Tolerant parsing.** A diff describes somebody else's repository and
  arrives truncated by our own cap. Unrecognised lines become `:meta` and
  render as themselves; nothing raises.

Validated against `git diff-tree --numstat` on real commits — file counts and
both line totals match exactly — plus sixteen unit tests covering renames,
binaries, mid-hunk truncation, missing hunk counts, and quoted paths.

### 2. `code_file/1` — one blob, numbered and addressable — **next**

Adapted from `File`. Line numbers, line anchors and ranges (`#L12`,
`#L12-L20`), a sticky filename header, copy and raw actions. Replaces the
blob page's bare `<pre><code>`.

The line-anchor model is the valuable part: a line number that is a link, and a
range that survives being pasted into an issue.

### 3. `file_tree/1` — the repository sidebar — **planned**

Adapted from `@pierre/trees`. Path-first: the tree is built from a list of
paths rather than from nested directory objects, which is what makes it cheap
to render a subtree at a ref. `Browse.tree/3` already supplies the data, and
native `<details>` gives collapsing without script.

### 4. `diff_list/1` — many files in one view — **planned**

Adapted from `CodeView`, minus virtualization. Composes `diff_file/1` items
with sticky per-file headers and a "files changed, +N −M" summary bar. This is
the compare and pull-request surface, and it is mostly composition once item 1
exists.

[pierre]: https://github.com/pierrecomputer/pierre
