import Foundation

/// Bridges non-cancellable system callbacks without waiting indefinitely after timeout/cancel.
/// The underlying system request may finish later; its result is discarded, never committed.
public enum Deadline {
    public static func call<T>(seconds: Double, operation: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, seconds: seconds)
                if !gate.isFinished { operation { gate.finish($0) } }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
    private final class Gate<T>: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<T, Error>?
        var result: Result<T, Error>?
        var timeout: DispatchWorkItem?
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
        func install(_ continuation: CheckedContinuation<T, Error>, seconds: Double) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            let timer = DispatchWorkItem { [weak self] in
                self?.finish(.failure(DomainError("capture_failed", "macOS capture timed out; no screenshot was committed")))
            }
            timeout = timer
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: timer)
        }
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            timeout?.cancel(); timeout = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
