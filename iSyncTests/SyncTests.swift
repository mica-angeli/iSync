import XCTest
import SQLite3
@testable import iSync

final class SyncSessionTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("iSyncSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func grappaReply() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "grappa-fixed-vectors", withExtension: "plist"))
        let vectors = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [[String: Data]])
        return try XCTUnwrap(vectors[0]["reply"])
    }

    private func snapshot() -> PhoneLibrarySnapshot {
        PhoneLibrarySnapshot(databasePID: -4163065678378989684, primaryContainerPID: 7, mediaAnchor: 41, tracks: [],
                             albumIDs: [.init(album: "Existing Album", artist: "Band"): 555],
                             artistIDs: ["band": 444], usedSyncIDs: [555, 444, 123456789, -987654321], largestArtworkID: 700,
                             musicFolders: ["F00", "F01"], tracksWithFiles: [], libraryID: "0123456789ABCDEF")
    }

    private func preparedTrack(name: String, codec: AudioFormatInfo.Codec, tags: TagSet, cover: Data?) throws -> PreparedTrack {
        let url = work.appendingPathComponent(name)
        let audio = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        try audio.write(to: url)
        let format = AudioFormatInfo(codec: codec, sampleRate: 44100, channels: 2, bitsPerSample: codec == .alac ? 16 : 0,
                                     bitRateKbps: codec == .alac ? 1411 : 320, sampleCount: 132300)
        return PreparedTrack(uploadURL: url, isTemporary: true, format: format, tags: tags, phoneCover: cover,
                             artworkChecksum: cover.map { UInt32($0.count + 17) } ?? 0, fileSize: Int64(audio.count))
    }

    func testSessionDeliversSongsArtworkAndSignedOperations() throws {
        let phone = FakePhone(grappaReply: try grappaReply())
        let snapshot = snapshot()
        var allocator = IdentityAllocator(snapshot: snapshot)

        var tags1 = TagSet()
        tags1.title = "First Song"; tags1.artist = "Band"; tags1.album = "Existing Album"; tags1.track = 1; tags1.trackTotal = 9
        tags1.genre = "Rock"; tags1.date = "2001-02-03"
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let first = try preparedTrack(name: "a.m4a", codec: .alac, tags: tags1, cover: cover)

        var tags2 = TagSet()
        tags2.title = "Second Song"; tags2.artist = "Solo Artist"; tags2.album = "New Album"
        let second = try preparedTrack(name: "b.mp3", codec: .mp3(audioFormat: 301), tags: tags2, cover: nil)

        var inserts = [PlannedInsert]()
        for (track, title) in [(first, "a"), (second, "b")] {
            let names = OperationFile.Names(tags: track.tags, fallbackTitle: title)
            let groups = allocator.groupIDs(album: names.album, effectiveArtist: names.effectiveAlbumArtist)
            inserts.append(PlannedInsert(pid: allocator.newPID(), albumPID: groups.album, artistPID: groups.artist,
                                         artworkCacheID: track.phoneCover == nil ? nil : allocator.artwork(),
                                         track: track, fallbackTitle: title))
        }
        XCTAssertEqual(inserts[0].albumPID, 555, "joins the existing album")
        XCTAssertEqual(inserts[0].artistPID, 444, "joins the existing artist")
        XCTAssertEqual(inserts[0].artworkCacheID, 701)

        var events = [SyncSession.Event]()
        let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Test Mac",
                                  libraryID: snapshot.libraryID!, onEvent: { events.append($0) })
        let outcome = try session.run(snapshot: snapshot, inserts: inserts)

        XCTAssertEqual(outcome.delivered, Set(inserts.map(\.pid)))
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(phone.signatureValid, "the .cig must sign the exact operation bytes")

        // Handshake messages.
        let commands = phone.received.map(\.command)
        XCTAssertEqual(Array(commands.prefix(3)), ["Ping", "RequestingSync", "FinishedSyncingMetadata"])
        XCTAssertEqual(commands.last, "Pong")
        let request = try XCTUnwrap(phone.received.first { $0.command == "RequestingSync" })
        XCTAssertEqual(request.session, 2)
        XCTAssertEqual((request.params["DataclassAnchors"] as? [String: String])?["Media"], "41")
        let hostInfo = try XCTUnwrap(request.params["HostInfo"] as? [String: Any])
        XCTAssertEqual(hostInfo["Grappa"] as? Data, GrappaSigner.hostRequest)
        XCTAssertEqual(hostInfo["LibraryID"] as? String, "0123456789ABCDEF")
        let finished = try XCTUnwrap(phone.received.first { $0.command == "FinishedSyncingMetadata" })
        XCTAssertEqual((finished.params["DataclassAnchors"] as? [String: String])?["Media"], "42")

        // Operation file.
        let staged = try XCTUnwrap(phone.stagedOperations)
        XCTAssertEqual(staged["revision"] as? Int, 42)
        let operations = try XCTUnwrap(staged["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 3)
        XCTAssertEqual(operations[0]["operation"] as? String, "update_db_info")
        XCTAssertEqual((operations[0]["pid"] as? NSNumber)?.int64Value, -4163065678378989684)
        let insert1 = operations[1]
        XCTAssertEqual(insert1["operation"] as? String, "insert_track")
        let item1 = try XCTUnwrap(insert1["item"] as? [String: Any])
        XCTAssertEqual(item1["title"] as? String, "First Song")
        XCTAssertEqual(item1["sort_name"] as? String, "First Song")
        XCTAssertEqual(item1["year"] as? Int, 2001)
        XCTAssertEqual(item1["track_number"] as? Int, 1)
        XCTAssertEqual(item1["track_count"] as? Int, 9)
        XCTAssertEqual(item1["total_time_ms"] as? Int, 3000)
        XCTAssertEqual(item1["artwork_cache_id"] as? Int, 701)
        XCTAssertEqual(item1["artwork_checksum"] as? Int, cover.count + 17)
        XCTAssertEqual((item1["album_pid"] as? NSNumber)?.int64Value, 555)
        let audio1 = try XCTUnwrap(insert1["avformat_info"] as? [String: Any])
        XCTAssertEqual(audio1["audio_format"] as? Int, 601)
        XCTAssertEqual(audio1["bit_rate"] as? Int, 1411)
        XCTAssertEqual(audio1["sample_rate"] as? Double, 44100)
        XCTAssertEqual(audio1["duration"] as? Int, 132300)
        XCTAssertEqual(audio1["gapless_heuristic_info"] as? Int, 1)
        XCTAssertNil(audio1["channels"])
        XCTAssertEqual((insert1["location"] as? [String: String])?["kind"], "Apple Lossless audio file")
        let audio2 = try XCTUnwrap(operations[2]["avformat_info"] as? [String: Any])
        XCTAssertEqual(audio2["audio_format"] as? Int, 301)
        XCTAssertEqual(audio2["channels"] as? Int, 2)
        XCTAssertNil(audio2["gapless_heuristic_info"])
        XCTAssertNil((operations[2]["item"] as? [String: Any])?["artwork_cache_id"])

        // Assets.
        for insert in inserts {
            let path = try XCTUnwrap(phone.completions[insert.assetID])
            XCTAssertTrue(path.hasPrefix("iTunes_Control/Music/F0"), path)
            XCTAssertTrue(path.hasSuffix("." + insert.track.fileExtension), path)
            XCTAssertEqual(phone.files[path], try Data(contentsOf: insert.track.uploadURL))
        }
        XCTAssertEqual(phone.files["Airlock/Media/Artwork/\(inserts[0].assetID)"], cover)
        XCTAssertNil(phone.files["Airlock/Media/Artwork/\(inserts[1].assetID)"])
        XCTAssertEqual(phone.refusals, ["123456789": 16, "-987654321": 16], "other songs' artwork/Genius requests are declined")
        XCTAssertNil(phone.files[SyncSession.operationFile])
        XCTAssertTrue(events.contains { if case .delivered = $0 { return true } else { return false } })
    }

    func testStopsWhenPhoneDisablesMusicSync() throws {
        let phone = FakePhone(grappaReply: try grappaReply())
        phone.disabledAssetTypes = ["Music", "Photo"]
        let track = try preparedTrack(name: "a.m4a", codec: .alac, tags: TagSet(), cover: nil)
        let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Mac", libraryID: "1")
        let insert = PlannedInsert(pid: 99999, albumPID: 1, artistPID: 2, artworkCacheID: nil, track: track, fallbackTitle: "a")
        XCTAssertThrowsError(try session.run(snapshot: snapshot(), inserts: [insert])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Sync Library"))
        }
        XCTAssertFalse(phone.received.contains { $0.command == "RequestingSync" })
    }

    private func singleInsert() throws -> PlannedInsert {
        let track = try preparedTrack(name: "a.m4a", codec: .alac, tags: TagSet(), cover: nil)
        return PlannedInsert(pid: 99999, albumPID: 1, artistPID: 2, artworkCacheID: nil, track: track, fallbackTitle: "a")
    }

    func testRefusesWhileSongsAwaitTheirAudio() throws {
        // Live iOS 27.2: answering the phone's audio requests for an unfinished Finder sync's songs
        // made it delete them, so iSync must not start a session at all.
        let phone = FakePhone(grappaReply: try grappaReply())
        var snapshot = snapshot()
        snapshot.awaitingAudio = [777, 778]
        let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Mac", libraryID: "1")
        XCTAssertThrowsError(try session.run(snapshot: snapshot, inserts: [try singleInsert()])) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 songs from an earlier sync"), error.localizedDescription)
        }
        XCTAssertTrue(phone.received.isEmpty, "nothing may be sent")
    }

    func testNeverAnswersAudioRequestsForOtherSongs() throws {
        for foreign in [("31337", 1), ("444", 1), ("555", 3), ("424242", 2)] {
            let phone = FakePhone(grappaReply: try grappaReply())
            phone.foreignRequests = [("123456789", 2), foreign]
            let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Mac", libraryID: "1")
            XCTAssertThrowsError(try session.run(snapshot: snapshot(), inserts: [try singleInsert()]), "\(foreign)")
            XCTAssertTrue(phone.refusals.isEmpty, "no FileError for \(foreign)")
            XCTAssertTrue(phone.completions.isEmpty, "stops before sending anything for \(foreign)")
        }
    }

    func testIdleExitAfterDeliveryEndsTheSession() throws {
        let phone = FakePhone(grappaReply: try grappaReply())
        phone.endsWithIdleExit = true
        let insert = try singleInsert()
        let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Mac", libraryID: "1")
        let outcome = try session.run(snapshot: snapshot(), inserts: [insert])
        XCTAssertEqual(outcome.delivered, [insert.pid])
        XCTAssertEqual(phone.refusals, ["123456789": 16, "-987654321": 16])
    }

    func testRefusesToOverwriteAnotherHostsStagedSync() throws {
        let phone = FakePhone(grappaReply: try grappaReply())
        try phone.makeDirectory(SyncSession.stagingDirectory)
        phone.files[SyncSession.stagingDirectory + "/Sync_00000000.plist"] = Data([1])
        let track = try preparedTrack(name: "a.m4a", codec: .alac, tags: TagSet(), cover: nil)
        let session = SyncSession(fs: phone, atc: ATCConnection(transport: phone), hostName: "Mac", libraryID: "1")
        let insert = PlannedInsert(pid: 99999, albumPID: 1, artistPID: 2, artworkCacheID: nil, track: track, fallbackTitle: "a")
        XCTAssertThrowsError(try session.run(snapshot: snapshot(), inserts: [insert]))
        XCTAssertFalse(phone.received.contains { $0.command == "FinishedSyncingMetadata" })
    }
}

