import Foundation

public struct Point: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// All Mac wire geometry is CG global top-left points, never AppKit coordinates.
public struct Rect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.y >= y && p.x < x + width && p.y < y + height
    }
    public var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

public struct WindowContext: Codable, Equatable {
    public var hwnd: String
    public var processId: Int32
    public var processName: String
    public var executablePath: String?
    public var shellFolderPath: String?
    public var documentPath: String?
    public var title: String
    public var className: String?
    public var surface: String?
    public var desktopWorkArea: Rect?
    public var bounds: Rect
    public var monitorId: String?
    public init(windowID: UInt32, pid: Int32, name: String, title: String, bounds: Rect,
                executablePath: String? = nil, monitorId: String? = nil) {
        hwnd = String(format: "0x%X", windowID); processId = pid; processName = name
        self.title = title; self.bounds = bounds; self.executablePath = executablePath
        self.monitorId = monitorId
    }
    public var windowID: UInt32? { UInt32(hwnd.hasPrefix("0x") ? String(hwnd.dropFirst(2)) : hwnd, radix: 16) }
}

public struct Monitor: Codable, Equatable {
    public var id: String
    public var deviceName: String?
    public var isPrimary: Bool
    public var bounds: Rect
    public var workArea: Rect
    public init(id: String, name: String?, primary: Bool, bounds: Rect, workArea: Rect) {
        self.id = id; deviceName = name; isPrimary = primary; self.bounds = bounds; self.workArea = workArea
    }
}

public struct ElementSummary: Codable, Equatable {
    public var name: String?
    public var controlType: String?
    public var bounds: Rect?
    public var isEnabled: Bool?
    public var isKeyboardFocusable: Bool?
    public var value: String?
    public init(name: String? = nil, controlType: String? = nil, bounds: Rect? = nil,
                isEnabled: Bool? = nil, isKeyboardFocusable: Bool? = nil, value: String? = nil) {
        self.name = name; self.controlType = controlType; self.bounds = bounds
        self.isEnabled = isEnabled; self.isKeyboardFocusable = isKeyboardFocusable; self.value = value
    }
}

public struct ScreenshotRef: Codable, Equatable {
    public var kind = "window"
    public var filePath: String?
    public var imageId: String?
    public var bounds: Rect?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public init(filePath: String, imageId: String, bounds: Rect, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        self.filePath = filePath; self.imageId = imageId; self.bounds = bounds
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }
}

public struct Snapshot: Codable, Equatable {
    public var id: String
    public var capturedAt: String
    public var cursor: Point
    public var foregroundWindow: WindowContext?
    public var windowUnderCursor: WindowContext?
    public var targetWindow: WindowContext?
    public var focusedElement: ElementSummary?
    public var elementUnderCursor: ElementSummary?
    public var selectedDesktopItems: [ElementSummary]?
    public var selectedDesktopItemCount: Int?
    public var selectedDesktopItemsTruncated: Bool?
    public var screenshot: ScreenshotRef?
    public var browser: BrowserHint?
    public var monitors: [Monitor]
    public init(id: String = "ctx-" + UUID().uuidString, cursor: Point,
                target: WindowContext?, underCursor: WindowContext?, monitors: [Monitor]) {
        self.id = id; capturedAt = ISO8601DateFormatter().string(from: Date())
        self.cursor = cursor; foregroundWindow = target; targetWindow = target
        windowUnderCursor = underCursor; self.monitors = monitors
    }

    // These three nullable keys are required by the shared contract, even with no target.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(cursor, forKey: .cursor); try c.encode(monitors, forKey: .monitors)
        try c.encode(foregroundWindow, forKey: .foregroundWindow)
        try c.encode(windowUnderCursor, forKey: .windowUnderCursor)
        try c.encode(targetWindow, forKey: .targetWindow)
        try c.encodeIfPresent(focusedElement, forKey: .focusedElement)
        try c.encodeIfPresent(elementUnderCursor, forKey: .elementUnderCursor)
        try c.encodeIfPresent(selectedDesktopItems, forKey: .selectedDesktopItems)
        try c.encodeIfPresent(selectedDesktopItemCount, forKey: .selectedDesktopItemCount)
        try c.encodeIfPresent(selectedDesktopItemsTruncated, forKey: .selectedDesktopItemsTruncated)
        try c.encodeIfPresent(screenshot, forKey: .screenshot)
        try c.encodeIfPresent(browser, forKey: .browser)
    }
}

