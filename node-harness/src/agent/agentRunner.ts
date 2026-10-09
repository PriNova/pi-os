import type { CreateAgentSessionOptions } from "@earendil-works/pi-coding-agent";
import {
  createAgentSession,
  getAgentDir,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import type { HostClient, DesktopContextSnapshot, ScreenshotRef } from "../hostClient.js";
import { createComputerUseExtension } from "./computerUseExtension.js";
import { BrowserSession } from "../browser/session.js";
import { BROWSER_TOOLS } from "../browser/tools.js";
import { LiveAgentSession, abortError, type AgentRunResult } from "./liveSession.js";
export { LiveAgentSession, abortError, assistantMessageText, type AgentRunResult } from "./liveSession.js";
import { loadScreenshotImage } from "./screenshotImage.js";
import { resolveModel } from "./modelCatalog.js";
import { loadAgentResources, registerResourceProviders } from "./resources.js";
import { effectiveResourceMode, TRUST_WARNING, type ResourceSelection } from "./resourceSettings.js";
export { loadAgentResources } from "./resources.js";

/**
 * One in-memory session per pinned thread; sequential follow-ups retain history,
 * original model and resource scope. One-shot callers still dispose immediately.
 */

/** Model + reasoning effort chosen in the settings page (modelSettings.ts). */
export interface ModelSelectionOption {
  provider: string;
  modelId: string;
  thinkingLevel: string;
}

export interface AgentRunOptions {
  hostClient: HostClient;
  contextId: string;
  prompt: string;
  /** Defaults to true; does not restrict later screenshot tools. */
  includeScreenshot?: boolean;
  snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null };
  capturesDir: string;
  log: (line: string) => void;
  /** Per-invocation host capabilities. Mac tools remain isolated even when input is enabled. */
  readOnly?: boolean;
  resourceSelection?: ResourceSelection;
  /** Stored settings selection; undefined/invalid falls back to pi's default. */
  modelSelection?: ModelSelectionOption | null;
  /** Abort signal; when fired the pi session is aborted and runAgent throws AbortError. */
  signal?: AbortSignal;
  /** Called on every agent tool execution start (for live invocation status). */
  onToolCall?: (toolName: string) => void;
  /** Live activity marker for the host pill: tool name while a tool runs,
   * "thinking" during reasoning, undefined when idle. */
  onActivity?: (activity: string | undefined) => void;
}

/** Compact summary injected into the prompt; full detail stays on tools. */
export function summarizeSnapshot(snapshot: DesktopContextSnapshot): string {
  const pickWindow = (window: DesktopContextSnapshot["targetWindow"]) =>
    window && {
      process: `${window.processName} (${window.processId})`,
      title: window.title,
      className: window.className,
      surface: window.surface,
      shellFolderPath: window.shellFolderPath,
      documentPath: window.documentPath,
      hwnd: window.hwnd,
      bounds: window.bounds,
      monitorId: window.monitorId,
      dpi: window.dpi,
    };
  const pickElement = (element: DesktopContextSnapshot["focusedElement"]) =>
    element && {
      name: element.name,
      controlType: element.controlType,
      value: element.value,
      bounds: element.bounds,
    };
  const cursorMonitor = snapshot.monitors.find(({ bounds }) =>
    snapshot.cursor.x >= bounds.x && snapshot.cursor.x < bounds.x + bounds.width
    && snapshot.cursor.y >= bounds.y && snapshot.cursor.y < bounds.y + bounds.height);

  return JSON.stringify(
    {
      targetWindow: pickWindow(snapshot.targetWindow),
      browser: snapshot.browser,
      foregroundWindow: pickWindow(snapshot.foregroundWindow),
      windowUnderCursor: pickWindow(snapshot.windowUnderCursor),
      focusedElement: snapshot.focusedElement && {
        meaning: "keyboard focus only; does not imply selection",
        ...pickElement(snapshot.focusedElement),
      },
      elementUnderCursor: pickElement(snapshot.elementUnderCursor),
      selectedDesktopItems: snapshot.selectedDesktopItems?.map(pickElement),
      selectedDesktopItemCount: snapshot.selectedDesktopItemCount,
      selectedDesktopItemsTruncated: snapshot.selectedDesktopItemsTruncated,
      screenshot: snapshot.screenshot && {
        imageWidth: snapshot.screenshot.imageWidth, imageHeight: snapshot.screenshot.imageHeight,
        bounds: snapshot.screenshot.bounds,
      },
      cursor: { ...snapshot.cursor, monitorId: cursorMonitor?.id },
      monitors: snapshot.monitors.map(monitor => ({
        id: monitor.id,
        deviceName: monitor.deviceName,
        isPrimary: monitor.isPrimary,
        bounds: monitor.bounds,
        workArea: monitor.workArea,
        dpi: monitor.dpi,
      })),
    },
    null,
    1,
  );
}

export const READ_ONLY_TOOLS = ["desktop_get_context", "desktop_refresh_context", "desktop_capture_window"];

