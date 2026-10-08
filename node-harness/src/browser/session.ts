import { createHash, randomUUID } from "node:crypto";
import type { HostClient } from "../hostClient.js";
import { BrowserError, CdpConnection, failure, verifyBraveEndpoint, type BrowserConnection, type Cdp } from "./cdp.js";
import { PAGE_SCRIPT } from "./pageScript.js";

export interface BrowserAction { action: "click" | "fill" | "press" | "scroll"; ref: string; text?: string; key?: string; deltaY?: number }
export const BROWSER_KEYS = ["Enter", "Tab", "Escape", "Space", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End"] as const;
export interface BrowserDependencies {
  verifyEndpoint(connection: BrowserConnection, signal?: AbortSignal): Promise<void>;
  connect(port: number, signal?: AbortSignal): Promise<Cdp>;
}
const realDependencies: BrowserDependencies = { verifyEndpoint: verifyBraveEndpoint, connect: CdpConnection.connect };
const WORLD_NAME = `pi-os-${createHash("sha256").update(PAGE_SCRIPT).digest("hex").slice(0, 16)}`;
export function webURL(raw: string): string {
  try {
    const url = new URL(raw);
    if (raw.length > 8192 || !["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new Error();
    return url.href;
  } catch { return failure("browser_page_unsupported", "Only ordinary HTTP(S) pages are supported"); }
}
function sameBounds(a: BrowserConnection["bounds"], b: any): boolean {
  return !!b && [a.x, a.y, a.width, a.height, b.left, b.top, b.width, b.height].every(Number.isFinite)
    && Math.abs(a.x - b.left) <= 1 && Math.abs(a.y - b.top) <= 1 && Math.abs(a.width - b.width) <= 1 && Math.abs(a.height - b.height) <= 1 && b.windowState !== "minimized";
}
const messages: Record<string, string> = {
  browser_stale: "The page or referenced element changed. Take a fresh browser_snapshot before any action.",
  browser_target_changed: "The pinned tab is no longer visible. Start a new task on the intended tab.",
  secure_input: "The destination rejected input. Inspect it before starting a new task.",
  credential_input_blocked: "This clearly identified username/password field is blocked by pi-os. You can enable ‘Allow input in username and password fields’ in pi-os Settings. Other fields and clicks remain available; do not disable macOS Secure Keyboard Entry.",
  file_deletion_blocked: "Computer use cannot delete files, move them to Trash or empty Trash. Do not work around this refusal.",
  browser_unsupported_action: "This element/action is unsupported. Do not work around a refusal using another tool.",
  browser_unsupported_link: "This link downloads a file, opens another tab/app, or uses a non-web URL. This task stays in the pinned tab.",
  browser_occluded: "The element is offscreen or covered. Scroll the page or dismiss the known overlay before using a fresh snapshot.",
  browser_focus_failed: "The referenced field did not receive focus; no typing was attempted.",
};

/** One invocation, one native tab, one socket, one target. No process-wide pool. */
export class BrowserSession {
  private tail: Promise<unknown> = Promise.resolve();
  private client?: Cdp;
  private sessionId?: string;
  private targetId?: string;
  private bound?: BrowserConnection;
  private attempted = false;
  private ended = false;
  private uncertain = false;
  private allowCredentialFields = false;
  private dialog = false;
  private revision = 0;
  private frameId?: string;
  private documentKey?: string;
  private helper?: string;
  private refs = new Set<string>();
  private snapshotRevision = -1;
  private snapshotTime = 0;
  private snapshots = 0;
  private readonly prefix = randomUUID().slice(0, 8);
  private readonly abort = () => { this.ended = true; this.refs.clear(); this.client?.close(); };
  constructor(private host: HostClient, private contextId: string, private signal?: AbortSignal, private dependencies = realDependencies) {
    signal?.addEventListener("abort", this.abort, { once: true });
  }
  /** A new user turn never inherits old DOM action references or resets uncertainty. */
  invalidateReferences(): void { this.refs.clear(); this.snapshotRevision = -1; }
  exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {});
    return result;
  }
  private combined(signal?: AbortSignal): AbortSignal | undefined {
    if (this.signal && signal) return AbortSignal.any([this.signal, signal]);
    return signal ?? this.signal;
  }
  private check(signal?: AbortSignal) {
    signal?.throwIfAborted(); this.signal?.throwIfAborted();
    if (this.ended) failure("browser_disconnected", "The pinned browser connection ended; start a new task");
    if (this.dialog) failure("browser_dialog", "Brave displayed a dialog. Handle it manually and start a new task; no dialog was accepted automatically.");
  }
  private async native(mutation: boolean, action?: BrowserAction, signal?: AbortSignal): Promise<BrowserConnection> {
    this.check(signal);
    const result = await this.host.invokeTool<BrowserConnection>(this.attempted ? "browser.validate" : "browser.connection", {
      contextId: this.contextId, mutation, ...(action ? { action: action.action, characters: action.action === "fill" ? action.text?.length ?? 0 : 0 } : {}),
    }, signal ? AbortSignal.any([signal, AbortSignal.timeout(5000)]) : AbortSignal.timeout(5000));
    this.check(signal);
    if (!result.ok) {
      if (["browser_target_changed", "browser_disabled", "target_gone", "unknown_context", "control_disabled", "secure_input", "accessibility_denied", "input_permission_denied", "target_elevated", "policy_blocked"].includes(result.error.code)) this.abort();
      throw new BrowserError(result.error.code, result.error.message);
    }
    const value = result.result;
    if (!value || !Number.isInteger(value.port) || !Number.isInteger(value.processId) || !value.bounds) failure("browser_unavailable", "Invalid native browser metadata");
    webURL(value.url); webURL(value.initialURL);
    // This permission comes only from the authenticated native host, never tool input.
    this.allowCredentialFields = value.allowCredentialFields === true;
    if (this.bound && (value.processId !== this.bound.processId || value.port !== this.bound.port || value.initialURL !== this.bound.initialURL)) {
      failure("browser_target_changed", "Native browser identity changed; start a new task");
    }
    return value;
  }
  private async connect(signal?: AbortSignal): Promise<void> {
    if (this.client) return;
    this.check(signal);
    if (this.attempted) failure("browser_disconnected", "Connection was already attempted. Fix Brave Setup and start a new task; no automatic reconnect.");
    const connection = await this.native(false, undefined, signal);
    this.attempted = true;
    if (webURL(connection.initialURL) !== webURL(connection.url)) failure("browser_target_changed", "The page navigated after the hotkey and before connection; start a new task");
    this.bound = connection;
    await this.dependencies.verifyEndpoint(connection, signal);
    this.check(signal);
    const client = await this.dependencies.connect(connection.port, signal);
    this.client = client;
    client.onEvent((method, params, sessionId) => {
      if (method === "connection.closed") { this.ended = true; this.refs.clear(); return; }
      if (method === "Target.detachedFromTarget" && params.sessionId === this.sessionId) { this.ended = true; this.refs.clear(); return; }
      if (sessionId !== this.sessionId) return;
      if (method === "Page.javascriptDialogOpening") { this.dialog = true; this.refs.clear(); }
      if (method === "Runtime.executionContextsCleared" || method === "Page.frameNavigated" || method === "Page.navigatedWithinDocument") {
        this.revision++; this.refs.clear(); this.helper = undefined;
      }
    });
    try {
      await this.native(false, undefined, signal); // Permission/PID/tab could have changed while consent was pending.
      const targets = (await client.call<{ targetInfos: any[] }>("Target.getTargets", {}, undefined, signal)).targetInfos;
      if (!Array.isArray(targets) || targets.length > 2048) failure("browser_target_unknown", "Browser target list is unavailable or too large");
      const candidates = targets.filter(t => t.type === "page" && t.url === webURL(connection.initialURL));
      if (candidates.length > 16) failure("browser_target_ambiguous", "Too many identical tabs; keep only one copy in the chosen window");
      const matches: string[] = [];
      for (const target of candidates) {
        const result = await client.call("Browser.getWindowForTarget", { targetId: target.targetId }, undefined, signal);
        if (sameBounds(connection.bounds, result.bounds)) matches.push(target.targetId);
      }
      if (matches.length !== 1) failure("browser_target_ambiguous", "The pinned page does not match exactly one Brave tab/window. Close duplicate copies in that window or start a new task on a unique page.");
      this.targetId = matches[0]!;
      const verified = await this.native(false, undefined, signal);
      if (verified.url !== connection.url || !sameBounds(verified.bounds, { left: connection.bounds.x, top: connection.bounds.y, ...connection.bounds })) {
        failure("browser_target_changed", "The pinned tab changed during connection; start a new task");
      }
      const attached = await client.call<{ sessionId: string }>("Target.attachToTarget", { targetId: this.targetId, flatten: true }, undefined, signal);
      this.sessionId = attached.sessionId;
      await this.page("Page.enable", {}, signal);
      await this.page("Runtime.enable", {}, signal);
      await this.frame(verified, signal);
    } catch (error) { client.close(); throw error; }
  }
  private page<T = any>(method: string, params: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
    this.check(signal);
    if (!this.client || !this.sessionId) failure("browser_disconnected", "No pinned browser session");
    return this.client!.call<T>(method, params, this.sessionId, signal);
  }
  private async frame(native: BrowserConnection, signal?: AbortSignal) {
    const { frameTree } = await this.page("Page.getFrameTree", {}, signal);
    const frame = frameTree?.frame;
    if (!frame?.id || !frame.loaderId || webURL(frame.url) !== webURL(native.url)) failure("browser_stale", "Native tab and browser document do not agree; take a fresh snapshot");
    const win = await this.client!.call("Browser.getWindowForTarget", { targetId: this.targetId }, undefined, signal);
    if (!sameBounds(native.bounds, win.bounds)) failure("browser_target_changed", "Browser target left the pinned native window");
    const key = `${frame.id}/${frame.loaderId}/${frame.url}`;
    if (key !== this.documentKey) { this.refs.clear(); this.helper = undefined; this.revision++; this.documentKey = key; }
    this.frameId = frame.id;
    return frame;
  }
  private async world(signal?: AbortSignal) {
    if (this.helper) return;
    const world = await this.page("Page.createIsolatedWorld", { frameId: this.frameId, worldName: WORLD_NAME }, signal);
    const installed = await this.page("Runtime.evaluate", { expression: PAGE_SCRIPT, contextId: world.executionContextId, returnByValue: true }, signal);
    if (installed.exceptionDetails) failure("browser_script_failed", "The isolated browser helper could not initialize");
    const result = await this.page("Runtime.evaluate", { expression: "globalThis.__piBrowser", contextId: world.executionContextId, returnByValue: false, objectGroup: "pi-os" }, signal);
    if (!result.result?.objectId) failure("browser_script_failed", "The isolated browser helper is unavailable");
    this.helper = result.result.objectId;
  }
  private async helperCall(method: "snapshot" | "inspect" | "act" | "verifyFill" | "clear", args: unknown[], signal?: AbortSignal) {
    if (!this.helper) failure("browser_stale", messages.browser_stale!);
    const result = await this.page("Runtime.callFunctionOn", { objectId: this.helper,
      functionDeclaration: "function(method,args){return this[method](...args)}", arguments: [{ value: method }, { value: args }], returnByValue: true }, signal);
    if (result.exceptionDetails) failure("browser_script_failed", "The pinned page operation failed; do not retry a mutation");
    return result.result?.value;
  }
  snapshot(filter = "", toolSignal?: AbortSignal): Promise<{ text: string; truncated: boolean }> {
    return this.exclusive(async () => {
      const signal = this.combined(toolSignal);
      this.check(signal);
      if (typeof filter !== "string" || filter.length > 120) failure("invalid_arguments", "Snapshot filter is limited to 120 characters");
      await this.connect(signal);
      const native = await this.native(false, undefined, signal);
      await this.frame(native, signal); await this.world(signal);
      const revision = this.revision;
      const result = await this.helperCall("snapshot", [filter.toLowerCase(), `r${this.prefix}-${++this.snapshots}-`, this.allowCredentialFields], signal);
      this.check(signal);
      await this.frame(await this.native(false, undefined, signal), signal);
      if (this.revision !== revision) failure("browser_stale", messages.browser_stale!);
      if (typeof result?.text !== "string" || result.text.length > 24500) failure("browser_script_failed", "Invalid or oversized page snapshot");
      this.refs = new Set([...result.text.matchAll(/^\[([^\]\n]+)\]/gm)].map(m => m[1]!));
      this.snapshotRevision = revision; this.snapshotTime = Date.now();
      return { text: result.text, truncated: !!result.truncated };
    });
  }
  act(action: BrowserAction, toolSignal?: AbortSignal): Promise<{ performed: true; verification: string }> {
    return this.exclusive(async () => {
      const signal = this.combined(toolSignal);
      this.check(signal);
      validateAction(action);
      if (action.action === "fill") action = { ...action, text: action.text!.replace(/\r\n|\r/g, "\n") };
      if (this.uncertain) failure("input_failed", "A prior browser action had an uncertain outcome. No more mutations in this task.");
      if (!this.refs.has(action.ref) || this.snapshotRevision !== this.revision || Date.now() - this.snapshotTime > 60_000) failure("browser_stale", messages.browser_stale!);
      await this.frame(await this.native(false, undefined, signal), signal);
      if (!this.refs.has(action.ref)) failure("browser_stale", messages.browser_stale!);
      const checked = await this.helperCall("inspect", [action.ref, action.action, action.key, this.allowCredentialFields, action.text], signal);
      this.requireOK(checked);
      await this.frame(await this.native(true, action, signal), signal);
      this.check(signal);
      if (!this.refs.has(action.ref) || this.snapshotRevision !== this.revision) failure("browser_stale", messages.browser_stale!);
      let mutated = false;
      try {
        // The helper repeats visibility, element/context identity, secure/deletion/link
        // checks in the same JS turn as the click/focus/scroll. No model-supplied script.
        mutated = true;
        const result = await this.helperCall("act", [action.ref, action.action, action.key, action.deltaY, this.allowCredentialFields, action.text], signal);
        if (result?.error && result.error !== "browser_focus_failed") mutated = false;
        this.requireOK(result);
        if (action.action === "fill") {
          this.requireOK(await this.helperCall("inspect", [action.ref, action.action, action.key, this.allowCredentialFields, action.text], signal));
          await this.page("Input.insertText", { text: action.text }, signal);
          const verified = await this.helperCall("verifyFill", [action.ref, action.text, this.allowCredentialFields], signal);
          if (verified !== true) failure("input_failed", "Text delivery was not verified. Do not retry.");
        } else if (action.action === "press") {
          const key = action.key === "Space" ? " " : action.key!;
          const codes: Record<string, number> = { Enter: 13, Tab: 9, Escape: 27, Space: 32, Backspace: 8, Delete: 46, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35 };
          const params = { key, code: action.key, windowsVirtualKeyCode: codes[action.key!], ...(action.key === "Enter" ? { text: "\r" } : action.key === "Space" ? { text: " " } : {}) };
          await this.page("Input.dispatchKeyEvent", { type: "keyDown", ...params }, signal);
          await this.page("Input.dispatchKeyEvent", { type: "keyUp", key, code: action.key, windowsVirtualKeyCode: codes[action.key!] }, signal);
        }
        this.check(signal);
        return { performed: true, verification: action.action === "fill" ? "Text value verified. Take browser_snapshot to verify the page's resulting state." : "Action dispatched once. Take browser_snapshot and verify the requested postcondition before claiming success." };
      } catch (error) {
        if (mutated) {
          this.uncertain = true;
          await this.host.invokeTool("browser.invalidate", { contextId: this.contextId }, AbortSignal.timeout(1500)).catch(() => {});
        }
        throw error;
      } finally { this.refs.clear(); }
    });
  }
  private requireOK(result: any) {
    if (result?.ok === true) return;
    const code = result?.error in messages ? result.error as string : "browser_script_failed";
    if (code === "file_deletion_blocked" || code === "secure_input") this.uncertain = true;
    if (code === "browser_target_changed") this.abort();
    failure(code, messages[code] ?? "The browser helper could not verify this action");
  }
  async dispose() {
    this.signal?.removeEventListener("abort", this.abort);
    this.refs.clear();
    try {
      if (this.client && this.sessionId && !this.ended) {
        if (this.helper && !this.dialog) {
          await this.helperCall("clear", [], AbortSignal.timeout(500)).catch(() => {});
          await this.client.call("Runtime.releaseObjectGroup", { objectGroup: "pi-os" }, this.sessionId, AbortSignal.timeout(500)).catch(() => {});
        }
        await this.client.call("Target.detachFromTarget", { sessionId: this.sessionId }, undefined, AbortSignal.timeout(1000)).catch(() => {});
      }
    } finally { this.ended = true; this.client?.close(); }
  }
}

export function validateAction(action: BrowserAction): void {
  if (!action || !["click", "fill", "press", "scroll"].includes(action.action) || typeof action.ref !== "string" || action.ref.length > 100) failure("invalid_arguments", "Use an action and a current browser snapshot reference");
  if (action.action === "fill" && (typeof action.text !== "string" || action.text.length > 20_000)) failure("invalid_arguments", "Text is limited to 20,000 UTF-16 units");
  if (action.action === "press" && !BROWSER_KEYS.includes(action.key as typeof BROWSER_KEYS[number])) failure("invalid_arguments", "Unsupported browser key");
  if (action.action === "scroll" && (!Number.isFinite(action.deltaY) || !action.deltaY || Math.abs(action.deltaY) > 3000)) failure("invalid_arguments", "Scroll requires a non-zero deltaY within 3000 CSS pixels");
}
