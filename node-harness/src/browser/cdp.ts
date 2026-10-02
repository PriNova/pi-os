import { createRequire } from "node:module";
import type { EventEmitter } from "node:events";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export class BrowserError extends Error {
  constructor(readonly code: string, message: string) { super(`${code}: ${message}`); }
}
export const failure = (code: string, message: string): never => { throw new BrowserError(code, message); };
export interface BrowserConnection {
  processId: number; port: number; initialURL: string; url: string;
  allowCredentialFields?: boolean;
  bounds: { x: number; y: number; width: number; height: number };
}
export interface Cdp {
  call<T = any>(method: string, params?: Record<string, unknown>, sessionId?: string, signal?: AbortSignal): Promise<T>;
  onEvent(listener: (method: string, params: any, sessionId?: string) => void): void;
  close(): void;
}
interface Socket extends EventEmitter { readyState: number; send(data: string): void; terminate(): void; close(): void }
const require = createRequire(import.meta.url);
const SocketClass = require("ws") as new (url: string, options: Record<string, unknown>) => Socket;
const exec = promisify(execFile);

/** No generic port scan, profile files, executable override, shell, or browser launch. */
export async function verifyBraveEndpoint(connection: BrowserConnection, signal?: AbortSignal): Promise<void> {
  const { processId, port } = connection;
  if (process.platform !== "darwin" || !Number.isInteger(processId) || processId <= 1 || !Number.isInteger(port) || port < 1 || port > 65535) {
    failure("browser_unavailable", "Invalid native Brave connection");
  }
  try {
    const { stdout: executable } = await exec("/bin/ps", ["-p", String(processId), "-o", "comm="], { signal, timeout: 2000, maxBuffer: 65536 });
    if (executable.trim() !== "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser") failure("browser_unavailable", "Unexpected Brave executable");
    const { stdout } = await exec("/usr/sbin/lsof", ["-nP", "-a", "-p", String(processId), `-iTCP:${port}`, "-sTCP:LISTEN", "-Fn"], { signal, timeout: 2000, maxBuffer: 65536 });
    const addresses = stdout.split("\n").filter(line => line.startsWith("n")).map(line => line.slice(1));
    if (!addresses.includes(`127.0.0.1:${port}`) || addresses.some(address => ![`127.0.0.1:${port}`, `[::1]:${port}`].includes(address))) {
      failure("browser_unavailable", "Brave endpoint is absent or is not loopback-only");
    }
  } catch {
    signal?.throwIfAborted();
    failure("browser_unavailable", "Enable remote debugging in brave://inspect/#remote-debugging and set the matching port in pi-os Settings → Brave Setup. No other browser was opened.");
  }
}

const methods = new Set([
  "Browser.getVersion", "Browser.getWindowForTarget", "Target.getTargets", "Target.getTargetInfo",
  "Target.attachToTarget", "Target.detachFromTarget", "Page.enable", "Page.getFrameTree", "Page.createIsolatedWorld",
  "Runtime.enable", "Runtime.evaluate", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup",
  "DOM.resolveNode", "Accessibility.getFullAXTree", "Accessibility.getPartialAXTree",
  "Input.insertText", "Input.dispatchKeyEvent",
]);

/** Bounded, cancellable transport. Never reconnects or retries; raw CDP is not a model tool. */
export class CdpConnection implements Cdp {
  private nextId = 0;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; clean: () => void }>();
  private listeners: ((method: string, params: any, sessionId?: string) => void)[] = [];
  private closed = false;
  private constructor(private socket: Socket, private timeoutMs: number) {
    socket.on("message", (bytes: Buffer) => {
      let message: any;
      try { message = JSON.parse(bytes.toString("utf8")); } catch { this.close(); return; }
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id); pending.clean();
        if (message.error) pending.reject(new BrowserError("browser_protocol_error", "Brave rejected a scoped operation; no automatic retry"));
        else pending.resolve(message.result);
      } else if (typeof message.method === "string") {
        for (const listener of this.listeners) listener(message.method, message.params ?? {}, message.sessionId);
      }
    });
    socket.on("error", () => this.close());
    socket.on("close", () => this.close());
  }
  static async connect(port: number, signal?: AbortSignal, timeoutMs = 10_000, consentMs = 60_000): Promise<CdpConnection> {
    signal?.throwIfAborted();
    if (!Number.isInteger(port) || port < 1 || port > 65535) failure("browser_unavailable", "Invalid browser port");
    const socket = new SocketClass(`ws://127.0.0.1:${port}/devtools/browser`, {
      handshakeTimeout: consentMs, maxPayload: 8 * 1024 * 1024, perMessageDeflate: false, followRedirects: false,
    });
    // Install handlers before awaiting a human permission dialog.
    const connection = new CdpConnection(socket, consentMs);
    try {
      await new Promise<void>((resolve, reject) => {
        const cleanup = () => { signal?.removeEventListener("abort", abort); socket.removeListener("open", opened); socket.removeListener("error", error); socket.removeListener("close", error); };
        const opened = () => { cleanup(); resolve(); };
        const error = () => { cleanup(); reject(new BrowserError("browser_unavailable", "Brave connection was denied, closed or unavailable. Check Brave Setup; no replacement browser was launched.")); };
        const abort = () => { cleanup(); connection.close(); reject(new BrowserError("browser_cancelled", "Connection cancelled")); };
        socket.once("open", opened); socket.once("error", error); socket.once("close", error);
        signal?.addEventListener("abort", abort, { once: true });
        if (signal?.aborted) abort();
      });
      // A WebSocket upgrade is not proof that Brave's consent/UI transition has
      // completed. Wait for a real protocol response before checking the native tab.
      await connection.call("Browser.getVersion", {}, undefined, signal);
      connection.timeoutMs = timeoutMs;
      return connection;
    } catch (error) { connection.close(); throw error; }
  }
  onEvent(listener: (method: string, params: any, sessionId?: string) => void) { this.listeners.push(listener); }
  call<T = any>(method: string, params: Record<string, unknown> = {}, sessionId?: string, signal?: AbortSignal): Promise<T> {
    signal?.throwIfAborted();
    if (this.closed || this.socket.readyState !== 1) failure("browser_disconnected", "Browser connection ended; start a new task");
    if (!methods.has(method)) failure("policy_blocked", "CDP method is outside the first-party browser adapter");
    if (this.pending.size >= 8) failure("browser_busy", "Too many pending browser operations");
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const abort = () => { this.close(); };
      const timer = setTimeout(() => {
        this.pending.delete(id); clean();
        reject(new BrowserError("browser_timeout", "Browser operation timed out; outcome may be uncertain. Do not retry a mutation."));
        this.close();
      }, this.timeoutMs);
      const clean = () => { clearTimeout(timer); signal?.removeEventListener("abort", abort); };
      this.pending.set(id, { resolve, reject, clean });
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) { abort(); return; }
      try { this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); }
      catch { this.close(); }
    });
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) { pending.clean(); pending.reject(new BrowserError("browser_disconnected", "Browser connection ended; no mutation retry")); }
    this.pending.clear();
    this.socket.terminate(); // Disconnect only. Never Browser.close / Target.closeTarget.
    for (const listener of this.listeners) listener("connection.closed", {});
    this.listeners = [];
  }
}
