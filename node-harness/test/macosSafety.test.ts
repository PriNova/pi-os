import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension } from "../src/agent/computerUseExtension.js";
import { loadAgentResources, READ_ONLY_TOOLS } from "../src/agent/agentRunner.js";
import { loadScreenshotImage } from "../src/agent/screenshotImage.js";
import { supportDirectory } from "../src/platformPaths.js";
import type { HostClient } from "../src/hostClient.js";

test("Darwin paths preserve Windows defaults and explicit overrides", () => {
  assert.equal(supportDirectory({}, "darwin", "/Users/test"), "/Users/test/Library/Application Support/pi-os");
  assert.equal(supportDirectory({ PI_OS_SUPPORT_DIR: "/custom" }, "darwin", "/Users/test"), "/custom");
  assert.equal(supportDirectory({ LOCALAPPDATA: "/local" }, "win32", "/home"), join("/local", "pi-os"));
});

test("read-only agent has exactly the pinned observation tools, no global or planted project resources", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-os-isolation-"));
  const cwd = join(root, "agent-cwd");
  const agentDir = resolve("test/fixtures/global-agent-dir");
  await mkdir(join(cwd, ".pi/extensions"), { recursive: true });
  await writeFile(join(root, "AGENTS.md"), "THIS_PROJECT_CONTEXT_MUST_NOT_LOAD");
  await writeFile(join(cwd, ".pi/extensions/evil.ts"), "throw new Error('PROJECT_EXTENSION_EXECUTED')");
  await writeFile(join(cwd, ".pi/SYSTEM.md"), "THIS_SYSTEM_PROMPT_MUST_NOT_LOAD");
  const extension = createComputerUseExtension("ctx-pinned", {} as HostClient, root, true);
  try {
    const loader = await loadAgentResources(extension, cwd, agentDir, true);
    assert.deepEqual(loader.getSkills().skills, []);
    assert.deepEqual(loader.getAgentsFiles().agentsFiles, []);
    assert.equal(loader.getExtensions().errors.length, 0);
    assert.equal(loader.getExtensions().extensions.length, 1);
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json") });
    const { session } = await createAgentSession({
      cwd, agentDir, resourceLoader: loader, modelRuntime: runtime,
      tools: READ_ONLY_TOOLS, sessionManager: SessionManager.inMemory(cwd),
      settingsManager: SettingsManager.create(cwd, agentDir, { projectTrusted: false }),
    });
    try {
      assert.deepEqual(session.agent.state.tools.map(t => t.name).sort(), [...READ_ONLY_TOOLS].sort());
      assert.deepEqual(session.getAllTools().map(t => t.name).sort(), [...READ_ONLY_TOOLS].sort());
      assert.doesNotMatch(session.agent.state.systemPrompt, /THIS_PROJECT_CONTEXT|THIS_SYSTEM_PROMPT/);
    } finally { session.dispose(); }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("PNG containment resolves symlinks and accepts a trusted root alias", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-os-paths-"));
  const captures = join(root, "captures");
  await mkdir(captures);
  const png = await readFile(resolve("../shared/fixtures/captures/window.png"));
  await writeFile(join(captures, "shot.png"), png);
  await writeFile(join(root, "outside.png"), png);
  try {
    await symlink(captures, join(root, "alias"), "junction");
    const image = await loadScreenshotImage(join(captures, "shot.png"), join(root, "alias"));
    assert.equal(image.data, png.toString("base64"));
    // Directory symlink works on Windows without file-symlink privilege as well.
    await symlink(root, join(captures, "escape"), "junction");
    await assert.rejects(loadScreenshotImage(join(captures, "escape/outside.png"), captures), /outside/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
