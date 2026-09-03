# pi-os Project Notes

## Command working directories

The repository root has no `package.json`. Run npm scripts from
`node-harness/`, or use `npm --prefix node-harness run <script>` from the root.

## Process safety

Never kill processes by image name (`taskkill /IM node.exe`, `pkill node`, and
similar). Shared runtimes also host unrelated tooling and live user sessions.

Kill only the specific PID this project started:

1. Resolve it: `netstat -ano | grep :<my-port>` — note the PID in the last column.
2. Verify it is not a known live-session process.
3. Kill exactly that PID: `taskkill //PID <pid> //F` (Git Bash: double slashes).

This rule exists because an image-wide `node.exe` kill destroyed a live agent
session on 2026-08-24.

## Stable install is a snapshot

`%LOCALAPPDATA%\pi-os\` (desktop shortcut target) only changes when someone
re-publishes. After implementation changes, run `refresh-install.ps1`
(repo root) — or the README recipe it wraps — and if that is not possible,
explicitly tell the user the installed copy is now stale. Never assume a
freshly built `bin/Debug` or repo state is what runs when the user presses
the hotkey.

## Desktop input invariants (read before touching the input path)

`docs/desktop-input-semantics.md` (tracked) is the binding contract for typed
text input: characters must arrive exactly as sent, `\n` must become a real
line break, keystrokes are paced (default 20 ms/char, `PI_OS_TYPE_INTERVAL_MS`),
and down/up travel atomically. Several of these were learned only through live
defects, so read that document and re-run its verification whenever you change
`ComputerUseService` or add a new platform host. Invariants are host-neutral;
mechanisms are Windows-specific — never push them into the shared node layer.

## Progress tracker commits

Do not create separate commits for `docs/progress-tracker.md` status updates.
Include tracker updates in the same commit as the related implementation work
(when applicable). A standalone tracker commit is only acceptable when no
implementation change exists in the same session.
