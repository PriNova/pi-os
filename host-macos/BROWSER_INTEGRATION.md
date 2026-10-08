# Optional scoped Brave connection

An explicit existing-session path for Brave on macOS. The user enables debugging
and approves the connection through **π menu → Brave Connection…**. The app does not
launch/restart Brave, copy profiles, export cookies, touch browser Local State or
click a connection-approval prompt. Debugging is powerful; enable it only deliberately.

## Identity and transport

- Pre-panel native capture binds executable/PID, selected HTTP(S) tab and window.
- Loopback endpoint ownership/executable is verified, not inferred from a port number.
- Bounded protocol readiness precedes native tab validation; observation-only refresh
  can accommodate navigation of the retained selected tab without selecting a new tab.
- One uniquely matched target is attached. Private connection/validation/invalidation
  routes require the host token and are absent from the model catalog.
- No reconnect, browser/tab restart, profile fallback, unrelated-target selection or
  automatic dialog/consent handling. Transport or identity failure ends that operation.

Some existing Brave installations expose the browser WebSocket directly at
`ws://127.0.0.1:<port>/devtools/browser` without HTTP `/json/version` discovery. The
adapter supports that explicitly configured route; it does not scan arbitrary profiles
or choose another browser. Debugger consent UI varies by Brave version.

## Tools and limits

`browser_snapshot` returns bounded semantic controls from the main document/open
shadow roots. `browser_act` uses short-lived, generation-bound consumed references.
Host pin validation, selected-tab checks, cancellation and uncertainty apply before
mutation. Page content is untrusted data, not instructions. Old references invalidate
on navigation and each follow-up. No mutation replay after an uncertain outcome.

Browser-bound tasks cannot bypass this route through native clicks/keys. Same-tab web
navigation, text fill, limited unmodified keys and scrolling are supported. Frames,
canvas/closed shadows, new tabs, external protocols, browser settings and downloads
are unsupported. Caps: 24,000 snapshot characters / 300 controls / 8,000 traversed
nodes, 20,000 UTF-16 text units, 3,000 CSS-pixel scroll and 60-second reference age.

Username/password input defaults off and follows the host's explicit credential
setting. Their values remain excluded from text snapshots, including enabled mode.
The helper verifies fill privately, normalizes line endings, refuses multiline text
in single-line controls and does not synthesize Enter submission or clipboard paste.
Recognized deletion controls/commands are refused; this is not a filesystem sandbox.

## Acceptance

The branch has guarded helper, session, transport and tool tests. Historical signed
fixtures exercised dummy Like/Delete controls, credential modes and multiline text;
no account actions or actual deletion. The latest UI acceptance did not revalidate
credential-enabled production transport or run a live model. Broader frameworks,
editor fidelity and user-visible consent/navigation/lifecycle matrices remain pending.
Run GUI fixtures only in a coordinated idle window using an already approved browser;
do not automate consent, relax policy or reconnect within a failed invocation.
