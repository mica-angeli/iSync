import XCTest
@testable import iSync

/// Converting and syncing at the same time (`prepareAndDeliver`), with stand-ins for both.
@MainActor
final class PipelineTests: XCTestCase {
    @MainActor
    private final class Record {
        var started = [Int]()
        var prepared = [Int]()
        var batches = [[Int]]()
        var deliveryStarted = false
    }

    /// Waits, letting other main-actor work run, until `condition` holds. False after `timeout`.
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    func testSyncsEachBatchWhileTheRestAreStillConverting() async throws {
        let record = Record()
        try await prepareAndDeliver(
            ready: [], pending: Array(0..<7), limit: 2, batchSize: 3, isCancelled: { false },
            prepare: { n, _ in
                // Songs after the first batch can't finish converting until that batch is syncing.
                if n >= 3 {
                    let started = await self.eventually { record.deliveryStarted }
                    XCTAssertTrue(started, "song \(n) waited for a sync that never started")
                }
                record.prepared.append(n)
                return true
            },
            deliver: { batch in
                record.batches.append(batch)
                guard record.batches.count == 1 else { return }
                XCTAssertEqual(record.prepared.count, 3, "the first batch should go out as soon as it is converted")
                record.deliveryStarted = true
                let caughtUp = await self.eventually { record.prepared.count == 7 }
                XCTAssertTrue(caughtUp, "the rest should keep converting while a batch syncs")
            })
        XCTAssertEqual(record.batches.map(\.count), [3, 3, 1])
        XCTAssertEqual(record.batches.flatMap { $0 }.sorted(), Array(0..<7))
    }

    func testConvertedLeftoversGoFirstAndFailedSongsAreSkipped() async throws {
        let record = Record()
        try await prepareAndDeliver(
            ready: [100, 101], pending: Array(0..<6), limit: 2, batchSize: 3, isCancelled: { false },
            prepare: { n, _ in n != 2 },  // song 2 fails to convert
            deliver: { record.batches.append($0) })
        XCTAssertEqual(record.batches.map(\.count), [3, 3, 1])
        XCTAssertEqual(Array(record.batches[0].prefix(2)), [100, 101])
        XCTAssertEqual(record.batches.flatMap { $0 }.sorted(), [0, 1, 3, 4, 5, 100, 101])
    }

    func testSyncErrorStopsConvertingAndIsReported() async {
        let record = Record()
        do {
            try await prepareAndDeliver(
                ready: [], pending: Array(0..<20), limit: 2, batchSize: 2, isCancelled: { false },
                prepare: { n, shouldStop in
                    record.started.append(n)
                    guard n >= 2 else { return true }
                    // Like ffmpeg: keep working until told to stop.
                    let stopped = await self.eventually { shouldStop() }
                    XCTAssertTrue(stopped, "song \(n) was never told to stop")
                    throw CancellationError()
                },
                deliver: { batch in
                    record.batches.append(batch)
                    throw ISyncError("The iPhone went away.")
                })
            XCTFail("expected the sync error")
        } catch {
            XCTAssertEqual((error as? ISyncError)?.message, "The iPhone went away.")
        }
        XCTAssertEqual(record.batches.map { $0.sorted() }, [[0, 1]])
        XCTAssertTrue(record.started.allSatisfy { $0 < 4 }, "nothing new should start after the sync failed: \(record.started)")
    }

    func testStopSendsNothingMore() async {
        let record = Record()
        let cancel = CancelFlag()
        do {
            try await prepareAndDeliver(
                ready: [], pending: Array(0..<5), limit: 2, batchSize: 10, isCancelled: { cancel.isCancelled },
                prepare: { n, shouldStop in
                    if n == 2 { cancel.set(true) }  // the user presses Stop
                    if shouldStop() { throw CancellationError() }
                    return true
                },
                deliver: { record.batches.append($0) })
            XCTFail("expected Stop to end the run")
        } catch {}
        XCTAssertEqual(record.batches, [], "the partly filled batch must not be sent after Stop")
    }
}
