# Gemini CLI tool definition audit

**Date:** 2026-08-23  
**Status:** Audit. No code changes.  
**OpenAgents commit measured:** `9f5bf06` (`openagents/main`).  
**Gemini CLI commit measured:** `5411f113c` (`main`, from `google-gemini/gemini-cli`).  
**Question:** How does the `openagents.com` documentation define the `openagents coder` tools, and how does the Gemini CLI define equivalent tools like `read_file`, `write_file`, and `run_shell_command`?  
**Method:** Direct reading of `docs/2026-08-23-openagents-coder-cli-spec.md` in this repository; direct reading of the Gemini CLI files `packages/core/src/tools/definitions/*`, `packages/core/src/tools/*.ts`, and `packages/core/src/tools/tool-registry.ts`.

---

## 0. Summary

The two definitions live at opposite ends of the same spectrum. The OpenAgents docs describe a *prescriptive contract*: six runtime tools, an ACP kind per tool, and an approval ladder. The Gemini CLI provides a *running reference implementation*: 20+ built-in tools, JSON schemas for every tool, model-family variants, and a complete execution lifecycle.

The central difference is the boundary between the model-facing definition and the runtime behavior.

1. **OpenAgents keeps the contract short.** The `openagents coder` spec records six local tools, each with an ACP kind, a bound, and a place on the approval ladder. The actual implementation is in the separate `probe` repository.
2. **Gemini co-locates schema, validation, execution, and telemetry.** A tool is a `BaseDeclarativeTool` class that owns the `FunctionDeclaration` sent to the model, validates the untrusted parameters it gets back, and runs the operation through a `ToolInvocation`.
3. **Gemini treats the model declaration as a variable artifact.** `coreTools.ts` and `definitions/resolver.ts` select a `FunctionDeclaration` per model family, with base and override declarations.
4. **Both agree on the safety primitives** (workspace confinement, approval gates, output caps), but Gemini encodes them in code as well as in the schema: `resolveDefensiveToolPath`, `validatePathAccess`, the `confirmation-bus/message-bus`, and `ToolErrorType`.

The recommendation for OpenAgents is not to copy the Gemini surface, but to adopt four of its structural choices: per-model `FunctionDeclaration` resolution, a declarative `Tool`/`Invocation` split, an explicit `ToolError` taxonomy, and a registry that can deactivate tools per session.

---

## 1. How OpenAgents docs define tools

The only tool definitions inside the `openagents.com` repository are in `docs/2026-08-23-openagents-coder-cli-spec.md`. The document is a specification, not a runtime; it delegates implementation to the `probe` repository.

### 1.1 The six local tools

`2026-08-23-openagents-coder-cli-spec.md` section 7.1 lists the tools that execute in the runtime process:

| Tool | ACP kind | Bound |
| --- | --- | --- |
| `read_file` | `read` | Offset and limit; 48 KiB output cap |
| `list_files` | `read` | 500 entries; `.git`, `node_modules`, `target`, `dist` skipped |
| `grep_files` | `search` | 200 lines |
| `write_file` | `edit` | Path confined to the workspace, never inside `.git` |
| `edit_file` | `edit` | Exact match, byte-order-mark and line-ending preserved, stale-content guard |
| `shell` | `execute` | `/bin/sh -c`, no standard input, 60-second default and 240-second ceiling, grant variables removed from the child environment |

The document also adds `git` and `delegate` as client-side tools. `git` handles read-only and write effects, and `delegate` reaches the OpenAgents delegation API.

### 1.2 Path and approval rules

Section 7.1 states that path resolution refuses NUL bytes, absolute paths, and any parent-directory component. Mutations also refuse anything under `.git`.

Section 7.3 describes the approval ladder:

| Level | Applies to | Behavior |
| --- | --- | --- |
| Automatic | `read`, `search`, `think`; tracker reads | Runs and is disclosed in the transcript |
| Ask once | `edit` inside the workspace | Prompts; `a` approves that kind for the session |
| Ask every time | `execute`, `fetch`, `delete`, `move`, `git push`, tracker writes, delegation | Prompts every call |
| Refuse | Paths outside the workspace, unlisted tools, anything the token's scope does not cover | Typed refusal with the reason |

