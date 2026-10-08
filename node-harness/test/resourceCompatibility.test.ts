import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { Type } from "typebox";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { AgentResourceSettings, effectiveResourceMode } from "../src/agent/resourceSettings.js";
import { loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";

test("resource compatibility is explicit, persisted, and always suppressed by read-only mode", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-os-resources-"));
  const path = join(dir, "resources.json");
  const settings = new AgentResourceSettings(path);
  try {
    assert.deepEqual(settings.get(), { mode: "isolated" });
    assert.throws(() => settings.set("trustedGlobal", false), /acknowledgement/);
    settings.set("trustedGlobal", true);
    assert.deepEqual(new AgentResourceSettings(path).get(), { mode: "trustedGlobal" });
    assert.equal(effectiveResourceMode("darwin", true, settings.get()), "isolated");
    assert.equal(effectiveResourceMode("darwin", false, settings.get()), "trustedGlobal");
    assert.equal(effectiveResourceMode("darwin", false), "isolated");
    assert.equal(effectiveResourceMode("win32", false), "trustedGlobal");
    await writeFile(path, '{"mode":"trustedGlobal"}');
    assert.equal(settings.get().mode, "isolated");
    await writeFile(path, "broken");
    assert.equal(settings.get().mode, "isolated");
    settings.set("isolated", false);
    assert.equal(JSON.parse(await readFile(path, "utf8")).trustAcknowledgement, 0);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("trusted Mac globals expose fixture resources but never load planted project extensions or context", { skip: process.platform !== "darwin" }, async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-os-global-compat-"));
  const dir = resolve("test/fixtures/global-agent-dir");
  await mkdir(join(cwd, ".pi/extensions"), { recursive: true });
  await writeFile(join(cwd, ".pi/extensions/evil.ts"), "throw new Error('PROJECT_CODE_EXECUTED')");
  await writeFile(join(cwd, "AGENTS.md"), "PROJECT_CONTEXT_MUST_NOT_APPEAR");
  try {
    const loader = await loadAgentResources({ name: "fixture", factory() {} }, cwd, dir, false);
    assert.equal(loader.getExtensions().errors.length, 0);
    assert.ok(loader.getSkills().skills.some(skill => skill.name === "fixture-global-skill"));
    assert.ok(!loader.getAgentsFiles().agentsFiles.some(file => file.content.includes("PROJECT_CONTEXT_MUST_NOT_APPEAR")));
    const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json") });
    const { session } = await createAgentSession({ cwd, agentDir: dir, modelRuntime: runtime, resourceLoader: loader,
      sessionManager: SessionManager.inMemory(cwd), settingsManager: SettingsManager.inMemory() });
    try {
      const tools = session.getAllTools().map(tool => tool.name);
      assert.ok(tools.includes("fixture_global_tool"));
      assert.ok(tools.includes("bash"));
    } finally { session.dispose(); }
  } finally { await rm(cwd, { recursive: true, force: true }); }
});

test("trusted extension providers are registered before model selection without startup hooks or inference", async () => {
  const dir = resolve("test/fixtures/global-agent-dir");
  let started = 0;
  let activeTools: (() => string[]) | undefined;
  const loader = await loadAgentResources({ name: "fixture-provider", factory(pi) {
    pi.on("session_start", async () => { started += 1; });
    activeTools = () => pi.getActiveTools();
    pi.registerTool({ name: "fixture_probe", label: "Probe", description: "Fixture", parameters: Type.Object({}),
      async execute() { return { content: [{ type: "text", text: "fixture" }], details: {} }; } });
    pi.registerProvider("fixture-custom", { baseUrl: "https://never-called.invalid/v1", apiKey: "fixture-key", api: "openai-completions",
      models: [{ id: "fixture-model", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  } }, process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json") });
  assert.equal(runtime.getModel("fixture-custom", "fixture-model"), undefined);
  const disposeBootstrap = await registerResourceProviders(loader, runtime);
  try {
    assert.equal(runtime.getModel("fixture-custom", "fixture-model")?.id, "fixture-model");
    const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader,
      model: runtime.getModel("fixture-custom", "fixture-model"), tools: ["fixture_probe"],
      settingsManager: SettingsManager.inMemory(), sessionManager: SessionManager.inMemory() });
    try { assert.deepEqual(activeTools!(), ["fixture_probe"]); }
    finally { session.dispose(); }
    assert.equal(started, 0);
  } finally { disposeBootstrap(); }
});
