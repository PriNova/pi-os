import type { AgentSession, AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, ImageContent } from "@earendil-works/pi-ai";

export interface AgentRunResult { responseText: string; toolCalls: number }

export function assistantMessageText(message: AssistantMessage): string {
  return message.content.filter((part): part is { type: "text"; text: string } => part.type === "text")
    .map(part => part.text).join("\n");
}

export function abortError(signal: AbortSignal): Error {
  const reason = signal.reason instanceof Error ? signal.reason : undefined;
  const error = new Error(reason?.message ?? "Invocation aborted");
  error.name = "AbortError";
  return error;
}

export type SessionTransport = Pick<AgentSession, "prompt" | "subscribe" | "abort" | "dispose">;

/** Owns one in-memory SDK history and its resources; never queues concurrent prompts. */
export class LiveAgentSession {
  private capture?: { responseText: string; toolCalls: number; providerError?: string };
  private closing?: Promise<void>;
  private closed = false;
  private readonly unsubscribe: () => void;
  constructor(
    private readonly session: SessionTransport,
    readonly lifetime: AbortController,
    private readonly callbacks: {
      log: (line: string) => void;
      onToolCall?: (name: string) => void;
      onActivity?: (name: string | undefined) => void;
    },
    private readonly cleanup: () => Promise<void> = async () => {},
    private readonly beforeTurn: () => void = () => {},
    private readonly imageSupport: () => boolean = () => true,
  ) {
    this.unsubscribe = session.subscribe(event => this.event(event));
  }
  private event(event: AgentSessionEvent) {
    const capture = this.capture;
    if (!capture || this.closed) return;
    if (event.type === "tool_execution_start") {
      capture.toolCalls++;
      this.callbacks.log(`[agent] tool -> ${event.toolName}`);
      this.callbacks.onToolCall?.(event.toolName);
      this.callbacks.onActivity?.(event.toolName);
    } else if (event.type === "tool_execution_end") {
      this.callbacks.onActivity?.(undefined);
    } else if (event.type === "message_update") {
      if (event.assistantMessageEvent.type === "thinking_delta") this.callbacks.onActivity?.("thinking");
      if (event.assistantMessageEvent.type === "text_delta") this.callbacks.onActivity?.(undefined);
    } else if (event.type === "message_end" && event.message.role === "assistant") {
      capture.responseText = assistantMessageText(event.message);
      if (event.message.stopReason === "error") capture.providerError = event.message.errorMessage ?? "Provider failed";
    }
  }
  get supportsImages(): boolean { return this.imageSupport(); }

  async prompt(text: string, signal?: AbortSignal, image?: ImageContent): Promise<AgentRunResult> {
    if (this.closed) throw new Error("session_closed: Start a new task");
    if (this.capture) throw new Error("not_idle: A prompt is already running");
    if (signal?.aborted) throw abortError(signal);
    this.lifetime.signal.throwIfAborted();
    const capture = { responseText: "", toolCalls: 0, providerError: undefined as string | undefined };
    this.capture = capture;
    const abort = () => { this.lifetime.abort(); void this.session.abort().catch(() => {}); };
    signal?.addEventListener("abort", abort, { once: true });
    try {
      this.beforeTurn();
      await this.session.prompt(text, { expandPromptTemplates: process.platform !== "darwin", ...(image && this.supportsImages ? { images: [image] } : {}) });
      if (signal?.aborted) throw abortError(signal);
      this.lifetime.signal.throwIfAborted();
      if (this.closed) throw new Error("session_closed: Reader was closed");
      if (capture.providerError) throw new Error(capture.providerError);
      return { responseText: capture.responseText.trim(), toolCalls: capture.toolCalls };
    } finally {
      signal?.removeEventListener("abort", abort);
      this.capture = undefined;
    }
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    // Publish the single cleanup promise before invoking re-entrant SDK callbacks.
    this.closing = Promise.resolve().then(async () => {
      try { this.session.dispose(); } catch { /* Still release browser/provider resources. */ }
      try { await this.cleanup(); } finally { this.lifetime.abort(); }
    });
    this.unsubscribe();
    // Active closure revokes browser authority synchronously, before awaiting cleanup.
    if (this.capture) { this.lifetime.abort(); void this.session.abort().catch(() => {}); }
    return this.closing;
  }
}
