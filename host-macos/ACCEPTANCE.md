# Draft-port acceptance

This is component evidence, **not full macOS/Windows parity or release sign-off**.
The PR is based on upstream `9ddcfd4` and preserves its Windows paced input/newline,
persistent reader and sequential follow-up work.

## Reproducible branch checks

Local CPU/model-free validation on this PR branch:

- TypeScript check/build and **72 guarded Node tests** pass.
- **67 Swift tests** pass. `PresentationTests/testLastAnswerSurvivesDismissalNewPromptAndError`
  remains explicitly excluded: its transient main-window test needs reliable GUI acceptance.
- Real Swift loopback server ↔ Node client and supervised harness conformance passes.
- Re-entrant SDK cleanup, abort/timeout, close-during-startup, capacity/TTL, stale action
  authority, credentials, deletion heuristics, field normalization and resource isolation
  have fixture tests. Native appearance control wiring exercises every preset.
- Windows HTTP-client tests assert explicit retained-session opt-in, authentication and
  follow-up availability. Windows/.NET and macOS 14/26 CI are required independent gates;
  local macOS tests alone do not establish their result.

CI uses fresh hosted runners and a no-live-provider guard. No models, provider tokens,
TCC grants, browser consent or notarization/signing secrets are required. Passing these
jobs does not exercise native input, VoiceOver or live-model conversations.

## Historical signed GUI evidence (pre-PR local build)

The source before PR preparation was installed using a stable Apple Development
identity, without changing TCC or credentials. It passed 17 candidate and 17 actual
installed reader/lifecycle checks: pre-panel Carbon pin, sequential multiline follow-ups,
explicit retry after simulated failure, idle warm reservation, disposal/native revocation
and unrelated-window canaries. An earlier UI candidate passed 33 native checks.
A final native rerun passed nine then correctly refused NotificationCenter occlusion;
that stopped rerun is not a full native pass. No system app/protection was disabled.

Default signed dark reader/bar pixels were inspected. Earlier browser fixtures used
only dummy credentials and harmless Like/Delete counters (Delete count remained zero).
The latest credential-enabled production transport was blocked before attachment/input.
These machine-specific logs/screenshots are excluded from the PR; scripts remain for
maintainers to reproduce in a coordinated idle desktop. They do not validate the PR's
later shared-session refactor or Windows UI changes against a signed installed binary.

## Still required before merge/release

- Passing Windows/.NET and both macOS CI jobs; maintainer review of shared lifecycle and
  Windows reader availability behavior. Physical Windows reader/input regression matrix.
- Signed PR-branch native/reader acceptance, real-model conversations and native/browser
  follow-ups in a coordinated provider window. Never probe an occupied local GPU.
- Credential-enabled Brave transport acceptance; broader framework/slow-editor, Finder,
  keyboard-layout, multi-display, full-screen/Spaces/Stage Manager and cancellation matrices.
- Native popup and all-preset light/dark/busy-background review, VoiceOver and physical
  keyboard, zoom/narrow-width, accessibility preferences and older-OS material rendering.
- Notifications/login launch and official self-contained Node runtime, signing, hardened
  runtime/notarization and distribution acceptance.

Deletion labels/shortcuts/known commands are heuristic defenses, not an absolute
filesystem sandbox. Trusted extensions are arbitrary code. Do not promise otherwise.
The PR does not replace a permission grant, automate a debugger approval prompt or
silently retarget/replay an uncertain mutation.
