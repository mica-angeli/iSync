import Foundation

/// What ffprobe reports about one file.
struct ProbeResult {
    struct Audio {
        var index: Int
        var codec: String
        var profile: String?
        var sampleRate: Int
        var channels: Int
        var sampleFormat: String?
        /// Significant bits per sample for lossless codecs (0 when unknown).
        var bitsPerSample: Int
        var bitRate: Int?
        var duration: Double?
        var durationTS: Int64?
        var timeBase: String?
        var codecTag: String?
    }

    struct Picture: Equatable {
        var index: Int
        var codec: String
        var comment: String?
        var width: Int?
        var height: Int?
        var isFront: Bool { comment?.lowercased().contains("front") ?? false }
    }

    var formatName: String
    var duration: Double?
    var formatBitRate: Int?
    var audio: Audio
    var pictures: [Picture]
    /// Tags in priority order: container-level first, then the audio stream's (Ogg keeps its
    /// comments on the stream).
    var rawTags: [(String, String)]

    var tags: TagSet { TagSet(raw: rawTags) }

    /// Duration in seconds, preferring the audio stream.
    var bestDuration: Double? {
        if let d = audio.duration, d > 0 { return d }
        if let d = duration, d > 0 { return d }
        return nil
    }

    var isMP4Family: Bool {
        formatName.split(separator: ",").contains { ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"].contains(String($0)) }
    }

    /// The front cover (or the first picture when none is marked as front).
    var frontPicture: Picture? { pictures.first(where: \.isFront) ?? pictures.first }

    /// Pictures ordered front cover first.
    var orderedPictures: [Picture] {
        guard let front = frontPicture else { return [] }
        return [front] + pictures.filter { $0 != front }
    }

    // MARK: Running ffprobe

    static func probe(_ url: URL, tools: FFTools) throws -> ProbeResult {
        let output = try ProcessRunner.run(tools.ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ], timeout: 120)
        guard output.status == 0 else {
            let reason = output.stderrString.split(separator: "\n").last.map(String.init) ?? "unreadable file"
            throw ISyncError("Not a readable audio file (\(reason)).")
        }
        return try parse(json: output.stdout)
    }

    static func parse(json: Data) throws -> ProbeResult {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ISyncError("ffprobe returned unexpected output.")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []

        func int(_ value: Any?) -> Int? {
            if let n = value as? NSNumber { return n.intValue }
            if let s = value as? String { return Int(s) }
            return nil
        }
        func double(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        func tagPairs(_ value: Any?) -> [(String, String)] {
            guard let tags = value as? [String: Any] else { return [] }
            return tags.compactMap { key, value in (value as? String).map { (key, $0) } }
                .sorted { $0.0 < $1.0 }
        }
        func isAttachedPicture(_ stream: [String: Any]) -> Bool {
            (stream["disposition"] as? [String: Any]).flatMap { int($0["attached_pic"]) } == 1
        }

        guard let audioStream = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw ISyncError("The file has no audio.")
        }
        let bitsRaw = int(audioStream["bits_per_raw_sample"]) ?? 0
        let bitsSample = int(audioStream["bits_per_sample"]) ?? 0
        let audio = Audio(
            index: int(audioStream["index"]) ?? 0,
            codec: audioStream["codec_name"] as? String ?? "unknown",
            profile: audioStream["profile"] as? String,
            sampleRate: int(audioStream["sample_rate"]) ?? 0,
            channels: int(audioStream["channels"]) ?? 0,
            sampleFormat: audioStream["sample_fmt"] as? String,
            bitsPerSample: bitsRaw > 0 ? bitsRaw : bitsSample,
            bitRate: int(audioStream["bit_rate"]),
            duration: double(audioStream["duration"]),
            durationTS: (audioStream["duration_ts"] as? NSNumber)?.int64Value,
            timeBase: audioStream["time_base"] as? String,
            codecTag: audioStream["codec_tag_string"] as? String
        )

        let pictures = streams.filter { $0["codec_type"] as? String == "video" && isAttachedPicture($0) }.map { stream in
            Picture(
                index: int(stream["index"]) ?? 0,
                codec: stream["codec_name"] as? String ?? "unknown",
                comment: (stream["tags"] as? [String: Any])?["comment"] as? String,
                width: int(stream["width"]),
                height: int(stream["height"])
            )
        }

        return ProbeResult(
            formatName: format["format_name"] as? String ?? "",
            duration: double(format["duration"]),
            formatBitRate: int(format["bit_rate"]),
            audio: audio,
            pictures: pictures,
            rawTags: tagPairs(format["tags"]) + tagPairs(audioStream["tags"])
        )
    }
}