The rules underneath are behavioral: tool name and arguments grant no authority, `a` is a client-side policy and not a wire option, and refusal is a bounded typed outcome the agent must handle. The spec also bans option names matching `/bypass/i` and requires that every outcome name its executor.

### 1.3 What the OpenAgents docs do not define

The docs do not define:

* The JSON schema the model sees.
* The runtime validation code.
* The error taxonomy.
* The tool registry or model-family selection.
* Telemetry or confirmation UI.

These are intentionally out of scope for the document and are left to the `probe` runtime and the `openagents` CLI monorepo.

---

## 2. How the Gemini CLI defines tools

The Gemini CLI defines tools in two layers: the *declaration* that goes to the model, and the *implementation* that executes the call.

### 2.1 Declaration layer

The declaration files are in `packages/core/src/tools/definitions/`.

* `base-declarations.ts` is a registry of string constants for every tool name and parameter name (`READ_FILE_TOOL_NAME`, `PARAM_FILE_PATH`, `EDIT_PARAM_OLD_STRING`, and so on). It sits at the bottom of the dependency tree to prevent circular imports.
* `types.ts` defines `ToolDefinition` (a base `FunctionDeclaration` plus an optional `overrides` function) and `CoreToolSet` (a `FunctionDeclaration` for every built-in tool).
* `coreTools.ts` exports concrete `ToolDefinition` objects such as `READ_FILE_DEFINITION`, `WRITE_FILE_DEFINITION`, and `SHELL_DEFINITION`. Each has a `base` declaration and an `overrides(modelId)` function.
* `resolver.ts` resolves the final `FunctionDeclaration` for a tool by applying the model-specific override to the base.
* `model-family-sets/default-legacy.ts` and `model-family-sets/gemini-3.ts` contain the full `FunctionDeclaration` for each model family.
* `dynamic-declaration-helpers.ts` generates declarations that depend on runtime state, such as the platform-specific `run_shell_command` schema and the skill list for `activate_skill`.

`modelFamilyService.ts` maps a model ID to a family, and `getToolSet` in `coreTools.ts` returns either the `DEFAULT_LEGACY_SET` or the `GEMINI_3_SET`.

The model-facing declaration is a `FunctionDeclaration` from `@google/genai` with `name`, `description`, and `parametersJsonSchema`. For example, `DEFAULT_LEGACY_SET.read_file` requires `file_path` and optionally `start_line` and `end_line`. The `write_file` schema requires `file_path` and `content` and explicitly warns the model not to use omission placeholders.

### 2.2 Implementation layer

The implementation files are in `packages/core/src/tools/`.

* `tools.ts` defines `BaseDeclarativeTool`, `BaseToolInvocation`, `Kind`, `ToolResult`, and `ExecuteOptions`. A `BaseDeclarativeTool` validates parameters in `validateToolParams` and builds a `BaseToolInvocation`. The invocation owns `execute`, `toolLocations`, `getDescription`, and `getConfirmationDetails`.
* `read-file.ts`, `write-file.ts`, `edit.ts`, `grep.ts`, `ls.ts`, `glob.ts`, `shell.ts`, `web-search.ts`, `web-fetch.ts`, `ask-user.ts`, and the rest each define a `*Tool` and a `*ToolInvocation`.
* `tool-error.ts` defines the `ToolErrorType` enum, with categories for file system, edit, grep, shell, MCP, web, and memory errors.
* `tool-names.ts` lists canonical names, display names, tool sets that require narrowing, plan-mode tools, and an alias map.
* `tool-registry.ts` registers built-in, discovered, and MCP tools and exposes `getFunctionDeclarations` and `getActiveTools`.

### 2.3 Key per-tool behavior

#### `read_file`

`packages/core/src/tools/read-file.ts`:

* Resolves the path with `resolveDefensiveToolPath` and `resolveToRealPath`.
* Validates workspace access with `config.validatePathAccess(resolvedPath, 'read')`.
* Calls `processSingleFileContent`, which handles text, images, audio, and PDFs.
* If the result is truncated, the tool returns a message that explicitly tells the model to use `start_line` and `end_line` in a follow-up call.
* Appends just-in-time (JIT) subdirectory context after the read.

