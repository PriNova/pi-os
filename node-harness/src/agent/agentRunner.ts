import type { AssistantMessage } from "@earendil-works/pi-ai";
import type {
  AgentSession,
  CreateAgentSessionOptions,
  InlineExtension,
} from "@earendil-works/pi-coding-agent";
import {
  createAgentSession,
  DefaultResourceLoader,
  getAgentDir,
  ModelRuntime,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import type { HostClient, DesktopContextSnapshot, ScreenshotRef } from "../hostClient.js";
import { createComputerUseExtension } from "./computerUseExtension.js";
import { loadScreenshotImage } from "./screenshotImage.js";
import { resolveModel } from "./modelCatalog.js";

/**
 * Live pi sessions for sequential follow-ups.
 *
 * KISS: one live session per invocation id. The first prompt creates it
 * (with the pinned context summary + screenshot). Follow-up prompts reuse
 * the same session object so the agent keeps history. The session is
 * disposed only when the reader window closes.
 *
 * Pi's standard agent directory supplies the user's global extensions,
 * skills, settings, models, and authentication alongside Computer Use.
 * Compaction stays inside pi; pi-os keeps the thread's original model.
 */

export interface LiveAgentSession {
  session: AgentSession;
  contextId: string;
  /** Per-prompt capture; set before each prompt(), read after it resolves. */
  capture: { responseText: string; toolCalls: number; providerError?: string } | null;
}

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
  snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null };
  capturesDir: string;
  log: (line: string) => void;
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

export interface LiveSessionCreateOptions {
  hostClient: HostClient;
  contextId: string;
  capturesDir: string;
  log: (line: string) => void;
  modelSelection?: ModelSelectionOption | null;
  onToolCall?: (toolName: string) => void;
  onActivity?: (activity: string | undefined) => void;
}

export interface AgentRunResult {
  responseText: string;
  toolCalls: number;
}