final class PhoneLibraryTests: XCTestCase {
    /// Builds a miniature MediaLibrary.sqlitedb with the columns iSync reads.
    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString).sqlitedb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE db_info (db_pid INTEGER, primary_container_pid INTEGER);
        INSERT INTO db_info VALUES (-12345, 678);
        CREATE TABLE _MLDatabaseProperties (key TEXT, value TEXT);
        INSERT INTO _MLDatabaseProperties VALUES ('MLSyncClientSyncAnchor', '17');
        CREATE TABLE item (item_pid INTEGER, item_artist_pid INTEGER, album_pid INTEGER, album_artist_pid INTEGER,
                           base_location_id INTEGER, in_my_library INTEGER, remote_location_id INTEGER);
        CREATE TABLE item_extra (item_pid INTEGER, title TEXT, total_time_ms REAL, location TEXT);
        CREATE TABLE item_store (item_pid INTEGER, sync_id INTEGER);
        CREATE TABLE item_artist (item_artist_pid INTEGER, item_artist TEXT, sync_id INTEGER);
        CREATE TABLE album (album_pid INTEGER, album TEXT, album_artist_pid INTEGER, sync_id INTEGER);
        CREATE TABLE album_artist (album_artist_pid INTEGER, album_artist TEXT, sync_id INTEGER);
        CREATE TABLE container (container_pid INTEGER, sync_id INTEGER);
        CREATE TABLE artwork_token (artwork_token TEXT);
        CREATE TABLE artwork (artwork_token TEXT);
        CREATE TABLE base_location (base_location_id INTEGER, path TEXT);
        INSERT INTO base_location VALUES (1, 'iTunes_Control/Music/F07'), (2, 'iTunes_Control/Ringtones'),
                                         (200, 'Music/Cache'), (250, 'Music/Downloads');
        INSERT INTO album_artist VALUES (1, 'The Band', 9001);
        INSERT INTO album VALUES (1, 'Great Album', 1, 9002);
        INSERT INTO item_artist VALUES (1, 'The Band', 0);
        INSERT INTO item VALUES (1, 1, 1, 1, 1, 1, 0), (2, 1, 1, 1, 0, 0, 0), (3, 1, 1, 1, 0, 1, 0),
                                (4, 1, 1, 1, 0, 1, 100), (5, 1, 1, 1, 200, 1, 100), (6, 1, 1, 1, 250, 1, 100);
        INSERT INTO item_extra VALUES (1, 'Don''t Stop', 201000, 'ABCD.m4a'), (2, 'Not In Library', 1000, ''),
                                      (3, 'Never Arrived', 1000, ''), (4, 'Apple Music Only', 2000, ''),
                                      (5, 'Streamed Once', 3000, '5bd8b2a8-eeee-4b70-97b0-c04d8c50d183.m4a'),
                                      (6, 'Downloaded', 4000, 'f0e1d2c3.m4a');
        INSERT INTO item_store VALUES (1, 5555), (2, 0), (3, 7777), (4, 0), (5, 0), (6, 0);
        INSERT INTO container VALUES (1, 4242);
        INSERT INTO artwork_token VALUES ('700'), ('abc'), ('2146701822');
        INSERT INTO artwork VALUES ('701');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        return url
    }

    func testReadsSnapshot() throws {
        let url = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try PhoneLibrary.read(databaseAt: url)
        XCTAssertEqual(snapshot.databasePID, -12345)
        XCTAssertEqual(snapshot.primaryContainerPID, 678)
        XCTAssertEqual(snapshot.mediaAnchor, 17)
        XCTAssertEqual(snapshot.tracks.sorted { $0.title < $1.title }, [
            PhoneTrack(title: "Don't Stop", artist: "The Band", album: "Great Album", albumArtist: "The Band",
                       durationMs: 201000, syncID: 5555),
            PhoneTrack(title: "Downloaded", artist: "The Band", album: "Great Album", albumArtist: "The Band",
                       durationMs: 4000, syncID: 0),
        ], "only songs whose audio is stored on the phone count: not Apple Music songs that aren't downloaded "
            + "(even with a copy in the streaming cache), nor synced songs whose audio never arrived")
        XCTAssertEqual(snapshot.albumIDs[.init(album: "great album", artist: "THE BAND")], 9002)
        XCTAssertEqual(snapshot.artistIDs["the band"], 9001)
        XCTAssertTrue(snapshot.usedSyncIDs.isSuperset(of: [5555, 9001, 9002, 4242, -12345, 678]))
        XCTAssertEqual(snapshot.largestArtworkID, 2146701822)
        XCTAssertEqual(snapshot.musicFolders, ["F07"])
        XCTAssertEqual(snapshot.tracksWithFiles, [5555])
        XCTAssertEqual(snapshot.awaitingAudio, [7777])
    }

    func testParsesLibraryIdentity() {
        var raw = Data(count: 1232)
        raw.replaceSubrange(0..<4, with: Data("frpd".utf8))
        raw[8] = 1
        var components = Data()
        components.appendLE(UInt64(0x1234))
        components.appendLE(UInt64(0xAB))
        raw.replaceSubrange(12..<28, with: components)
        XCTAssertEqual(PhoneLibrary.parseLibraryID(prefs: raw), "000000000000129F")
        let wrapped = try! PropertyListSerialization.data(fromPropertyList: ["iPodPrefs": raw], format: .binary, options: 0)
        XCTAssertEqual(PhoneLibrary.parseLibraryID(prefs: wrapped), "000000000000129F")
        raw[8] = 0
        XCTAssertNil(PhoneLibrary.parseLibraryID(prefs: raw), "unconfigured preferences carry no identity")
    }
}

