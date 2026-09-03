# Local HTTP/JSON Protocol Contract v0

Communication between the C# Windows host and the TypeScript agent harness.
Loopback only. See `docs/windows-agent-harness-handoff.md`, sections 9, 10, 21.

This document defines the mechanism: endpoints, ports, message shapes, and
error handling. The tool catalog grows per phase; the live catalog always
comes from `GET /tools` on the host.

## Base URLs and ownership

| Service | Default URL | Owner |
|---------|-------------|-------|
| C# Windows Host | `http://127.0.0.1:17831` | Native primitives: context store, screenshots, UIA, input |
| Node Agent Harness | `http://127.0.0.1:17832` | Reasoning, tool selection, observe/act loops |

Rules:

- Bind to `127.0.0.1` only. Never bind `0.0.0.0`.
- Ports are defaults, overridable by config/env (`PI_OS_HOST_PORT`,
  `PI_OS_NODE_PORT`) so two dev instances can run side by side.
- IPv6 `::1` binding is optional and must never replace the IPv4 binding.
- No CORS headers. No browser clients.

## Authentication

All requests except `GET /health` require the header:

```text
X-Harness-Token: <hex token>
```

- The C# host generates a random 32-byte hex token at startup.
- The token reaches the Node harness through the environment variable
  `PI_OS_TOKEN`, set by whichever process launches the other.
- Wrong or missing token: `401`.
- Rationale: loopback binding alone does not stop other local processes.

## Message conventions

- Encoding: UTF-8 JSON. Field names are camelCase, matching
  `shared/schemas/desktop-context.ts`.
- Timestamps: ISO-8601 strings with UTC offset.
- Enums: lowercase camelCase strings (for example `"window"`).
- Unknown fields must be ignored by receivers, not rejected. This keeps the
  schema extensible.
- `monitors` contains metadata for every active display; it does not imply
  visual capture of every display. Window `monitorId` values reference these
  stable device IDs.
- `focusedElement` means keyboard focus only and does not imply selection.
  For desktop captures, `selectedDesktopItems: []` explicitly means UIA
  selection was checked and no icons were selected; an omitted/null field
  means desktop selection was not applicable or unavailable. When
  `selectedDesktopItemsTruncated` is true, `selectedDesktopItemCount` remains
  the complete selection count.

### Two error layers

Transport problems use plain HTTP status codes. Domain outcomes inside a
successful tool call are data, not transport errors, because the agent must
read and react to them.

| Layer | Example | Shape |
|-------|---------|-------|
| HTTP error | malformed JSON, bad token, unknown route | status + `{"error":{"code","message","details"?}}` |
| Tool outcome | target window closed during task | HTTP 200 + `{"ok":false,"error":{...}}` |

HTTP statuses used:

| Status | Meaning |
|--------|---------|
| 200 | success (including `ok:false` tool outcomes) |
| 202 | accepted for async processing |
| 400 | malformed request or failed argument validation |
| 401 | missing/wrong token |
| 404 | unknown route |
| 500 | unexpected server failure |

Tool outcome codes (open set, camelCase):

| Code | Meaning |
|------|---------|
| `invalid_arguments` | arguments fail the tool's input schema |
| `target_gone` | pinned HWND no longer valid, process identity changed |
| `unknown_context` | context ID is unknown or expired |
| `target_elevated` | target runs at higher integrity; UIPI blocks automation |
| `policy_blocked` | target is excluded by the Computer Use safety policy |
| `focus_failed` | the pinned target could not be verified as foreground |
| `input_failed` | Windows did not accept or safely complete native input |
| `capture_failed` | screenshot/window capture failed |
| `uia_failed` | UI Automation query/action failed |
| `busy` | operation was cancelled while waiting for the serialized input gate |
| `internal_error` | unexpected failure inside the host |

## C# Host API (17831)

### `GET /health`

`200 {"service":"windows-host","version":"<semver>","uptimeSeconds":<int>}`
No token required. Used for readiness checks.

### `GET /tools`

`200 {"tools":[ToolDescriptor]}` where `ToolDescriptor`:

```json
{
  "name": "desktop.captureWindow",
  "description": "Captures a fresh screenshot of a window.",
  "inputSchema": { "type": "object", "properties": {}, "required": [] }
}
```

`inputSchema` is JSON Schema draft 2020-12. This endpoint is the source of
truth for tool discovery (handoff section 10).

### `POST /tools/{toolName}`

Uniform tool invocation. Dotted tool names are used directly in the path,
for example `/tools/desktop.getContext`.

Request:

```json
{ "arguments": { "contextId": "ctx-123" } }
```

Response, always HTTP 200:

```json
{ "ok": true, "result": { } }
```

```json
{ "ok": false, "error": { "code": "target_gone", "message": "HWND 0x000A1234 no longer exists" } }
```

