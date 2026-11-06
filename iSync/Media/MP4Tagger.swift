import Foundation

/// An embedded picture to store in an MP4 `covr` atom.
struct CoverImage: Equatable {
    enum Kind: UInt32 {
        case jpeg = 13
        case png = 14
        case bmp = 27
    }

    var data: Data
    var kind: Kind
}

/// Writes iTunes-style metadata (`moov/udta/meta/ilst`) into an MP4/M4A file.
///
/// FFmpeg's MP4 muxer only knows a fixed list of tags and drops the rest, so iSync writes the metadata
/// itself: every standard iTunes atom plus a freeform `----:com.apple.iTunes:<name>` atom for each other
/// tag, and every embedded picture (front cover first).
enum MP4Tagger {
    // MARK: Building ilst

    private static func atom(_ type: String, _ body: Data) -> Data {
        var data = Data()
        data.appendBE(UInt32(8 + body.count))
        data.append(fourCC(type))
        data.append(body)
        return data
    }

    /// Four-character code; `©` is encoded as the single MacRoman byte 0xA9.
    static func fourCC(_ type: String) -> Data {
        let bytes = type.unicodeScalars.map { $0.value == 0xA9 ? UInt8(0xA9) : UInt8(truncatingIfNeeded: $0.value) }
        precondition(bytes.count == 4, "atom types have four characters")
        return Data(bytes)
    }

    private static func dataAtom(type: UInt32, _ value: Data) -> Data {
        var body = Data()
        body.appendBE(type)       // version 0 + well-known type
        body.appendBE(UInt32(0))  // locale
        body.append(value)
        return atom("data", body)
    }

    private static func textItem(_ type: String, _ value: String?) -> Data? {
        guard let value, !value.isEmpty else { return nil }
        return atom(type, dataAtom(type: 1, Data(value.utf8)))
    }

    private static func freeformItem(name: String, value: String) -> Data {
        var mean = Data()
        mean.appendBE(UInt32(0))
        mean.append(Data("com.apple.iTunes".utf8))
        var nameBody = Data()
        nameBody.appendBE(UInt32(0))
        nameBody.append(Data(name.utf8))
        return atom("----", atom("mean", mean) + atom("name", nameBody) + dataAtom(type: 1, Data(value.utf8)))
    }

    static func buildItemList(tags: TagSet, covers: [CoverImage], encoder: String?) -> Data {
        var items = Data()
        let text: [(String, String?)] = [
            ("©nam", tags.title), ("©ART", tags.artist), ("aART", tags.albumArtist), ("©alb", tags.album),
            ("©gen", tags.genre), ("©wrt", tags.composer), ("©day", tags.date), ("©cmt", tags.comment),
            ("cprt", tags.copyright), ("©grp", tags.grouping), ("©lyr", tags.lyrics),
            ("sonm", tags.sortTitle), ("soar", tags.sortArtist), ("soaa", tags.sortAlbumArtist),
            ("soal", tags.sortAlbum), ("soco", tags.sortComposer), ("©too", encoder),
        ]
        for (type, value) in text {
            if let item = textItem(type, value) { items.append(item) }
        }
        if tags.track != nil || tags.trackTotal != nil {
            var value = Data()
            value.appendBE(UInt16(0))
            value.appendBE(UInt16(clamping: tags.track ?? 0))
            value.appendBE(UInt16(clamping: tags.trackTotal ?? 0))
            value.appendBE(UInt16(0))
            items.append(atom("trkn", dataAtom(type: 0, value)))
        }
        if tags.disc != nil || tags.discTotal != nil {
            var value = Data()
            value.appendBE(UInt16(0))
            value.appendBE(UInt16(clamping: tags.disc ?? 0))
            value.appendBE(UInt16(clamping: tags.discTotal ?? 0))
            items.append(atom("disk", dataAtom(type: 0, value)))
        }
        if tags.compilation {
            items.append(atom("cpil", dataAtom(type: 21, Data([1]))))
        }
        if let bpm = tags.bpm {
            var value = Data()
            value.appendBE(UInt16(clamping: bpm))
            items.append(atom("tmpo", dataAtom(type: 21, value)))
        }
        if let rating = tags.contentRating {
            items.append(atom("rtng", dataAtom(type: 21, Data([UInt8(clamping: rating)]))))
        }
        if !covers.isEmpty {
            items.append(atom("covr", covers.reduce(into: Data()) { $0.append(dataAtom(type: $1.kind.rawValue, $1.data)) }))
        }
        for extra in tags.extras {
            items.append(freeformItem(name: extra.name, value: extra.value))
        }
        return atom("ilst", items)
    }

    static func buildUserData(tags: TagSet, covers: [CoverImage], encoder: String?) -> Data {
        var handler = Data()
        handler.appendBE(UInt32(0))          // version/flags
        handler.appendBE(UInt32(0))          // pre_defined
        handler.append(fourCC("mdir"))       // handler type
        handler.append(fourCC("appl"))       // reserved (manufacturer)
        handler.appendBE(UInt32(0))
        handler.appendBE(UInt32(0))
        handler.append(0)                    // empty name
        var meta = Data()
        meta.appendBE(UInt32(0))             // meta is a full box
        meta.append(atom("hdlr", handler))
        meta.append(buildItemList(tags: tags, covers: covers, encoder: encoder))
        return atom("udta", atom("meta", meta))
    }

