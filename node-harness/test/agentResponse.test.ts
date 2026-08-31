import assert from "node:assert/strict";
import test from "node:test";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { assistantMessageText } from "../src/agent/agentRunner.js";

function assistantMessage(content: AssistantMessage["content"]): AssistantMessage {
  return { role: "assistant", content } as AssistantMessage;
}

test("extracts only visible text from a completed assistant message", () => {
  const message = assistantMessage([
    { type: "thinking", thinking: "internal reasoning" },
    { type: "text", text: "First paragraph." },
    { type: "toolCall", id: "call-1", name: "desktop_capture_window", arguments: {} },
    { type: "text", text: "Second paragraph." },
  ]);

  assert.equal(assistantMessageText(message), "First paragraph.\nSecond paragraph.");
});

test("a later completed assistant message replaces earlier narration", () => {
  let responseText = assistantMessageText(assistantMessage([
    { type: "text", text: "I will inspect the window." },
    { type: "toolCall", id: "call-1", name: "desktop_capture_window", arguments: {} },
  ]));

  responseText = assistantMessageText(assistantMessage([
    { type: "text", text: "The requested work is complete." },
  ]));

  assert.equal(responseText, "The requested work is complete.");
});
