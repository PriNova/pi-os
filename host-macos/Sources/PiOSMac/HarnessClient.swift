import Foundation
import Darwin
import Security
import PiOSCore

public struct MacConfiguration {
    public let support: URL
    public let captures: URL
    public let token: String
    public let hostPort: UInt16
    public let nodePort: UInt16
    public let nodePath: String?
    public let nodeEntry: String?
    public let warmTTL: Double
    public let echo: Bool
    public let forceReadOnly: Bool
    public var canControl: Bool { !forceReadOnly && ControlAvailability.ready }
    public var trustedCompatibility: Bool {
        guard canControl,
              let size = try? support.appendingPathComponent("resources.json").resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16_384,
              let data = try? Data(contentsOf: support.appendingPathComponent("resources.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["mode"] as? String == "trustedGlobal" && value["trustAcknowledgement"] as? Int == 1
    }
    public init(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        support = URL(fileURLWithPath: env["PI_OS_SUPPORT_DIR"] ?? NSHomeDirectory() + "/Library/Application Support/pi-os", isDirectory: true)
        captures = URL(fileURLWithPath: env["PI_OS_CAPTURES_DIR"] ?? support.appendingPathComponent("captures").path, isDirectory: true)
        if let configured = env["PI_OS_TOKEN"], !configured.isEmpty { token = configured }
        else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DomainError("startup_failed", "Secure session token generation failed")
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        func port(_ key: String, _ fallback: UInt16) throws -> UInt16 {
            guard let raw = env[key] else { return fallback }
            guard let port = UInt16(raw), port > 0 else { throw DomainError("configuration_error", "Invalid \(key)") }
            return port
        }
        hostPort = try port("PI_OS_HOST_PORT", 17831); nodePort = try port("PI_OS_NODE_PORT", 17832)
        nodePath = env["PI_OS_NODE_PATH"] ?? Bundle.main.url(forResource: "node", withExtension: nil, subdirectory: "runtime/bin")?.path
            ?? Bundle.main.object(forInfoDictionaryKey: "PiOSNodePath") as? String
        nodeEntry = env["PI_OS_NODE_ENTRY"] ?? Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "node-harness/dist")?.path
            ?? Bundle.main.object(forInfoDictionaryKey: "PiOSNodeEntry") as? String
        if let raw = env["PI_OS_NODE_WARM_TTL_SECONDS"] {
            guard let value = Double(raw), value.isFinite, value >= 0, value <= 3600 else {
                throw DomainError("configuration_error", "Warm TTL must be between 0 and 3600 seconds")
            }
            warmTTL = value
        } else { warmTTL = 120 }
        echo = env["PI_OS_ECHO"] == "1"
        forceReadOnly = env["PI_OS_READ_ONLY"] == "1"
        for directory in [support, captures, support.appendingPathComponent("agent-cwd"), support.appendingPathComponent("logs")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

/// Authoritative single-instance gate, independent of TCP readiness or port ownership.
public final class InstanceLock {
    private var fd: Int32 = -1
    public init(directory: URL) throws {
        fd = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DomainError("startup_failed", "Cannot open the application lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw DomainError("already_running", "pi-os is already running for this application-support directory")
        }
    }
    deinit { if fd >= 0 { close(fd) } }
}

/// posix_spawn establishes the process group atomically (no post-spawn setpgid race).
private final class OwnedChild {
    let pid: pid_t
    private var stdinFD: Int32
    private(set) var exited = false
    init(node: String, entry: String, cwd: String, env: [String: String], logPath: String) throws {
        guard node.hasPrefix("/"), entry.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.fileExists(atPath: entry) else {
            throw DomainError("harness_unreachable", "Set absolute PI_OS_NODE_PATH and PI_OS_NODE_ENTRY, or use a bundled installation")
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw DomainError("startup_failed", "Cannot create child stdin") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let log = open(logPath, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard log >= 0 else { close(fds[0]); close(fds[1]); throw DomainError("startup_failed", "Cannot open harness log") }
        defer { close(fds[0]); close(log) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = [node, entry].map { value in value.withCString { strdup($0) } } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.sorted(by: { $0.key < $1.key }).map { pair in
            "\(pair.key)=\(pair.value)".withCString { strdup($0) }
        } + [nil]
        defer { for p in argv + envp { free(p) } }
        var child: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { vars in
                posix_spawn(&child, node, &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard status == 0 else {
            close(fds[1]); throw DomainError("harness_unreachable", "Node could not start (posix_spawn \(status))")
        }
        pid = child; stdinFD = fds[1]
    }
    func observe(_ completed: @escaping (Int32) -> Void) {
        let childPID = pid
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async {
                self.exited = true
                self.closeInput()
                // Only the group created by this exact spawn. Read-only children have no shell tools.
                kill(-childPID, SIGKILL)
                completed(status)
            }
        }
    }
    func closeInput() { if stdinFD >= 0 { close(stdinFD); stdinFD = -1 } }
    func stop() {
        closeInput()
        guard !exited else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if !exited { kill(-pid, SIGKILL) }
        }
    }
}

@MainActor public final class HarnessClient {
    private let config: MacConfiguration
    private let session: URLSession
    private var child: OwnedChild?
    private var starting: Task<Void, Error>?
    private var retention: Task<Void, Never>?
    private var generation = UUID()
    private var expectedExit = false
    private var reservations: Set<UUID> = []
    public var onUnexpectedExit: (() -> Void)?
    public var ownedPID: pid_t? { child?.exited == false ? child?.pid : nil }

    public init(config: MacConfiguration) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 10
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c)
    }
    public func warm() async throws {
        retention?.cancel(); retention = nil
        if let starting { return try await starting.value }
        // A previous cancellation may still be reaping its owned group. Only poll during a new warm request.
        if expectedExit {
            let deadline = Date().addingTimeInterval(3)
            while child != nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard child == nil else { throw DomainError("harness_unreachable", "Previous agent process is still stopping") }
        }
        if let child, !child.exited { return }
        generation = UUID(); expectedExit = false
        let run = generation
        guard let node = config.nodePath, let entry = config.nodeEntry else {
            throw DomainError("harness_unreachable", "Node is not configured. Launch with host-macos/scripts/run-dev.sh.")
        }
        var env = ProcessInfo.processInfo.environment
        env["PI_OS_TOKEN"] = config.token
        env["PI_OS_SESSION_ID"] = run.uuidString
        env["PI_OS_HOST_URL"] = "http://127.0.0.1:\(config.hostPort)"
        env["PI_OS_NODE_PORT"] = String(config.nodePort)
        env["PI_OS_CAPTURES_DIR"] = config.captures.path
        env["PI_OS_SUPPORT_DIR"] = config.support.path
        env["PI_OS_SUPERVISED"] = "1"
        // Actual native capabilities are negotiated for each invocation, not frozen
        // into a warm child. Keep only the user's explicit read-only override here.
        env["PI_OS_READ_ONLY"] = config.forceReadOnly ? "1" : "0"
        env["PI_OS_INSECURE_DEV"] = nil
        // Never evaluate shell profiles or inherited Node preload hooks in a TCC-bearing child.
        env["NODE_OPTIONS"] = nil; env["NODE_PATH"] = nil
        let process = try OwnedChild(node: node, entry: entry, cwd: config.support.appendingPathComponent("agent-cwd").path,
                                     env: env, logPath: config.support.appendingPathComponent("logs/harness.log").path)
        child = process
        process.observe { [weak self, weak process] _ in
            guard let self, self.child === process else { return }
            self.child = nil
            self.starting?.cancel(); self.starting = nil
            if !self.expectedExit { self.onUnexpectedExit?() }
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                try Task.checkCancellation()
                guard self.generation == run, self.child?.exited == false else {
                    throw DomainError("harness_unreachable", "Node stopped during startup")
                }
                if let data = try? await self.request("GET", "/health", authenticated: false),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["sessionId"] as? String == run.uuidString { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw DomainError("harness_unreachable", "Node readiness timed out; check logs/harness.log and port \(self.config.nodePort)")
        }
        starting = task
        do {
            try await task.value
            if generation == run { starting = nil }
        } catch {
            let startupFailed = generation == run
            if startupFailed { stop() }
            if startupFailed && error is CancellationError {
                throw DomainError("harness_unreachable", "Node exited before becoming ready; check logs/harness.log")
            }
            throw error
        }
    }
    public func reserve() -> UUID {
        retention?.cancel(); retention = nil
        let id = UUID(); reservations.insert(id); return id
    }
    public func release(_ id: UUID) {
        reservations.remove(id)
        retainWarm()
    }
    public func stopIfUnused() { if reservations.isEmpty { stop() } }
    public func retainWarm() {
        retention?.cancel(); retention = nil
        guard reservations.isEmpty, child?.exited == false, !expectedExit else { return }
        retention = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.config.warmTTL * 1_000_000_000)) }
            catch { return }
            self.stop()
        }
    }
    public func stop() {
        expectedExit = true; generation = UUID()
        retention?.cancel(); retention = nil
        starting?.cancel(); starting = nil
        child?.stop()
        // Keep ownership until waitpid completes; a new invocation must not attach to a stopping child.
    }
    public func submit(id: String, context: String, prompt: String) async throws {
        _ = try await request("POST", "/invoke", payload: ["invocationId": id, "contextId": context, "prompt": prompt, "retainSession": true,
                                                              "invokedAt": ISO8601DateFormatter().string(from: Date())])
    }
    public func followup(_ id: String, prompt: String) async throws {
        _ = try await request("POST", "/invocations/\(id)/followup", payload: ["prompt": prompt])
    }
    public func closeThread(_ id: String) async {
        // Do not warm/restart a dead child merely to close a session it no longer owns.
        guard ownedPID != nil, !expectedExit else { return }
        _ = try? await request("POST", "/invocations/\(id)/close", payload: [:])
    }
    public struct Model: Codable, Equatable {
        public let provider: String
        public let id: String
        public let name: String
        public let thinkingLevels: [String]
    }
    public struct ModelSelection: Codable, Equatable {
        public let provider: String
        public let modelId: String
        public let thinkingLevel: String
    }
    public struct ModelCatalog: Decodable { public let models: [Model]; public let current: ModelSelection? }
    public func models() async throws -> ModelCatalog {
        try await warm()
        return try JSONDecoder().decode(ModelCatalog.self, from: await request("GET", "/models"))
    }
    public func setModel(_ selection: ModelSelection) async throws {
        try await warm()
        _ = try await request("POST", "/settings/model", payload: ["provider": selection.provider, "modelId": selection.modelId, "thinkingLevel": selection.thinkingLevel])
    }
    public struct ResourceSelection: Codable { public let mode: String }
    public struct ResourceSettings: Decodable { public let current: ResourceSelection; public let warning: String? }
    public func resources() async throws -> ResourceSettings {
        try await warm()
        return try JSONDecoder().decode(ResourceSettings.self, from: await request("GET", "/settings/resources"))
    }
    public func setResources(trusted: Bool) async throws {
        try await warm()
        _ = try await request("POST", "/settings/resources", payload: ["mode": trusted ? "trustedGlobal" : "isolated", "acknowledgeUnpinnedAccess": trusted])
    }
    public struct Status: Decodable {
        public let state: String
        public let activity: String?
        public let responseText: String?
        public let failureMessage: String?
        public let followupAvailable: Bool?
    }
    public func status(_ id: String) async throws -> Status {
        try JSONDecoder().decode(Status.self, from: await request("GET", "/invocations/" + id))
    }
    public func cancel(_ id: String) async -> Bool {
        do { _ = try await request("POST", "/invocations/\(id)/cancel", payload: [:]); return true }
        catch { return false }
    }
    private func request(_ method: String, _ path: String, payload: [String: Any]? = nil, authenticated: Bool = true) async throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.nodePort)" + path)!)
        req.httpMethod = method
        if authenticated { req.setValue(config.token, forHTTPHeaderField: "X-Harness-Token") }
        if let payload {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: DomainError }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw failure.error }
            throw DomainError("harness_unreachable", "Harness rejected the request (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return data
    }
}
