import Foundation

/// Platform-neutral, bounded selection semantics, tested without querying the live desktop.
public struct FinderSelection: Equatable {
    public let items: [ElementSummary]
    public let totalCount: Int
    public var truncated: Bool { items.count < totalCount }
    public init(items: [ElementSummary], totalCount: Int) { self.items = items; self.totalCount = totalCount }
}

public enum FinderSelectionRead<Node> {
    case unavailable
    /// `nodes` may be a bounded prefix; count is obtained independently from AX.
    case available(count: Int, nodes: [Node])
}

public protocol FinderTreeReader {
    associatedtype Node: Equatable
    var exhausted: Bool { get }
    func children(_ node: Node) -> [Node]?
    func parent(_ node: Node) -> Node?
    func role(_ node: Node) -> String?
    func frame(_ node: Node) -> Rect?
    func owner(_ node: Node) -> Int32?
    func selection(_ node: Node, limit: Int) -> FinderSelectionRead<Node>
    func summary(_ node: Node) -> ElementSummary?
}

public enum FinderContextPolicy {
    public static let desktopSurface = "finderDesktop"
    public static let collectionRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXBrowser", "AXTable"]
    public static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        a.valid && b.valid && abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5
            && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }
    public static func desktopContainer<R: FinderTreeReader>(reader: R, application: R.Node, pid: Int32, frame: Rect, workArea: Rect? = nil, desktopUnion: Rect? = nil) -> R.Node? {
        guard let children = reader.children(application), !reader.exhausted else { return nil }
        // Only direct Finder children. Never mistake a normal Finder window's file list
        // or a sidebar selection for the desktop, even when titles/locales look similar.
        let allowedWorkArea = workArea.flatMap { area -> Rect? in
            guard area.valid, area.x >= frame.x, area.y >= frame.y,
                  area.x + area.width <= frame.x + frame.width,
                  area.y + area.height <= frame.y + frame.height else { return nil }
            return area
        }
        let allowedUnion = desktopUnion.flatMap { area -> Rect? in
            guard area.valid, contains(area, frame) else { return nil }
            return area
        }
        let matches = children.filter {
            reader.owner($0) == pid && collectionRoles.contains(reader.role($0) ?? "")
                && reader.frame($0).map { bounds in
                    sameFrame(bounds, frame) || allowedWorkArea.map { sameFrame(bounds, $0) } == true
                        || allowedUnion.map { sameFrame(bounds, $0) } == true
                } == true
        }
        return !reader.exhausted && matches.count == 1 ? matches[0] : nil
    }
    public static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        outer.valid && inner.valid && inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
    }
    public static func union(_ frames: [Rect]) -> Rect? {
        guard let first = frames.first, frames.allSatisfy(\.valid) else { return nil }
        let left = frames.map(\.x).min() ?? first.x, top = frames.map(\.y).min() ?? first.y
        let right = frames.map { $0.x + $0.width }.max()!, bottom = frames.map { $0.y + $0.height }.max()!
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
    /// A shared AX desktop may span multiple CG desktop windows. Keyboard operations
    /// must not affect a selection outside the one pinned/captured desktop surface.
    public static func keyboardSelectionIsWithin<R: FinderTreeReader>(reader: R, container: R.Node, pid: Int32, frame: Rect) -> Bool {
        guard let containerFrame = reader.frame(container),
              case let .available(count, nodes) = reader.selection(container, limit: 64),
              count >= 0, count <= 64, nodes.count == count, !reader.exhausted else { return false }
        if count == 0 { return contains(frame, containerFrame) }
        return nodes.allSatisfy { node in
            isDescendant(reader: reader, node: node, of: container, pid: pid)
                && reader.frame(node).map { contains(frame, $0) } == true && !reader.exhausted
        }
    }
    public static func isDescendant<R: FinderTreeReader>(reader: R, node: R.Node, of container: R.Node, pid: Int32) -> Bool {
        var current: R.Node? = node, visited: [R.Node] = []
        for _ in 0..<12 {
            guard let value = current, !reader.exhausted, reader.owner(value) == pid, !visited.contains(value) else { return false }
            if value == container { return true }
            visited.append(value); current = reader.parent(value)
        }
        return false
    }
    public static func selected<R: FinderTreeReader>(reader: R, container: R.Node, pid: Int32, limit: Int = 32) -> FinderSelection? {
        guard reader.owner(container) == pid, collectionRoles.contains(reader.role(container) ?? ""), limit > 0 else { return nil }
        // Selection must be explicitly reported by this verified container. No directory
        // listing, focused-item inference, or Finder-wide fallback is authoritative.
        guard case let .available(count, nodes) = reader.selection(container, limit: limit),
              count >= 0, nodes.count <= count, nodes.count == min(count, limit), !reader.exhausted else { return nil }
        var items: [ElementSummary] = []
        for node in nodes {
            guard isDescendant(reader: reader, node: node, of: container, pid: pid),
                  let summary = reader.summary(node), !reader.exhausted else { return nil }
            items.append(summary)
        }
        return FinderSelection(items: items, totalCount: count)
    }
}
