import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import type { HostClient } from "../src/hostClient.js";

test("production logs omit provider error text, prompt, capture path and image capability", async () => {
  const privateText = "private-fixture-sentinel";
  const lines: string[] = [];
  const originals = { log: console.log, warn: console.warn, error: console.error };
  for (const method of ["log", "warn", "error"] as const) console[method] = (...args) => { lines.push(args.join(" ")); };
  try {
    for (const failed of [false, true]) {
      const host = {
        getSnapshot: async () => ({ ok: true, result: { targetWindow: null } }),
        invokeTool: async () => ({ ok: true, result: { imageId: privateText, filePath: "/private/" + privateText } }),
      } as unknown as HostClient;
      const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "fixture-token", agentEnabled: false }, {
        hostClient: host,
        ...(failed ? { onInvocation: async () => { throw new Error(privateText); } } : {}),
      });
      const base = `http://127.0.0.1:${await server.listen()}`;
      const headers = { "X-Harness-Token": "fixture-token", "Content-Type": "application/json" };
      try {
        assert.equal((await fetch(base + "/invoke", { method: "POST", headers, body: JSON.stringify({ invocationId: "fixture", contextId: privateText, prompt: privateText }) })).status, 202);
        let status: any;
        for (let i = 0; i < 100; i++) {
          status = await (await fetch(base + "/invocations/fixture", { headers })).json();
          if (!["queued", "running"].includes(status.state)) break;
          await delay(5);
        }
        assert.equal(status.state, failed ? "failed" : "completed");
        if (failed) assert.equal(status.failureMessage, privateText, "Authenticated UI can still explain the failure");
      } finally { await server.close(); }
    }
    assert(!lines.some(line => line.includes(privateText)), "Private payload entered a production log");
  } finally { Object.assign(console, originals); }
});