public struct DomainError: Error, Codable, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public struct ToolOutcome<T: Encodable>: Encodable {
    public var ok: Bool
    public var result: T?
    public var error: DomainError?
    public static func success(_ result: T) -> Self { .init(ok: true, result: result) }
    public static func failure(_ error: DomainError) -> Self { .init(ok: false, error: error) }
}

/// Actual returned dimensions are load-bearing even when requesting one image pixel per point.
public struct CaptureTransform: Equatable {
    public let frame: Rect
    public let imageWidth: Int
    public let imageHeight: Int
    public init(frame: Rect, imageWidth: Int, imageHeight: Int) throws {
        guard frame.valid, imageWidth > 0, imageHeight > 0,
              abs(Double(imageWidth) / Double(imageHeight) - frame.width / frame.height)
                <= max(0.01, 2 / Double(imageHeight)) else {
            throw DomainError("capture_failed", "Screenshot dimensions do not match the window frame")
        }
        self.frame = frame; self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }
    public func screenPoint(_ pixel: Point, currentFrame: Rect) throws -> Point {
        guard currentFrame.width == frame.width, currentFrame.height == frame.height else {
            throw DomainError("capture_stale", "Window resized; capture again before acting")
        }
        guard pixel.x.isFinite, pixel.y.isFinite, pixel.x >= 0, pixel.y >= 0,
              pixel.x < Double(imageWidth), pixel.y < Double(imageHeight) else {
            throw DomainError("invalid_arguments", "Point is outside the latest screenshot")
        }
        return Point(x: currentFrame.x + pixel.x * frame.width / Double(imageWidth),
                     y: currentFrame.y + pixel.y * frame.height / Double(imageHeight))
    }
}

/// Keep full-window images under common provider/SDK resize thresholds. Only the host resizes.
public enum CaptureSizing {
    public static func pixels(for frame: Rect) -> (width: Int, height: Int) {
        guard frame.valid else { return (0, 0) }
        let scale = min(1, 1280 / max(frame.width, frame.height), sqrt(1_000_000 / (frame.width * frame.height)))
        return (max(1, Int((frame.width * scale).rounded(.down))), max(1, Int((frame.height * scale).rounded(.down))))
    }
}

public enum Placement {
    /// The sole coordinate-system boundary. primaryHeight is NOT NSScreen.main's height.
    public static func appKit(_ rect: Rect, primaryHeight: Double) -> Rect {
        Rect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }
    /// Whisper grows upward from the selected display's visible work area, never the target window.
    public static func bottomPanel(width: Double, height: Double, workArea: Rect, lowerInset: Double = 32) -> Rect {
        guard workArea.valid, width.isFinite, height.isFinite else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        let margin = min(12, workArea.width / 4, workArea.height / 4)
        let gap = min(max(margin, lowerInset.isFinite ? lowerInset : 32), workArea.height - margin - 1)
        let w = min(max(1, width), workArea.width - 2 * margin)
        let h = min(max(1, height), max(1, workArea.height - gap - margin))
        return Rect(x: workArea.x + (workArea.width - w) / 2, y: workArea.y + gap, width: w, height: h)
    }
    /// Inputs and output here are all AppKit points. Works with negative display origins.
    public static func panel(width: Double, height: Double, target: Rect?, workArea: Rect) -> Rect {
        let w = min(width, workArea.width - 24), h = min(height, workArea.height - 24)
        let anchor = target ?? workArea
        return Rect(x: min(max(anchor.x + (anchor.width - w) / 2, workArea.x + 12), workArea.x + workArea.width - w - 12),
                    y: min(max(anchor.y + (anchor.height - h) / 2, workArea.y + 12), workArea.y + workArea.height - h - 12),
                    width: w, height: h)
    }
}
