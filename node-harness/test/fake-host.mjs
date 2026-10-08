import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const delay = Number.parseInt(process.env.FAKE_HOST_DELAY_MS ?? "0", 10);
const fixture = new URL("../../shared/fixtures/macos-window.json", import.meta.url);
const snapshot = JSON.parse(await readFile(fixture, "utf8"));
snapshot.id = "ctx-smoke";
snapshot.screenshot.filePath = resolve(fileURLToPath(new URL("../../shared", import.meta.url)), snapshot.screenshot.filePath);
const token = process.env.PI_OS_TOKEN;
if (!token && process.env.PI_OS_INSECURE_DEV !== "1") throw new Error("Set PI_OS_TOKEN (or PI_OS_INSECURE_DEV=1 explicitly)");
const server = createServer(async (req, res) => {
  const json = (status, payload) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(payload)); };
  if (req.url === "/health") return json(200, { service: "fake-host" });
  if (token && req.headers["x-harness-token"] !== token) return json(401, { error: { code: "unauthorized" } });
  if (req.method === "GET" && req.url === "/tools") return json(200, { tools: ["desktop.getContext", "desktop.refreshContext", "desktop.captureWindow"].map(name => ({ name })) });
  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 1_000_000) return json(413, { error: { code: "invalid_arguments" } });
  }
  let parsed;
  try { parsed = JSON.parse(body); } catch { return json(400, { error: { code: "invalid_arguments" } }); }
  if (parsed.arguments?.contextId !== snapshot.id) return json(200, { ok: false, error: { code: "unknown_context", message: "Unknown fixture" } });
  const name = req.url?.replace("/tools/", "");
  if (!["desktop.getContext", "desktop.refreshContext", "desktop.captureWindow"].includes(name)) return json(404, { error: { code: "not_found" } });
  if (delay) await new Promise(r => setTimeout(r, delay));
  json(200, { ok: true, result: name === "desktop.captureWindow" ? snapshot.screenshot : snapshot });
});
server.listen(Number(process.env.PI_OS_HOST_PORT ?? 17831), "127.0.0.1", () => console.log("[fake-host] ready; contextId=ctx-smoke"));
