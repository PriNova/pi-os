import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import type { HostClient } from "../src/hostClient.js";

test("model/resource Settings APIs round-trip against injected catalog with no provider networking", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-os-settings-api-"));
  const model: Model<"openai-completions"> = { id: "fixture-model", name: "Fixture model", provider: "fixture", api: "openai-completions",
    baseUrl: "https://never-called.invalid", reasoning: true, input: ["text", "image"],
    contextWindow: 8192, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const calls: boolean[] = [];
  let allowInput = true;
  const resources = new AgentResourceSettings(join(dir, "resources.json"));
  const models = new AgentModelSettings(join(dir, "settings.json"), () => {});
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "test", readOnly: false, agentEnabled: false }, {
    modelSettings: models, resourceSettings: resources,
    hostClient: { getToolNames: async () => allowInput ? ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"] : [] } as unknown as HostClient,
    modelRuntimeFactory: async (trusted = false) => {
      calls.push(trusted);
      return { getAvailable: async () => [model] } as unknown as ModelRuntime;
    },
  });
  const port = await server.listen();
  const base = `http://127.0.0.1:${port}`;
  const headers = { "X-Harness-Token": "test", "Content-Type": "application/json" };
  const post = (path: string, body: unknown) => fetch(base + path, { method: "POST", headers, body: JSON.stringify(body) });
  try {
    assert.equal((await fetch(base + "/settings/resources")).status, 401);
    const catalog = await (await fetch(base + "/models", { headers })).json() as any;
    assert.equal(catalog.models[0].id, model.id);
    const selection = { provider: model.provider, modelId: model.id, thinkingLevel: getSupportedThinkingLevels(model)[0] };
    assert.equal((await post("/settings/model", selection)).status, 200);
    assert.deepEqual(new AgentModelSettings(join(dir, "settings.json"), () => {}).get(), selection);
    assert.equal((await post("/settings/model", { ...selection, thinkingLevel: "not-supported" })).status, 400);
    assert.equal((await post("/settings/model", { ...selection, modelId: "not-authenticated" })).status, 400);
    assert.deepEqual(models.get(), selection);
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal" })).status, 400);
    assert.equal(resources.get().mode, "isolated");
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal", acknowledgeUnpinnedAccess: true })).status, 200);
    await fetch(base + "/models", { headers });
    assert.equal(calls.at(-1), true);
    allowInput = false;
    await fetch(base + "/models", { headers });
    assert.equal(calls.at(-1), false, "Revoked control must suppress trusted resource loading");
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal", acknowledgeUnpinnedAccess: true })).status, 409);
    assert.equal((await post("/settings/resources", { mode: "isolated" })).status, 200);
    assert.equal(resources.get().mode, "isolated");
  } finally { await server.close(); await rm(dir, { recursive: true, force: true }); }
});
