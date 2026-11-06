import Foundation
import SQLite3

/// A song already in the phone's library.
struct PhoneTrack: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var durationMs: Int?
    var syncID: Int64
}

/// What iSync needs to know about the phone's music library before a sync session.
struct PhoneLibrarySnapshot {
    var databasePID: Int64
    var primaryContainerPID: Int64
    /// `MLSyncClientSyncAnchor`: the Media anchor, +1 per accepted sync session.
    var mediaAnchor: Int
    var tracks: [PhoneTrack]
    /// Existing album sync IDs keyed by `AlbumKey`.
    var albumIDs: [AlbumKey: Int64]
    /// Existing album-artist sync IDs keyed by `groupKey(name)`.
    var artistIDs: [String: Int64]
    /// Every persistent ID in use, so new ones never collide.
    var usedSyncIDs: Set<Int64>
    var largestArtworkID: UInt32
    /// Music folders the library already uses (`F00` …).
    var musicFolders: [String]
    /// Sync IDs of tracks whose audio file is on the phone.
    var tracksWithFiles: Set<Int64>
    /// The host library identity from `iTunesPrefs`, when the phone has been synced before.
    var libraryID: String?

    /// The phone groups albums and artists by name, ignoring ASCII case.
    static func groupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    struct AlbumKey: Hashable {
        var album: String
        var artist: String

        init(album: String, artist: String) {
            self.album = PhoneLibrarySnapshot.groupKey(album)
            self.artist = PhoneLibrarySnapshot.groupKey(artist)
        }
    }
}

enum PhoneLibrary {
    static let databasePath = "iTunes_Control/iTunes/MediaLibrary.sqlitedb"

    /// Copies the phone's music database and identity to a temporary folder and reads them.
    static func read(from fs: PhoneFileSystem) throws -> PhoneLibrarySnapshot {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSync-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let local = directory.appendingPathComponent("MediaLibrary.sqlitedb")
        guard try fs.exists(databasePath) else {
            throw ISyncError("The iPhone has no music library yet. Open the Music app on the iPhone once, then try again.")
        }
        try fs.download(databasePath, to: local)
        // The write-ahead log holds recent changes; SQLite applies it when the copy is opened.
        if try fs.exists(databasePath + "-wal") {
            try fs.download(databasePath + "-wal", to: directory.appendingPathComponent("MediaLibrary.sqlitedb-wal"))
        }
        var snapshot = try read(databaseAt: local)
        snapshot.libraryID = readLibraryID(from: fs)
        return snapshot
    }

    /// The host library identity Finder registered on the phone (`iTunesPrefs`), formatted as Apple's
    /// host does: the XOR of two persisted 64-bit components as 16 uppercase hex digits.
    static func readLibraryID(from fs: PhoneFileSystem) -> String? {
        for path in ["iTunes_Control/iTunes/iTunesPrefs", "iTunes_Control/iTunes/iTunesPrefs.plist"] {
            guard let data = try? fs.readFile(path, limit: 1 << 20), let id = parseLibraryID(prefs: data) else { continue }
            return id
        }
        return nil
    }

    static func parseLibraryID(prefs input: Data) -> String? {
        var raw = input
        if !input.starts(with: Array("frpd".utf8)) {
            guard let plist = try? PropertyListSerialization.propertyList(from: input, format: nil) as? [String: Any],
                  let embedded = plist["iPodPrefs"] as? Data else { return nil }
            raw = embedded
        }
        guard raw.count >= 28, raw.starts(with: Array("frpd".utf8)), raw[raw.startIndex + 8] == 1 else { return nil }
        let catalog = raw.readLE(UInt64.self, at: 12)
        let user = raw.readLE(UInt64.self, at: 20)
        guard catalog != 0, user != 0, catalog ^ user != 0 else { return nil }
        return String(format: "%016llX", catalog ^ user)
    }

    // MARK: SQLite

