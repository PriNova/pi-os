import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { supportDirectory } from "../platformPaths.js";

/**
 * User-selected agent model + reasoning effort, chosen in the host settings
 * page and applied by every NEW invocation (sessions are per-invocation, so
 * an in-flight invocation keeps its own model).
 *
 * Persisted at %LOCALAPPDATA%\pi-os\settings.json so the choice survives
 * restarts of the supervised harness child.
 */

export interface ModelSelection {
  provider: string;
  modelId: string;
  /** pi ThinkingLevel name; the SDK clamps to model capabilities at use time. */
  thinkingLevel: string;
}

interface SettingsFile {
  model?: Partial<ModelSelection>;
}

export class AgentModelSettings {
  private current: ModelSelection | null;

  constructor(
    private readonly filePath: string = defaultSettingsPath(),
    private readonly log: (line: string) => void = (line) => console.log(line),
  ) {
    this.current = readSelection(this.filePath, this.log);
    if (this.current) {
      const c = this.current;
      this.log(`[settings] loaded model preference ${c.provider}/${c.modelId} effort=${c.thinkingLevel}`);
    } else {
      this.log("[settings] no model preference; pi picks its automatic default");
    }
  }

  get(): ModelSelection | null {
    return this.current;
  }

  /**
   * Store and persist a validated selection. Returns the previous selection;
   * the caller logs the old -> new switch.
   */
  set(selection: ModelSelection): ModelSelection | null {
    const previous = this.current;
    this.current = {
      provider: selection.provider,
      modelId: selection.modelId,
      thinkingLevel: selection.thinkingLevel,
    };
    writeSelection(this.filePath, this.current, this.log);
    return previous;
  }
}

function defaultSettingsPath(): string {
  return join(supportDirectory(), "settings.json");
}

/** Tolerant reader: any malformed/stale file degrades to "no preference". */
function readSelection(path: string, log: (line: string) => void): ModelSelection | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null; // Missing file is the normal first-run case.
  }

  try {
    const parsed = JSON.parse(raw) as SettingsFile;
    const m = parsed?.model;
    if (
      typeof m?.provider === "string" && m.provider &&
      typeof m?.modelId === "string" && m.modelId &&
      typeof m?.thinkingLevel === "string" && m.thinkingLevel
    ) {
      return { provider: m.provider, modelId: m.modelId, thinkingLevel: m.thinkingLevel };
    }
    if (m !== undefined) {
      log(`[settings] ignoring incomplete model entry in ${path}`);
    } // Else: valid file without a model entry -> keep pi's automatic default.
  } catch (error) {
    log(`[settings] ignoring unreadable ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
  return null;
}

function writeSelection(path: string, selection: ModelSelection, log: (line: string) => void): void {
  try {
    mkdirSync(dirname(path), { recursive: true });
    const payload: SettingsFile = { model: selection };
    writeFileSync(path, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  } catch (error) {
    // Memory-only fallback: the session still honors the choice until restart.
    log(`[settings] failed writing ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
}
