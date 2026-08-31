import { loadConfig } from "./config.js";
import { HarnessServer } from "./server.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const server = new HarnessServer(config);
  await server.listen();

  console.log(`[harness] node harness listening on http://127.0.0.1:${config.port}`);
  console.log(`[harness] host expected at ${config.hostBaseUrl}`);

  const shutdown = async (): Promise<void> => {
    console.log("[harness] shutting down");
    await server.close().catch(() => {});
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

void main().catch((error) => {
  console.error("[harness] fatal:", error);
  process.exit(1);
});
