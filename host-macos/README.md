# Native macOS host (draft port)

An AppKit/Swift host for the existing TypeScript pi harness. macOS 14+; no Electron,
WebView, alternate RPC stack or new agent implementation. The .NET/WPF host remains
Windows-specific. This port is implemented and fixture-tested, **not full parity or a
notarized distribution**. See [acceptance](ACCEPTANCE.md), [architecture](ARCHITECTURE.md),
[desktop input semantics](../docs/desktop-input-semantics.md) and
[protocol](../shared/protocol/protocol.md).

## Build and run

Requires Xcode command-line tools and Node 24+ on PATH (or `PI_OS_NODE_PATH`). Run
npm commands in `node-harness/`; the repository root has no package.json.

```sh
npm --prefix node-harness ci --ignore-scripts
npm --prefix node-harness run build
host-macos/scripts/run-dev.sh
```

Development builds use native visual-effect material with older Xcode SDKs; Xcode
26+ enables Apple glass on macOS 26+. macOS 14/15 always use the material fallback.
`Control+Option+Command+Space` pins the foreground target before opening the prompt.
`PI_OS_HOTKEY` changes the chord. Control requires signing, Accessibility and PostEvent;
window screenshots require Screen Recording. Missing permissions are actionable errors,
not reasons to disable OS protection. `PI_OS_READ_ONLY=1` limits the agent to observation.

### Signed development install

```sh
PI_OS_SIGN_IDENTITY='Your existing signing certificate' host-macos/scripts/build-app.sh
# Quit the verified, idle installed pi-os first; do not kill processes by image name.
PI_OS_SIGN_IDENTITY='Your existing signing certificate' host-macos/scripts/refresh-install.sh
open -g "$HOME/Applications/pi-os.app"
```

Do not update a Screen Recording-authorized app with ad-hoc signing: its code
requirement may change and strand its permission grant. Installed updates require
a stable certificate. `PI_OS_ALLOW_ADHOC_INSTALL=1` is an explicit disposable-test
choice, never the routine installation recipe. Never edit TCC, weaken code requirements,
disable SIP or globally trust a new certificate to make an install work.

The development app links checkout harness files and uses external Node; it is not
self-contained. `bundle-runtime.sh`/`notarize-app.sh` provide gated packaging recipes,
but official standalone Node, Developer ID, hardened runtime and notarization remain
release-acceptance gates. No certificate or notarization credential is included.

## Whisper UI

A native 480 × 50 pt one-line command bar, bottom-centered on the pinned display's
visible work area. It respects Dock/menu-bar geometry and grows upward for multiline
input. Answers use a detached readable surface. Click π for pinned context and
appearance, or use the menu-bar Appearance window without starting the harness.

System (default), Clear, Frost, Graphite, Warm and Contrast presets are visual only.
Larger text, opacity and 20/32/48 pt spacing are persisted separately from security,
model and resource settings. Reduce Transparency/Increase Contrast force opacity;
Reduce Motion replaces the spinner with a static status symbol. There are no custom
opening/closing animations. True native glass uses NSGlassEffectView when supported,
not CSS blur.

Return submits; Shift-Return inserts a newline; IME marked text is respected. The
reader persists until explicit close. Follow-ups keep SDK history and the original
model/target, but invalidate old action references. Changing appearance never repins,
renews authority or resets budgets. Last-answer recall is text-only. One Mac reader
is retained at a time; replacing it revokes the previous thread.

## Control and trust

Native operations validate exact ownership/window/focus, live permissions, occlusion,
geometry, immutable viewed-image binding, cancellation and cumulative budgets. An
uncertain mutation poisons that context; input is never automatically replayed. Typing
uses Unicode scalars and paced balanced event pairs with real Return strokes, not
clipboard fallback. See the shared semantics contract for limits.

Ordinary apps are not denied by brand on Mac. Recognized file-deletion actions,
Move to Trash and Empty Trash are refused. This is defense in depth, **not a filesystem
no-delete sandbox**: aliases, opaque scripts/custom controls or trusted extensions can
evade heuristics. Native credential input is default-blocked for clearly identified
username/password fields; explicit Settings consent permits input, never extraction.
Values remain omitted from snapshots. Secure Keyboard Entry is never disabled and
does not veto unrelated ordinary fields.

Mac defaults to isolated pinned tools. Explicit acknowledged Trusted pi compatibility
loads global pi resources and coding tools, which execute arbitrary code with app
permissions and are not window-confined. The UI keeps a visible warning. Project
resources remain untrusted. Windows retains its existing global-resource behavior.

Brave is an optional, explicitly configured existing-session CDP path: see
[BROWSER_INTEGRATION.md](BROWSER_INTEGRATION.md). It never restarts a browser, copies
profiles, exports cookies or silently attaches an unrelated page. Browser-bound work
uses scoped browser tools instead of native input. Human connection consent is never
automated.

## Tests

```sh
npm --prefix node-harness run check
npm --prefix node-harness test
npm --prefix node-harness run test:macos
PI_OFFLINE=1 PI_OS_AGENT=0 swift test --jobs 2 --package-path host-macos \
  --skip PresentationTests/testLastAnswerSurvivesDismissalNewPromptAndError
```

Node tests preload a no-live-provider guard and run serially. Swift lifecycle tests
use the same guard. Tests do not need models, provider credentials or permission grants.
Do not bypass the guard or probe local providers during another GPU owner's reservation.

Signed GUI fixtures in `scripts/test-{installed,reader-installed,brave-installed}.py`
are separately opt-in (`PI_OS_INSTALLED_TEST=1`) and require an idle coordinated desktop,
existing permissions/certificate and disposable receiving fixtures. They use dummy
text/credentials, private support directories and an extra Shift in the setup hotkey.
Browser fixtures require an already approved Brave connection and create/close only
fixture tabs. They do not automate consent or act on real accounts. GUI fixture output,
local screenshots and historical installation logs are intentionally not committed.
