import assert from "node:assert/strict";
import { test } from "node:test";
import { LiveAgentSession, type SessionTransport } from "../src/agent/liveSession.js";

test("session cleanup is one promise even when SDK disposal re-enters or throws", async () => {
  for (const throws of [false, true]) {
    let disposed = 0, cleaned = 0, nested: Promise<void> | undefined;
    let live!: LiveAgentSession;
    const transport: SessionTransport = {
      subscribe: () => () => {}, prompt: async () => {}, abort: async () => {},
      dispose() { disposed++; nested = live.close(); if (throws) throw new Error("fixture dispose failure"); },
    };
    live = new LiveAgentSession(transport, new AbortController(), { log() {} }, async () => { cleaned++; });
    const closing = live.close();
    assert.equal(live.close(), closing);
    await closing;
    assert.equal(nested, closing);
    assert.equal(disposed, 1); assert.equal(cleaned, 1);
    assert.equal(live.lifetime.signal.aborted, true);
    await assert.rejects(live.prompt("cannot resurrect"), /session_closed/);
  }
});
