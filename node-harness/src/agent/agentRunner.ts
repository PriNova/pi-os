import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { CreateAgentSessionOptions, InlineExtension } from "@earendil-works/pi-coding-agent";
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
 * Runs one desktop invocation through a pi agent session.
 *
 * Session choices:
 * - Session per invocation (in-memory): desktop tasks are independent; no
 *   stale history from earlier invocations.
 * - Pi's standard agent directory supplies the user's global extensions,
 *   skills, settings, models, and authentication alongside Computer Use.
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

export async function runAgent(options: AgentRunOptions): Promise<AgentRunResult> {
  const { hostClient, contextId, prompt, snapshot, capturesDir, log, signal, onToolCall, onActivity } = options;

  const extension = createComputerUseExtension(contextId, hostClient, capturesDir);
  const loader = await loadAgentResources(extension);

  const modelRuntime = await ModelRuntime.create();

  // Settings-page selection (if any) -> concrete model for THIS invocation.
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
      // The SDK clamps unsupported levels to model capabilities.
      sessionOptions.thinkingLevel = options.modelSelection.thinkingLevel as CreateAgentSessionOptions["thinkingLevel"];
    }
  }

  const { session } = await createAgentSession(sessionOptions);
  log(
    `[agent] model=${session.model ? `${session.model.provider}/${session.model.id}` : "default"}` +
    ` effort=${session.thinkingLevel}`,
  );

  let responseText = "";
  let toolCalls = 0;
  let providerError: string | undefined;
  session.subscribe((event) => {
    if (event.type === "tool_execution_start") {
      toolCalls += 1;
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
        // Narration started: thinking is over.
        onActivity?.(undefined);
      }
    } else if (event.type === "message_end" && event.message.role === "assistant") {
      // Keep only the most recently completed assistant message. Earlier
      // messages can be narration before tool calls, not the final answer.
      responseText = assistantMessageText(event.message);

      // Provider/model failures arrive as a synthetic assistant message
      // (stopReason "error"); prompt() still resolves normally.
      if (event.message.stopReason === "error" && event.message.errorMessage) {
        providerError = event.message.errorMessage;
        log(`[agent] provider error: ${providerError}`);
      }
    }
  });

  if (signal) {
    // The SDK has no signal input for prompt(); it exposes abort() instead.
    signal.addEventListener("abort", () => void session.abort(), { once: true });
  }

  const userMessage = [
    "## Pinned desktop context (captured before you were invoked)",
    summarizeSnapshot(snapshot),
    "",
    "## Request",
    prompt,
  ].join("\n");

  try {
    const image = snapshot.screenshot?.filePath
      ? await loadScreenshotImage(snapshot.screenshot.filePath, capturesDir).catch(() => null)
      : null;
    await session.prompt(userMessage, image ? { images: [image] } : undefined);
  } finally {
    session.dispose();
  }

  if (signal?.aborted) {
    throw abortError(signal);
  }

  if (providerError !== undefined) {
    // Fail the invocation with the real reason instead of completing empty.
    throw new Error(providerError);
  }

  return { responseText: responseText.trim(), toolCalls };
}

/** Normalize an aborted signal into a classifiable error. */
export function abortError(signal: AbortSignal): Error {
  const reason = signal.reason instanceof Error ? signal.reason : undefined;
  const error = new Error(reason?.message ?? "Invocation aborted");
  error.name = "AbortError";
  return error;
}
