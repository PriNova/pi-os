# Local HTTP/JSON Protocol Contract v0

Communication between a native host (C# Windows / Swift macOS) and the
TypeScript agent harness. Loopback only. The Mac parity candidate implements the
three observation tools and gated native input. GET /tools advertises input only
when the signed host, user setting and TCC grants permit it. Installed-build and
acceptance status are tracked separately in `host-macos/ACCEPTANCE.md`.

This document defines the mechanism: endpoints, ports, message shapes, and
error handling. The tool catalog grows per phase; the live catalog always
comes from `GET /tools` on the host.

## Base URLs and ownership

| Service | Default URL | Owner |
|---------|-------------|-------|
| Native Host | `http://127.0.0.1:17831` | Native primitives: context store, screenshots, UIA/AX, input (per platform phase) |
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

- The native host generates a random 32-byte hex token at startup (or uses an explicit split-development token).
- The token reaches the Node harness through the environment variable
  `PI_OS_TOKEN`, set by whichever process launches the other.
- Wrong or missing token: `401`. An unconfigured token fails closed; only explicit
  `PI_OS_INSECURE_DEV=1` opts out in isolated development. Mac supervised mode cannot opt out.
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
  means desktop selection was not applicable or unavailable. On macOS a pinned
  Finder desktop uses `targetWindow.surface: "finderDesktop"`, its real CG window ID,
  and an optional `desktopWorkArea` for exact AX geometry matching. Only explicit AX
  selection on that verified surface populates the desktop-selection fields. When
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
| 404 | unknown route or closed/expired thread |
| 409 | duplicate invocation, busy thread or retained-thread capacity reached |
| 500 | unexpected server failure |

Tool outcome codes (open set, snake_case):

| Code | Meaning |
|------|---------|
| `invalid_arguments` | arguments fail the tool's input schema |
| `target_gone` | pinned HWND no longer valid, process identity changed |
| `unknown_context` | context ID is unknown or expired |
| `target_elevated` | target runs at higher integrity; UIPI blocks automation |
| `policy_blocked` | action/surface is excluded by native safety policy, not an ordinary app-brand ban on Mac |
| `file_deletion_blocked` | recognized file-deletion UI action, shortcut or terminal command was rejected |
| `focus_failed` | the pinned target could not be verified as foreground |
| `input_failed` | Windows did not accept or safely complete native input |
| `capture_failed` | screenshot/window capture failed (including an existing but unavailable Mac window) |
| `no_target` | frontmost application has no capturable normal window |
| `permission_denied` | required macOS permission is absent |
| `capture_stale` | image is stale/unseen, or geometry changed; no input posted |
| `accessibility_denied` / `input_permission_denied` | native control grants are absent |
| `control_disabled` | native control is disabled or the installation is not certificate-signed |
| `credential_input_blocked` | clearly identified username/password field requires explicit pi-os Settings opt-in; other fields remain usable |
| `secure_input` / `focus_unknown` | destination input security/focus cannot be established safely; the OS-wide Secure Keyboard Entry flag alone is not a veto |
| `budget_exceeded` | invocation reached its bounded native input budget |
| `uia_failed` | UI Automation query/action failed |
| `busy` | operation was cancelled while waiting for the serialized input gate |
| `internal_error` | unexpected failure inside the host |

## Native Host API (17831)

### `GET /health`

`200 {"service":"windows-host","version":"<semver>","uptimeSeconds":<int>}`
Mac uses `"service":"macos-host"`. No token required. Used for readiness checks.

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

### Screenshot transfer

Hosts write PNGs into the explicitly shared `PI_OS_CAPTURES_DIR`. Node reads
`ScreenshotRef.filePath` after realpath containment, regular-file, size and PNG
signature checks, then attaches image bytes to the model. `imageId` identifies the
capture; no `GET /images/{imageId}` route is implemented. Mac captures include actual
`imageWidth`/`imageHeight`, capped at a 1280-pixel long edge and 1 MP to avoid common
provider/SDK image resizers changing the coordinate space. The Mac host removes
managed captures on context disposal/orderly shutdown (crash leftovers may remain).

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

Tool coordinates are pixels in the latest target-window screenshot, not global
screen coordinates. Windows currently captures physical pixels and computes
`screenX = bounds.x + x`, `screenY = bounds.y + y`. Mac wire bounds/cursor/monitors
use CG global top-left **points**; its private transform uses captured bounds and
actual returned image dimensions. On Mac, clicks and coordinate-based scrolls also
require a private `screenshotId` injected by the extension. It advances only after
successful image ingestion and must match the host's latest capture. Metadata-only
refresh does not authorize coordinates. Pure movement uses the current origin;
resizing or unseen/stale imagery returns `capture_stale` before input.

Mac input results contain `action` and `postedEvents`, plus optional character count
or image coordinates. Posted events are **not** proof that the UI accepted them;
the agent must visually verify. Any uncertain input outcome prevents further input
in the same context; observation tools remain available.

Scroll deltas use normalized wheel notches: `1` is one conventional notch and
the host converts it to 120 Windows wheel units (Mac: three native scroll lines). Negative `deltaY` scrolls
down; positive `deltaY` scrolls up. Supply both `x` and `y` to choose a
screenshot-relative scroll point, for example inside a nested scrolling panel.
Omit both coordinates to use the current target-window center. Supplying only
one coordinate, an out-of-bounds point, zero movement, or a non-zero delta too
small to produce one Windows wheel unit fails with `invalid_arguments`.

The Windows host writes a privacy-bounded action trace to `host.log`: sequence ID,
action name, context ID, target identity/bounds, safe arguments, pointer target
and actual position, window under the pointer, normalized wheel data, duration,
and outcome. Typed text is never logged; only its character count is recorded.

Supported keys: Enter, Tab, Escape, Backspace, Delete, Home, End, PageUp,
PageDown, arrow keys, F1-F12, letters, and digits. Supported modifiers: `ctrl`,
`alt`, and `shift` on Windows. The Mac schema additionally supports `cmd` and the
`space` key, with current-layout letter/digit mapping. System/window-escape shortcuts
are refused on Mac; ordinary app save/close/hide/minimize shortcuts are not blanket-banned.
Mac input additionally inspects actionable AX labels/identifiers and editing context
for file-deletion controls/shortcuts. These checks do not sandbox arbitrary scripts,
aliases, opaque custom controls or trusted extension code. Mac traces in `logs/host-actions.jsonl` record action/outcome,
duration and counts, without typed text, key values, titles or context capabilities.

Cancellation is honored while waiting for the host operation gate and between
typed UTF-16 characters. A cancelled or partially completed mutating action is
not retried. Domain failures use `invalid_arguments`, `unknown_context`,
`target_gone`, `target_elevated`, `policy_blocked`, `focus_failed`,
`input_failed`, `busy`, or `internal_error` as applicable. Responses never
contain typed text or raw stack traces.

### macOS private Brave adapter routes

An optional snapshot `browser: {name:"Brave", mode:"cdp", pinned:boolean}` selects the
first-party browser route. It contains no socket endpoint or CDP target capability.
The native host retains the selected AX tab/window objects from before the prompt.
These authenticated `/tools/browser.*` routes are private adapter coordination,
not general agent tools in the public `/tools` discovery catalog:

- `browser.connection` / `browser.validate`: arguments `{contextId, mutation?:boolean,
  action?:"click"|"fill"|"press"|"scroll", characters?:number}`. Returns private
  `{processId,port,initialURL,url,bounds,allowCredentialFields}` only after native
  context, process identity, ownership, permission and selected-tab checks. Mutation
  validation also hides the capsule, focuses the exact window and charges the shared
  input budget. No model can supply this context, endpoint or target identity.
- `browser.invalidate`: `{contextId}` marks uncertain input; it does not re-enable,
  retarget or delete a context. All three routes require the shared host token.

The harness validates loopback-listener ownership and uses an explicit WebSocket
endpoint, no profile reads or arbitrary port scans. It attaches only after the
pinned URL/native bounds identify exactly one target. Session target IDs remain
private. Native `input.*` / `window.focus` return `browser_route_required` for this
context even if invoked directly; the agent instead gets `browser_snapshot` and
`browser_act` with semantic references, no arbitrary JS/CDP/cookie tools. Browser
scroll uses **CSS pixels, positive downward**, unlike native wheel-notch deltas.
References are consumed after action and invalidated by navigation. Tool calls
serialize; unknown outcomes poison writes and cannot trigger mutation retries.
Cancellation revokes the native context and closes the CDP connection. Cleanup
detaches only; it never closes the user's Brave process or tabs.

Additional domain errors include `browser_disabled`, `browser_tab_unknown`,
`browser_target_changed`, `browser_target_ambiguous`, `browser_page_unsupported`,
`browser_stale`, `browser_occluded`, `browser_dialog`, `browser_disconnected`,
`browser_timeout`, `browser_unsupported_action`, `browser_unsupported_link` and
`browser_script_failed`. Field-local credential refusal is `credential_input_blocked`;
file deletion remains `file_deletion_blocked`. The native Settings permission defaults
to false, is supplied only by the authenticated host and is rechecked before mutation.
Neither text snapshots nor opt-in expose stored field values; the setting allows input
only. It does not disable macOS Secure Keyboard Entry, which no longer blanket-blocks
ordinary typing, clicks or observation. Only a clearly pre-mutation `browser_stale`
authorizes taking a fresh snapshot; uncertain writes must not be retried.

This transport does not make opaque page scripts or trusted global extensions a
no-delete sandbox. Supported page scope, installation and acceptance limits are in
`host-macos/BROWSER_INTEGRATION.md`. Windows behavior/schema remains compatible;
the optional Mac browser hint is additive.

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
- `includeScreenshot?: boolean`: defaults to true. Set false to omit the image
  from the initial prompt only. Local capture, text context, and later screenshot
  tools remain unchanged. Follow-ups do not automatically attach the pinned image.
- `retainSession?: boolean`: explicit opt-in to an in-memory conversational thread.
  Both native reader hosts send true; omission/false requests a one-shot lifecycle. At most 20 threads are retained, with a fixed 30-minute lazy TTL (409
  `thread_limit` before accepting a new retained invocation at capacity).
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

Body: `{"prompt":"..."}` (nonblank, at most 20,000 characters).

- 202 accepts one sequential turn on the existing invocation/context/session/model.
  The status record is synchronously requeued; prior response/failure/activity are
  cleared before acknowledgement, while step history is retained.
- 409 `not_idle` rejects a concurrent turn; nothing is queued or replayed.
- 404 `session_closed` means no retained thread, reader closure, cancellation or expiry.
- Each turn gets a new cancellation/timeout controller. Abort listeners are removed
  when it settles. Cancel/timeout closes the thread; Mac revokes its native context.
- Host context is revalidated before a follow-up prompt. Permission loss cannot expand
  or resurrect the original tool/resource scope. First-turn model and settings stay fixed.
- Screenshots and browser references from earlier turns are historical: a follow-up
  clears action-reference authority and requires fresh observation. Native context TTL,
  cumulative input budgets and uncertain-input poisoning are never reset.
- `followupAvailable` in status identifies an open thread; a failed follow-up can retain
  it for an explicit retry if authority remains valid. It is false after close/revocation.

#### `POST /invocations/{invocationId}/close`

Idempotently returns `200 {"closed":true,"invocationId":"..."}` even for an unknown
thread. Revoke the entry before awaiting cleanup; abort an active turn and dispose
SDK, browser and provider-bootstrap resources. Closure during async startup must not
allow a late session to be retained. It does not close user tabs or terminate Brave.
Mac closes/revokes before releasing the harness reservation; its reader survives
outside clicks/deactivation. Escape, Done, close, a replacing hotkey, security-setting
changes and quit end that single native reader's thread. Recalled answers do not
recreate sessions. No idle status polling occurs.

### Model settings (settings page)

The host tray menu opens a settings page for agent model + reasoning effort.
The harness owns both the pi catalog and the stored choice. Every NEW hotkey thread
picks up the current setting; an existing thread and its follow-ups keep their model.

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

The choice persists in `%LOCALAPPDATA%\pi-os\settings.json` on Windows or
`~/Library/Application Support/pi-os/settings.json` on macOS and is re-applied
to each new invocation by `runAgent`, which also logs the effective pair
(`[agent] model=<provider>/<id> effort=<level>`) as the session starts.

### Resource compatibility settings

`GET /settings/resources` returns
`{"current":{"mode":"isolated"|"trustedGlobal"},"warning":"..."}`.

`POST /settings/resources` accepts `{"mode":"isolated"}` or
`{"mode":"trustedGlobal","acknowledgeUnpinnedAccess":true}`. Enabling trusted mode
requires the host to advertise all native input routes and no explicit read-only
launch override; otherwise it returns 409 `control_disabled`. Missing acknowledgement
is 400. The authenticated setting is persisted atomically in `resources.json`, applies
to future sessions/catalog loads, and is suppressed whenever native control is unavailable.

Default Mac mode remains isolated. Trusted mode intentionally loads global pi resources
and coding tools; arbitrary trusted code can bypass native window restrictions. The UI
must show this distinction and obtain explicit confirmation, not imply sandboxing.
Project extensions/context are not trusted on Mac. Factory providers are registered
before model choice; catalog-only loading does not invoke a model or session-start hooks.

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

Text fidelity/line breaks/no-default-clipboard and platform-specific typing mechanisms
are documented in [`docs/desktop-input-semantics.md`](../../docs/desktop-input-semantics.md).

## Non-goals for this version

- No MCP wrapping yet. The tool surface above maps cleanly onto MCP later;
  revisit once primitives stabilize (research question RQ5).
- No streaming/websockets. Polling `/invocations/{id}` is enough for the MVP.
- No multi-tenant auth, no TLS. Loopback + token is the whole security story
  for this phase; deeper policy/approval design comes separately.
