import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { loadConfig, type HarnessConfig } from "./config.js";
import { HostClient, type DesktopContextSnapshot, type ScreenshotRef } from "./hostClient.js";
import { InvocationStore, type InvocationRecord } from "./invocations.js";
import { abortError, createLiveSession, promptFirst, promptFollowup } from "./agent/agentRunner.js";
import { LiveSessionStore } from "./agent/liveSessions.js";
import { getModelRuntime, listAvailableModels } from "./agent/modelCatalog.js";
import { AgentModelSettings, type ModelSelection } from "./agent/modelSettings.js";
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";

/**
 * Node agent harness HTTP surface per shared/protocol/protocol.md:
 * - GET  /health
 * - POST /invoke                    (202, async processing)
 * - GET  /invocations/{id}          (execution status)
 * - POST /invocations/{id}/followup (202, sequential prompt on idle session)
 * - POST /invocations/{id}/close    (dispose the live session)
 *
 * Bound to loopback only. All non-health routes require X-Harness-Token.
 */

interface InvokeBody {
  invocationId?: unknown;
  contextId?: unknown;
  prompt?: unknown;
  invokedAt?: unknown;
}

export interface HarnessServerOptions {
  onInvocation?: (record: InvocationRecord) => Promise<void>;
}

/** Bookkeeping for one in-flight invocation (A.3: cancel + timeout). */
interface RunningInvocation {
  controller: AbortController;
  timedOut: boolean;
  timer?: NodeJS.Timeout;
}

export class HarnessServer {
  readonly invocations = new InvocationStore();
  private readonly running = new Map<string, RunningInvocation>();
  /** Live sessions for sequential follow-ups; disposed on reader close. */
  private readonly liveSessions = new LiveSessionStore();
  private readonly server: Server;
  /** Settings-page model choice applied to every new invocation. */
  private readonly modelSettings = new AgentModelSettings();

  constructor(
    private readonly config: HarnessConfig = loadConfig(),
    private readonly options: HarnessServerOptions & { hostClient?: HostClient } = {},
  ) {
    this.options.hostClient ??= new HostClient(config);
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
  }

