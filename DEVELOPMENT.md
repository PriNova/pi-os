# Development

This project has native C# Windows and draft Swift/AppKit macOS hosts and a
shared Node.js agent harness. Each host owns desktop UI and OS operations; Node
owns the pi conversation and normalized tools. Mac build/install, signing and
acceptance details are in [`host-macos/README.md`](host-macos/README.md).

## Prerequisites

- .NET SDK 10
- Node.js 24 or later
- pi authentication through `pi /login` or a provider API key

Install the Node dependencies once:

```powershell
cd node-harness
npm install
```

## Recommended workflow: one launch

Build the Node harness, then run the C# host. The host starts and stops the
Node process automatically.

```powershell
cd node-harness
npm run check
npm run build

cd ../host-dotnet/WindowsHarness.Host
dotnet run
```

Rebuild the Node harness after a TypeScript change. `dotnet run` rebuilds the
C# host after a C# or XAML change.

## Split workflow: Node live reload

Use two terminals when working frequently on the Node harness.

Terminal 1:

```powershell
cd node-harness
npm run dev
```

Terminal 2:

```powershell
$env:PI_OS_SUPERVISOR = "0"
cd host-dotnet/WindowsHarness.Host
dotnet run
```

Set the **same nonempty `PI_OS_TOKEN` in both terminals** before starting either
process. Split development fails closed without it. `PI_OS_INSECURE_DEV=1` in both
processes is an explicit isolated-development opt-out, never the production default.
The normal supervised workflow generates and passes a shared token automatically.

## Tests

Run the Node checks from `node-harness/`:

```powershell
npm run check
npm test
```

Run the .NET tests from the repository root:

```powershell
dotnet test host-dotnet/WindowsHarness.Host.Tests/WindowsHarness.Host.Tests.csproj
```

To run the Node harness without an LLM, set `PI_OS_AGENT=0`. The fake host in
`node-harness/test/fake-host.mjs` can provide deterministic desktop context for
headless checks.

## Refresh the installed application

The desktop shortcut runs the installed copy, not the repository build. After
validating a change, refresh that copy from the repository root:

```powershell
.\refresh-install.ps1
```

Use `-ForceDeps` when the installed Node dependencies must be installed again.

## Environment variables

All variables are optional. The normal one-launch workflow uses their default
values.

| Variable | Purpose |
|----------|---------|
| `PI_OS_TOKEN` | Shared authentication token. Generated automatically by the supervisor; set the same nonempty value in both processes for split development. |
| `PI_OS_INSECURE_DEV` | Explicit split-development auth opt-out (`1`), not a production default. |
| `PI_OS_HOTKEY` | Overrides the global hotkey, for example `Ctrl+Shift+F9` (default `Ctrl+Alt+Space`). |
| `PI_OS_AGENT` | Set to `0` or `false` to use deterministic test mode without LLM calls. The agent is enabled by default. |
| `PI_OS_NODE_PORT` | Changes the Node harness listening port (default `17832`). Also set `PI_OS_NODE_URL` to the matching address for the C# host. |
| `PI_OS_HOST_PORT` | Changes the C# host listening port (default `17831`). Also set `PI_OS_HOST_URL` to the matching address for the Node harness. |
| `PI_OS_HOST_URL` | Changes the C# host address used by the Node harness (default `http://127.0.0.1:17831`). |
| `PI_OS_NODE_URL` | Changes the Node harness address used by the C# host (default `http://127.0.0.1:17832`). |
| `PI_OS_SUPERVISOR` | Set to `0` to prevent the C# host from starting the Node harness. Use this for the split workflow. |
| `PI_OS_NODE_ENTRY` | Overrides the Node entry file started by the supervisor. The default resolver finds `node-harness/dist/index.js`. |
| `PI_OS_INVOKE_TIMEOUT_MS` | Sets the maximum request time in milliseconds (default `300000`; `0` disables the timeout). |
| `PI_OS_TYPE_INTERVAL_MS` | Sets the delay between typed characters in milliseconds (default `20`; `0` disables pacing). |
| `PI_OS_CAPTURES_DIR` | Changes the shared screenshot directory (default `%LOCALAPPDATA%\pi-os\captures`). Both processes must use the same directory. |

Environment variables apply only to processes started after the variables are
set. Remove a PowerShell override with, for example:

```powershell
Remove-Item Env:PI_OS_SUPERVISOR
```

## Process safety

Stop foreground processes with `Ctrl+C`. If a process remains, find the PID
that owns the relevant port and stop only that PID. Do not stop every
`node.exe` process because other tools can use the same runtime.
