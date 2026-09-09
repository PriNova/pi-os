import Foundation
import CoreGraphics

/// AppKit global screen coordinates: points, bottom-left origin, possibly
/// negative. These are NOT screenshot pixels or the Windows wire coordinates.
public struct ScreenArea: Equatable, Sendable {
    public let id: Int
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: Int, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum Placement {
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxX, rect.maxY]
            .allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    /// Half-open edges give adjacent displays an unambiguous owner. A pointer
    /// in a display gap chooses the nearest valid display; ties keep input order.
    public static func screen(at point: CGPoint, among screens: [ScreenArea]) -> ScreenArea? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let validScreens = screens.filter {
            valid($0.frame) && valid($0.visibleFrame) && valid($0.frame.intersection($0.visibleFrame))
        }
        if let containing = validScreens.first(where: {
            point.x >= $0.frame.minX && point.x < $0.frame.maxX &&
            point.y >= $0.frame.minY && point.y < $0.frame.maxY
        }) { return containing }
        return validScreens.min { distance(point, to: $0.frame) < distance(point, to: $1.frame) }
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// Top-centered within the usable area (menu bar/Dock already excluded).
    /// Oversized surfaces shrink to fit; UI content must remain scrollable.
    public static func frame(size: CGSize, on screen: ScreenArea, inset: CGFloat = 24) -> CGRect? {
        guard valid(screen.frame), valid(screen.visibleFrame),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, inset.isFinite else { return nil }
        let work = screen.frame.intersection(screen.visibleFrame)
        guard valid(work) else { return nil }
        let margin = min(max(inset, 0), min(work.width, work.height) / 4)
        let width = min(size.width, work.width - 2 * margin)
        let height = min(size.height, work.height - 2 * margin)
        return CGRect(x: work.midX - width / 2, y: work.maxY - margin - height,
                      width: width, height: height)
    }
}
