import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPFailure: Error {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// One bounded HTTP/1.1 request per connection. No pipelining, chunking, upgrades or keepalive.
public struct HTTPParser {
    public static let maxHeaders = 8_192
    public static let maxBody = 1_000_000
    private var data = Data()
    private var headerEnd: Int?
    private var length = 0
    private var method = ""
    private var path = ""
    private var headers: [String: String] = [:]
    public init() {}

    public mutating func append(_ bytes: Data) throws -> HTTPRequest? {
        guard data.count + bytes.count <= Self.maxHeaders + Self.maxBody else {
            throw HTTPFailure(413, "Request too large")
        }
        data.append(bytes)
        if headerEnd == nil {
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
                if data.count > Self.maxHeaders { throw HTTPFailure(431, "Headers too large") }
                return nil
            }
            guard separator.upperBound <= Self.maxHeaders,
                  let text = String(data: data[..<separator.lowerBound], encoding: .ascii) else {
                throw HTTPFailure(400, "Invalid headers")
            }
            let lines = text.components(separatedBy: "\r\n")
            let start = lines[0].components(separatedBy: " ")
            guard start.count == 3, start[2] == "HTTP/1.1", ["GET", "POST"].contains(start[0]),
                  start[1].hasPrefix("/"), !start[1].contains("#"),
                  !start[1].unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else {
                throw HTTPFailure(400, "Expected GET or POST origin-form HTTP/1.1 request")
            }
            method = start[0]; path = start[1]
            let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                    throw HTTPFailure(400, "Malformed header")
                }
                let name = String(line[..<colon])
                guard name.unicodeScalars.allSatisfy({ token.contains($0) }) else {
                    throw HTTPFailure(400, "Invalid header name")
                }
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }),
                      headers[name.lowercased()] == nil else {
                    throw HTTPFailure(400, "Invalid or duplicate header")
                }
                headers[name.lowercased()] = value
            }
            guard headers["host"] != nil else { throw HTTPFailure(400, "Host is required") }
            guard headers["transfer-encoding"] == nil, headers["expect"] == nil, headers["upgrade"] == nil else {
                throw HTTPFailure(400, "Transfer-Encoding, Expect and Upgrade are not supported")
            }
            if let raw = headers["content-length"] {
                guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(raw) else {
                    throw HTTPFailure(400, "Invalid Content-Length")
                }
                guard n <= Self.maxBody else { throw HTTPFailure(413, "Body too large") }
                length = n
            } else if method == "POST" {
                throw HTTPFailure(411, "Content-Length is required")
            }
            if method == "GET", length != 0 { throw HTTPFailure(400, "GET body is not supported") }
            headerEnd = separator.upperBound
        }
        guard let end = headerEnd else { return nil }
        guard data.count <= end + length else { throw HTTPFailure(400, "Trailing or pipelined data") }
        guard data.count == end + length else { return nil }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(data[end...]))
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int = 200, body: Data) { self.status = status; self.body = body }
    public static func json<T: Encodable>(_ payload: T, status: Int = 200) -> Self {
        do { return .init(status: status, body: try JSONEncoder().encode(payload)) }
        catch { return .error(500, "internal_error", "Response encoding failed") }
    }
    public static func error(_ status: Int, _ code: String, _ message: String) -> Self {
        .json(["error": DomainError(code, message)], status: status)
    }
    public var wire: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      408: "Request Timeout", 411: "Length Required", 413: "Payload Too Large",
                      431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(body)
        return bytes
    }
}

public enum HostRoutes {
    public static let names = ["desktop.getContext", "desktop.refreshContext", "desktop.captureWindow"]
    public struct ToolArguments: Decodable {
        public let arguments: Arguments
        public struct Arguments: Decodable { public let contextId: String }
    }
    private struct Descriptor: Encodable {
        let name: String
        let description: String
        var inputSchema = Schema()
        struct Property: Encodable {
            let type: String
            var items: [String: String]?
        }
        struct Schema: Encodable {
            let type = "object"
            var properties = ["contextId": Property(type: "string")]
            var required = ["contextId"]
        }
    }
    public static func catalog(includeInput: Bool = false) -> HTTPResponse {
        var tools = names.map { Descriptor(name: $0, description: "Read the pinned target window.") }
        if includeInput {
            for action in InputAction.allCases {
                var tool = Descriptor(name: action.rawValue, description: "\(action.name) in the exact pinned window; fails closed before input when verification fails.")
                var required: [String] = [], optional: [String] = []
                switch action {
                case .focus: break
                case .click: required = ["x", "y", "screenshotId"]
                case .typeText: required = ["text"]
                case .pressKey: required = ["key"]
                case .keyChord: required = ["key", "modifiers"]
                case .scroll: optional = ["deltaX", "deltaY", "x", "y", "screenshotId"]
                }
                tool.inputSchema.required += required
                for key in required + optional {
                    tool.inputSchema.properties[key] = Descriptor.Property(
                        type: key == "modifiers" ? "array" : ["x", "y", "deltaX", "deltaY"].contains(key) ? "number" : "string",
                        items: key == "modifiers" ? ["type": "string"] : nil)
                }
                tools.append(tool)
            }
        }
        return .json(["tools": tools])
    }
    public static func authorized(_ supplied: String?, token: String) -> Bool {
        guard let supplied, !token.isEmpty else { return false }
        let a = Array(supplied.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