final class DuplicateIndexTests: XCTestCase {
    func testMatching() {
        let index = DuplicateIndex(tracks: [
            PhoneTrack(title: "Don’t Stop", artist: "The Band", album: "Great Album", albumArtist: "The Band", durationMs: 201000, syncID: 1),
            PhoneTrack(title: "Intro", artist: "Someone", album: "Other", albumArtist: nil, durationMs: 60000, syncID: 2),
        ])
        func tags(_ title: String?, _ artist: String?, _ album: String?, albumArtist: String? = nil) -> TagSet {
            var tags = TagSet()
            tags.title = title; tags.artist = artist; tags.album = album; tags.albumArtist = albumArtist
            return tags
        }
        XCTAssertTrue(index.contains(tags("don't stop", "the band", "GREAT ALBUM"), durationMs: 200500))
        XCTAssertTrue(index.contains(tags("Dont Stop", "The Band", nil), durationMs: nil), "missing album still matches")
        XCTAssertTrue(index.contains(tags("Don't Stop", "Guest", "Great Album", albumArtist: "The Band"), durationMs: nil))
        XCTAssertFalse(index.contains(tags("Don't Stop", "The Band", "Great Album"), durationMs: 260000), "different length: another version")
        XCTAssertFalse(index.contains(tags("Don't Stop", "Another Band", "Great Album"), durationMs: nil))
        XCTAssertFalse(index.contains(tags("Don't Stop", "The Band", "Live Album"), durationMs: nil))
        XCTAssertFalse(index.contains(tags("Intro", nil, nil), durationMs: nil), "a bare title is not enough")
        XCTAssertTrue(index.contains(tags("Intro", nil, nil), durationMs: 60500))
        XCTAssertFalse(index.contains(tags(nil, "The Band", "Great Album"), durationMs: nil))
    }
}

