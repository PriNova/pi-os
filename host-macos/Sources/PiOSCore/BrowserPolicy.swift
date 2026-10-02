import Foundation

public struct BrowserHint: Codable, Equatable {
    public var name = "Brave"
    public var mode = "cdp"
    public var pinned: Bool
    public init(pinned: Bool) { self.pinned = pinned }
}

/// Private host→harness metadata. Never expose this as a model tool result.
public struct BrowserConnection: Codable {
    public var processId: Int32
    public var port: Int
    public var initialURL: String
    public var url: String
    public var bounds: Rect
    public var allowCredentialFields: Bool
    public init(processId: Int32, port: Int, initialURL: String, url: String, bounds: Rect, allowCredentialFields: Bool = false) {
        self.processId = processId; self.port = port; self.initialURL = initialURL; self.url = url; self.bounds = bounds
        self.allowCredentialFields = allowCredentialFields
    }
}

public struct BrowserArguments: Decodable {
    public var contextId: String
    public var mutation: Bool?
    public var action: String?
    public var characters: Int?
}

public enum BrowserPolicy {
    public static let bundleID = "com.brave.Browser"
    public static let enabledKey = "braveConnectionEnabled"
    public static let portKey = "braveConnectionPort"
    public static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8192, let url = URLComponents(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }
    public static func validateBudget(_ args: BrowserArguments, budget: inout InputBudget) throws {
        let count = args.characters ?? 0
        guard ["click", "fill", "press", "scroll"].contains(args.action ?? ""),
              count >= 0, count <= 20_000, args.action == "fill" || count == 0 else {
            throw DomainError("invalid_arguments", "Invalid browser action budget")
        }
        let action: InputAction = args.action == "fill" ? .typeText : .click
        try budget.reserve(action, arguments: InputArguments(contextId: args.contextId, text: String(repeating: " ", count: count)))
    }
}
