import assert from "node:assert/strict";
import { test } from "node:test";
import { resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension } from "../src/agent/computerUseExtension.js";
import { loadAgentResources, READ_ONLY_TOOLS } from "../src/agent/agentRunner.js";
import { BROWSER_TOOLS } from "../src/browser/tools.js";
import { BrowserSession } from "../src/browser/session.js";
import type { HostClient } from "../src/hostClient.js";

test("Brave route replaces native mutations in the actual isolated SDK tool set", async () => {
  const dir = resolve("test/fixtures/global-agent-dir"), browser = new BrowserSession({} as HostClient, "ctx-fixed");
  const extension = createComputerUseExtension("ctx-fixed", {} as HostClient, "/captures", false, "darwin", undefined, browser);
  const loader = await loadAgentResources(extension, process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: resolve(dir, "auth.json"), modelsPath: resolve(dir, "models.json") });
  const names = [...READ_ONLY_TOOLS, ...BROWSER_TOOLS];
  const { session } = await createAgentSession({ resourceLoader: loader, modelRuntime: runtime, agentDir: dir,
    sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(), tools: names });
  try {
    assert.deepEqual(session.getAllTools().map(t => t.name).sort(), [...names].sort());
    assert.deepEqual(session.agent.state.tools.map(t => t.name).sort(), [...names].sort());
    assert(!session.agent.state.tools.some(t => t.name === "desktop_act" || t.name === "bash"));
    const schema = JSON.stringify(session.agent.state.tools.find(t => t.name === "browser_act")!.parameters);
    for (const forbidden of ['"contextId"', '"targetId"', '"url"', '"script"', '"method"', '"port"']) assert(!schema.includes(forbidden));
  } finally { session.dispose(); await browser.dispose(); }
});

test("read-only sessions never register browser authority; browser guidance forbids native fallback", () => {
  const browser = new BrowserSession({} as HostClient, "ctx-fixed");
  for (const readOnly of [true, false]) {
    const tools: string[] = []; let before: any;
    createComputerUseExtension("ctx-fixed", {} as HostClient, "/captures", readOnly, "darwin", undefined, browser).factory({
      on(name: string, callback: any) { if (name === 'before_agent_start') before = callback; },
      registerTool(tool: any) { tools.push(tool.name); },
    } as unknown as ExtensionAPI);
    assert.equal(tools.includes('browser_act'), !readOnly);
    assert(!tools.includes('desktop_act'));
    if (!readOnly) assert.match(before({ systemPrompt: '' }).systemPrompt, /desktop_act is not available/);
  }
});