final class OperationFileTests: XCTestCase {
    func testCleaning() {
        XCTAssertNil(OperationFile.clean("   "))
        XCTAssertEqual(OperationFile.clean("a\u{0}b\u{7}c"), "abc")
        XCTAssertEqual(OperationFile.clean("line1\nline2", allowNewlines: true), "line1\nline2")
        XCTAssertEqual(OperationFile.clean(String(repeating: "é", count: 300))?.utf16.count, 255)
        XCTAssertEqual(OperationFile.clean(String(repeating: "😀", count: 200))?.utf16.count, 254, "never splits a surrogate pair")
    }

    func testNamesFallBackSensibly() {
        var tags = TagSet()
        tags.compilation = true
        let names = OperationFile.Names(tags: tags, fallbackTitle: "01 Track.flac")
        XCTAssertEqual(names.title, "01 Track.flac")
        XCTAssertEqual(names.artist, "Unknown Artist")
        XCTAssertEqual(names.album, "Unknown Album")
        XCTAssertEqual(names.albumArtist, "Various Artists")
    }

    func testPIDsAreSignedSixtyFourBitIntegers() throws {
        let format = AudioFormatInfo(codec: .aac(profileCode: 502), sampleRate: 48000, channels: 2, bitsPerSample: 0,
                                     bitRateKbps: 256, sampleCount: 48000)
        let track = PreparedTrack(uploadURL: URL(fileURLWithPath: "/dev/null"), isTemporary: false, format: format,
                                  tags: TagSet(), phoneCover: nil, artworkChecksum: 0, fileSize: 0)
        let insert = PlannedInsert(pid: Int64.min + 5, albumPID: -1, artistPID: Int64.max, artworkCacheID: 9,
                                   track: track, fallbackTitle: "x")
        let data = try OperationFile.build(revision: 3, databasePID: -2, primaryContainerPID: 4, inserts: [insert])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertTrue(plist["timestamp"] is Date)
        let operation = try XCTUnwrap((plist["operations"] as? [[String: Any]])?.last)
        XCTAssertEqual((operation["pid"] as? NSNumber)?.int64Value, Int64.min + 5)
        let item = try XCTUnwrap(operation["item"] as? [String: Any])
        XCTAssertEqual((item["artist_pid"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertNil(item["artwork_cache_id"], "no cache ID without a cover")
        XCTAssertEqual(item["total_time_ms"] as? Int, 1000)
        XCTAssertEqual((operation["location"] as? [String: String])?["kind"], "AAC audio file")
    }
}