  listen(): Promise<number> {
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      // Loopback only; never bind 0.0.0.0 (protocol.md).
      this.server.listen(this.config.port, "127.0.0.1", () => {
        resolve(this.config.port);
      });
    });
  }

  close(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server.close((error) => (error ? reject(error) : resolve()));
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
          models: await listAvailableModels(),
          current: this.modelSettings.get(),
        });
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
        await this.handleFollowup(followupMatch[1] as string, request, response);
        return;
      }

      const closeMatch = /^\/invocations\/([\w-]+)\/close$/.exec(url.pathname);
      if (request.method === "POST" && closeMatch) {
        this.liveSessions.dispose(closeMatch[1] as string);
        return this.json(response, 200, { closed: true, invocationId: closeMatch[1] });
      }

      this.json(response, 404, { error: { code: "not_found", message: `No route: ${route}` } });
    } catch (error) {
      this.json(response, 500, {
        error: { code: "internal_error", message: error instanceof Error ? error.message : String(error) },
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
    if (typeof contextId !== "string" || typeof prompt !== "string" || prompt.length === 0) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "contextId (string) and prompt (non-empty string) are required" },
      });
    }

    const record = this.invocations.create(
      contextId,
      prompt,
      typeof body.invokedAt === "string" ? body.invokedAt : new Date().toISOString(),
      typeof body.invocationId === "string" ? body.invocationId : undefined,
    );

    console.log(`[invoke] id=${record.invocationId} context=${record.contextId}`);
    console.log(`[invoke] prompt=${JSON.stringify(record.prompt)}`);
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

    const runtime = await getModelRuntime();
    const model = runtime.getModel(provider, modelId);
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

  /** POST /invocations/{id}/followup — sequential prompt on the idle live session. */
  private async handleFollowup(id: string, request: IncomingMessage, response: ServerResponse): Promise<void> {
    const record = this.invocations.get(id);
    if (!record) {
      return void this.json(response, 404, {
        error: { code: "not_found", message: `Unknown invocation '${id}'` },
      });
    }
    const body = (await this.readJson(request)) as { prompt?: unknown } | null;
    const prompt = body?.prompt;
    if (typeof prompt !== "string" || prompt.trim().length === 0) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "prompt (non-empty string) is required" },
      });
    }
    if (record.state === "queued" || record.state === "running") {
      return void this.json(response, 409, {
        error: { code: "not_idle", message: `Invocation '${id}' is not idle` },
      });
    }
    if (this.config.agentEnabled && !this.liveSessions.get(id) && !this.options.onInvocation) {
      return void this.json(response, 404, {
        error: { code: "session_closed", message: `Live session for '${id}' is gone` },
      });
    }
    const trimmed = prompt.trim();
    if (!this.invocations.requeueForFollowup(id, trimmed)) {
      return void this.json(response, 409, {
        error: { code: "not_idle", message: `Invocation '${id}' is not idle` },
      });
    }
    console.log(`[invoke] followup id=${id} prompt=${JSON.stringify(trimmed.slice(0, 200))}`);
    this.json(response, 202, { accepted: true, invocationId: id });
    void this.processFollowup(record, trimmed);
  }

  private trackRun(id: string): { signal: AbortSignal; entry: RunningInvocation } {
    // A.3: one AbortController per run; timeout fires it when configured.
    const entry: RunningInvocation = { controller: new AbortController(), timedOut: false };
    if (this.config.invokeTimeoutMs > 0) {
      entry.timer = setTimeout(() => {
        entry.timedOut = true;
        entry.controller.abort();
        console.warn(`[invoke] timeout (${this.config.invokeTimeoutMs}ms) id=${id}`);
      }, this.config.invokeTimeoutMs);
      entry.timer.unref();
    }
    this.running.set(id, entry);
    return { signal: entry.controller.signal, entry };
  }

  private endRun(id: string, entry: RunningInvocation): void {
    if (entry.timer) {
      clearTimeout(entry.timer);
    }
    this.running.delete(id);
  }

  private finishWithOutcome(id: string, entry: RunningInvocation, error: unknown): void {
    const signal = entry.controller.signal;
    const aborted = signal.aborted;
    const message = error instanceof Error ? error.message : String(error);
    if (aborted) {
      console.warn(`[invoke] ${entry.timedOut ? "timed out" : "aborted"}: ${message}`);
      this.invocations.addStep(id, entry.timedOut ? "timeout" : "cancel", false, message);
      this.invocations.finish(id, entry.timedOut ? "timed_out" : "aborted", message);
    } else if (error) {
      console.error(`[invoke] failed: ${message}`);
      this.invocations.addStep(id, "process", false, message);
      this.invocations.finish(id, "failed", message);
    } else {
      this.invocations.finish(id, "completed");
    }
  }

  private async processInvocation(record: InvocationRecord): Promise<void> {
    const { signal, entry } = this.trackRun(record.invocationId);
    let error: unknown = null;
    try {
      this.invocations.start(record.invocationId);
      if (this.options.onInvocation) {
        await this.options.onInvocation(record);
      } else {
        await this.defaultProcessor(record, signal);
      }
      if (signal.aborted) {
        throw abortError(signal);
      }
    } catch (e) {
      error = e;
    } finally {
      // A live session that failed to start is useless; drop it so a
      // follow-up reports session_closed instead of reusing a broken thread.
      if (error && this.liveSessions.get(record.invocationId)) {
        const rec = this.invocations.get(record.invocationId);
        const neverRan = !rec?.steps.some((s) => s.tool.startsWith("agent."));
        if (neverRan && !signal.aborted) {
          this.liveSessions.dispose(record.invocationId);
        }
      }
      this.finishWithOutcome(record.invocationId, entry, error);
      this.endRun(record.invocationId, entry);
    }
  }

  private async processFollowup(record: InvocationRecord, prompt: string): Promise<void> {
    const { signal, entry } = this.trackRun(record.invocationId);
    let error: unknown = null;
    try {
      if (this.options.onInvocation) {
        await this.options.onInvocation(record);
      } else {
        await this.followupProcessor(record, prompt, signal);
      }
      if (signal.aborted) {
        throw abortError(signal);
      }
    } catch (e) {
      error = e;
    } finally {
      this.finishWithOutcome(record.invocationId, entry, error);
      this.endRun(record.invocationId, entry);
    }
  }

  /**
   * First prompt: fetch the pinned snapshot, create the live session,
   * and keep it for sequential follow-ups until the reader closes.
   */
  private async defaultProcessor(record: InvocationRecord, signal?: AbortSignal): Promise<void> {
    const hostClient = this.options.hostClient;
    if (!hostClient) {
      throw new Error("No host client configured");
    }

    console.log(`[context] fetching ${record.contextId} from host`);
    const outcome = await hostClient.getSnapshot(record.contextId, signal);

    if (!outcome.ok) {
      // Domain outcome as data (protocol.md): e.g. target_gone / expired.
      console.warn(`[context] unavailable: ${outcome.error.code}: ${outcome.error.message}`);
      this.invocations.addStep(record.invocationId, "desktop.getContext", false,
        `${outcome.error.code}: ${outcome.error.message}`);
      throw new Error(`Context ${record.contextId} unavailable (${outcome.error.code})`);
    }

    const snapshot = outcome.result;
    console.log("[context] complete pinned snapshot:");
    console.log(JSON.stringify(snapshot, null, 2));

    const target = snapshot.targetWindow ?? snapshot.foregroundWindow;
    console.log(
      `[context] target=${target?.processName ?? "?"} hwnd=${target?.hwnd ?? "?"} title=${JSON.stringify(target?.title ?? "")}`,
    );
    this.invocations.addStep(record.invocationId, "desktop.getContext", true,
      `target=${target?.processName ?? "?"}`);

    if (!this.config.agentEnabled) {
      // Deterministic slice mode: prove the round trip without an LLM.
      await this.roundTripCapture(record, record.contextId, signal);
      this.invocations.setResponse(record.invocationId,
        "[slice] round-trip capture ok (PI_OS_AGENT=0)");
      return;
    }

    // Agent mode: create the live session and keep it for follow-ups.
    // The thread keeps its original model; later settings changes apply
    // only to new invocations.
    const live = await createLiveSession({
      hostClient,
      contextId: record.contextId,
      capturesDir: this.config.capturesDir,
      log: (line) => console.log(line),
      modelSelection: this.modelSettings.get(),
      onToolCall: (toolName) =>
        this.invocations.addStep(record.invocationId, `agent.${toolName}`, true),
      onActivity: (activity) => this.invocations.setActivity(record.invocationId, activity),
    });
    this.liveSessions.set(record.invocationId, live);
    const result = await promptFirst(
      live,
      snapshot as DesktopContextSnapshot & { screenshot?: ScreenshotRef | null },
      record.prompt,
      this.config.capturesDir,
      signal,
    );
    console.log(`[agent] finished (${result.toolCalls} tool calls)`);
    if (result.responseText) {
      console.log(`[agent] response: ${result.responseText.slice(0, 800)}`);
    }
    this.invocations.setResponse(record.invocationId, result.responseText);
    this.invocations.addStep(record.invocationId, "agent.run", true,
      `${result.toolCalls} tool calls; ${result.responseText.length} chars`);
  }

  /** Follow-up prompt on the idle live session: plain text, history kept by pi. */
  private async followupProcessor(record: InvocationRecord, prompt: string, signal?: AbortSignal): Promise<void> {
    if (!this.config.agentEnabled) {
      await this.roundTripCapture(record, record.contextId, signal);
      this.invocations.setResponse(record.invocationId,
        "[slice] follow-up ok (PI_OS_AGENT=0)");
      return;
    }
    const live = this.liveSessions.get(record.invocationId);
    if (!live) {
      throw new Error(`Live session for '${record.invocationId}' is gone`);
    }
    // Route this run's tool/activity callbacks to the same record.
    const result = await promptFollowup(live, prompt, signal);
    console.log(`[agent] followup finished (${result.toolCalls} tool calls)`);
    if (result.responseText) {
      console.log(`[agent] followup response: ${result.responseText.slice(0, 800)}`);
    }
    this.invocations.setResponse(record.invocationId, result.responseText);
    this.invocations.addStep(record.invocationId, "agent.followup", true,
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
      console.warn(`[roundtrip] capture failed: ${capture.error.code}: ${capture.error.message}`);
      this.invocations.addStep(record.invocationId, "desktop.captureWindow", false,
        `${capture.error.code}: ${capture.error.message}`);
      throw new Error(`Round-trip capture failed (${capture.error.code})`);
    }

    console.log(`[roundtrip] fresh screenshot: imageId=${capture.result.imageId} file=${capture.result.filePath}`);
    this.invocations.addStep(record.invocationId, "desktop.captureWindow", true,
      `imageId=${capture.result.imageId}`);
  }

  private authorized(request: IncomingMessage): boolean {
    const expected = this.config.hostToken;
    if (!expected) {
      return true; // Dev mode without a token; the host only sets one when launching us.
    }
    return request.headers["x-harness-token"] === expected;
  }

  private async readJson(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of request) {
      total += (chunk as Buffer).length;
      if (total > 1_000_000) {
        throw new Error("Request body too large");
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