export async function runAgent(options: AgentRunOptions): Promise<AgentRunResult> {
  const live = await createLiveSession(options);
  try { return await promptFirst(live, options); }
  finally { await live.close(); }
}

export async function createLiveSession(options: AgentRunOptions): Promise<LiveAgentSession> {
  const { hostClient, contextId, snapshot, capturesDir, log, signal, onToolCall, onActivity } = options;
  const lifetime = new AbortController();
  const readOnly = options.readOnly ?? process.platform === "darwin";
  const browser = process.platform === "darwin" && !readOnly && snapshot.browser?.mode === "cdp"
    ? new BrowserSession(hostClient, contextId, lifetime.signal) : undefined;

  if (signal?.aborted) throw abortError(signal);
  const isolated = effectiveResourceMode(process.platform, readOnly, options.resourceSelection) === "isolated";
  const extension = createComputerUseExtension(contextId, hostClient, capturesDir, readOnly, process.platform, options.includeScreenshot === false ? undefined : snapshot.screenshot?.imageId, browser);
  const loader = await loadAgentResources(extension, process.cwd(), getAgentDir(), isolated);

  const modelRuntime = await ModelRuntime.create();
  const disposeProviderBootstrap = !isolated ? await registerResourceProviders(loader, modelRuntime) : undefined;
  if (signal?.aborted) { disposeProviderBootstrap?.(); throw abortError(signal); }

  // Settings-page selection (if any) -> concrete model for THIS invocation.
  const resolved = resolveModel(modelRuntime, options.modelSelection);
  if (resolved.fallbackReason) {
    log(`[agent] ${resolved.fallbackReason}; using pi's automatic default`);
  }

  const sessionOptions: CreateAgentSessionOptions = {
    modelRuntime,
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(),
    ...(isolated ? {
      tools: readOnly ? READ_ONLY_TOOLS : [...READ_ONLY_TOOLS, ...(browser ? BROWSER_TOOLS : ["desktop_act"])],
    } : {}),
    ...(process.platform === "darwin" || isolated ? {
      settingsManager: SettingsManager.create(process.cwd(), getAgentDir(), { projectTrusted: false }),
    } : {}),
  };
  if (resolved.model) {
    sessionOptions.model = resolved.model;
    if (options.modelSelection?.thinkingLevel) {
      // The SDK clamps unsupported levels to model capabilities.
      sessionOptions.thinkingLevel = options.modelSelection.thinkingLevel as CreateAgentSessionOptions["thinkingLevel"];
    }
  }

  let created: Awaited<ReturnType<typeof createAgentSession>>;
  try { created = await createAgentSession(sessionOptions); }
  catch (error) { disposeProviderBootstrap?.(); throw error; }
  const { session } = created;
  log(
    `[agent] model=${session.model ? `${session.model.provider}/${session.model.id}` : "default"}` +
    ` effort=${session.thinkingLevel}`,
  );

  let first = true;
  return new LiveAgentSession(session, lifetime, { log, onToolCall, onActivity }, async () => {
    try { await browser?.dispose(); } finally { disposeProviderBootstrap?.(); }
  }, () => {
    if (!first) { extension.invalidateScreenshot(); browser?.invalidateReferences(); }
    first = false;
  });
}

export async function promptFirst(live: LiveAgentSession, options: AgentRunOptions): Promise<AgentRunResult> {
  const { snapshot, prompt, capturesDir, signal } = options;
  const isolated = effectiveResourceMode(process.platform, options.readOnly ?? process.platform === "darwin", options.resourceSelection) === "isolated";
  const userMessage = [
    "## Desktop context (target identity pinned before the prompt appeared)",
    summarizeSnapshot(snapshot),
    ...(options.includeScreenshot === false ? ["The user disabled the initial screenshot attachment. No image is attached; screenshot tools remain available if needed."] : []),
    "",
    ...(!isolated && process.platform === "darwin" ? ["## Trusted pi compatibility", TRUST_WARNING,
      "Desktop tool refusals must not be bypassed through another input path.", ""] : []),
    "## Request",
    prompt,
  ].join("\n");

  if (signal?.aborted) throw abortError(signal);
  const image = options.includeScreenshot !== false && snapshot.screenshot?.filePath
    ? await loadScreenshotImage(snapshot.screenshot.filePath, capturesDir) : undefined;
  return live.prompt(userMessage, signal, image);
}

export function promptFollowup(live: LiveAgentSession, prompt: string, signal?: AbortSignal): Promise<AgentRunResult> {
  if (process.platform !== "darwin") return live.prompt(prompt, signal);
  return live.prompt([
    "## Follow-up on the same pinned target",
    "Keep the thread's original target; never retarget. Earlier screenshots and browser references are historical.",
    "Take a fresh desktop_capture_window or browser_snapshot before acting. All safety and cumulative input budgets still apply.",
    "## Request", prompt,
  ].join("\n"), signal);
}
