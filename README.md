# pi-os

An OS-level AI layer for Windows, with a draft native macOS port: press a global hotkey in **any** application,
type an instruction, and a [pi](https://github.com/earendil-works/pi) agent
already knows what you were looking at and has tools to act on it.

```
Notepad, Explorer, Excel, browser, anything
        |
   Ctrl+Alt+Space
        |
        v
+---------------------------+      HTTP/JSON       +---------------------------+
|  C# host (hidden WPF)     | -------------------> |  node-harness             |
|  - pins context BEFORE    |   POST /invoke       |  - pi SDK AgentSession    |
|    the popup shows        | <------------------- |  - desktop tools          |
|  - prompt overlay         |  POST /tools/{name}  |  - observe/act loops      |
|  - screenshots, UIA, input|                      |    via pi extensions      |
+---------------------------+                      +---------------------------+
```

The core split:

- **C# host** = stable native substrate: hotkey, context pinning, screenshots,
  UI Automation, input primitives.
- **node-harness** = the intelligence: a real pi session that reasons, picks
  tools, and re-observes after actions.
- Everything rapidly changing lives on the node side or in sidecars — the host
  stays small.

## macOS (draft port)

[`host-macos/`](host-macos/README.md) implements the same host/harness split with
Swift/AppKit, AX, ScreenCaptureKit and native input. **Control+Option+Command+Space**
opens a native bottom-centered Whisper bar; a persistent reader supports sequential
follow-ups. Appearance presets are independent of permissions and pinned authority.
The existing Windows host/input fixes remain intact.

See [build/use instructions](host-macos/README.md),
[architecture and simplification review](host-macos/ARCHITECTURE.md) and
[acceptance/remaining gates](host-macos/ACCEPTANCE.md). This is not full parity or a
notarized distribution. Isolated Mac tools, optional explicitly consented Brave CDP,
credential opt-in and deletion heuristics have deliberately bounded guarantees;
trusted global extensions are arbitrary code, not sandboxed.

## Repository layout

| Path | Purpose |
|------|---------|
| `host-dotnet/` | C# solution: `WindowsHarness.Host` (WPF background app) + `WindowsHarness.Contracts` (shared schema types) |
| `host-macos/` | Swift/AppKit native host, dependency-free Swift package, fixtures and packaging recipes (draft) |
| `node-harness/` | Node service: HTTP server on port 17832, pi SDK agent sessions, desktop tool wrappers |
| `shared/schemas/` | Canonical TypeScript types for the context snapshot (`desktop-context.ts`) |
| `shared/protocol/` | The localhost HTTP contract (`protocol.md`) — ports, endpoints, error model |

## Development

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for prerequisites, build and test
commands, development workflows, environment variables, and instructions for
refreshing the installed application.

## Use it

1. Focus any desktop app (Notepad, Explorer, ...).
2. Press **Ctrl+Alt+Space**.
3. Type an instruction. On Windows, **Include screenshot** is on by default;
   switch it off to omit the initial image attachment. Press **Enter**. The overlay closes instantly and
   focus returns to your app.
4. The persistent reader shows the answer and accepts sequential follow-ups. Logs omit prompt/snapshot contents.

A pi session receives the context summary and, by default, a screenshot. The
Windows switch controls only the initial attachment: local capture stays enabled,
and later screenshot tools remain available for image-capable models. Each new
prompt starts with the switch on if the selected model supports image input.
Text-only models have the switch disabled. If model support cannot be determined
(including an unsaved automatic model choice), the switch stays off until an
image-capable model is selected in Settings. The active session model is checked
again before image attachments are sent.
It can observe the
captured window and use `desktop_act` to focus, click, type, press supported
keys or shortcuts, and scroll. Safe action traces are written to
`logs\host.log`; typed content is never logged. Agent mode requires pi
authentication through `pi /login` or a provider API key.

### Choosing the model

Right-click the tray icon → **Settings…** to pick the agent model and its
reasoning effort. Settings also shows whether the selected model supports image
input, based on pi model metadata. Image-capable models have an **IMG** badge in
the model dropdown. The list shows models with configured authentication, and
effort options adapt to the selected model. The choice persists in
`%LOCALAPPDATA%\pi-os\settings.json`; every new hotkey invocation uses it
(a running task keeps its own model), both switches are logged to
`logs\host.log`.

## Configuration

No environment variables are required for normal use. These optional settings
change user-visible behavior:

| Variable | Meaning |
|----------|---------|
| `PI_OS_HOTKEY` | Hotkey override, e.g. `Ctrl+Shift+F9` (default `Ctrl+Alt+Space`) |
| `PI_OS_INVOKE_TIMEOUT_MS` | Maximum time for each request in milliseconds (default `300000`; `0` disables the timeout) |

Other `PI_OS_*` variables are development and test controls documented in
[`DEVELOPMENT.md`](DEVELOPMENT.md).

Artifacts live under `%LOCALAPPDATA%\pi-os\`: `logs\host.log`,
`captures\shot-*.png`, plus `settings.json` (model + reasoning effort chosen
in the tray settings page).

## Reference files

| File | Read when |
|------|-----------|
| `shared/protocol/protocol.md` | You change any endpoint, port, or message shape |
| `shared/schemas/desktop-context.ts` | You touch the context snapshot shape (C# mirror must stay field-compatible) |
| `AGENTS.md` | You use a coding agent in this repository |

## Current capabilities

- Starts from one desktop shortcut and remains available in the system tray.
- Captures the active window, screenshot, focused UI element, and monitor
  information before showing the prompt.
- Uses a pi agent to inspect and interact with the captured window.
- Supports focusing, clicking, typing, key presses, keyboard shortcuts, and
  scrolling.
- Provides model and reasoning-effort settings from the tray menu.
- Supports cancellation, request timeouts, and live task status.
- Blocks computer input in protected applications such as password managers
  and elevated windows.

## License

pi-os is available under the [MIT License](LICENSE). Third-party dependencies
remain subject to their own licenses.
