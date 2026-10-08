# Architecture and simplification review

## Keep the two existing responsibilities

```text
AppKit host                       TypeScript harness
hotkey + pre-panel target pin      one pi SDK conversation
permissions + context leases      model/resource selection
AX / SCK / native event dispatch   normalized tool interface
native UI + Node supervision       bounded retained threads
            authenticated loopback HTTP
```

The host is the authority on OS identity, permissions and event delivery. The harness
owns conversation history and translates agent tools, but cannot grant permissions or
change the native pin. No additional service, alternate RPC protocol, generic desktop
agent framework or production WebView is needed.

Optional Brave tools retain the same boundary: the host pins the selected native tab
and privately validates it; a small CDP adapter owns one target, isolated-world helper,
semantic references and uncertainty. Connection capabilities are not model tools.

## Simplifications made while preparing the PR

- **One thread registry:** remove upstream's now-unused LiveSessionStore instead of
  keeping a second eviction policy next to the server's bounded lifecycle map. Capacity
  is refused, never satisfied by silently closing someone else's reader.
- **No runner/session import cycle:** result extraction and abort classification live
  with the SDK transport owner. The runner builds context/model/resources; the session
  wrapper handles events, sequential prompts and one cleanup promise.
- **Re-entrant cleanup:** publish the single close promise before SDK disposal can
  invoke callbacks. Disposal exceptions still release browser/provider resources.
- **Explicit retention on both hosts:** Windows' existing follow-up reader sends
  retainSession=true, just like Mac. One-shot callers remain explicit/default-compatible;
  retention does not silently depend on the server OS. Windows displays whether the
  thread remains usable after completion/cancel/timeout.
- **No Windows input rewrite:** preserve upstream's paced SendInput, newline handling,
  reader persistence and follow-up behavior. Windows changes are confined to shared
  authentication and retained-thread wire/UI availability.
- **Native material, not a UI subsystem:** AppKit controls with appearance tokens; SDK
  guards allow an older-Xcode material build and newer-Xcode glass build.
- **Bounded production logs:** failure detail remains in authenticated in-memory status,
  not console logs; capture paths/image capabilities and prompt contents are omitted.
- Exclude experimental HTML, machine-specific QA records, build products and local
  acceptance diaries from the implementation PR.

## Deliberately not collapsed

Ownership/focus, geometry/occlusion, screenshot provenance, credential policy,
deletion heuristics, cancellation and budgets protect different failure modes.
Combining them into a generic "allowed" flag would hide uncertainty and make review
harder, not simpler. Context expiry and conversation retention remain separate.

Trusted-resource provider bootstrap remains a public-SDK lifecycle adapter. Provider
registration must precede model selection, and loaded extension closures must remain
valid until the real session closes. Removing it through private SDK internals or a
model switch that writes global pi settings would trade clarity for behavior changes.
A future public SDK provider-registration hook could eliminate that extra bootstrap.

The Node server still owns HTTP status, active cancellation and retained threads in
one place. Extracting a broad session manager/state-machine framework is deferred:
current race/capacity/expiry tests make this small ownership model directly reviewable.

## Remaining boundaries

All native input refusals fail closed; no retargeting or uncertain-input replay.
Trusted extensions are arbitrary code, not sandboxed. Deletion checks cannot prove
that arbitrary scripts/aliases or custom widgets will not delete files. TCC/signing
identity cannot be replaced by an app preference. Fixture tests are not evidence of
complete editor fidelity, live-model parity or a releasable distribution.
