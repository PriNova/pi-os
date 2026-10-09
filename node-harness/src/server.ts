import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { loadConfig, type HarnessConfig } from "./config.js";
import { HostClient, type DesktopContextSnapshot, type ScreenshotRef } from "./hostClient.js";
import { InvocationStore, type InvocationRecord } from "./invocations.js";
import { abortError, createLiveSession, promptFirst, promptFollowup, type AgentRunOptions, type LiveAgentSession } from "./agent/agentRunner.js";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { createModelCatalogContext, listAvailableModels } from "./agent/modelCatalog.js";
import { AgentModelSettings, type ModelSelection } from "./agent/modelSettings.js";
import { AgentResourceSettings, TRUST_WARNING } from "./agent/resourceSettings.js";
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";

/**
 * Node agent harness HTTP surface per shared/protocol/protocol.md:
 * - GET  /health
 * - POST /invoke            (202, async processing)
 * - GET  /invocations/{id}  (execution status)
 *
 * Bound to loopback only. All non-health routes require X-Harness-Token.
 */

class RequestError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

interface InvokeBody {
  invocationId?: unknown;
  contextId?: unknown;
  prompt?: unknown;
  invokedAt?: unknown;
  retainSession?: unknown;
  includeScreenshot?: unknown;
}

export interface HarnessServerOptions {
  onInvocation?: (record: InvocationRecord) => Promise<void>;
  /** Fixture injection; production always creates the isolated SDK session. */
  createSession?: (options: AgentRunOptions) => Promise<LiveAgentSession>;
  modelSettings?: AgentModelSettings;
  resourceSettings?: AgentResourceSettings;
  modelRuntimeFactory?: (trustedResources: boolean) => Promise<ModelRuntime>;
  /** Deterministic expiry clock for fixture tests. */
  now?: () => number;
}

/** Bookkeeping for one in-flight invocation (A.3: cancel + timeout). */
interface RunningInvocation {
  controller: AbortController;
  timedOut: boolean;
  timer?: NodeJS.Timeout;
}

interface ThreadEntry { live?: LiveAgentSession; expires: number; readOnly?: boolean }
const MAX_THREADS = 20;
const THREAD_TTL_MS = 30 * 60_000;

export class HarnessServer {
  private readonly threads = new Map<string, ThreadEntry>();
  private stopping = false;
  readonly invocations = new InvocationStore();
  private readonly running = new Map<string, RunningInvocation>();
  private readonly server: Server;
  /** Settings-page model choice applied to every new invocation. */
  private readonly modelSettings: AgentModelSettings;
  private readonly resourceSettings: AgentResourceSettings;

