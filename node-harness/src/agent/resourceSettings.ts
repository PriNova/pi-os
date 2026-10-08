import { mkdirSync, readFileSync, renameSync, writeFileSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { supportDirectory } from "../platformPaths.js";

export type ResourceMode = "isolated" | "trustedGlobal";
export interface ResourceSelection { mode: ResourceMode }
export const TRUST_WARNING = "Trusted pi compatibility loads your global extensions, skills, prompts and coding tools. Extensions execute code with pi-os permissions; these tools are not confined to the pinned window. Enable only for code you trust.";

/** Separate from model settings. Missing/malformed/unacknowledged files fail closed. */
export class AgentResourceSettings {
  constructor(private readonly path = join(supportDirectory(), "resources.json")) {}
  get(): ResourceSelection {
    try {
      if (statSync(this.path).size > 16_384) return { mode: "isolated" };
      const parsed = JSON.parse(readFileSync(this.path, "utf8"));
      if (parsed.mode === "trustedGlobal" && parsed.trustAcknowledgement === 1) return { mode: "trustedGlobal" };
    } catch { /* first run or malformed: isolated */ }
    return { mode: "isolated" };
  }
  set(mode: ResourceMode, acknowledgeUnpinnedAccess: boolean): ResourceSelection {
    if (mode === "trustedGlobal" && !acknowledgeUnpinnedAccess) throw new Error("Explicit trust acknowledgement is required");
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporary, JSON.stringify({ mode, trustAcknowledgement: mode === "trustedGlobal" ? 1 : 0 }) + "\n", { mode: 0o600 });
      renameSync(temporary, this.path);
    } finally { rmSync(temporary, { force: true }); }
    return this.get();
  }
}

export function effectiveResourceMode(platform: NodeJS.Platform, readOnly: boolean, selection?: ResourceSelection): ResourceMode {
  if (readOnly) return "isolated";
  if (platform !== "darwin") return "trustedGlobal"; // Preserve existing Windows resource behavior.
  return selection?.mode === "trustedGlobal" ? "trustedGlobal" : "isolated";
}
