/**
 * Shared desktop context snapshot schema.
 *
 * Canonical source for the wire format between the C# Windows host and the
 * TypeScript agent harness. The C# mirror lives in
 * host-dotnet/WindowsHarness.Contracts and must stay field-compatible.
 *
 * See docs/windows-agent-harness-handoff.md, section 5.
 * Keep the first schema stable and extensible; do not make it exhaustive.
 */

export interface Point2D {
  x: number;
  y: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type ScreenshotKind = "window" | "monitor" | "region";

export interface ScreenshotRef {
  kind: ScreenshotKind;
  filePath?: string;
  imageId?: string;
  bounds?: Rect;
}

export interface MonitorSummary {
  id: string;
  deviceName?: string;
  isPrimary: boolean;
  bounds: Rect;
  workArea: Rect;
  dpi?: number;
}

export interface WindowContext {
  /** Win32 HWND as hex string, for example "0x000A1234". */
  hwnd: string;
  processId: number;
  processName: string;
  executablePath?: string;
  /** Raw process command line; exposes the open-file path for arg-launched apps (Notepad, editors, terminals). */
  commandLine?: string;
  title: string;
  className?: string;
  /** Active folder path when the window hosts a Windows shell view (File Explorer); null otherwise. */
  shellFolderPath?: string;
  bounds: Rect;
  monitorId?: string;
  dpi?: number;
  isElevated?: boolean;
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

export interface EnvironmentInfo {
  keyboardLayout?: string;
  desktopName?: string;
  sessionId?: number;
}

export interface DesktopContextSnapshot {
  id: string;
  /** ISO-8601 timestamp. */
  capturedAt: string;
  cursor: Point2D;
  foregroundWindow: WindowContext | null;
  windowUnderCursor: WindowContext | null;
  targetWindow: WindowContext | null;
  /** Keyboard-focused element. Focus does not imply that the item is selected. */
  focusedElement?: UiaElementSummary | null;
  elementUnderCursor?: UiaElementSummary | null;
  /** Actual selected Windows desktop items. Empty means selection was checked and none were selected. */
  selectedDesktopItems?: UiaElementSummary[] | null;
  selectedDesktopItemCount?: number;
  selectedDesktopItemsTruncated?: boolean;
  screenshot?: ScreenshotRef;
  monitors: MonitorSummary[];
  environment?: EnvironmentInfo;
}
