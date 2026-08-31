import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Environment-driven configuration for the node harness.
 * Defaults match shared/protocol/protocol.md.
 */
export interface HarnessConfig {
  port: number;
  hostBaseUrl: string;
  hostToken: string | undefined;
  /** Routes invocations through a real pi agent session.
   *  Default ON since 2026-08-24 (product decision): slice mode only helps
   *  headless smoke tests. Opt out with PI_OS_AGENT=0 or =false. */
  agentEnabled: boolean;
  /** Max wall-clock time per invocation in ms (PI_OS_INVOKE_TIMEOUT_MS). 0 disables. Default: 5 min. */
  invokeTimeoutMs: number;
  /** Trusted directory where the C# host writes screenshots. */
  capturesDir: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): HarnessConfig {
  return {
    port: Number.parseInt(env.PI_OS_NODE_PORT ?? "17832", 10),
    hostBaseUrl: env.PI_OS_HOST_URL ?? "http://127.0.0.1:17831",
    hostToken: env.PI_OS_TOKEN,
    agentEnabled: parseAgentEnabled(env.PI_OS_AGENT),
    invokeTimeoutMs: parseTimeoutMs(env.PI_OS_INVOKE_TIMEOUT_MS),
    capturesDir: env.PI_OS_CAPTURES_DIR
      ?? join(env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "pi-os", "captures"),
  };
}

function parseTimeoutMs(raw: string | undefined): number {
  const value = Number.parseInt(raw ?? "300000", 10);
  return Number.isFinite(value) && value >= 0 ? value : 300_000;
}

/** Unset -> true (agent mode is the product); explicit 0/false -> slice mode. */
function parseAgentEnabled(raw: string | undefined): boolean {
  if (raw === undefined || raw.trim() === "") {
    return true;
  }
  return !["0", "false"].includes(raw.trim().toLowerCase());
}