### `GET /images/{imageId}`

Returns captured image bytes (`image/png`). Referenced by `ScreenshotRef.imageId`
from `shared/schemas/desktop-context.ts`.

### Pinned desktop tool catalog

All tools require `contextId: string`. The Node extension injects it; the model
cannot select or change it. Every action reloads the snapshot and validates the
HWND/process identity immediately before input. Actions are serialized and are
never retried by the host.

| Tool | Additional arguments | Result | Purpose |
|------|----------------------|--------|---------|
| `desktop.getContext` | none | `DesktopContextSnapshot` | Return the pinned snapshot |
| `desktop.refreshContext` | none | `DesktopContextSnapshot` | Refresh metadata and screenshot |
| `desktop.captureWindow` | none | `ScreenshotRef` | Capture a fresh PNG |
| `window.focus` | none | `{action:"focus"}` | Focus and verify the pinned target |
| `input.click` | `x:number`, `y:number` | `{action:"click",x,y}` | One left click |
| `input.typeText` | `text:string` (non-empty) | `{action:"typeText",characters:number}` | Type Unicode text without clipboard use |
| `input.pressKey` | `key:string` | `{action:"pressKey",key}` | Press one supported key |
| `input.keyChord` | `key:string`, `modifiers:string[]` | `{action:"keyChord",key}` | Press key with Ctrl/Alt/Shift |
| `input.scroll` | `deltaX?:number`, `deltaY?:number`, `x?:number`, `y?:number` | `{action:"scroll",deltaX,deltaY,x,y,wheelDeltaX,wheelDeltaY}` | Wheel scroll in normalized notches; optional screenshot-relative point |

Click coordinates are physical pixels relative to the latest target-window
screenshot. The host refreshes current bounds and computes
`screenX = bounds.x + x`, `screenY = bounds.y + y`; values outside current
bounds fail with `invalid_arguments`.

Scroll deltas use normalized wheel notches: `1` is one conventional notch and
the host converts it to 120 Windows wheel units. Negative `deltaY` scrolls
down; positive `deltaY` scrolls up. Supply both `x` and `y` to choose a
screenshot-relative scroll point, for example inside a nested scrolling panel.
Omit both coordinates to use the current target-window center. Supplying only
one coordinate, an out-of-bounds point, zero movement, or a non-zero delta too
small to produce one Windows wheel unit fails with `invalid_arguments`.

The host writes a privacy-bounded action trace to `host.log`: sequence ID,
action name, context ID, target identity/bounds, safe arguments, pointer target
and actual position, window under the pointer, normalized wheel data, duration,
and outcome. Typed text is never logged; only its character count is recorded.

Supported keys: Enter, Tab, Escape, Backspace, Delete, Home, End, PageUp,
PageDown, arrow keys, F1-F12, letters, and digits. Supported modifiers: `ctrl`,
`alt`, and `shift`. Windows/Meta/Super/Cmd is not supported.

Cancellation is honored while waiting for the host operation gate and between
typed UTF-16 characters. A cancelled or partially completed mutating action is
not retried. Domain failures use `invalid_arguments`, `unknown_context`,
`target_gone`, `target_elevated`, `policy_blocked`, `focus_failed`,
`input_failed`, `busy`, or `internal_error` as applicable. Responses never
contain typed text or raw stack traces.

## Node Harness API (17832)

### `GET /health`

Same shape as the host health endpoint, `"service":"node-harness"`.

### `POST /invoke`

Entry point for a hotkey submission. Request:

```json
{
  "invocationId": "inv-abc",
  "contextId": "ctx-123",
  "prompt": "Create a chart from this table",
  "invokedAt": "2026-08-24T12:00:00Z"
}
```

- `invocationId`: UUID, generated by the caller (host) for log correlation.
- `contextId`: references the pinned snapshot stored in the C# host.
- The snapshot itself is NOT embedded; the agent fetches it via
  `desktop.getContext`.

Response: `202 {"accepted": true, "invocationId": "inv-abc"}`.
The agent then runs its observe/act loop asynchronously.

### `GET /invocations/{invocationId}`

Execution status for tests and diagnostics:

```json
{
  "invocationId": "inv-abc",
  "state": "running",
  "startedAt": "...",
  "finishedAt": null,
  "activity": "thinking",
  "steps": [
    { "tool": "desktop.getContext", "at": "...", "ok": true }
  ],
  "responseText": null,
  "failureMessage": null
}
```

`state`: `"queued" | "running" | "completed" | "failed" | "aborted" | "timed_out"`.

`steps` grows live while the invocation runs (one entry per host tool call
and per agent tool execution); clients poll this endpoint for progress.

Result-surfacing fields (ux-design-notes.md):

