/// Writes values one at a time, in the order they were submitted, keeping only the newest that is
/// waiting: a snapshot superseded before its turn is never written, and an older one can never land
/// after a newer one. `submit` never waits, so it is safe on the keystroke path.
final class LatestWriter<Value: Sendable>: Sendable {
    private let continuation: AsyncStream<Value>.Continuation

    init(write: @escaping @Sendable (Value) async -> Void) {
        let (values, continuation) = AsyncStream.makeStream(
            of: Value.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        Task.detached(priority: .utility) {
            for await value in values { await write(value) }
        }
    }

    func submit(_ value: Value) {
        continuation.yield(value)
    }

    deinit {
        // What is waiting is still written; then the task ends.
        continuation.finish()
    }
}
