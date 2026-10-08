import assert from "node:assert/strict";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension, validateDesktopAction } from "../src/agent/computerUseExtension.js";
import { MAX_SCREENSHOT_BYTES, loadScreenshotImage } from "../src/agent/screenshotImage.js";
import type { HostClient } from "../src/hostClient.js";

const png = await readFile(new URL("../../shared/fixtures/captures/window.png", import.meta.url));

function register(fakeInvoke: (...args: any[]) => any, captureDir = "C:/captures") {
  const tools = new Map<string, any>();
  const extension = createComputerUseExtension("ctx-fixed", { invokeTool: fakeInvoke } as unknown as HostClient, captureDir);
  extension.factory({
    on: () => undefined,
    registerTool: (tool: any) => tools.set(tool.name, tool),
  } as unknown as ExtensionAPI);
  return tools;
}

async function execute(tool: any, params: object, signal?: AbortSignal) {
  return tool.execute("call-1", params, signal, undefined, {});
}

test("inline extension registers observation and action tools", () => {
  const tools = register(async () => ({ ok: true, result: {} }));
  assert.deepEqual([...tools.keys()], [
    "desktop_get_context", "desktop_refresh_context", "desktop_capture_window", "desktop_act",
  ]);
});

test("inline extension appends pi-os guidance to the existing system prompt", () => {
  let beforeAgentStart: any;
  const extension = createComputerUseExtension(
    "ctx-fixed",
    { invokeTool: async () => ({ ok: true, result: {} }) } as unknown as HostClient,
    "C:/captures",
  );
  extension.factory({
    on: (event: string, handler: any) => {
      if (event === "before_agent_start") beforeAgentStart = handler;
    },
    registerTool: () => undefined,
  } as unknown as ExtensionAPI);

  const result = beforeAgentStart({ systemPrompt: "Existing pi system prompt" });
  assert.ok(result.systemPrompt.startsWith("Existing pi system prompt\n\n"));
  assert.match(result.systemPrompt, /## pi-os desktop invocation/);
});

test("desktop_act validates parameters and injects immutable context", async () => {
  const calls: any[] = [];
  const tools = register(async (name, args, signal) => {
    calls.push({ name, args, signal });
    return { ok: true, result: { done: true } };
  });
  const controller = new AbortController();
  await execute(tools.get("desktop_act"), { action: "click", x: 4, y: 8, contextId: "ctx-attacker" }, controller.signal);
  assert.equal(calls[0].name, "input.click");
  assert.deepEqual(calls[0].args, { contextId: "ctx-fixed", x: 4, y: 8 });
  assert.equal(calls[0].signal, controller.signal);

  await execute(tools.get("desktop_act"), { action: "scroll", deltaY: -3, x: 900, y: 500 });
  assert.equal(calls[1].name, "input.scroll");
  assert.deepEqual(calls[1].args, { contextId: "ctx-fixed", deltaY: -3, x: 900, y: 500 });

  assert.throws(() => validateDesktopAction({ action: "click", x: Number.NaN, y: 1 }), /invalid_arguments/);
  assert.throws(() => validateDesktopAction({ action: "key_chord", key: "a", modifiers: [] }), /invalid_arguments/);
  assert.throws(() => validateDesktopAction({ action: "press_key", key: "meta" }), /invalid_arguments/);
  assert.throws(() => validateDesktopAction({ action: "scroll", deltaX: 0, deltaY: 0 }), /invalid_arguments/);
  assert.throws(() => validateDesktopAction({ action: "scroll", deltaY: -1, x: 4 }), /supplied together/);
});

test("host domain errors become failed tool executions", async () => {
  const tools = register(async () => ({ ok: false, error: { code: "policy_blocked", message: "blocked" } }));
  await assert.rejects(execute(tools.get("desktop_act"), { action: "focus" }), /policy_blocked: blocked/);
});

test("fresh capture returns image only and propagates cancellation", async () => {
  const root = join(process.cwd(), "test", ".tmp-captures");
  await mkdir(root, { recursive: true });
  const file = join(root, "fresh.png");
  await writeFile(file, png);
  const controller = new AbortController();
  let receivedSignal: AbortSignal | undefined;
  const tools = register(async (_name, _args, signal) => {
    receivedSignal = signal;
    return { ok: true, result: { kind: "window", filePath: file } };
  }, root);
  try {
    const result = await execute(tools.get("desktop_capture_window"), {}, controller.signal);
    assert.equal(receivedSignal, controller.signal);
    assert.deepEqual(result.details, {});
    assert.equal(result.content.length, 1);
    assert.equal(result.content[0].type, "image");
    assert.equal(result.content[0].data, png.toString("base64"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("screenshot loader rejects missing, empty, oversized, non-PNG, and outside files", async () => {
  const root = join(process.cwd(), "test", ".tmp-image-validation");
  await mkdir(root, { recursive: true });
  const empty = join(root, "empty.png");
  const large = join(root, "large.png");
  const text = join(root, "text.png");
  const outside = join(process.cwd(), "test", ".tmp-outside.png");
  await writeFile(empty, Buffer.alloc(0));
  await writeFile(large, Buffer.alloc(MAX_SCREENSHOT_BYTES + 1));
  await writeFile(text, "not png");
  await writeFile(outside, png);
  try {
    await assert.rejects(loadScreenshotImage(join(root, "missing.png"), root), /missing or unreadable/);
    await assert.rejects(loadScreenshotImage(empty, root), /empty/);
    await assert.rejects(loadScreenshotImage(large, root), /8 MB/);
    await assert.rejects(loadScreenshotImage(text, root), /not a PNG/);
    await assert.rejects(loadScreenshotImage(outside, root), /outside/);
  } finally {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { force: true });
  }
});
