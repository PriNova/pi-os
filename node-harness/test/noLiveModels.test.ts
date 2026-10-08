import assert from "node:assert/strict";
import { test } from "node:test";

test("test bootstrap blocks Ollama and provider calls without opening a connection", async () => {
  assert.equal(process.env.PI_OFFLINE, "1");
  assert.equal(process.env.PI_OS_AGENT, "0");
  for (const url of ["http://127.0.0.1:11434/health", "http://127.0.0.1:11434/api/generate",
    "http://localhost:8080/v1/chat/completions", "https://api.openai.com/v1/responses"]) {
    await assert.rejects(fetch(url), /forbidden in tests/);
  }
});