    static func read(databaseAt url: URL) throws -> PhoneLibrarySnapshot {
        let db = try SQLiteReader(url: url)
        let (databasePID, primaryContainerPID) = try db.first("SELECT db_pid, primary_container_pid FROM db_info LIMIT 1") {
            ($0.int64(0), $0.int64(1))
        } ?? (0, 0)
        guard databasePID != 0, primaryContainerPID != 0 else {
            throw ISyncError("The iPhone's music library is missing its identity.")
        }
        let anchorText = try db.first("SELECT value FROM _MLDatabaseProperties WHERE key = 'MLSyncClientSyncAnchor'") { $0.text(0) } ?? nil
        let anchor = anchorText.flatMap { Int($0) } ?? 0

        // Songs that count as "on the phone": in the library, or stored locally, or synced.
        let itemColumns = try db.columns(of: "item")
        var conditions = ["i.base_location_id != 0", "s.sync_id != 0"]
        if itemColumns.contains("in_my_library") { conditions.append("i.in_my_library = 1") }
        let tracks: [PhoneTrack] = try db.all("""
            SELECT e.title, ia.item_artist, al.album, aa.album_artist, e.total_time_ms, s.sync_id
            FROM item i
            JOIN item_extra e ON e.item_pid = i.item_pid
            LEFT JOIN item_store s ON s.item_pid = i.item_pid
            LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid
            LEFT JOIN album al ON al.album_pid = i.album_pid
            LEFT JOIN album_artist aa ON aa.album_artist_pid = i.album_artist_pid
            WHERE \(conditions.joined(separator: " OR "))
            """) { row in
            guard let title = row.text(0), !title.isEmpty else { return nil }
            let duration = row.double(4)
            return PhoneTrack(title: title, artist: row.text(1), album: row.text(2), albumArtist: row.text(3),
                              durationMs: duration > 0 ? Int(duration) : nil, syncID: row.int64(5))
        }

        var albumIDs = [PhoneLibrarySnapshot.AlbumKey: Int64]()
        for (syncID, album, artist) in try db.all("""
            SELECT a.sync_id, a.album, aa.album_artist FROM album a
            LEFT JOIN album_artist aa ON aa.album_artist_pid = a.album_artist_pid
            WHERE a.sync_id != 0
            """, { row -> (Int64, String, String)? in
                guard let album = row.text(1) else { return nil }
                return (row.int64(0), album, row.text(2) ?? "")
            }) {
            albumIDs[.init(album: album, artist: artist)] = syncID
        }
        var artistIDs = [String: Int64]()
        for (syncID, name) in try db.all("SELECT sync_id, album_artist FROM album_artist WHERE sync_id != 0", { row -> (Int64, String)? in
            guard let name = row.text(1) else { return nil }
            return (row.int64(0), name)
        }) {
            artistIDs[PhoneLibrarySnapshot.groupKey(name)] = syncID
        }

        var used = Set<Int64>([databasePID, primaryContainerPID])
        for table in ["item_store", "album", "album_artist", "item_artist", "container", "composer"] where db.tableExists(table) {
            if try db.columns(of: table).contains("sync_id") {
                used.formUnion(try db.all("SELECT sync_id FROM \(table) WHERE sync_id != 0") { $0.int64(0) })
            }
        }

        var largestArtwork: UInt32 = 0
        for table in ["artwork_token", "artwork"] where db.tableExists(table) {
            for token in try db.all("SELECT artwork_token FROM \(table)", { $0.text(0) }) {
                if let value = UInt32(token), value < UInt32(Int32.max) { largestArtwork = max(largestArtwork, value) }
            }
        }

        let folders = try db.all("SELECT path FROM base_location", { $0.text(0) }).compactMap { path -> String? in
            guard path.hasPrefix("iTunes_Control/Music/") else { return nil }
            let folder = String(path.dropFirst("iTunes_Control/Music/".count))
            return folder.count == 3 && folder.hasPrefix("F") && folder.dropFirst().allSatisfy(\.isNumber) ? folder : nil
        }

        let withFiles = Set(try db.all("""
            SELECT s.sync_id FROM item i
            JOIN item_store s ON s.item_pid = i.item_pid
            JOIN item_extra e ON e.item_pid = i.item_pid
            WHERE s.sync_id != 0 AND i.base_location_id != 0 AND e.location IS NOT NULL AND e.location != ''
            """) { $0.int64(0) })

        return PhoneLibrarySnapshot(
            databasePID: databasePID, primaryContainerPID: primaryContainerPID, mediaAnchor: anchor,
            tracks: tracks, albumIDs: albumIDs, artistIDs: artistIDs, usedSyncIDs: used,
            largestArtworkID: largestArtwork, musicFolders: Array(Set(folders)).sorted(),
            tracksWithFiles: withFiles, libraryID: nil)
    }
}

/// Minimal read access to a SQLite database.
final class SQLiteReader {
    struct Row {
        let statement: OpaquePointer
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }

    private var db: OpaquePointer?

    init(url: URL) throws {
        // Read-write so SQLite can apply the copied write-ahead log; only the local copy is touched.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ISyncError("Could not read the iPhone's music library (\(message)).")
        }
    }

    deinit { sqlite3_close(db) }

    func all<T>(_ sql: String, _ transform: (Row) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ISyncError("The iPhone's music library has an unexpected format (\(String(cString: sqlite3_errmsg(db)))).")
        }
        defer { sqlite3_finalize(statement) }
        var results = [T]()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ISyncError("Could not read the iPhone's music library (\(String(cString: sqlite3_errmsg(db)))).")
            }
            if let value = try transform(Row(statement: statement)) { results.append(value) }
        }
        return results
    }

    func first<T>(_ sql: String, _ transform: (Row) throws -> T?) throws -> T? {
        try all(sql, transform).first
    }

    func tableExists(_ name: String) -> Bool {
        (try? first("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") { $0.int64(0) }) != nil
    }

    func columns(of table: String) throws -> Set<String> {
        Set(try all("PRAGMA table_info(\(table))") { $0.text(1) })
    }
}
