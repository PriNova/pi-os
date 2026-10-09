import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { resolve, join } from "node:path";
import { loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import type { HostClient, DesktopContextSnapshot } from "../src/hostClient.js";
import type { ImageContent } from "@earendil-works/pi-ai";
import { readFile } from "node:fs/promises";
import { LiveAgentSession, type SessionTransport } from "../src/agent/liveSession.js";
import { promptFollowup } from "../src/agent/agentRunner.js";

class FixtureSession implements SessionTransport {
  listener?: (event: AgentSessionEvent) => void;
  history: string[] = []; disposed = 0; aborted = 0;
  images: (ImageContent[] | undefined)[] = [];
  hold?: Promise<void>; release?: () => void; fail = false;
  subscribe(listener: (event: AgentSessionEvent) => void) { this.listener = listener; return () => { this.listener = undefined; }; }
  async prompt(text: string, options?: { images?: ImageContent[] }) {
    this.history.push(text);
    this.images.push(options?.images);
    if (this.hold) await this.hold;
    this.listener?.({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: `Answer ${this.history.length}` }], stopReason: this.fail ? "error" : "stop", ...(this.fail ? { errorMessage: "fixture provider failure" } : {}) } } as AgentSessionEvent);
  }
  async abort() { this.aborted++; this.release?.(); }
  dispose() { this.disposed++; }
  pause() { this.hold = new Promise(resolve => { this.release = resolve; }); }
}
const snapshot = { id: "ctx-pinned", capturedAt: "fixture", targetWindow: null, foregroundWindow: null, windowUnderCursor: null, cursor: { x: 0, y: 0 }, monitors: [] };
async function fixture(timeout = 0, startup?: Promise<void>, pinned: DesktopContextSnapshot = snapshot) {
  const transports: FixtureSession[] = [];
  let unavailable = false, control = true, now = Date.now();
  const host = {
    getSnapshot: async (id: string) => { assert.equal(id, "ctx-pinned"); return unavailable ? { ok: false, error: { code: "unknown_context", message: "revoked" } } : { ok: true, result: pinned }; },
    getToolNames: async () => control ? ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"] : [],
  } as unknown as HostClient;
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "fixture-token", agentEnabled: true, invokeTimeoutMs: timeout, capturesDir: resolve("../shared/fixtures/captures") }, {
    hostClient: host, now: () => now,
    createSession: async options => {
      if (startup) await startup;
      const session = new FixtureSession(); transports.push(session);
      return new LiveAgentSession(session, new AbortController(), options);
    },
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  async function request(path: string, body?: unknown) {
    return fetch(base + path, { method: body === undefined ? "GET" : "POST", headers: { "X-Harness-Token": "fixture-token", "Content-Type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  }
  async function terminal(id = "thread") {
    for (let i = 0; i < 200; i++) {
      const status = await (await request(`/invocations/${id}`)).json() as any;
      if (!["queued", "running"].includes(status.state)) return status;
      await delay(5);
    }
    throw new Error("Fixture did not settle");
  }
  return { server, transports, request, terminal, revoke: () => { unavailable = true; }, denyControl: () => { control = false; }, elapse: (ms: number) => { now += ms; } };
}
const invoke = { invocationId: "thread", contextId: "ctx-pinned", prompt: "first question", retainSession: true };

test("sequential HTTP follow-ups reuse history/identity, reset results and close idempotently", async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request("/invoke", invoke)).status, 202);
    assert.equal((await f.terminal()).followupAvailable, true);
    const session = f.transports[0]!;
    session.pause();
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "second question" })).status, 202);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "duplicate" })).status, 409);
    const running = await (await f.request("/invocations/thread")).json() as any;
    assert.equal(running.responseText, undefined);
    session.release!(); session.hold = undefined;
    const result = await f.terminal();
    assert.equal(result.responseText, "Answer 2"); assert.equal(result.contextId, "ctx-pinned");
    assert.equal(f.transports.length, 1); assert.equal(session.history.length, 2);
    assert.match(session.history[0]!, /first question/); assert.match(session.history[1]!, /second question/);
    assert.equal(session.disposed, 0);
    for (let i = 0; i < 2; i++) assert.equal((await f.request("/invocations/thread/close", {})).status, 200);
    assert.equal(session.disposed, 1);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "no resurrection" })).status, 404);
  } finally { await f.server.close(); }
});

