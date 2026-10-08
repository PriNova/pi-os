import Foundation

/// FIFO, cancellable serialization. No polling or background timer.
public actor OperationGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init() {}
    public func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !held { held = true; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    public func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }
}

/// Cross-queue cancellation/expiry for a context already handed to a native operation.
public final class ContextLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let expires: Date
    public init(expires: Date) { self.expires = expires }
    public func revoke() { lock.lock(); active = false; lock.unlock() }
    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard active && Date() < expires else { throw DomainError("unknown_context", "The pinned context expired or was cancelled") }
    }
}