#### `write_file`

`packages/core/src/tools/write-file.ts`:

* Supports a `modified_by_user` flag to record whether the user edited the proposed content.
* Runs `getCorrectedFileContent`, which can call a base LLM to correct the proposed content before writing.
* Detects omission placeholders and refuses them.
* Preserves CRLF line endings for existing files.
* Returns a unified diff, an `isNewFile` flag, and a `diffStat` so the agent can verify the change without a second read.

#### `replace` (edit)

`packages/core/src/tools/edit.ts`:

* Requires `file_path`, `instruction`, `old_string`, `new_string`, and `allow_multiple`.
* The description in `default-legacy.ts` is extremely prescriptive: the `old_string` must be exact literal text, with at least three lines of context, and the tool will fail if the match is not unique unless `allow_multiple` is true.

#### `run_shell_command`

`packages/core/src/tools/shell.ts`:

* The declaration is generated by `getShellDeclaration` in `dynamic-declaration-helpers.ts`. It is platform-specific: `bash -c` on macOS/Linux and `powershell.exe -NoProfile -Command` on Windows.
* `ShellToolInvocation` supports `is_background` and `delay_ms`.
* It can run under a sandbox and request additional `network` or `fileSystem` permissions through `additional_permissions`.
* It trims live output to 100,000 characters and summarizes oversized output.

### 2.4 Confirmation and policy

`packages/core/src/tools/tools.ts` shows that every `BaseToolInvocation` participates in a confirmation bus:

* `shouldConfirmExecute` first checks whether the current approval mode or a forced decision short-circuits the prompt.
* It then publishes a `TOOL_CONFIRMATION_REQUEST` to the message bus and waits for a `TOOL_CONFIRMATION_RESPONSE`.
* The response can be `allow`, `deny`, or `ask_user`. If the response is `ask_user`, the tool returns `getConfirmationDetails`.
* `getPolicyUpdateOptions` lets a tool narrow the policy after approval, for example by file path for file tools or by command prefix for shell.

### 2.5 Error handling

`packages/core/src/tools/tool-error.ts` defines a single, type-safe `ToolErrorType` enum. Errors are grouped by subsystem and by recoverability. `isFatalToolError` currently treats `NO_SPACE_LEFT` as the only fatal error; all other errors are expected to be returned to the model for self-correction.

### 2.6 Tool registry and activation

`packages/core/src/tools/tool-registry.ts`:

* Registers built-in tools, discovered tools from a project command, and MCP tools.
* Sorts tools: built-in first, then discovered, then MCP by server name.
* Respects `excludeTools` configuration and legacy aliases.
* Deactivates `enter_plan_mode` or `exit_plan_mode` based on the current `ApprovalMode`.
* Deactivates `read_mcp_resource` and `list_mcp_resources` if no MCP resources are available.

---

## 3. Direct comparison

| Concern | OpenAgents docs | Gemini CLI |
| --- | --- | --- |
| **Tool catalog size** | Six local tools plus `git` and `delegate`. | 20+ built-in tools, plus discovered and MCP tools. |
| **Schema ownership** | Not specified in docs. | Each tool owns a `FunctionDeclaration` with `parametersJsonSchema`. |
| **Model-family variants** | Not specified. | `getToolSet` selects `DEFAULT_LEGACY_SET` or `GEMINI_3_SET` per model ID, with per-tool overrides. |
| **Declaration vs. execution split** | The docs prescribe behavior; `probe` and the CLI implement it. | `BaseDeclarativeTool` declares and validates; `BaseToolInvocation` executes. |
| **Path safety** | Prescribed in docs: no NUL, no `..`, no absolute paths, no `.git` mutations. | Implemented in `resolveDefensiveToolPath`, `resolveToRealPath`, and `config.validatePathAccess`. |
| **Approval model** | Ladder with four levels: automatic, ask once, ask every time, refuse. | Message-bus confirmation with `allow`, `deny`, `ask_user` plus a configurable `ApprovalMode`. |
| **Error taxonomy** | Behavioral requirement: typed, bounded refusals. | Concrete `ToolErrorType` enum with file/edit/shell/MCP/web/memory categories. |
| **Telemetry** | Mentioned as a requirement for budget and receipts. | `FileOperationEvent`, shell summaries, and `logFileOperation` hooks are wired into tool execution. |
| **Extensibility** | Client adds `git` and `delegate`. | Built-in registry, discovered tools from a command, and MCP tools. |
| **Line-ending and encoding** | Prescribed in `edit_file`: BOM and line-ending preserved. | Implemented in `write-file.ts` with `detectLineEnding` and CRLF preservation. |