- `activity`: current live line for the host pill — a tool name while a tool
  executes, `"thinking"` during reasoning, absent when idle. Cleared when the
  invocation reaches a terminal state.
- `responseText`: final agent answer, capped (~8 KB); set on completion.
- `failureMessage`: why the invocation failed/aborted/timed out; terminal
  failure states only.

#### `POST /invocations/{invocationId}/cancel`

Requests cancellation of a running invocation (A.3):

- `202 {"accepted": true, "invocationId": "..."}` — cancellation started;
  the record ends in state `aborted`.
- `409 {"error":{"code":"not_running"}}` — invocation exists but is not
  in flight (already finished, failed, or cancelled).
- `404 {"error":{"code":"not_found"}}` — unknown invocation id.

Each invocation also has a wall-clock timeout (`PI_OS_INVOKE_TIMEOUT_MS`,
default 300000, `0` disables). A timed-out invocation ends in state
`timed_out`; both terminal paths record a `cancel` / `timeout` step.

#### `POST /invocations/{invocationId}/followup`

Sequential prompt on the idle live session (same reader window). KISS:
plain text only; history is kept by pi, no new screenshot is attached.
Tools re-observe via `desktop_capture_window` when fresh pixels are needed.
The thread keeps its original model.

Request: `{"prompt": "and now sort it"}`.

- `202 {"accepted": true, "invocationId": "..."}` — requeued to
  `running`; poll `GET /invocations/{id}` for the new answer. Steps append;
  `responseText` is replaced.
- `400 {"error":{"code":"invalid_arguments"}}` — missing/empty prompt.
- `404 {"error":{"code":"not_found"}}` — unknown invocation id.
- `404 {"error":{"code":"session_closed"}}` — live session is gone
  (reader closed, harness restarted, or slice-mode first run failed).
- `409 {"error":{"code":"not_idle"}}` — still `queued`/`running`.

#### `POST /invocations/{invocationId}/close`

Disposes the live session when the reader window closes. Idempotent:
`200 {"closed": true, "invocationId": "..."}` even when no session
remains. The host fires this on window close and never blocks on it.

### Model settings (settings page)

The host tray menu opens a settings page for agent model + reasoning effort.
The harness owns both the pi catalog and the stored choice; sessions are per
invocation, so every NEW hotkey invocation picks up the current setting while
an already-running invocation keeps its model.

#### `GET /models`

Catalog for the settings page. Only models with configured authentication are
listed (`ModelRuntime.getAvailable()`), sorted provider then id:

```json
{
  "models": [
    {
      "provider": "openai",
      "id": "gpt-5.2",
      "name": "GPT-5.2",
      "reasoning": true,
      "thinkingLevels": ["off", "low", "medium", "high", "xhigh"]
    }
  ],
  "current": { "provider": "openai", "modelId": "gpt-5.2", "thinkingLevel": "low" }
}
```

- `thinkingLevels`: pi thinking levels this exact model accepts, ascending;
  non-reasoning models report `["off"]` only. Derived via pi-ai's
  `getSupportedThinkingLevels` (`thinkingLevelMap` null entries excluded).
- `current`: the stored selection; `null` when no preference is saved and pi
  resolves its automatic default at session creation.

#### `POST /settings/model`

Request body `{"provider":"...","modelId":"...","thinkingLevel":"..."}`.
Validated against the live catalog before storing:

- Unknown/unauthenticated model → `400 {"error":{"code":"invalid_arguments"}}`.
- Level not in that model's supported list → `400` listing valid levels.
- Success → `200 {"current":{"provider","modelId","thinkingLevel"}}`; the
  switch is logged (`[settings] model switched: <old> -> <new>`).

The choice persists in `%LOCALAPPDATA%\pi-os\settings.json` and is re-applied
to each new invocation by `runAgent`, which also logs the effective pair
(`[agent] model=<provider>/<id> effort=<level>`) as the session starts.

## Invocation flow (happy path)

```text
User presses global hotkey
  |
  v
C# host: capture pinned context (BEFORE overlay), generate contextId
  |
  v
C# host: show overlay -> user submits prompt -> overlay closes
  |
  v
C# host --POST /invoke (contextId, prompt)--> Node harness   [202]
  |
  v
Node agent loop --POST /tools/desktop.getContext------------> C# host
  |                                                           [200]
  v
Node agent loop --POST /tools/<any tool>-- repeated --------> C# host
  |
  v
Node harness records steps; invocation completes/fails/is aborted/times out
```

## Non-goals for this version

- No MCP wrapping yet. The tool surface above maps cleanly onto MCP later;
  revisit once primitives stabilize (research question RQ5).
- No streaming/websockets. Polling `/invocations/{id}` is enough for the MVP.
- No multi-tenant auth, no TLS. Loopback + token is the whole security story
  for this phase; deeper policy/approval design comes separately.
