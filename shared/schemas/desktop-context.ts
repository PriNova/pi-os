/**
 * Shared desktop context snapshot schema.
 *
 * Canonical source for the wire format between native hosts and the
 * TypeScript agent harness. Mirrors in host-dotnet/WindowsHarness.Contracts
 * and host-macos/Sources/PiOSCore must remain field-compatible.
 * macOS geometry uses CG global top-left points; Windows uses physical pixels.
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
  /** Actual delivered image dimensions; coordinates refer to these pixels, not desktop points. */
  imageWidth?: number;
  imageHeight?: number;
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
  /** Opaque native window ID: Win32 HWND or macOS CGWindowID encoded in hex. Always pair with processId. */
  hwnd: string;
  processId: number;
  processName: string;
  executablePath?: string;
  /** Raw process command line; exposes the open-file path for arg-launched apps (Notepad, editors, terminals). */
  commandLine?: string;
  title: string;
  className?: string;
  /** macOS Finder desktop surface; absent for ordinary windows. */
  surface?: "finderDesktop";
  desktopWorkArea?: Rect;
  /** Active folder path when the window hosts a Windows shell view (File Explorer); null otherwise. */
  shellFolderPath?: string;
  /** Native document URL path, when the pinned AX window exposes a file URL. */
  documentPath?: string;
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
  /** Optional macOS Brave route. Private endpoint/tab capabilities are not part of this snapshot. */
  browser?: { name: "Brave"; mode: "cdp"; pinned: boolean };
  monitors: MonitorSummary[];
  environment?: EnvironmentInfo;
}
