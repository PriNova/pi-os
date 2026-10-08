import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { CdpConnection } from "../src/browser/cdp.js";
const { WebSocketServer } = createRequire(import.meta.url)("ws");

async function fixture(respond: boolean) {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>(done => server.once("listening", done));
  const calls: string[] = [];
  server.on("connection", (socket: any) => socket.on("message", (data: Buffer) => {
    const request = JSON.parse(data.toString()); calls.push(request.method);
    if (respond || calls.length === 1) socket.send(JSON.stringify({ id: request.id, result: { protocolVersion: "1.3" } }));
  }));
  const client = await CdpConnection.connect(server.address().port, undefined, 40, 1000);
  assert.deepEqual(calls, ['Browser.getVersion'], 'connection waits for protocol readiness');
  return { client, calls, close: async () => { client.close(); await new Promise<void>(done => server.close(done)); } };
}

test("CDP transport uses one bounded loopback connection and refuses out-of-scope methods", async () => {
  const f = await fixture(true);
  try {
    assert.equal((await f.client.call("Browser.getVersion")).protocolVersion, "1.3");
    assert.throws(() => f.client.call("Browser.close"), /policy_blocked/);
    assert.throws(() => f.client.call("Storage.getCookies"), /policy_blocked/);
    assert.deepEqual(f.calls, ["Browser.getVersion", "Browser.getVersion"]);
  } finally { await f.close(); }
});

test("CDP command timeout closes pending work rather than reconnecting/retrying", async () => {
  const f = await fixture(false);
  try {
    await assert.rejects(f.client.call("Browser.getVersion"), /browser_timeout/);
    assert.throws(() => f.client.call("Browser.getVersion"), /browser_disconnected/);
    assert.deepEqual(f.calls, ["Browser.getVersion", "Browser.getVersion"]);
  } finally { await f.close(); }
});

test("cancelling a pending CDP operation tears down the connection", async () => {
  const f = await fixture(false), controller = new AbortController();
  try {
    const pending = f.client.call("Browser.getVersion", {}, undefined, controller.signal);
    controller.abort(); await assert.rejects(pending, /browser_disconnected/);
    assert.throws(() => f.client.call("Browser.getVersion"), /browser_disconnected/);
  } finally { await f.close(); }
});
