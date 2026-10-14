import Foundation

/// A continuation that is resumed exactly once, whichever of callback / deadline / cancellation wins.
/// Late resumes are ignored and reported via the return value so the loser can clean up.
@MainActor
final class OneShot<Value> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    var isResolved: Bool { result != nil }

    @discardableResult
    func resolve(_ value: Result<Value, Error>) -> Bool {
        guard result == nil else { return false }
        result = value
        if let continuation {
            self.continuation = nil
            continuation.resume(with: value)
        }
        return true
    }

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    /// Resolves with `error` after `seconds` unless something else resolved first; runs `onExpire` only if it won.
    func deadline(_ seconds: TimeInterval, error: @autoclosure @escaping () -> Error, onExpire: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resolve(.failure(error())) else { return }
                onExpire?()
            }
        }
    }
}

/// FIFO async mutex for the main actor. Used to make "write + read back" a single transaction so replies with
/// the same command/selector can never be claimed by an interleaved operation.
@MainActor
final class AsyncSerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        // A caller cancelled while queued (e.g. superseded by a newer connection) must not write anything.
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
