# Desktop Input Semantics (pi-os)

## Purpose

pi-os types text into desktop applications on behalf of a model. The text that
arrives in the target application must be exactly the text the model sent:
same characters, same order, same line breaks. This document is the durable
contract for that guarantee. Any future host (Windows, macOS, Linux) and any
future change to the input path must preserve it.

Read this document before changing anything in the text-input path
(`ComputerUseService.TypeTextAsync`, the node tool mapping, or a new host).

## Invariants

### I1. Text fidelity

Every character of the typed text arrives in the target application in order.
Characters that have no physical key (Unicode outside the layout, emoji,
accented text under a non-matching layout) must still arrive via a
Unicode-capable injection method.

### I2. Line breaks

A `\n` in the text **must** become a line break. `\r\n` is exactly one line
break, never two. `\r` alone is also one line break.

- Windows trap: injecting LF (0x0A) as a `KEYEVENTF_UNICODE` character event
  is silently dropped by editor pipelines (observed in Windows 11 Notepad,
  UWP `RichEditD2DPT`). Only a real Enter key press (`VK_RETURN`) inserts a
  break. The current host therefore converts `\n`/`\r` to `VK_RETURN` and
  collapses `\r\n` to one Enter (`SendTextCharacter`).

### I3. Pacing

Characters must not be injected back-to-back at maximum rate.

- Windows trap: bursting keystrokes at ~1 ms per character overwhelms the
  target text pipeline (UWP/TSF editors). The editor enters auto-repeat and
  the text degenerates into a run of one repeated character (for example
  `Morning light breaks tttttttt...`). Observed: 79 characters in 91 ms →
  corrupted; 20 ms per character → exact.
- Default: 20 ms per character, configurable via `PI_OS_TYPE_INTERVAL_MS`
  (`0` disables pacing). Do not lower the default without re-running the
  live verification below.

### I4. Atomic keystrokes

Key-down and key-up for one character travel in the same `SendInput` batch.

- Reason: a late or lost key-up leaves the key logically held down and the OS
  auto-repeats it, which fills the rest of the text with repeats.

### I5. No clipboard fallback by default

Do not make clipboard mutation the default typing mechanism (handoff §12.10).
Clipboard-based input may be used only when a requirement genuinely needs it.

## Where the contract is implemented

| Piece | File |
|-------|------|
| Pacing loop + CRLF collapse | `host-dotnet/WindowsHarness.Host/Automation/ComputerUseService.cs` (`TypeTextAsync`) |
| Newline → Enter conversion | same file (`SendTextCharacter`) |
| Atomic Unicode keystroke | same file (`SendUnicodeKeystroke`) |
| Pace configuration | `PI_OS_TYPE_INTERVAL_MS`, see `DEVELOPMENT.md` |

## Cross-platform rule

Invariants I1, I2, I5 are host-neutral contract. The mechanisms (Win32
`SendInput`, `VK_RETURN`) are Windows-specific and belong in the Windows host
only. A future macOS/Linux host must implement the same invariants with its
own input API (CGEvent, X11/Wayland keyboard events). Never push a Windows
mechanism into the shared node layer.

## Live verification (run after any input-path change)

1. Open a fresh Notepad window and focus it.
2. Call `ComputerUseService.TypeTextAsync` (seed a `ContextStore` snapshot for
   that window, as the scratch harness `%USERPROFILE%\tmp\pi-os-typing-repro\live`
   does) with text containing: plain ASCII, `\n` line breaks, one `\r\n`, and a
   blank line (`\r\n\r\n`).
3. Capture the window visually. Confirm all lines exist, no blank extra line
   from `\r\n`, no repeated-character runs, and the character count in the
   Notepad status bar matches the sent text.
4. Confirm duration scales with length: N characters ≈ N × interval.

## History

- 2026-09-03: filed after two input defects. Pacing fix (`e7a3bb6`) and newline
  handling (`SendTextCharacter`). Both were caught only in live testing; the
  invariants above are the regression fence.

## macOS / browser mechanisms and acceptance

The Windows mechanisms above remain unchanged. Native macOS uses scalar-safe
Unicode strokes, collapses CRLF and posts real Return pairs. Its down/up pairs
are preallocated, consecutive and balanced, **not an atomic OS transaction**.
Posting events is not proof that every receiving application delivered them.
The default is the same 20 ms spacing; `PI_OS_TYPE_INTERVAL_MS` accepts 0–1000 ms.
Scheduled pacing over 20 s is refused before focus/input; split long text instead
of silently truncating or racing the tool deadline. The 20,000 UTF-16-unit input
limit also applies.

Return can submit forms or execute terminal commands. Multiline native input
requires an identified authorized multiline destination. Identity, focus,
credential/deletion policy, cancellation and cumulative budgets still apply;
interruption after possible posting is an uncertain failure, never replayed.

Scoped Brave uses private verified `Input.insertText`, not keystroke bursts or
clipboard paste. It normalizes CRLF/CR, permits multiline fill only for textarea
or contenteditable, verifies privately and never synthesizes Enter submission.
Credential input opt-in is not credential extraction; values stay out of snapshots.

Browser fill and keypress recheck the active field, its shadow hosts and page focus
before delivery. Fill also requires a complete replacement selection; unsupported
input selection types are refused. Observed focus or selection loss stops delivery
without refocusing or replay. These CDP checks and input calls are separate: they
reduce the race but do not provide atomic recipient isolation.

Browser key-down/up use the same target session. Cancellation before key-down sends
neither event. Once key-down can have been sent, release is attempted before action
cancellation or reader disposal closes the socket. Each leg has a separate 1.5 s
maximum deadline. Socket loss or a failed release is an uncertain outcome: no
reconnect or replay, and no further mutations in that task.

See `host-macos/ACCEPTANCE.md` for component evidence and pending framework,
slow-editor, keyboard-layout and live-model acceptance. Do not infer broad
application fidelity from a single receiving fixture or a successful OS post.