/** Extract the visible text from one completed assistant message. */
export function assistantMessageText(message: AssistantMessage): string {
  return message.content
    .filter((part): part is { type: "text"; text: string } => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

/** Compact summary injected into the prompt; full detail stays on tools. */
export function summarizeSnapshot(snapshot: DesktopContextSnapshot): string {
  const pickWindow = (window: DesktopContextSnapshot["targetWindow"]) =>
    window && {
      process: `${window.processName} (${window.processId})`,
      title: window.title,
      className: window.className,
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

export async function loadAgentResources(
  extension: InlineExtension,
  cwd = process.cwd(),
  agentDir = getAgentDir(),
): Promise<DefaultResourceLoader> {
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir,
    extensionFactories: [extension],
  });
  await loader.reload();
  return loader;
}

/** Create a live session without prompting. The caller owns dispose(). */
export async function createLiveSession(options: LiveSessionCreateOptions): Promise<LiveAgentSession> {
  const { hostClient, contextId, capturesDir, log, onToolCall, onActivity } = options;

  const extension = createComputerUseExtension(contextId, hostClient, capturesDir);
  const loader = await loadAgentResources(extension);

  const modelRuntime = await ModelRuntime.create();

  const resolved = resolveModel(modelRuntime, options.modelSelection);
  if (resolved.fallbackReason) {
    log(`[agent] ${resolved.fallbackReason}; using pi's automatic default`);
  }

  const sessionOptions: CreateAgentSessionOptions = {
    modelRuntime,
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(),
  };
  if (resolved.model) {
    sessionOptions.model = resolved.model;
    if (options.modelSelection?.thinkingLevel) {
      sessionOptions.thinkingLevel = options.modelSelection.thinkingLevel as CreateAgentSessionOptions["thinkingLevel"];
    }
  }

  const { session } = await createAgentSession(sessionOptions);
  log(
    `[agent] model=${session.model ? `${session.model.provider}/${session.model.id}` : "default"}` +
    ` effort=${session.thinkingLevel}`,
  );

  const live: LiveAgentSession = { session, contextId, capture: null };
  session.subscribe((event) => {
    const capture = live.capture;
    if (event.type === "tool_execution_start") {
      if (capture) {
        capture.toolCalls += 1;
      }
      log(`[agent] tool -> ${event.toolName}`);
      onToolCall?.(event.toolName);
      onActivity?.(event.toolName);
    } else if (event.type === "tool_execution_end") {
      onActivity?.(undefined);
    } else if (event.type === "message_update") {
      const kind = event.assistantMessageEvent.type;
      if (kind === "thinking_delta") {
        onActivity?.("thinking");
      } else if (kind === "text_delta") {
        onActivity?.(undefined);
      }
    } else if (event.type === "message_end" && event.message.role === "assistant" && capture) {
      capture.responseText = assistantMessageText(event.message);
      if (event.message.stopReason === "error" && event.message.errorMessage) {
        capture.providerError = event.message.errorMessage;
        log(`[agent] provider error: ${capture.providerError}`);
      }
    }
  });

  return live;
}

function wireAbort(session: AgentSession, signal?: AbortSignal): void {
  if (signal) {
    signal.addEventListener("abort", () => void session.abort(), { once: true });
  }
}

function throwIfAbortedOrFailed(
  live: LiveAgentSession,
  signal?: AbortSignal,
): { responseText: string; toolCalls: number } {
  const capture = live.capture;
  if (signal?.aborted) {
    throw abortError(signal);
  }
  if (capture?.providerError !== undefined) {
    throw new Error(capture.providerError);
  }
  return {
    responseText: (capture?.responseText ?? "").trim(),
    toolCalls: capture?.toolCalls ?? 0,
  };
}

/** First prompt on a live session: pinned context summary + screenshot. */
export async function promptFirst(
  live: LiveAgentSession,
  snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null },
  prompt: string,
  capturesDir: string,
  signal?: AbortSignal,
): Promise<AgentRunResult> {
  live.capture = { responseText: "", toolCalls: 0 };
  wireAbort(live.session, signal);

  const userMessage = [
    "## Pinned desktop context (captured before you were invoked)",
    summarizeSnapshot(snapshot),
    "",
    "## Request",
    prompt,
  ].join("\n");

  const image = snapshot.screenshot?.filePath
    ? await loadScreenshotImage(snapshot.screenshot.filePath, capturesDir).catch(() => null)
    : null;
  await live.session.prompt(userMessage, image ? { images: [image] } : undefined);
  return throwIfAbortedOrFailed(live, signal);
}

/** Follow-up prompt on an idle live session: plain text, history is kept by pi. */
export async function promptFollowup(
  live: LiveAgentSession,
  prompt: string,
  signal?: AbortSignal,
): Promise<AgentRunResult> {
  live.capture = { responseText: "", toolCalls: 0 };
  wireAbort(live.session, signal);
  await live.session.prompt(prompt);
  return throwIfAbortedOrFailed(live, signal);
}

/** One-shot helper (first prompt + dispose). Kept for slice tests callers. */
export async function runAgent(options: AgentRunOptions): Promise<AgentRunResult> {
  const { hostClient, contextId, prompt, snapshot, capturesDir, log, signal, onToolCall, onActivity } = options;
  const live = await createLiveSession({
    hostClient,
    contextId,
    capturesDir,
    log,
    modelSelection: options.modelSelection,
    onToolCall,
    onActivity,
  });
  try {
    return await promptFirst(live, snapshot, prompt, capturesDir, signal);
  } finally {
    try {
      live.session.dispose();
    } catch {
      // Best-effort.
    }
  }
}

/** Normalize an aborted signal into a classifiable error. */
export function abortError(signal: AbortSignal): Error {
  const reason = signal.reason instanceof Error ? signal.reason : undefined;
  const error = new Error(reason?.message ?? "Invocation aborted");
  error.name = "AbortError";
  return error;
}
