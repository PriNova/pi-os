import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentModelSettings } from "../src/agent/modelSettings.js";

function tempStore(): string {
  return join(mkdtempSync(join(tmpdir(), "pi-os-settings-")), "settings.json");
}

function quietLog(): (line: string) => void {
  return () => {};
}

test("missing file -> no preference", () => {
  const store = new AgentModelSettings(tempStore(), quietLog);
  assert.equal(store.get(), null);
});

test("set persists a readable selection and returns the previous one", () => {
  const path = tempStore();
  const store = new AgentModelSettings(path, quietLog);

  const first = store.set({ provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });
  assert.equal(first, null);

  // Reload from disk in a fresh instance to prove persistence.
  const reloaded = new AgentModelSettings(path, quietLog);
  assert.deepEqual(reloaded.get(), { provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });

  const previous = store.set({ provider: "xai", modelId: "grok-4", thinkingLevel: "off" });
  assert.deepEqual(previous, { provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });
  assert.equal(
    JSON.parse(readFileSync(path, "utf8")).model.modelId,
    "grok-4",
  );
});

test("malformed or incomplete files degrade to no preference", () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-settings-"));

  for (const [name, content] of [
    ["broken.json", "{not json"],
    ["incomplete.json", JSON.stringify({ model: { provider: "openai" } })],
    ["empty.json", ""],
  ] as const) {
    const path = join(dir, name);
    writeFileSync(path, content, "utf8");
    const store = new AgentModelSettings(path, quietLog);
    assert.equal(store.get(), null, name);
  }
});
