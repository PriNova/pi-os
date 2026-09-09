# pi-os — experimental macOS native-shell foundation

**This is NOT a complete or usable agent Mac port.** It is a dependency-free
Swift/AppKit shell foothold and local review candidate. It can demonstrate a
menu-bar → prompt → status → reader lifecycle, but it cannot observe or act on
the desktop, answer a question, or connect to an agent. Upstream acceptance of
this platform, scope, transport or distribution is **not assumed**.

Built against public upstream `9ddcfd490c1cbf3aa665834e5a365326ec050ded`.
The [current protocol](../shared/protocol/protocol.md),
[desktop schema](../shared/schemas/desktop-context.ts),
[input semantics](../docs/desktop-input-semantics.md),
[development guide](../DEVELOPMENT.md), and current Windows
[application](../host-dotnet/WindowsHarness.Host/App.xaml.cs) /
[overlay](../host-dotnet/WindowsHarness.Host/Overlay/OverlayWindow.xaml.cs)
were reviewed first. Referenced historical handoff/design documents that are
not present in this checkout are not treated as implemented contracts.

## Implemented foundation

- A text-branded **pi-os** menu-bar app with demonstration, capability notice,
  session-only hotkey configuration/disable, close/cancel, and quit actions.
- Public Carbon `RegisterEventHotKey`, not an event tap or global keyboard
  monitor. Registration failures are visible; a failed replacement preserves
  the previous binding. Quit unregisters owned shortcuts and the handler.
- Nonactivating `NSPanel` surfaces, created as nonactivating from the outset.
  An explicit user invocation makes the prompt key for typing without calling
  `NSApplication.activate`. Submission relinquishes key status. Timer-driven
  reader presentation does not call `makeKey`; it must not intentionally take
  keyboard focus. Actual OS focus/activation behavior is a manual gate.
- An explicitly labeled **demonstration**, with a 1.5-second local timer and
  fixed sample text. Cancel/close invalidate pending completions; late callbacks
  cannot reopen a closed reader. Repeated hotkeys preserve an open draft/demo.
- A read-only, selectable reader. Follow-ups are visibly disabled because
  there is no live agent session. No automatic clipboard copy is performed;
  ordinary user-invoked Copy/Paste in native text controls remains available.
- Pure placement/geometry helpers, hotkey parser/registration replacement helper
  and demonstration state machine with unit tests that do not start AppKit.

There is no SwiftUI, external package dependency, Node process, SDK transport,
HTTP listener, model, memory store, telemetry or application-written log/history.
Hotkey settings exist for this process only. The sample prompt is cleared on
submit/close and is not included in the reader or saved by application code.
This is **not** a secure-memory erasure guarantee; OS text services, swap and
crash reporting are outside that claim. Use synthetic text only.

## Build and test — headless

Proposed deployment floor: **macOS 14**. Build tools: existing Xcode with
Swift 6 or later and a macOS SDK. No package-manager install, signing identity
change, agent login or permissions are required for these commands.

From the repository root:

```bash
host-macos/test.sh
host-macos/build.sh
```

Output: `host-macos/dist/pi-os-dev.app` (ignored by Git).

The scripts also work by absolute path from another working directory. They
keep SwiftPM caches/scratch/config paths under `host-macos/.build/`, disable
SwiftPM Keychain/netrc credential lookup, and use four compiler jobs. Tests
compile the executable but run only `ShellCoreTests`; **neither script launches
the GUI, registers a shortcut, requests permissions or installs the app**.

The development bundle has `LSUIElement = true` and both package and bundle
minimum OS set to 14.0. The build does not invoke `codesign`, change signing
identities, notarize, install a login item, or open the bundle. Apple's linker
may generate its normal ad-hoc executable signature. This is not a signed or
notarized distribution package; Gatekeeper/distribution remains unqualified.
Do not infer macOS 14 runtime compatibility from a newer-SDK headless build.

## Hotkey configuration (for a later authorized manual run)

Default: **Ctrl+Alt+Space** (Alt means Option on macOS).

- Menu → **Configure hotkey…** applies a binding only for the current process.
- `PI_OS_HOTKEY` sets the initial binding when launching the executable from
  an environment that actually contains that variable. Finder launches do not
  generally inherit a shell override. No `launchctl setenv` is needed or used.
- Supported modifiers: `Ctrl`/`Control`, `Alt`/`Option`/`Opt`, `Shift`,
  `Cmd`/`Command`. Case and surrounding whitespace are normalized.
- Supported keys: `Space`, `F1`–`F12`. At least one modifier is required.
  Letters, digits, symbol keys and unmodified keys are deliberately rejected;
  keyboard-layout mapping is not implemented in this foothold.
- Invalid initial configuration does not silently fall back. The menu remains
  available with an error and can configure or disable the shortcut.
- System shortcuts, another app, Secure Input and Fn/media-key settings can
  affect delivery even when Carbon registration succeeds. Registration success
  is not a claim that a live shortcut was tested.

Example **only after desktop testing is separately authorized**:

```bash
PI_OS_HOTKEY='Ctrl+Shift+F9' \
  host-macos/dist/pi-os-dev.app/Contents/MacOS/pi-os-native-shell
```

