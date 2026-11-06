import XCTest
@testable import iSync

/// Taking songs off the list at each stage: before converting, while converting, converted, synced.
@MainActor
final class RemovalTests: XCTestCase {
    private func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("iSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        return work
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func prepared(_ url: URL, isTemporary: Bool) -> PreparedTrack {
        let format = AudioFormatInfo(codec: .alac, sampleRate: 44100, channels: 2, bitsPerSample: 16,
                                     bitRateKbps: 1411, sampleCount: 132300)
        return PreparedTrack(uploadURL: url, isTemporary: isTemporary, format: format, tags: TagSet(),
                             phoneCover: nil, artworkChecksum: 0, fileSize: 3)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRemovesSelectedSongsAndTheirConvertedFilesButNotSongsBeingCopied() throws {
        let work = try makeWorkDirectory()
        let engine = SyncEngine(workDirectory: work.appendingPathComponent("Converted", isDirectory: true))
        let converted = engine.workDirectory

        func item(_ status: TrackItem.Status, prepared track: PreparedTrack? = nil) throws -> TrackItem {
            let item = TrackItem(url: try file("\(UUID().uuidString).flac", in: work))
            item.status = status
            item.prepared = track
            engine.items.append(item)
            return item
        }
        let readyFile = try file("ready.m4a", in: converted)
        let failedFile = try file("failed.m4a", in: converted)
        let copyingFile = try file("copying.m4a", in: converted)
        let sentAsIs = try file("as-is.mp3", in: work)

        let synced = try item(.synced)
        let already = try item(.alreadyOnPhone)
        let queued = try item(.queued)
        let waiting = try item(.waitingForDevice)
        let ready = try item(.readyToSync, prepared: prepared(readyFile, isTemporary: true))
        let readyAsIs = try item(.readyToSync, prepared: prepared(sentAsIs, isTemporary: false))
        let failed = try item(.failed("Sent, but the iPhone didn't list it afterwards."),
                              prepared: prepared(failedFile, isTemporary: true))
        let copying = try item(.syncing, prepared: prepared(copyingFile, isTemporary: true))
        let unselected = try item(.waitingForDevice)

        let selected = [synced, already, queued, waiting, ready, readyAsIs, failed, copying]
        XCTAssertEqual(engine.remove(Set(selected.map(\.id))), 7)

        XCTAssertEqual(engine.items.map(\.id), [copying.id, unselected.id], "a song being copied stays")
        XCTAssertTrue(selected.filter { $0 !== copying }.allSatisfy(\.isRemoved))
        XCTAssertFalse(copying.isRemoved)
        XCTAssertFalse(exists(readyFile), "a converted file is deleted")
        XCTAssertFalse(exists(failedFile), "a converted file is deleted")
        XCTAssertNil(ready.prepared)
        XCTAssertTrue(exists(sentAsIs), "a file sent as is is the user's own and stays")
        XCTAssertTrue(exists(copyingFile), "the file being copied stays")
        XCTAssertTrue(selected.allSatisfy { exists($0.url) }, "source files stay")

        XCTAssertEqual(engine.remove([copying.id]), 0)
        XCTAssertEqual(engine.items.count, 2)
    }

    // MARK: With the real ffmpeg

    private func convertible(in work: URL, seconds: Int) throws -> (TrackItem, FFTools) {
        let tools: FFTools
        do { tools = try FFTools.locate() } catch { throw XCTSkip("ffmpeg is not installed") }
        let flac = work.appendingPathComponent("song.flac")
        let result = try ProcessRunner.run(tools.ffmpeg, ["-v", "error", "-nostdin", "-y", "-f", "lavfi",
                                                          "-i", "sine=frequency=440:duration=\(seconds)",
                                                          "-ac", "2", "-c:a", "flac", flac.path])
        XCTAssertEqual(result.status, 0, result.stderrString)
        let item = TrackItem(url: flac)
        item.probe = try ProbeResult.probe(flac, tools: tools)
        item.plan = try ConversionPlan.plan(for: XCTUnwrap(item.probe), source: flac)
        item.status = .converting
        return (item, tools)
    }

    func testRemovingASongWhileItConvertsStopsAndLeavesNothingBehind() async throws {
        let work = try makeWorkDirectory()
        let engine = SyncEngine(workDirectory: work.appendingPathComponent("Converted", isDirectory: true))
        let (item, tools) = try convertible(in: work, seconds: 600)
        engine.items = [item]

        let ffmpegRunning = CancelFlag()
        let started = Date()
        async let converted = engine.convert(item, tools: tools, isCancelled: { ffmpegRunning.set(true); return false })
        while !ffmpegRunning.isCancelled {
            XCTAssertLessThan(Date().timeIntervalSince(started), 30, "ffmpeg never started")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        engine.remove([item.id])

        let isReady = try await converted
        XCTAssertFalse(isReady)
        XCTAssertNil(item.prepared)
        XCTAssertEqual(item.status, .converting, "a removed song isn't marked as failed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: engine.workDirectory.path), [],
                       "no converted or half-written file is left")
        XCTAssertTrue(exists(item.url))
    }

    func testSongRemovedBeforeItsTurnIsNotConverted() async throws {
        let work = try makeWorkDirectory()
        let engine = SyncEngine(workDirectory: work.appendingPathComponent("Converted", isDirectory: true))
        let (item, tools) = try convertible(in: work, seconds: 1)
        engine.items = [item]
        engine.remove([item.id])

        let ffmpegRan = CancelFlag()
        let isReady = try await engine.convert(item, tools: tools, isCancelled: { ffmpegRan.set(true); return false })
        XCTAssertFalse(isReady)
        XCTAssertFalse(ffmpegRan.isCancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: engine.workDirectory.path), [])
    }
}