test("initial screenshot attachment defaults on, respects the switch, and does not affect follow-ups", async () => {
  const filePath = resolve("../shared/fixtures/captures/window.png");
  for (const includeScreenshot of [undefined, true, false]) {
    const pinned = { ...snapshot, screenshot: { kind: "window", imageId: "image-fixture", filePath } };
    const f = await fixture(0, undefined, pinned);
    try {
      assert.equal((await f.request("/invoke", { ...invoke, includeScreenshot })).status, 202);
      assert.equal((await f.terminal()).state, "completed");
      const transport = f.transports[0]!;
      if (includeScreenshot === false) {
        assert.equal(transport.images[0], undefined);
        assert.match(transport.history[0]!, /No image is attached/);
      } else {
        assert.equal(transport.images[0]?.length, 1);
        assert.equal(transport.images[0]?.[0]?.data, (await readFile(filePath)).toString("base64"));
      }
      assert.equal(pinned.screenshot.filePath, filePath, "The stored screenshot remains available to tools");
      await f.request("/invocations/thread/followup", { prompt: "follow-up" });
      assert.equal((await f.terminal()).state, "completed");
      assert.equal(transport.images[1], undefined);
    } finally { await f.server.close(); }
  }
});

test("invalid screenshot attachment flags are rejected", async () => {
  const f = await fixture();
  try {
    for (const includeScreenshot of [null, "false", 0]) {
      assert.equal((await f.request("/invoke", { ...invoke, includeScreenshot })).status, 400);
    }
    assert.equal(f.transports.length, 0);
  } finally { await f.server.close(); }
});

test("explicit one-shot clients do not retain sessions; new threads do not share history", async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request("/invoke", { ...invoke, retainSession: false })).status, 202);
    assert.equal((await f.terminal()).followupAvailable, false);
    assert.equal(f.transports[0]!.disposed, 1);
    await f.request("/invoke", { ...invoke, invocationId: "other" }); await f.terminal("other");
    assert.equal(f.transports.length, 2); assert.equal(f.transports[1]!.history.length, 1);
  } finally { await f.server.close(); }
  assert.equal(f.transports[1]!.disposed, 1);
});

test("invalid/blank follow-ups are rejected; provider failure preserves idle thread for explicit retry", async () => {
  const f = await fixture();
  try {
    await f.request("/invoke", invoke); await f.terminal();
    for (const body of [{}, { prompt: " \n " }, { prompt: "x".repeat(20_001) }]) assert.equal((await f.request("/invocations/thread/followup", body)).status, 400);
    f.transports[0]!.fail = true;
    await f.request("/invocations/thread/followup", { prompt: "fail" });
    const failed = await f.terminal(); assert.equal(failed.state, "failed"); assert.equal(failed.followupAvailable, true);
    f.transports[0]!.fail = false;
    await f.request("/invocations/thread/followup", { prompt: "explicit retry" });
    assert.equal((await f.terminal()).responseText, "Answer 3");
  } finally { await f.server.close(); }
});

test("retained sessions have bounded capacity and lazy TTL, with no expiry-based input renewal", async () => {
  const f = await fixture();
  try {
    for (let i = 0; i < 20; i++) {
      await f.request('/invoke', { ...invoke, invocationId: 'thread-' + i }); await f.terminal('thread-' + i);
    }
    assert.equal((await f.request('/invoke', { ...invoke, invocationId: 'overflow' })).status, 409);
    f.elapse(30 * 60_000 + 1);
    assert.equal((await f.request('/invocations/thread-0/followup', { prompt: 'expired' })).status, 404);
    assert(f.transports.every(s => s.disposed === 1));
    assert.equal((await f.request('/invoke', { ...invoke, invocationId: 'new-thread' })).status, 202);
    await f.terminal('new-thread'); assert.equal(f.transports.length, 21);
  } finally { await f.server.close(); }
});

