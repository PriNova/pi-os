import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { CdpConnection, dispatchKeyPair } from "../src/browser/cdp.js";
const { WebSocketServer } = createRequire(import.meta.url)("ws");

async function fixture(respond: boolean, onRequest?: (request: any, socket: any) => boolean) {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await new Promise<void>(done => server.once("listening", done));
  const calls: string[] = [], requests: any[] = [];
  server.on("connection", (socket: any) => socket.on("message", (data: Buffer) => {
    const request = JSON.parse(data.toString()); calls.push(request.method); requests.push(request);
    if (onRequest?.(request, socket)) return;
    if (respond || calls.length === 1) socket.send(JSON.stringify({ id: request.id, result: { protocolVersion: "1.3" } }));
  }));
  const client = await CdpConnection.connect(server.address().port, undefined, 40, 1000);
  assert.deepEqual(calls, ['Browser.getVersion'], 'connection waits for protocol readiness');
  return { client, calls, requests, close: async () => { client.close(); await new Promise<void>(done => server.close(done)); } };
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

test("cancelled browser key pairs send nothing before down, but release after down", async () => {
  const before = new AbortController(); before.abort();
  const f = await fixture(true);
  try {
    await assert.rejects(dispatchKeyPair(f.client, { key: ' ', code: 'Space' }, 'pinned', before.signal));
    assert.equal(f.requests.length, 1);
  } finally { await f.close(); }
  const during = new AbortController();
  const g = await fixture(true, (request) => {
    if (request.params?.type === 'keyDown') during.abort();
    return false;
  });
  try {
    await assert.rejects(dispatchKeyPair(g.client, { key: ' ', code: 'Space', text: ' ' }, 'pinned', during.signal));
    const keys = g.requests.filter(r => r.method === 'Input.dispatchKeyEvent');
    assert.deepEqual(keys.map(r => r.params.type), ['keyDown', 'keyUp']);
    assert(keys.every(r => r.sessionId === 'pinned'));
    assert.equal(keys[1].params.text, undefined);
    // Cancellation of the action did not kill the transport before release.
    await g.client.call('Browser.getVersion');
  } finally { await g.close(); }
});

test("CDP rejection of key-down still attempts release, without replay", async () => {
  const f = await fixture(true, (request, socket) => {
    if (request.params?.type !== 'keyDown') return false;
    socket.send(JSON.stringify({ id: request.id, error: { code: -32000 } })); return true;
  });
  try {
    await assert.rejects(dispatchKeyPair(f.client, { key: 'Enter', code: 'Enter' }, 'pinned'), /browser_protocol_error/);
    assert.deepEqual(f.requests.filter(r => r.method === 'Input.dispatchKeyEvent').map(r => r.params.type), ['keyDown', 'keyUp']);
  } finally { await f.close(); }
});

test("a missing release response times out and closes the socket", async () => {
  const f = await fixture(true, request => request.params?.type === 'keyUp');
  try {
    await assert.rejects(dispatchKeyPair(f.client, { key: 'Enter', code: 'Enter' }, 'pinned'), /browser_timeout/);
    assert.deepEqual(f.requests.filter(r => r.method === 'Input.dispatchKeyEvent').map(r => r.params.type), ['keyDown', 'keyUp']);
    assert.throws(() => f.client.call('Browser.getVersion'), /browser_disconnected/);
  } finally { await f.close(); }
});

test("socket loss after key-down fails without reconnect or replay", async () => {
  const f = await fixture(true, (request, socket) => {
    if (request.params?.type !== 'keyDown') return false;
    socket.terminate(); return true;
  });
  try {
    await assert.rejects(dispatchKeyPair(f.client, { key: 'Enter', code: 'Enter' }, 'pinned'), /browser_disconnected/);
    assert.deepEqual(f.requests.filter(r => r.method === 'Input.dispatchKeyEvent').map(r => r.params.type), ['keyDown']);
    assert.throws(() => f.client.call('Browser.getVersion'), /browser_disconnected/);
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
