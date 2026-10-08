import type { HarnessConfig } from "./config.js";

/**
 * Client for the C# Windows host tool API (protocol.md: POST /tools/{name}).
 * Tool outcomes are data, not transport errors: target_gone & friends arrive
 * as HTTP 200 with ok:false so the agent can react to them.
 */

export interface ToolOk<T> {
  ok: true;
  result: T;
}

export interface ToolError {
  ok: false;
  error: { code: string; message: string };
}

export type ToolOutcome<T> = ToolOk<T> | ToolError;

// Mirrors shared/schemas/desktop-context.ts (canonical schema).
export interface Point2D { x: number; y: number }

export interface Rect { x: number; y: number; width: number; height: number }

export interface WindowContext {
  hwnd: string;
  processId: number;
  processName: string;
  executablePath?: string;
  commandLine?: string;
  title: string;
  className?: string;
  surface?: "finderDesktop";
  desktopWorkArea?: Rect;
  shellFolderPath?: string;
  documentPath?: string;
  bounds: Rect;
  monitorId?: string;
  dpi?: number;
  isElevated?: boolean;
}

export interface DesktopContextSnapshot {
  id: string;
  capturedAt: string;
  cursor: Point2D;
  foregroundWindow: WindowContext | null;
  windowUnderCursor: WindowContext | null;
  targetWindow: WindowContext | null;
  /** Keyboard focus only; this does not prove selection. */
  focusedElement?: UiaElementSummary | null;
  elementUnderCursor?: UiaElementSummary | null;
  /** Actual Windows desktop selection; [] explicitly means no selected icons. */
  selectedDesktopItems?: UiaElementSummary[] | null;
  selectedDesktopItemCount?: number;
  selectedDesktopItemsTruncated?: boolean;
  screenshot?: ScreenshotRef | null;
  /** Selected native Brave tab pinned before the panel; no endpoint/capability exposed. */
  browser?: { name: "Brave"; mode: "cdp"; pinned: boolean };
  monitors: MonitorSummary[];
}

export interface MonitorSummary {
  id: string;
  deviceName?: string;
  isPrimary: boolean;
  bounds: Rect;
  workArea: Rect;
  dpi?: number;
}

export interface UiaElementPathEntry {
  name?: string;
  controlType?: string;
  automationId?: string;
}

export interface UiaElementSummary {
  name?: string;
  controlType?: string;
  automationId?: string;
  className?: string;
  bounds?: Rect;
  isEnabled?: boolean;
  isKeyboardFocusable?: boolean;
  value?: string;
  parentPath?: UiaElementPathEntry[];
}

export interface ScreenshotRef {
  kind: string;
  filePath?: string;
  imageId?: string;
  bounds?: Rect;
  imageWidth?: number;
  imageHeight?: number;
}

interface ToolResponsePayload {
  ok?: unknown;
  result?: unknown;
  error?: { code?: unknown; message?: unknown };
}

export class HostClient {
  constructor(private readonly config: HarnessConfig) {}

  async invokeTool<T>(
    toolName: string,
    args: Record<string, unknown> = {},
    signal?: AbortSignal,
  ): Promise<ToolOutcome<T>> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.config.hostToken) {
      headers["X-Harness-Token"] = this.config.hostToken;
    }

    const response = await fetch(`${this.config.hostBaseUrl}/tools/${encodeURIComponent(toolName)}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ arguments: args }),
      signal,
    });

    if (!response.ok) {
      // Transport-level problem (400/401/404/500).
      throw new Error(`Host returned HTTP ${response.status} for ${toolName}`);
    }

    const payload = (await response.json()) as ToolResponsePayload;
    if (payload.ok === true) {
      return { ok: true, result: payload.result as T };
    }

    return {
      ok: false,
      error: {
        code: typeof payload.error?.code === "string" ? payload.error.code : "internal_error",
        message: typeof payload.error?.message === "string" ? payload.error.message : "Unknown host error",
      },
    };
  }

  async getToolNames(signal?: AbortSignal): Promise<string[]> {
    const headers: Record<string, string> = {};
    if (this.config.hostToken) headers["X-Harness-Token"] = this.config.hostToken;
    const response = await fetch(`${this.config.hostBaseUrl}/tools`, { headers, signal });
    if (!response.ok) throw new Error(`Host returned HTTP ${response.status} for tool discovery`);
    const body = await response.json() as { tools?: { name?: unknown }[] };
    if (!Array.isArray(body.tools)) throw new Error("Invalid host tool catalog");
    return body.tools.flatMap(tool => typeof tool.name === "string" ? [tool.name] : []);
  }

  getSnapshot(contextId: string, signal?: AbortSignal): Promise<ToolOutcome<DesktopContextSnapshot>> {
    return this.invokeTool<DesktopContextSnapshot>("desktop.getContext", { contextId }, signal);
  }
}
