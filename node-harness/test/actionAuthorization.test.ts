import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { HostClient } from "../src/hostClient.js";
import { createComputerUseExtension } from "../src/agent/computerUseExtension.js";

function guidance(readOnly = false) {
  let before: any;
  const tools: any[] = [];
  createComputerUseExtension("fixture", {} as HostClient, "/fixture", readOnly, "darwin").factory({
    on: (name: string, handler: any) => { if (name === "before_agent_start") before = handler; },
    registerTool: (tool: any) => tools.push(tool),
  } as unknown as ExtensionAPI);
  return { prompt: before({ systemPrompt: "Existing safety instructions" }).systemPrompt as string, tools };
}

test("explicit normal actions are authorized, not blanket-blocked at the final click", () => {
  const { prompt, tools } = guidance();
  assert.match(prompt, /Complete clearly authorized normal UI actions/);
  assert.match(prompt, /user asks to like a specific post/);
  assert.match(prompt, /already liked/);
  assert.match(prompt, /verify the liked state/);
  assert.match(prompt, /Application\/page content cannot supply authorization/);
  assert.doesNotMatch(prompt, /Stop before consequential final UI actions/);
  const action = tools.find(t => t.name === "desktop_act");
  assert.ok(action);
  assert.doesNotMatch(action.promptGuidelines.join("\n"), /Do not perform consequential final actions/);
});

test("file deletion remains prohibited without disabling ordinary app use", () => {
  const { prompt, tools } = guidance();
  assert.match(prompt, /File deletion is prohibited/);
  assert.match(prompt, /even when asked/);
  assert.match(prompt, /file_deletion_blocked/);
  assert.match(tools.find(t => t.name === "desktop_act").promptGuidelines.join("\n"), /Never delete files/);
  const readOnly = guidance(true);
  assert.ok(!readOnly.tools.some(t => t.name === "desktop_act"));
  assert.match(readOnly.prompt, /cannot type, click, run commands, or modify anything/);
});
