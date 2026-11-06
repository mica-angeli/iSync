import Foundation

/// Decides whether a song is already on the phone.
///
/// Songs match on title plus artist and album, compared loosely (case, accents, punctuation and
/// spacing are ignored, so "Don't" matches "Don’t"), and their durations must agree within a few
/// seconds when both are known.
struct DuplicateIndex {
    struct Entry {
        var artist: String
        var albumArtist: String
        var album: String
        var durationMs: Int?
    }

    static let durationTolerance = 3000

    private var byTitle = [String: [Entry]]()

    init(tracks: [PhoneTrack] = []) {
        for track in tracks {
            insert(title: track.title, artist: track.artist, albumArtist: track.albumArtist,
                   album: track.album, durationMs: track.durationMs)
        }
    }

    /// Folds a name for comparison: lowercase, no diacritics, letters and digits only.
    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    mutating func insert(title: String, artist: String?, albumArtist: String?, album: String?, durationMs: Int?) {
        let key = Self.normalize(title)
        guard !key.isEmpty else { return }
        byTitle[key, default: []].append(Entry(artist: Self.normalize(artist), albumArtist: Self.normalize(albumArtist),
                                               album: Self.normalize(album), durationMs: durationMs))
    }

    mutating func insert(_ tags: TagSet, durationMs: Int?) {
        guard let title = tags.title else { return }
        insert(title: title, artist: tags.artist, albumArtist: tags.albumArtist, album: tags.album, durationMs: durationMs)
    }

    func contains(_ tags: TagSet, durationMs: Int?) -> Bool {
        guard let title = tags.title, let candidates = byTitle[Self.normalize(title)] else { return false }
        let artist = Self.normalize(tags.artist)
        let albumArtist = Self.normalize(tags.albumArtist)
        let album = Self.normalize(tags.album)
        return candidates.contains { entry in
            let durationAgrees: Bool
            if let a = durationMs, let b = entry.durationMs {
                durationAgrees = abs(a - b) <= Self.durationTolerance
            } else {
                durationAgrees = true
            }
            guard durationAgrees else { return false }

            let artistKnown = !artist.isEmpty || !albumArtist.isEmpty
            let artistAgrees = !artistKnown
                || (!artist.isEmpty && (artist == entry.artist || artist == entry.albumArtist))
                || (!albumArtist.isEmpty && (albumArtist == entry.albumArtist || albumArtist == entry.artist))
            let albumAgrees = album.isEmpty || entry.album.isEmpty || album == entry.album
            guard artistAgrees, albumAgrees else { return false }
            // A bare title is too weak on its own: require a matching duration as well.
            if !artistKnown && album.isEmpty {
                return durationMs != nil && entry.durationMs != nil
            }
            return true
        }
    }
}
