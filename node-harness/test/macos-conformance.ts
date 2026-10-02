import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, connect } from "node:net";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { test } from "node:test";
import { HostClient } from "../src/hostClient.js";
import { loadScreenshotImage } from "../src/agent/screenshotImage.js";
import type { HarnessConfig } from "../src/config.js";

async function freePort() {
  const server = createServer();
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const port = (server.address() as { port: number }).port;
  await new Promise<void>(r => server.close(() => r()));
  return port;
}
async function stop(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exit = once(child, "exit");
  child.kill("SIGTERM"); // Only this suite's exact child PID.
  await exit;
}
async function ready(child: ChildProcess, marker: string) {
  let output = "", stderr = "";
  child.stderr?.on("data", data => { stderr += data; });
  await new Promise<void>((accept, reject) => {
    const timer = setTimeout(() => reject(new Error(`Readiness timed out: ${stderr}`)), 15_000);
    child.once("exit", code => { clearTimeout(timer); reject(new Error(`Child exited ${code}: ${stderr}`)); });
    child.stdout?.on("data", data => {
      output += data;
      if (output.includes(marker)) { clearTimeout(timer); accept(); }
    });
  });
}
async function raw(port: number, request: string) {
  return new Promise<string>((accept, reject) => {
    const socket = connect(port, "127.0.0.1"); let text = "";
    socket.setTimeout(8000, () => { socket.destroy(); reject(new Error("socket timeout")); });
    socket.on("connect", () => socket.write(request));
    socket.on("data", d => { text += d; });
    socket.on("end", () => accept(text)); socket.on("error", reject);
  });
}

test("real Swift NWListener ↔ Node fetch/hostClient and supervised harness (no LLM or TCC)", { timeout: 60_000 }, async () => {
  assert.equal(process.platform, "darwin", "This explicit suite requires macOS; it must not silently skip conformance");
  const root = await mkdtemp(join(tmpdir(), "pi-os-conformance-"));
  const hostPort = await freePort(), nodePort = await freePort();
  const token = "test-" + crypto.randomUUID();
  const captures = resolve("../shared/fixtures/captures");
  const fixture = JSON.parse(await readFile(resolve("../shared/fixtures/macos-window.json"), "utf8"));
  fixture.screenshot.filePath = join(captures, "window.png");
  await writeFile(join(root, "context.json"), JSON.stringify(fixture));
  const host = spawn(resolve("../host-macos/.build/debug/pi-os"), ["--conformance", join(root, "context.json")], {
    env: { ...process.env, PI_OS_TOKEN: token, PI_OS_HOST_PORT: String(hostPort) }, stdio: ["pipe", "pipe", "pipe"],
  });
  let node: ChildProcess | undefined;
  const config: HarnessConfig = { port: nodePort, hostBaseUrl: `http://127.0.0.1:${hostPort}`, hostToken: token,
    agentEnabled: false, invokeTimeoutMs: 10_000, capturesDir: captures };
  const headers = { "X-Harness-Token": token, "Content-Type": "application/json" };
  try {
    await ready(host, "READY");
    const base = config.hostBaseUrl;
    assert.equal((await fetch(base + "/health")).status, 200);
    for (const auth of [undefined, "wrong", token]) {
      const response = await fetch(base + "/tools", { headers: auth ? { "X-Harness-Token": auth } : {} });
      assert.equal(response.status, auth === token ? 200 : 401);
      if (auth === token) assert.equal(((await response.json()) as { tools: unknown[] }).tools.length, 3);
    }
    const client = new HostClient(config);
    for (const tool of ["desktop.getContext", "desktop.refreshContext", "desktop.captureWindow"]) {
      const outcome = await client.invokeTool<any>(tool, { contextId: fixture.id });
      assert.equal(outcome.ok, true);
      if (outcome.ok && tool === "desktop.captureWindow") {
        const image = await loadScreenshotImage(outcome.result.filePath, captures);
        assert.equal(image.data, (await readFile(fixture.screenshot.filePath)).toString("base64"));
      }
    }
    const unknown = await client.getSnapshot("ctx-gone");
    assert.equal(unknown.ok, false);
    if (!unknown.ok) assert.equal(unknown.error.code, "unknown_context");
    assert.equal((await fetch(base + "/tools/nope", { method: "POST", headers, body: "{}" })).status, 404);
    assert.equal((await fetch(base + "/tools/desktop.getContext", { method: "POST", headers, body: "{" })).status, 400);
    for (const [extra, expected] of [["Content-Length: 1000001", 413], ["Transfer-Encoding: chunked", 400], ["Content-Length: -1", 400]] as const) {
      assert.match(await raw(hostPort, `POST /tools/desktop.getContext HTTP/1.1\r\nHost: localhost\r\n${extra}\r\n\r\n`), new RegExp(`HTTP/1.1 ${expected}`));
    }
    // Complete request, intentional peer disconnect, then a successful fresh request.
    const socket = connect(hostPort, "127.0.0.1"); await once(socket, "connect");
    socket.write("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n{"); socket.destroy();
    assert.equal((await fetch(base + "/health")).status, 200);
    assert.match(await raw(hostPort, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"), /Connection: close/);

    const started = performance.now();
    node = spawn(process.execPath, [resolve("dist/index.js")], { stdio: ["pipe", "pipe", "pipe"], env: {
      ...process.env, PI_OS_TOKEN: token, PI_OS_SUPERVISED: "1", PI_OS_AGENT: "0", PI_OS_READ_ONLY: "1",
      PI_OS_HOST_URL: base, PI_OS_NODE_PORT: String(nodePort), PI_OS_CAPTURES_DIR: captures,
      PI_OS_SUPPORT_DIR: root, PI_OS_SESSION_ID: "test-spawn", NODE_OPTIONS: "", NODE_PATH: "",
    } });
    await ready(node, "node harness listening");
    console.log(`[measurement] full harness cold-start-to-listening ${(performance.now() - started).toFixed(1)} ms`);
    const harness = `http://127.0.0.1:${nodePort}`;
    assert.equal(((await (await fetch(harness + "/health")).json()) as any).sessionId, "test-spawn");
    for (const auth of [undefined, "wrong"]) {
      assert.equal((await fetch(harness + "/invoke", { method: "POST", headers: auth ? { "X-Harness-Token": auth } : {}, body: "{}" })).status, 401);
    }
    const invoked = await fetch(harness + "/invoke", { method: "POST", headers, body: JSON.stringify({ contextId: fixture.id, prompt: "Conformance, no model" }) });
    assert.equal(invoked.status, 202);
    const { invocationId } = await invoked.json() as any;
    let record: any;
    for (let i = 0; i < 100; i++) {
      record = await (await fetch(harness + "/invocations/" + invocationId, { headers })).json();
      if (!["queued", "running"].includes(record.state)) break;
      await new Promise(r => setTimeout(r, 50));
    }
    assert.equal(record.state, "completed", JSON.stringify(record));
    assert.match(record.responseText, /round-trip capture ok/);
    const exit = once(node, "exit"); const closing = performance.now();
    node.stdin!.end(); // Simulates the host pipe closing, not a signal sent to Node.
    const [code] = await exit;
    assert.equal(code, 0);
    console.log(`[measurement] supervised EOF shutdown ${(performance.now() - closing).toFixed(1)} ms`);
  } finally {
    if (node) await stop(node);
    await stop(host); await rm(root, { recursive: true, force: true });
  }
});
