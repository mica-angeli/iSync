import Foundation

/// One song to add to the phone, with the identities it will be filed under.
struct PlannedInsert {
    /// The song's persistent ID; the phone stores it as `item_store.sync_id` and uses its signed
    /// decimal form as the AssetID in the asset manifest.
    var pid: Int64
    var albumPID: Int64
    var artistPID: Int64
    var artworkCacheID: UInt32?
    var track: PreparedTrack
    /// Shown when the source has no title tag.
    var fallbackTitle: String

    var assetID: String { String(pid) }
}

/// Allocates persistent IDs that collide with nothing on the phone, and reuses the IDs of existing
/// albums and artists so new songs join them.
struct IdentityAllocator {
    private var used: Set<Int64>
    private var albums: [PhoneLibrarySnapshot.AlbumKey: Int64]
    private var artists: [String: Int64]
    private var nextArtwork: UInt32

    init(snapshot: PhoneLibrarySnapshot) {
        used = snapshot.usedSyncIDs
        albums = snapshot.albumIDs
        artists = snapshot.artistIDs
        nextArtwork = snapshot.largestArtworkID &+ 1
        if nextArtwork < 100 { nextArtwork = 100 }
    }

    mutating func newPID() -> Int64 {
        while true {
            let candidate = Int64(bitPattern: UInt64.random(in: 1000...UInt64.max))
            if candidate != 0, !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
        }
    }

    mutating func artwork() -> UInt32? {
        guard nextArtwork < UInt32(Int32.max) else { return nil }
        defer { nextArtwork += 1 }
        return nextArtwork
    }

    /// Album and album-artist IDs for a song, matching the phone's grouping rules: albums group by
    /// title and effective album artist; artists by name, ignoring ASCII case.
    mutating func groupIDs(album: String, effectiveArtist: String) -> (album: Int64, artist: Int64) {
        let artistKey = PhoneLibrarySnapshot.groupKey(effectiveArtist)
        let artistID = artists[artistKey] ?? newPID()
        artists[artistKey] = artistID
        let albumKey = PhoneLibrarySnapshot.AlbumKey(album: album, artist: effectiveArtist)
        let albumID = albums[albumKey] ?? newPID()
        albums[albumKey] = albumID
        return (albumID, artistID)
    }
}

/// Builds the signed operation file (`Sync_00000000.plist`) that tells the phone what to add.
enum OperationFile {
    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"
    static let variousArtists = "Various Artists"

    /// Text as Apple's host sends it: control characters removed (comments keep line breaks) and cut
    /// at 255 UTF-16 units on a character boundary.
    static func clean(_ value: String?, allowNewlines: Bool = false, limit: Int = 255) -> String? {
        guard let value else { return nil }
        let filtered = String(value.unicodeScalars.filter { scalar in
            if allowNewlines, scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }.map(Character.init)).trimmingCharacters(in: .whitespaces)
        guard !filtered.isEmpty else { return nil }
        var result = ""
        var units = 0
        for character in filtered {
            let length = character.utf16.count
            if units + length > limit { break }
            result.append(character)
            units += length
        }
        return result
    }

    /// The display values a song is filed under.
    struct Names {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String?

        var effectiveAlbumArtist: String { albumArtist ?? artist }

        init(tags: TagSet, fallbackTitle: String) {
            title = OperationFile.clean(tags.title) ?? OperationFile.clean(fallbackTitle) ?? "Untitled"
            artist = OperationFile.clean(tags.artist) ?? OperationFile.clean(tags.albumArtist) ?? OperationFile.unknownArtist
            album = OperationFile.clean(tags.album) ?? OperationFile.unknownAlbum
            albumArtist = OperationFile.clean(tags.albumArtist)
            // Apple only marks compilations that carry an explicit album artist.
            if tags.compilation && albumArtist == nil { albumArtist = OperationFile.variousArtists }
        }
    }

    static func insertTrack(_ insert: PlannedInsert, now: Date) -> [String: Any] {
        let tags = insert.track.tags
        let format = insert.track.format
        let names = Names(tags: tags, fallbackTitle: insert.fallbackTitle)

        var item: [String: Any] = [
            "title": names.title,
            "sort_name": clean(tags.sortTitle) ?? names.title,
            "artist": names.artist,
            "sort_artist": clean(tags.sortArtist) ?? names.artist,
            "album": names.album,
            "sort_album": clean(tags.sortAlbum) ?? names.album,
            "album_pid": insert.albumPID,
            "artist_pid": insert.artistPID,
            "is_song": true,
            "remember_bookmark": false,
            "total_time_ms": format.totalTimeMs,
            "date_created": now,
            "date_modified": now,
            "artwork_checksum": Int(insert.track.artworkChecksum),
        ]
        if let albumArtist = names.albumArtist {
            item["album_artist"] = albumArtist
            item["sort_album_artist"] = clean(tags.sortAlbumArtist) ?? albumArtist
        }
        if tags.compilation { item["is_compilation"] = true }
        if let genre = clean(tags.genre) { item["genre"] = genre }
        if let composer = clean(tags.composer) {
            item["composer"] = composer
            item["sort_composer"] = clean(tags.sortComposer) ?? composer
        }
        if let copyright = clean(tags.copyright) { item["copyright"] = copyright }
        if let comment = clean(tags.comment, allowNewlines: true, limit: 4096) { item["comment"] = comment }
        if let year = tags.year { item["year"] = year }
        if let track = tags.track { item["track_number"] = track }
        if let total = tags.trackTotal { item["track_count"] = total }
        if let disc = tags.disc { item["disc_number"] = disc }
        if let total = tags.discTotal { item["disc_count"] = total }
        if let rating = tags.contentRating { item["content_rating"] = rating }
        if let cacheID = insert.artworkCacheID, insert.track.phoneCover != nil {
            item["artwork_cache_id"] = Int(cacheID)
        }

        var audio: [String: Any] = [
            "audio_format": format.audioFormat,
            "bit_rate": format.bitRateKbps,
            "sample_rate": Double(format.sampleRate),
            "duration": format.sampleCount,
        ]
        switch format.codec {
        case .alac:
            // The gapless group and analysis flags every ALAC insert from Apple's host carries.
            audio["gapless_heuristic_info"] = 1
            audio["gapless_encoding_delay"] = 0
            audio["gapless_encoding_drain"] = 0
            audio["gapless_last_frame_resynch"] = 0
            audio["analysis_inhibit_flags"] = 2
        case .aac, .mp3:
            audio["channels"] = format.channels
        }

        return [
            "operation": "insert_track",
            "pid": insert.pid,
            "item": item,
            "avformat_info": audio,
            "item_stats": [
                "play_count_user": 0,
                "play_count_recent": 0,
                "skip_count_user": 0,
                "skip_count_recent": 0,
                "has_been_played": false,
            ] as [String: Any],
            "location": ["kind": format.kind],
        ]
    }

    /// Serialises the operation file: `update_db_info` (unchanged identities) followed by the inserts.
    static func build(revision: Int, databasePID: Int64, primaryContainerPID: Int64,
                      inserts: [PlannedInsert], now: Date = Date()) throws -> Data {
        let databaseInfo: [String: Any] = [
            "operation": "update_db_info",
            "pid": databasePID,
            "db_info": ["primary_container_pid": primaryContainerPID],
        ]
        let envelope: [String: Any] = [
            "revision": revision,
            "timestamp": now,
            "operations": [databaseInfo] + inserts.map { insertTrack($0, now: now) },
        ]
        return try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
    }
}
