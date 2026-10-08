import assert from "node:assert/strict";
import { test } from "node:test";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";

test("harness health is public; invoke/status/settings all enforce missing/wrong/correct tokens", async () => {
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "correct", agentEnabled: false }, {
    onInvocation: async () => {},
  });
  const port = await server.listen();
  const base = `http://127.0.0.1:${port}`;
  try {
    assert.equal((await fetch(base + "/health")).status, 200);
    for (const token of [undefined, "wrong"]) {
      const headers: Record<string, string> = token ? { "X-Harness-Token": token } : {};
      for (const [method, path] of [["POST", "/invoke"], ["GET", "/invocations/id"], ["POST", "/invocations/id/cancel"], ["POST", "/invocations/id/followup"], ["POST", "/invocations/id/close"], ["GET", "/models"], ["POST", "/settings/model"]]) {
        assert.equal((await fetch(base + path, { method, headers, ...(method === "POST" ? { body: "{}" } : {}) })).status, 401);
      }
    }
    const headers = { "X-Harness-Token": "correct", "Content-Type": "application/json" };
    assert.equal((await fetch(base + "/invoke", { method: "POST", headers, body: "{" })).status, 400);
    assert.equal((await fetch(base + "/settings/model", { method: "POST", headers, body: "{}" })).status, 400);
    assert.equal((await fetch(base + "/invocations/missing", { headers })).status, 404);
    assert.equal((await fetch(base + "/invoke", { method: "POST", headers, body: JSON.stringify({ contextId: "ctx-test", prompt: "test" }) })).status, 202);
  } finally { await server.close(); }
});

test("missing configured token fails closed unless insecure dev is explicit; supervised mode forbids opt-out", async () => {
  for (const insecureDev of [false, true]) {
    const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: undefined, insecureDev });
    const port = await server.listen();
    try {
      assert.equal((await fetch(`http://127.0.0.1:${port}/invocations/missing`)).status, insecureDev ? 404 : 401);
    } finally { await server.close(); }
  }
  assert.equal(loadConfig({ PI_OS_INSECURE_DEV: "1", PI_OS_SUPERVISED: "1" }).insecureDev, false);
});