  constructor(
    private readonly config: HarnessConfig = loadConfig(),
    private readonly options: HarnessServerOptions & { hostClient?: HostClient } = {},
  ) {
    this.modelSettings = options.modelSettings ?? new AgentModelSettings();
    this.resourceSettings = options.resourceSettings ?? new AgentResourceSettings();
    this.options.hostClient ??= new HostClient(config);
    this.server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000 }, (request, response) => {
      void this.handle(request, response);
    });
  }

  listen(): Promise<number> {
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      // Loopback only; never bind 0.0.0.0 (protocol.md).
      this.server.listen(this.config.port, "127.0.0.1", () => {
        resolve((this.server.address() as { port: number }).port);
      });
    });
  }

  close(): Promise<void> {
    this.stopping = true;
    for (const id of this.threads.keys()) void this.closeThread(id);
    for (const entry of this.running.values()) {
      entry.controller.abort();
      if (entry.timer) clearTimeout(entry.timer);
    }
    return new Promise((resolve, reject) => {
      this.server.close((error) => (error ? reject(error) : resolve()));
      this.server.closeAllConnections();
    });
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      const route = `${request.method} ${url.pathname}`;

      if (route === "GET /health") {
        return this.json(response, 200, {
          service: "node-harness",
          version: "0.1.0",
          uptimeSeconds: Math.round(process.uptime()),
          // Non-secret spawn identity prevents readiness attaching to a different listener.
          sessionId: process.env.PI_OS_SESSION_ID,
        });
      }

      if (!this.authorized(request)) {
        return this.json(response, 401, {
          error: { code: "unauthorized", message: "Missing or wrong X-Harness-Token" },
        });
      }

      if (route === "POST /invoke") {
        await this.handleInvoke(request, response);
        return;
      }

      if (route === "GET /models") {
        // Catalog for the host settings page; 500s flow through handle().
        return this.json(response, 200, {
          models: await this.withModelRuntime(runtime => listAvailableModels(runtime)),
          current: this.modelSettings.get(),
        });
      }

      if (route === "GET /settings/resources") {
        return this.json(response, 200, { current: this.resourceSettings.get(), warning: TRUST_WARNING });
      }
      if (route === "POST /settings/resources") {
        const body = await this.readJson(request) as { mode?: unknown; acknowledgeUnpinnedAccess?: unknown } | null;
        if (!body || !["isolated", "trustedGlobal"].includes(body.mode as string)
          || (body.mode === "trustedGlobal" && body.acknowledgeUnpinnedAccess !== true)) {
          return this.json(response, 400, { error: { code: "invalid_arguments", message: "mode and explicit trust acknowledgement are required" } });
        }
        if (body.mode === "trustedGlobal" && (this.config.readOnly || !(await this.hostAllowsInput()))) {
          return this.json(response, 409, { error: { code: "control_disabled", message: "Trusted compatibility requires the signed native host's computer-control permissions first" } });
        }
        const current = this.resourceSettings.set(body.mode as "isolated" | "trustedGlobal", body.acknowledgeUnpinnedAccess === true);
        return this.json(response, 200, { current });
      }

      if (route === "POST /settings/model") {
        await this.handleSetModel(request, response);
        return;
      }

      const invocationMatch = /^\/invocations\/([\w-]+)$/.exec(url.pathname);
      if (request.method === "GET" && invocationMatch) {
        const record = this.invocations.get(invocationMatch[1] as string);
        if (!record) {
          return this.json(response, 404, {
            error: { code: "not_found", message: `Unknown invocation '${invocationMatch[1]}'` },
          });
        }
        return this.json(response, 200, record);
      }

      const cancelMatch = /^\/invocations\/([\w-]+)\/cancel$/.exec(url.pathname);
      if (request.method === "POST" && cancelMatch) {
        return this.handleCancel(cancelMatch[1] as string, response);
      }

      const followupMatch = /^\/invocations\/([\w-]+)\/followup$/.exec(url.pathname);
      if (request.method === "POST" && followupMatch) {
        return await this.handleFollowup(followupMatch[1]!, request, response);
      }
      const closeMatch = /^\/invocations\/([\w-]+)\/close$/.exec(url.pathname);
      if (request.method === "POST" && closeMatch) {
        const id = closeMatch[1]!;
        this.running.get(id)?.controller.abort();
        await this.closeThread(id);
        return this.json(response, 200, { closed: true, invocationId: id });
      }
      this.json(response, 404, { error: { code: "not_found", message: `No route: ${route}` } });
    } catch (error) {
      const status = error instanceof RequestError ? error.status : error instanceof SyntaxError ? 400 : 500;
      this.json(response, status, {
        error: { code: status < 500 ? "invalid_arguments" : "internal_error", message: error instanceof Error ? error.message : String(error) },
      });
    }
  }

  private async handleInvoke(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = (await this.readJson(request)) as InvokeBody | null;
    if (!body || typeof body !== "object") {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "Body must be a JSON object" },
      });
    }

    const { contextId, prompt } = body;
    if (typeof contextId !== "string" || typeof prompt !== "string" || !prompt.trim() || prompt.length > 20_000
      || (body.retainSession !== undefined && typeof body.retainSession !== "boolean")
      || (body.includeScreenshot !== undefined && typeof body.includeScreenshot !== "boolean")) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "contextId (string) and prompt (non-empty string) are required" },
      });
    }

    if (body.invocationId !== undefined && (typeof body.invocationId !== "string"
      || !/^[\w-]{1,128}$/.test(body.invocationId))) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "Invalid invocationId" } });
    }
    if (typeof body.invocationId === "string" && this.invocations.get(body.invocationId)) {
      return this.json(response, 409, { error: { code: "duplicate_invocation", message: "Invocation already exists; it was not re-executed" } });
    }

    this.expireThreads();
    if (body.retainSession === true && this.threads.size >= MAX_THREADS) {
      return this.json(response, 409, { error: { code: "thread_limit", message: "Close an existing reader before starting another thread" } });
    }
    const record = this.invocations.create(
      contextId,
      prompt,
      typeof body.invokedAt === "string" ? body.invokedAt : new Date().toISOString(),
      typeof body.invocationId === "string" ? body.invocationId : undefined,
      body.includeScreenshot !== false,
    );

    if (body.retainSession === true) this.threads.set(record.invocationId, { expires: (this.options.now?.() ?? Date.now()) + THREAD_TTL_MS });
    console.log(`[invoke] id=${record.invocationId}`);
    console.log(`[invoke] invokedAt=${record.invokedAt}`);

    this.json(response, 202, { accepted: true, invocationId: record.invocationId });

    // Async processing after the 202 is out.
    void this.processInvocation(record);
  }

  /** POST /settings/model — validate + store the settings-page model choice.
   *  Validation uses the live pi catalog so unauthenticated/unknown models are
   *  rejected here instead of failing an invocation later. */
  private async handleSetModel(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = (await this.readJson(request)) as Partial<ModelSelection> | null;
    const { provider, modelId, thinkingLevel } = body ?? {};
    if (typeof provider !== "string" || typeof modelId !== "string"
      || typeof thinkingLevel !== "string" || !provider || !modelId || !thinkingLevel) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "provider, modelId and thinkingLevel (non-empty strings) are required" },
      });
    }

    const available = await this.withModelRuntime(runtime => runtime.getAvailable());
    const model = available.find(model => model.provider === provider && model.id === modelId);
    if (!model) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: `model ${provider}/${modelId} is not available in the pi catalog` },
      });
    }
    const selection = { provider, modelId, thinkingLevel };
    const supported = getSupportedThinkingLevels(model) as string[];
    if (!supported.includes(thinkingLevel)) {
      return void this.json(response, 400, {
        error: {
          code: "invalid_arguments",
          message: `model ${provider}/${modelId} supports effort levels [${supported.join(", ")}], got '${thinkingLevel}'`,
        },
      });
    }

    const previous = this.modelSettings.set(selection);
    const describe = (s: ModelSelection | null) =>
      s ? `${s.provider}/${s.modelId} effort=${s.thinkingLevel}` : "pi automatic default";
    console.log(`[settings] model switched: ${describe(previous)} -> ${describe(selection)}`);

    return this.json(response, 200, { current: selection });
  }

  private async hostAllowsInput(signal?: AbortSignal): Promise<boolean> {
    const tools = await this.options.hostClient!.getToolNames(signal);
    return ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"].every(name => tools.includes(name));
  }
  private async withModelRuntime<T>(use: (runtime: ModelRuntime) => Promise<T>): Promise<T> {
    const trusted = this.resourceSettings.get().mode === "trustedGlobal" && !this.config.readOnly && await this.hostAllowsInput();
    if (this.options.modelRuntimeFactory) return use(await this.options.modelRuntimeFactory(trusted));
    const context = await createModelCatalogContext(trusted);
    try { return await use(context.runtime); } finally { context.dispose(); }
  }

  /** POST /invocations/{id}/cancel — request cancellation of a running invocation. */
  private handleCancel(id: string, response: ServerResponse): void {
    if (!this.invocations.get(id)) {
      return this.json(response, 404, {
        error: { code: "not_found", message: `Unknown invocation '${id}'` },
      });
    }

    const entry = this.running.get(id);
    if (!entry || entry.controller.signal.aborted) {
      return this.json(response, 409, {
        error: { code: "not_running", message: `Invocation '${id}' is not running` },
      });
    }

    console.log(`[invoke] cancel requested id=${id}`);
    entry.controller.abort();
    this.json(response, 202, { accepted: true, invocationId: id });
  }

  private async closeThread(id: string): Promise<void> {
    const thread = this.threads.get(id);
    this.threads.delete(id); // Revoke before awaiting cleanup; startup cannot resurrect it.
    const record = this.invocations.get(id);
    if (record) record.followupAvailable = false;
    await thread?.live?.close();
  }
  private expireThreads(): void {
    for (const [id, thread] of this.threads) {
      if (thread.expires <= (this.options.now?.() ?? Date.now()) && !this.running.has(id)) void this.closeThread(id);
    }
  }
  private async handleFollowup(id: string, request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = await this.readJson(request) as { prompt?: unknown } | null;
    if (typeof body?.prompt !== "string" || !body.prompt.trim() || body.prompt.length > 20_000) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "A nonempty prompt of at most 20,000 characters is required" } });
    }
    this.expireThreads();
    const record = this.invocations.get(id);
    if (!record) return this.json(response, 404, { error: { code: "not_found", message: "Unknown invocation" } });
    if (this.running.has(id) || record.state === "queued" || record.state === "running") {
      return this.json(response, 409, { error: { code: "not_idle", message: "The previous prompt is still running; follow-ups are sequential" } });
    }
    if (!this.threads.has(id)) return this.json(response, 404, { error: { code: "session_closed", message: "The thread ended or expired. Start a new task" } });
    if (!this.invocations.requeueForFollowup(id, body.prompt.trim())) return;
    record.followupAvailable = false;
    this.json(response, 202, { accepted: true, invocationId: id });
    void this.processInvocation(record, true);
  }

  private async processInvocation(record: InvocationRecord, followup = false): Promise<void> {
    // A.3: one AbortController per invocation; timeout fires it when configured.
    const entry: RunningInvocation = { controller: new AbortController(), timedOut: false };
    if (this.config.invokeTimeoutMs > 0) {
      entry.timer = setTimeout(() => {
        entry.timedOut = true;
        entry.controller.abort();
        console.warn(`[invoke] timeout (${this.config.invokeTimeoutMs}ms) id=${record.invocationId}`);
      }, this.config.invokeTimeoutMs);
      entry.timer.unref();
    }
    this.running.set(record.invocationId, entry);
    const signal = entry.controller.signal;

    try {
      this.invocations.start(record.invocationId);
      if (this.options.onInvocation) {
        await this.options.onInvocation(record);
      }
      else {
        await this.defaultProcessor(record, signal, followup);
      }
      if (signal.aborted) {
        throw abortError(signal);
      }
      record.followupAvailable = this.threads.has(record.invocationId);
      this.invocations.finish(record.invocationId, "completed");
    } catch (error) {
      const aborted = signal.aborted;
      const message = error instanceof Error ? error.message : String(error);
      if (aborted || !followup) await this.closeThread(record.invocationId);
      record.followupAvailable = this.threads.has(record.invocationId);
      if (aborted) {
        console.warn(`[invoke] ${entry.timedOut ? "timed out" : "aborted"} id=${record.invocationId}`);
        this.invocations.addStep(record.invocationId,
          entry.timedOut ? "timeout" : "cancel", false, message);
        this.invocations.finish(record.invocationId, entry.timedOut ? "timed_out" : "aborted", message);
      } else {
        console.error(`[invoke] failed id=${record.invocationId}`);
        this.invocations.addStep(record.invocationId, "process", false, message);
        this.invocations.finish(record.invocationId, "failed", message);
      }
    } finally {
      if (entry.timer) {
        clearTimeout(entry.timer);
      }
      this.running.delete(record.invocationId);
    }
  }

  /** Validate the original context before every turn; history never renews authority. */
  private async defaultProcessor(record: InvocationRecord, signal?: AbortSignal, followup = false): Promise<void> {
    const hostClient = this.options.hostClient;
    if (!hostClient) {
      throw new Error("No host client configured");
    }

    console.log("[context] fetching pinned context from host");
    const outcome = await hostClient.getSnapshot(record.contextId, signal);

    if (!outcome.ok) {
      // Domain outcome as data (protocol.md): e.g. target_gone / expired.
      console.warn(`[context] unavailable: ${outcome.error.code}`);
      this.invocations.addStep(record.invocationId, "desktop.getContext", false,
        `${outcome.error.code}: ${outcome.error.message}`);
      await this.closeThread(record.invocationId);
      throw new Error(`Pinned context unavailable (${outcome.error.code})`);
    }

    const snapshot = outcome.result;
    // Do not persist window contents, context capabilities, or the user's prompt in logs.

    const target = snapshot.targetWindow ?? snapshot.foregroundWindow;
    console.log(`[context] target=${target?.processName ?? "?"}`);
    this.invocations.addStep(record.invocationId, "desktop.getContext", true,
      `target=${target?.processName ?? "?"}`);

    if (!this.config.agentEnabled) {
      // Deterministic slice mode (default): prove the round trip without an LLM.
      await this.roundTripCapture(record, record.contextId, signal);
      this.invocations.setResponse(record.invocationId,
        "[slice] round-trip capture ok (PI_OS_AGENT=0)");
      return;
    }

    // A warm Mac child may outlive permission/settings changes. Negotiate the host's
    // actual input catalog for EACH session; never infer input authority from the OS alone.
    let readOnly = this.config.readOnly ?? false;
    if (process.platform === "darwin" && !readOnly) {
      readOnly = !(await this.hostAllowsInput(signal));
    }
    const thread = this.threads.get(record.invocationId);
    if (followup && thread?.readOnly === false && readOnly) {
      await this.closeThread(record.invocationId);
      throw new Error("control_disabled: Permissions changed. Start a new task");
    }
    // Original model/resources/tool scope remain fixed for the entire thread.
    const runOptions: AgentRunOptions = {
      hostClient,
      contextId: record.contextId,
      prompt: record.prompt,
      includeScreenshot: record.includeScreenshot,
      snapshot: snapshot as DesktopContextSnapshot & { screenshot?: ScreenshotRef | null },
      capturesDir: this.config.capturesDir,
      readOnly,
      resourceSelection: this.resourceSettings.get(),
      log: (line) => console.log(line),
      modelSelection: this.modelSettings.get(),
      signal,
      onToolCall: (toolName) =>
        this.invocations.addStep(record.invocationId, `agent.${toolName}`, true),
      onActivity: (activity) => this.invocations.setActivity(record.invocationId, activity),
    };
    let live = thread?.live;
    if (!live) {
      if (followup) throw new Error("session_closed: Start a new task");
      live = await (this.options.createSession ?? createLiveSession)(runOptions);
      if (signal?.aborted || this.stopping || (thread && this.threads.get(record.invocationId) !== thread)) {
        await live.close();
        throw signal?.aborted ? abortError(signal) : new Error("session_closed: Reader closed during startup");
      }
      if (thread) { thread.live = live; thread.readOnly = readOnly; }
    }
    let result;
    try { result = followup ? await promptFollowup(live, record.prompt, signal) : await promptFirst(live, runOptions); }
    finally { if (!thread) await live.close(); }
    console.log(`[agent] finished (${result.toolCalls} tool calls)`);
    this.invocations.setResponse(record.invocationId, result.responseText);
    this.invocations.addStep(record.invocationId, "agent.run", true,
      `${result.toolCalls} tool calls; ${result.responseText.length} chars`);
  }

  /** Round-trip test (handoff section 23, item 9): call back into the C#
   * host for a fresh screenshot of the pinned target window. */
  private async roundTripCapture(
    record: InvocationRecord,
    contextId: string,
    signal?: AbortSignal,
  ): Promise<void> {
    const hostClient = this.options.hostClient;
    if (!hostClient) {
      throw new Error("No host client configured");
    }

    const capture = await hostClient.invokeTool<ScreenshotRef>(
      "desktop.captureWindow",
      { contextId },
      signal,
    );

    if (!capture.ok) {
      console.warn(`[roundtrip] capture failed: ${capture.error.code}`);
      this.invocations.addStep(record.invocationId, "desktop.captureWindow", false,
        `${capture.error.code}: ${capture.error.message}`);
      throw new Error(`Round-trip capture failed (${capture.error.code})`);
    }

    console.log("[roundtrip] fresh screenshot captured");
    this.invocations.addStep(record.invocationId, "desktop.captureWindow", true,
      `imageId=${capture.result.imageId}`);
  }

  private authorized(request: IncomingMessage): boolean {
    const expected = this.config.hostToken;
    if (!expected) return this.config.insecureDev === true;
    const supplied = request.headers["x-harness-token"];
    if (typeof supplied !== "string") return false;
    const a = Buffer.from(supplied), b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  private async readJson(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of request) {
      total += (chunk as Buffer).length;
      if (total > 1_000_000) {
        throw new RequestError(413, "Request body too large");
      }
      chunks.push(chunk as Buffer);
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    return raw.length > 0 ? JSON.parse(raw) : null;
  }

  private json(response: ServerResponse, status: number, payload: unknown): void {
    const body = JSON.stringify(payload);
    response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
    response.end(body);
  }
}