test("closing during async session startup cannot resurrect a session", async () => {
  let release!: () => void;
  const f = await fixture(0, new Promise<void>(resolve => { release = resolve; }));
  try {
    await f.request("/invoke", invoke);
    await f.request("/invocations/thread/close", {}); release();
    assert.equal((await f.terminal()).followupAvailable, false);
    assert.equal(f.transports[0]!.disposed, 1); assert.equal(f.transports[0]!.history.length, 0);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "no" })).status, 404);
  } finally { release(); await f.server.close(); }
});

test("cancel/timeout during follow-up closes input authority; context revocation prevents another prompt", async () => {
  for (const mode of (["cancel", "timeout", "revoke", ...(process.platform === "darwin" ? ["control"] : [])] as const)) {
    const f = await fixture(mode === "timeout" ? 200 : 0);
    try {
      await f.request("/invoke", invoke); await f.terminal();
      const s = f.transports[0]!;
      if (mode === "revoke") f.revoke();
      else if (mode === "control") f.denyControl();
      else s.pause();
      await f.request("/invocations/thread/followup", { prompt: "second" });
      if (mode === "cancel") await f.request("/invocations/thread/cancel", {});
      const end = await f.terminal(); assert.equal(end.followupAvailable, false, mode);
      assert.equal(s.disposed, 1, mode);
      if (["revoke", "control"].includes(mode)) assert.equal(s.history.length, 1, "No model prompt after revoked native authority");
      assert.equal((await f.request("/invocations/thread/followup", { prompt: "retry" })).status, 404);
    } finally { await f.server.close(); }
  }
});

test("real SDK retains finalized conversation between sequential prompts using an in-memory stream fixture", async () => {
  const dir = resolve("test/fixtures/global-agent-dir");
  const loader = await loadAgentResources({ name: "history-fixture", factory(pi) {
    pi.registerProvider("history-fixture", { api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      models: [{ id: "dummy", name: "Dummy", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  } }, process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json") });
  const cleanup = await registerResourceProviders(loader, runtime);
  const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel("history-fixture", "dummy"),
    tools: [], sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false } }) });
  const seen: string[] = [];
  session.agent.streamFunction = (model, context) => {
    seen.push(JSON.stringify(context.messages));
    const stream = createAssistantMessageEventStream();
    const answer: AssistantMessage = { role: "assistant", content: [{ type: "text", text: `Fixture answer ${seen.length}` }], provider: model.provider, model: model.id,
      api: model.api, stopReason: "stop", timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    stream.push({ type: "done", reason: "stop", message: answer }); stream.end(); return stream;
  };
  const live = new LiveAgentSession(session, new AbortController(), { log() {} }, async () => { cleanup(); });
  try {
    assert.equal((await live.prompt("Remember this dummy phrase: copper robin")).responseText, "Fixture answer 1");
    assert.equal((await promptFollowup(live, "What did I say?")).responseText, "Fixture answer 2");
    assert.match(seen[1]!, /copper robin/); assert.match(seen[1]!, /Fixture answer 1/);
    assert.equal(session.messages.filter(m => m.role === "user").length, 2);
    assert.equal(session.sessionFile, undefined, "Desktop conversation must remain in memory");
  } finally { await live.close(); }
});

test("per-turn abort listeners do not survive an idle prompt and busy prompts are not queued", async () => {
  const transport = new FixtureSession(), lifetime = new AbortController();
  const live = new LiveAgentSession(transport, lifetime, { log() {} });
  const first = new AbortController(); await live.prompt("first", first.signal); first.abort();
  assert.equal(transport.aborted, 0); assert.equal(lifetime.signal.aborted, false);
  transport.pause(); const pending = promptFollowup(live, "second");
  await assert.rejects(live.prompt("concurrent"), /not_idle/);
  transport.release!(); await pending;
  await live.close(); await live.close(); assert.equal(transport.disposed, 1);
});
