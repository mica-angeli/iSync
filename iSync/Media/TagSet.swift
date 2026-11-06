import Foundation

/// The metadata of one song, normalised from whatever tag format the source used
/// (Vorbis comments, ID3, MP4 atoms, APE, RIFF INFO …) as reported by ffprobe.
struct TagSet: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var date: String?
    var comment: String?
    var copyright: String?
    var lyrics: String?
    var grouping: String?
    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var sortAlbumArtist: String?
    var sortComposer: String?
    var track: Int?
    var trackTotal: Int?
    var disc: Int?
    var discTotal: Int?
    var compilation = false
    var bpm: Int?
    /// iTunes advisory: 1 explicit, 2 clean.
    var contentRating: Int?
    /// Every other tag, preserved as an iTunes freeform (`----`) atom: (name, value).
    var extras: [Extra] = []

    struct Extra: Equatable {
        var name: String
        var value: String
    }

    /// Four-digit year taken from the date tag.
    var year: Int? {
        guard let date else { return nil }
        let digits = date.prefix { $0.isNumber }
        guard digits.count >= 4, let year = Int(digits.prefix(4)), year > 0 else { return nil }
        return year
    }

    /// The name albums are grouped under: the album artist, or the track artist without one.
    var effectiveAlbumArtist: String? { albumArtist ?? artist }

    // MARK: Parsing

    private enum Field {
        case title, artist, album, albumArtist, composer, genre, date, comment, copyright, lyrics, grouping
        case sortTitle, sortArtist, sortAlbum, sortAlbumArtist, sortComposer
        case track, trackTotal, disc, discTotal, compilation, bpm, contentRating
        case originalDate
        case ignored
    }

    private static let aliases: [String: Field] = [
        "title": .title, "tit2": .title,
        "artist": .artist, "tpe1": .artist,
        "album": .album, "talb": .album,
        "album_artist": .albumArtist, "albumartist": .albumArtist, "album artist": .albumArtist, "tpe2": .albumArtist,
        "composer": .composer, "tcom": .composer,
        "genre": .genre, "tcon": .genre,
        "date": .date, "year": .date, "tdrc": .date, "tyer": .date,
        "originaldate": .originalDate, "originalyear": .originalDate, "original_year": .originalDate, "tdor": .originalDate,
        "comment": .comment, "comments": .comment, "description": .comment,
        "copyright": .copyright, "tcop": .copyright,
        "lyrics": .lyrics, "unsyncedlyrics": .lyrics, "unsynced lyrics": .lyrics, "uslt": .lyrics,
        "grouping": .grouping, "tit1": .grouping, "contentgroup": .grouping,
        "sort_name": .sortTitle, "titlesort": .sortTitle, "title-sort": .sortTitle, "title_sort": .sortTitle, "tsot": .sortTitle,
        "sort_artist": .sortArtist, "artistsort": .sortArtist, "artist-sort": .sortArtist, "artist_sort": .sortArtist, "tsop": .sortArtist,
        "sort_album": .sortAlbum, "albumsort": .sortAlbum, "album-sort": .sortAlbum, "album_sort": .sortAlbum, "tsoa": .sortAlbum,
        "sort_album_artist": .sortAlbumArtist, "albumartistsort": .sortAlbumArtist, "album_artist-sort": .sortAlbumArtist,
        "album_artist_sort": .sortAlbumArtist, "albumartist_sort": .sortAlbumArtist, "tso2": .sortAlbumArtist,
        "sort_composer": .sortComposer, "composersort": .sortComposer, "composer-sort": .sortComposer, "composer_sort": .sortComposer, "tsoc": .sortComposer,
        "track": .track, "tracknumber": .track, "trck": .track, "trkn": .track,
        "tracktotal": .trackTotal, "totaltracks": .trackTotal, "track_total": .trackTotal, "total tracks": .trackTotal,
        "disc": .disc, "discnumber": .disc, "disk": .disc, "tpos": .disc,
        "disctotal": .discTotal, "totaldiscs": .discTotal, "disc_total": .discTotal, "total discs": .discTotal,
        "compilation": .compilation, "cpil": .compilation, "itunescompilation": .compilation, "tcmp": .compilation,
        "bpm": .bpm, "tbpm": .bpm, "tmpo": .bpm,
        "itunesadvisory": .contentRating, "rtng": .contentRating,
        // Container and encoder bookkeeping that describes the old file, not the song.
        "encoder": .ignored, "encoded_by": .ignored, "major_brand": .ignored, "minor_version": .ignored,
        "compatible_brands": .ignored, "creation_time": .ignored, "handler_name": .ignored, "vendor_id": .ignored,
        "itunsmpb": .ignored, "cuesheet": .ignored, "duration": .ignored, "gapless_playback": .ignored,
        "media_type": .ignored, "hd_video": .ignored, "waveformatextensible_channel_mask": .ignored,
        "tsse": .ignored, "tenc": .ignored, "tlen": .ignored, "encoding_tool": .ignored, "encodedby": .ignored,
        "itunes_cddb_1": .ignored, "coverart": .ignored, "metadata_block_picture": .ignored,
    ]

    /// Picard's names for MusicBrainz and related tags when stored as iTunes freeform atoms.
    private static let freeformNames: [String: String] = [
        "musicbrainz_trackid": "MusicBrainz Track Id",
        "musicbrainz_releasetrackid": "MusicBrainz Release Track Id",
        "musicbrainz_albumid": "MusicBrainz Album Id",
        "musicbrainz_artistid": "MusicBrainz Artist Id",
        "musicbrainz_albumartistid": "MusicBrainz Album Artist Id",
        "musicbrainz_releasegroupid": "MusicBrainz Release Group Id",
        "musicbrainz_workid": "MusicBrainz Work Id",
        "musicbrainz_discid": "MusicBrainz Disc Id",
        "musicbrainz_albumstatus": "MusicBrainz Album Status",
        "releasestatus": "MusicBrainz Album Status",
        "musicbrainz_albumtype": "MusicBrainz Album Type",
        "releasetype": "MusicBrainz Album Type",
        "releasecountry": "MusicBrainz Album Release Country",
        "musicbrainz_albumcomment": "MusicBrainz Album Comment",
        "acoustid_id": "Acoustid Id",
        "acoustid_fingerprint": "Acoustid Fingerprint",
        "musicip_puid": "MusicIP PUID",
        "isrc": "ISRC",
        "tsrc": "ISRC",
        "barcode": "BARCODE",
        "catalognumber": "CATALOGNUMBER",
        "label": "LABEL",
        "publisher": "LABEL",
        "organization": "LABEL",
        "tpub": "LABEL",
        "media": "MEDIA",
        "script": "SCRIPT",
        "asin": "ASIN",
        "language": "LANGUAGE",
        "mood": "MOOD",
        "conductor": "CONDUCTOR",
        "tpe3": "CONDUCTOR",
        "performer": "PERFORMER",
        "lyricist": "LYRICIST",
        "text": "LYRICIST",
        "arranger": "ARRANGER",
        "producer": "PRODUCER",
        "engineer": "ENGINEER",
        "mixer": "MIXER",
        "djmixer": "DJMIXER",
        "remixer": "REMIXER",
        "subtitle": "SUBTITLE",
        "discsubtitle": "DISCSUBTITLE",
        "license": "LICENSE",
        "website": "WEBSITE",
        "replaygain_track_gain": "replaygain_track_gain",
        "replaygain_track_peak": "replaygain_track_peak",
        "replaygain_album_gain": "replaygain_album_gain",
        "replaygain_album_peak": "replaygain_album_peak",
        "replaygain_reference_loudness": "replaygain_reference_loudness",
        "itunnorm": "iTunNORM",
    ]

    /// Builds a tag set from raw `key = value` pairs in priority order (earlier pairs win).
    init(raw pairs: [(String, String)]) {
        var originalDate: String?
        var seenExtras = Set<String>()
        for (rawKey, rawValue) in pairs {
            let value = Self.clean(rawValue)
            guard !value.isEmpty else { continue }
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            let lower = key.lowercased()
            let field: Field? = Self.aliases[lower] ?? (lower.hasPrefix("lyrics-") || lower.hasPrefix("lyrics_") ? .lyrics : nil)
            switch field {
            case .title: title = title ?? value
            case .artist: artist = artist ?? value
            case .album: album = album ?? value
            case .albumArtist: albumArtist = albumArtist ?? value
            case .composer: composer = composer ?? value
            case .genre: genre = genre ?? Self.genreName(value)
            case .date: date = date ?? value
            case .originalDate: originalDate = originalDate ?? value
            case .comment: comment = comment ?? value
            case .copyright: copyright = copyright ?? value
            case .lyrics: lyrics = lyrics ?? value
            case .grouping: grouping = grouping ?? value
            case .sortTitle: sortTitle = sortTitle ?? value
            case .sortArtist: sortArtist = sortArtist ?? value
            case .sortAlbum: sortAlbum = sortAlbum ?? value
            case .sortAlbumArtist: sortAlbumArtist = sortAlbumArtist ?? value
            case .sortComposer: sortComposer = sortComposer ?? value
            case .track:
                let (number, total) = Self.numberPair(value)
                track = track ?? number
                trackTotal = trackTotal ?? total
            case .trackTotal: trackTotal = trackTotal ?? Self.number(value)
            case .disc:
                let (number, total) = Self.numberPair(value)
                disc = disc ?? number
                discTotal = discTotal ?? total
            case .discTotal: discTotal = discTotal ?? Self.number(value)
            case .compilation: compilation = compilation || ["1", "true", "yes"].contains(value.lowercased())
            case .bpm: bpm = bpm ?? Self.number(value)
            case .contentRating:
                if let rating = Self.number(value), rating == 1 || rating == 2 || rating == 4 {
                    contentRating = contentRating ?? (rating == 4 ? 1 : rating)
                }
            case .ignored:
                continue
            case nil:
                let name = Self.freeformNames[lower] ?? key
                guard !name.isEmpty, !seenExtras.contains(name.lowercased()) else { continue }
                seenExtras.insert(name.lowercased())
                extras.append(Extra(name: name, value: value))
            }
        }
        if date == nil { date = originalDate }
        if let total = trackTotal, let number = track, number > total { trackTotal = nil }
        if let total = discTotal, let number = disc, number > total { discTotal = nil }
    }

    init() {}

    /// Trims whitespace and NUL padding.
    static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
    }

    static func number(_ value: String) -> Int? {
        let digits = value.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let number = Int(digits), number > 0, number < 65536 else { return nil }
        return number
    }

    /// Parses "3", "3/12" or "03 of 12".
    static func numberPair(_ value: String) -> (Int?, Int?) {
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { String($0) }
        let first = parts.first.flatMap { number($0) }
        let second = parts.count > 1 ? number(parts[1]) : nil
        return (first, second)
    }

    /// ID3v1-style numeric genres such as "(17)" or "17" become names.
    static func genreName(_ value: String) -> String {
        var trimmed = value
        if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") {
            let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            if let index = Int(inner), index >= 0, index < id3Genres.count {
                let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? id3Genres[index] : rest
            }
        }
        if trimmed.allSatisfy(\.isNumber), let index = Int(trimmed), index < id3Genres.count {
            trimmed = id3Genres[index]
        }
        return trimmed
    }

    static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
        "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
        "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
        "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
        "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka",
        "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}