    // MARK: Parsing

    struct Box {
        var type: String
        var offset: Int      // start of the box header
        var headerSize: Int
        var size: Int

        var end: Int { offset + size }
        var bodyOffset: Int { offset + headerSize }
    }

    static func typeString(_ data: Data, at offset: Int) -> String {
        String(data.subdata(in: offset..<offset + 4).map { $0 == 0xA9 ? "©" : Character(UnicodeScalar($0)) })
    }

    /// Lists the boxes in `data[range]`.
    static func boxes(in data: Data, range: Range<Int>) throws -> [Box] {
        var result = [Box]()
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(data.readBE(UInt32.self, at: offset))
            let type = typeString(data, at: offset + 4)
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { throw ISyncError("Truncated MP4 box \(type).") }
                size = Int(data.readBE(UInt64.self, at: offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else {
                throw ISyncError("Malformed MP4 box \(type).")
            }
            result.append(Box(type: type, offset: offset, headerSize: header, size: size))
            offset += size
        }
        return result
    }

    /// Top-level boxes of a file, read from disk without loading media data.
    static func topLevelBoxes(of url: URL) throws -> [Box] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        var result = [Box]()
        var offset = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = Int(header.readBE(UInt32.self, at: 0))
            let type = typeString(header, at: 4)
            var headerSize = 8
            if size == 1, header.count >= 16 {
                size = Int(header.readBE(UInt64.self, at: 8))
                headerSize = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerSize, offset + size <= fileSize else {
                throw ISyncError("Malformed MP4 file (box \(type)).")
            }
            result.append(Box(type: type, offset: offset, headerSize: headerSize, size: size))
            offset += size
        }
        return result
    }

    // MARK: Writing

    /// Replaces the file's metadata with `tags` and `covers`.
    static func write(tags: TagSet, covers: [CoverImage], encoder: String? = "iSync", to url: URL) throws {
        let top = try topLevelBoxes(of: url)
        guard let moovBox = top.first(where: { $0.type == "moov" }) else {
            throw ISyncError("The converted file has no movie header.")
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(moovBox.offset))
        guard let moov = try handle.read(upToCount: moovBox.size), moov.count == moovBox.size else {
            throw ISyncError("Could not read the converted file's header.")
        }

        // Rebuild moov without its old user data, then append the new user data.
        let children = try boxes(in: moov, range: moovBox.headerSize..<moov.count)
        var body = Data()
        for child in children where child.type != "udta" {
            body.append(moov.subdata(in: child.offset..<child.end))
        }
        body.append(buildUserData(tags: tags, covers: covers, encoder: encoder))
        var newMoov = Data()
        newMoov.appendBE(UInt32(8 + body.count))
        newMoov.append(fourCC("moov"))
        newMoov.append(body)

        let isLast = moovBox.end == top.last?.end
        if isLast {
            // Media data precedes the header, so no chunk offsets move.
            try handle.truncate(atOffset: UInt64(moovBox.offset))
            try handle.seek(toOffset: UInt64(moovBox.offset))
            try handle.write(contentsOf: newMoov)
        } else {
            // The header precedes the media: shift every chunk offset by the size change.
            let delta = newMoov.count - moovBox.size
            let patched = try shiftChunkOffsets(in: newMoov, by: delta, after: moovBox.offset)
            try handle.seek(toOffset: UInt64(moovBox.end))
            let rest = try handle.readToEnd() ?? Data()
            try handle.truncate(atOffset: UInt64(moovBox.offset))
            try handle.seek(toOffset: UInt64(moovBox.offset))
            try handle.write(contentsOf: patched)
            try handle.write(contentsOf: rest)
        }
    }

    /// Adds `delta` to every `stco`/`co64` entry that points past `threshold`.
    static func shiftChunkOffsets(in moov: Data, by delta: Int, after threshold: Int) throws -> Data {
        guard delta != 0 else { return moov }
        var data = moov
        func walk(_ range: Range<Int>) throws {
            for box in try boxes(in: data, range: range) {
                switch box.type {
                case "trak", "mdia", "minf", "stbl", "edts", "dinf":
                    try walk(box.bodyOffset..<box.end)
                case "stco":
                    let count = Int(data.readBE(UInt32.self, at: box.bodyOffset + 4))
                    for i in 0..<count {
                        let at = box.bodyOffset + 8 + i * 4
                        let value = Int(data.readBE(UInt32.self, at: at))
                        if value > threshold {
                            guard let shifted = UInt32(exactly: value + delta) else {
                                throw ISyncError("The converted file is too large to tag.")
                            }
                            var bytes = Data(); bytes.appendBE(shifted)
                            data.replaceSubrange(at..<at + 4, with: bytes)
                        }
                    }
                case "co64":
                    let count = Int(data.readBE(UInt32.self, at: box.bodyOffset + 4))
                    for i in 0..<count {
                        let at = box.bodyOffset + 8 + i * 8
                        let value = Int(data.readBE(UInt64.self, at: at))
                        if value > threshold {
                            var bytes = Data(); bytes.appendBE(UInt64(value + delta))
                            data.replaceSubrange(at..<at + 8, with: bytes)
                        }
                    }
                default:
                    break
                }
            }
        }
        try walk(8..<data.count)
        return data
    }
}
