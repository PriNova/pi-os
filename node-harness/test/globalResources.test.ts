import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension } from "../src/agent/computerUseExtension.js";
import { loadAgentResources } from "../src/agent/agentRunner.js";
import type { HostClient } from "../src/hostClient.js";

const fixtureAgentDir = join(process.cwd(), "test", "fixtures", "global-agent-dir");

test("global skill and extension tool are visible beside Computer Use", async () => {
  const extension = createComputerUseExtension(
    "ctx-test",
    { invokeTool: async () => ({ ok: true, result: {} }) } as unknown as HostClient,
    join(process.cwd(), "test", "captures"),
  );
  const loader = await loadAgentResources(extension, process.cwd(), fixtureAgentDir);

  assert.ok(loader.getSkills().skills.some((skill) => skill.name === "fixture-global-skill"));

  const modelRuntime = await ModelRuntime.create({
    authPath: join(fixtureAgentDir, "auth.json"),
    modelsPath: join(fixtureAgentDir, "models.json"),
  });
  const { session } = await createAgentSession({
    agentDir: fixtureAgentDir,
    modelRuntime,
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(),
    settingsManager: SettingsManager.inMemory(),
  });

  try {
    const activeTools = session.agent.state.tools.map((tool) => tool.name);
    assert.ok(activeTools.includes("fixture_global_tool"));
    assert.ok(activeTools.includes("desktop_act"));
  } finally {
    session.dispose();
  }
});