### 3.1 Where OpenAgents is more opinionated

The OpenAgents spec is stricter in a few places that the Gemini CLI does not always encode in the same way:

* **No `--bypass` options.** The spec forbids any option whose id, name, or kind matches `/bypass/i`. Gemini does not have this rule at the declaration level.
* **No `allow` persistence.** The spec requires `allow_once` and `reject_once` on the wire, with session-scoped `a` only in the client. Gemini's `BaseToolInvocation` does not expose a wire `always` either, but the client can choose `ProceedAlways` or `ProceedAlwaysAndSave` through the message bus.
* **Named executor.** The spec requires every outcome to name whether OpenAgents, the runtime, or the user performed the work. Gemini returns `ToolResult` with `llmContent` and `returnDisplay`, but does not always label the executor.

### 3.2 Where Gemini is more concrete

* **Model schemas are explicit and versioned.** OpenAgents does not yet ship the JSON schema the model will see.
* **Parameter validation is per-tool and deep.** `ReadFileTool` checks `start_line <= end_line`; `WriteFileTool` rejects directories; `EditTool` will fail on non-unique matches.
* **Content correction before write.** `write-file.ts` can ask a base model to correct the proposed content, which is not in the OpenAgents spec.
* **Shell sandboxing.** Gemini's shell tool can request additional `network` and `fileSystem` permissions through the schema. OpenAgents only prescribes a 240-second ceiling and grant-variable scrubbing.
* **Discovered and MCP tools.** Gemini's registry is already designed for tools that are not built in.

---

## 4. Implications for OpenAgents

The Gemini CLI is not the right shape to drop into `openagents coder` directly. Its surface is broader, more browser and IDE aware, and more optimistic about shell. But four of its structural choices should inform the OpenAgents implementation:

1. **Resolve `FunctionDeclaration` per model family.** The `openagents` coder runtime will support both the OpenAI-compatible proxy and the Gemini lowering. Tool descriptions and parameter schemas should be model-family-aware from the start, not retrofitted.
2. **Split declaration from invocation.** The `BaseDeclarativeTool`/`BaseToolInvocation` pattern makes it possible to test the schema sent to the model independently from the behavior that runs it. This is the same separation the OpenAgents spec already implies between docs and `probe`.
3. **Adopt an explicit `ToolError` taxonomy.** The spec already demands typed refusals. A single enum with recoverable and fatal classes would let the model self-correct instead of aborting.
4. **Make the tool registry configuration-driven.** The OpenAgents runtime should be able to deactivate tools by policy, enable `git`/`delegate`, and include MCP tools later without rewriting the turn loop.

What should not be copied wholesale: the large built-in tool catalog (the spec intentionally starts with six), the Gemini-specific `activate_skill`/`update_topic` prompts, and the LLM content correction step in `write_file`, which adds an extra model call that may not be appropriate for a budgeted grant.

---

## 5. Settled and unsettled questions

**Settled:**

* OpenAgents docs define a small, prescriptive tool contract centered on ACP kinds and an approval ladder.
* Gemini CLI defines a complete, model-facing tool system with schemas, validation, execution, telemetry, and a registry.
* Both systems agree on workspace confinement, approval gates, and output bounds.

**Unsettled (out of scope for this audit):**

* The exact JSON schema the `openagents coder` model will receive. This belongs to the `probe` runtime and the CLI monorepo, not this repository.
* Whether OpenAgents will support MCP, discovered, or skill tools in Stage 1.
* Whether the OpenAgents runtime will implement `FunctionDeclaration` resolution itself or rely on the CLI to choose the tool set.
