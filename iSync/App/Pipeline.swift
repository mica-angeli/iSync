import Foundation

/// Thread-safe cancellation flag shared with background work.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Runs `body` for each element with at most `limit` running at once. Starts nothing new and throws
/// once `isCancelled` returns true.
@MainActor
func forEachConcurrently<Element: Sendable>(_ elements: [Element], limit: Int, isCancelled: () -> Bool,
                                            _ body: @escaping @MainActor (Element) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var iterator = elements.makeIterator()
        var running = 0
        while running < limit, let next = iterator.next() {
            group.addTask { try await body(next) }
            running += 1
        }
        while try await group.next() != nil {
            if isCancelled() { group.cancelAll(); throw ISyncError("Cancelled.") }
            if let next = iterator.next() {
                group.addTask { try await body(next) }
            }
        }
    }
}

/// Prepares `pending` (at most `limit` at once) and, at the same time, delivers the prepared elements
/// in batches of `batchSize`, so each batch goes out while the rest are still being prepared.
///
/// - `ready` elements are already prepared and go out first.
/// - `prepare` returns whether the element can be delivered. It should give up and throw once its
///   `shouldStop` argument returns true.
/// - `deliver` is called for one batch at a time. Every batch is full except possibly the last, which
///   is sent once preparation has finished.
///
/// If `deliver` throws, preparation is told to stop, and the error is rethrown once it has. If
/// `prepare` throws, no further batch starts and its error is rethrown.
@MainActor
func prepareAndDeliver<Element: Sendable>(
    ready: [Element], pending: [Element], limit: Int, batchSize: Int,
    isCancelled: @escaping @Sendable () -> Bool,
    prepare: @escaping @MainActor (Element, _ shouldStop: @escaping @Sendable () -> Bool) async throws -> Bool,
    deliver: @MainActor ([Element]) async throws -> Void
) async throws {
    let stop = CancelFlag()
    let shouldStop: @Sendable () -> Bool = { isCancelled() || stop.isCancelled }
    let (prepared, output) = AsyncStream.makeStream(of: Element.self)
    for element in ready { output.yield(element) }

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { @MainActor in
            defer { output.finish() }
            do {
                try await forEachConcurrently(pending, limit: limit, isCancelled: shouldStop) { element in
                    if try await prepare(element, shouldStop) { output.yield(element) }
                }
            } catch {
                stop.set(true)
                throw error
            }
        }
        do {
            var batch = [Element]()
            for await element in prepared {
                if stop.isCancelled { break }
                batch.append(element)
                if batch.count == batchSize {
                    try await deliver(batch)
                    batch.removeAll()
                }
            }
            try await group.waitForAll()
            if !batch.isEmpty { try await deliver(batch) }
        } catch {
            stop.set(true)
            throw error
        }
    }
}
