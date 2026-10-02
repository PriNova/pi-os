import Foundation
import Network
import PiOSCore

public final class LoopbackServer {
    public typealias Handler = (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "pi-os.http", qos: .userInitiated)
    private let listener: NWListener
    private let handler: Handler
    private var connections: [UUID: Client] = [:]
    public var onFailure: ((String) -> Void)?

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready()
            case .failed(let error): self?.onFailure?("port occupied or startup fault: \(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            let client = Client(connection, queue: self.queue, handler: self.handler) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.listener.cancel()
            let clients = Array(self.connections.values)
            clients.forEach { $0.close() }
        }
    }

    // Mutable state is confined to the listener's serial queue. The Task only reads
    // immutable handler/queue references and dispatches its response back to that queue.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let handler: Handler
        let onClose: () -> Void
        var parser = HTTPParser()
        var timeout: DispatchWorkItem?
        var operation: Task<Void, Never>?
        var closed = false
        init(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping Handler, onClose: @escaping () -> Void) {
            self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
        }
        func deadline(_ seconds: Double) {
            timeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.close() }
            timeout = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
            connection.start(queue: queue)
            deadline(5); receive()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                do {
                    if let data, let request = try self.parser.append(data) {
                        self.deadline(30)
                        self.operation = Task { [weak self] in
                            guard let self else { return }
                            let response = await self.handler(request)
                            self.queue.async { self.send(response) }
                        }
                        return
                    }
                    if complete { self.send(.error(400, "invalid_arguments", "Incomplete request")) }
                    else { self.receive() }
                } catch let failure as HTTPFailure {
                    self.send(.error(failure.status, "invalid_arguments", failure.message))
                } catch { self.send(.error(400, "invalid_arguments", "Malformed request")) }
            }
        }
        func send(_ response: HTTPResponse) {
            guard !closed else { return }
            deadline(5)
            connection.send(content: response.wire, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
        }
        func close() {
            guard !closed else { return }
            closed = true; timeout?.cancel(); timeout = nil
            operation?.cancel(); operation = nil
            connection.stateUpdateHandler = nil; connection.cancel(); onClose()
        }
    }
}