This command would launch the GUI and register a shortcut. It is not part of
build/test and was **not run** during the headless qualification. Quit from
the pi-os menu to release process-owned UI, timer and shortcut resources.

## Geometry, focus and upstream flow boundaries

Placement uses only `NSScreen` frame/visible-frame metadata and the cursor
location. It does not query the foreground app, window titles or target
contents. It anchors near the top center of the pointer's display, in AppKit
global **points**, with bottom-left origins and possible negative coordinates.
The anchor point is retained across demonstration transitions; each layout
re-resolves current displays. This is not target-window context pinning.

Visible-frame clamping excludes the menu bar/Dock. Oversized panels shrink and
contain scrollable content. The pure helpers handle fractional coordinates,
negative origins, screen gaps, ties, invalid/empty geometry and removed-screen
fallbacks. These are not screenshot pixel conversions and must not be reused
as the Windows input coordinate contract. Continuous screen-change reflow and
Spaces/full-screen policy still need live review.

The latest upstream keeps a live agent session for sequential follow-ups and
closes it when the reader closes. This foundation deliberately has **no**
remote invocation/session, `/followup`, `/close`, authentication, polling or
cancellation transport. Its local reader lifecycle is not protocol parity.
It does not fabricate a Windows `hwnd`, `contextId`, screenshot or successful
tool result. A real Mac context schema/transport needs upstream agreement.

The host-neutral text fidelity, newline and no-clipboard-fallback invariants
in [desktop-input-semantics](../docs/desktop-input-semantics.md) remain binding
for any future input implementation. This shell injects **no** input into
other applications; its own text field is not an input implementation or
verification of those invariants. No Windows or shared Node input code changed.

## Capability and permission gates

Unsupported and absent from this slice:

- Screenshots, ScreenCaptureKit, microphone/system audio, video or recording.
- Accessibility inspection, selected-text capture, input synthesis or CGEvent taps.
- Real models, agent SDK/RPC/HTTP, tools, live follow-ups and memory/persistence.
- Global notification delivery, automatic clipboard output, login items/updaters.

TCC-free is the **source/API design constraint**, not a completed live-desktop
certification: no permission-request/preflight APIs, privacy usage descriptions
or capture/automation entitlements are added. Absence of those declarations is
not a sandbox. Any later capture, AX or input work requires separate scope,
consent/refusal/identity contracts, permission UX and end-to-end tests. Do not
add a permission request just to make this demonstration appear more capable.

## Qualification and remaining manual checks

Headless qualification on 2026-09-09: Apple silicon, macOS 26.5.2, Xcode Swift
6.3.3. **24 XCTest tests passed** (7 demo lifecycle, 7 hotkey, 10 geometry), and
the release development bundle built with warnings treated as errors. Bundle
metadata and the Mach-O deployment target are inspected without executing it.
No GUI/permission/agent test was run. The checkout's existing forensic hook
was reported to have timed out; **no completed security audit is claimed**.

Before any usable-Mac-port claim, separately authorize and perform:

- [ ] Start/quit from the development bundle; verify no permission dialog,
  startup activation, Dock icon, unexpected network or credential access.
- [ ] Invoke from another app; type a synthetic prompt and verify it reaches
  only the shell. Enter, Escape, click-cancel and close behave correctly.
- [ ] Verify the nonactivating panel does not activate pi-os; verify typing
  focus returns to the prior app after submit/cancel. `resignKey()` alone is
  not proof of focus restoration. Do not force-activate another app as a fix.
- [ ] Timer-driven reader appearance must not take focus or overwrite the
  clipboard. Click-to-select, explicit Copy/Paste and keyboard navigation work.
- [ ] Test conflicting/invalid/repeated bindings, disabled hotkeys, Fn keys,
  Secure Input, two instances, and release/restore on quit.
- [ ] Test repeated hotkeys/drafts, rapid submit/cancel/close/quit, opening hotkey
  settings during a demo, and rejected stale completions.
- [ ] Test negative-origin/mixed-scale displays, Dock/menu-bar positions,
  reconnect/rearrange, tiny usable areas, Spaces and full-screen apps.
- [ ] Review layout, scrolling, light/dark/high-contrast appearance, VoiceOver
  labels and focus order on a real desktop. No screenshots were taken here.
- [ ] Qualify actual macOS 14 hardware/runtime and Intel separately, or narrow
  the support claim. Only ARM64 on the recorded host was compiled/tested.
- [ ] Agree upstream scope/transport/schema/release ownership; implement and
  qualify real agent lifecycle and future permission-gated native capabilities
  as separate slices. This local commit is not acceptance or a PR submission.

## Source map and license

- `Sources/ShellCore/`: pure geometry, hotkey and demo-lifecycle helpers.
- `Sources/NativeShell/`: AppKit surfaces, app lifecycle and Carbon registration.
- `Tests/ShellCoreTests/`: no GUI, native registration or permissions.
- `Resources/Info.plist`, `build.sh`, `test.sh`, `scripts/swift.sh`: dev packaging.

MIT, under the upstream [LICENSE](../LICENSE). Native system controls and
pi-os text branding only; no additional brand assets or third-party code.
