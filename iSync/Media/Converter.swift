import Foundation

/// The audio facts the phone's catalogue needs for an `insert_track` (`avformat_info`).
struct AudioFormatInfo: Equatable {
    enum Codec: Equatable {
        case alac
        case aac(profileCode: Int)   // 502 LC, 508 HE-AAC, 509 HE-AAC v2
        case mp3(audioFormat: Int)   // 301 MPEG-1, 302 MPEG-2, 303 MPEG-2.5 Layer III
    }

    var codec: Codec
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int
    var bitRateKbps: Int
    /// Duration in samples per channel.
    var sampleCount: Int64

    /// `avformat_info.audio_format`.
    var audioFormat: Int {
        switch codec {
        case .alac: return 601
        case .aac(let code): return code
        case .mp3(let code): return code
        }
    }

    /// `location.kind`, the string Apple's host sends for this codec.
    var kind: String {
        switch codec {
        case .alac: return "Apple Lossless audio file"
        case .aac: return "AAC audio file"
        case .mp3: return "MPEG audio file"
        }
    }

    var fileExtension: String {
        if case .mp3 = codec { return "mp3" }
        return "m4a"
    }

    /// `item.total_time_ms`: floor(samples × 1000 / rate), as Apple's host computes it.
    var totalTimeMs: Int64 {
        guard sampleRate > 0 else { return 0 }
        return sampleCount * 1000 / Int64(sampleRate)
    }

    var isLossless: Bool { codec == .alac }

    var summary: String {
        let rate = sampleRate % 1000 == 0 ? "\(sampleRate / 1000)" : String(format: "%.1f", Double(sampleRate) / 1000)
        switch codec {
        case .alac: return "ALAC \(bitsPerSample)-bit/\(rate) kHz"
        case .aac: return "AAC \(bitRateKbps) kbps"
        case .mp3: return "MP3 \(bitRateKbps) kbps"
        }
    }

    /// Reads the format of a phone-compatible file.
    static func from(_ probe: ProbeResult) throws -> AudioFormatInfo {
        let audio = probe.audio
        guard audio.sampleRate > 0, audio.channels > 0 else {
            throw ISyncError("The audio has no sample rate or channels.")
        }
        let codec: Codec
        switch audio.codec {
        case "alac":
            codec = .alac
        case "aac":
            switch audio.profile?.lowercased() {
            case "he-aacv2": codec = .aac(profileCode: 509)
            case "he-aac": codec = .aac(profileCode: 508)
            default: codec = .aac(profileCode: 502)
            }
        case "mp3":
            switch audio.sampleRate {
            case 32000, 44100, 48000: codec = .mp3(audioFormat: 301)
            case 16000, 22050, 24000: codec = .mp3(audioFormat: 302)
            default: codec = .mp3(audioFormat: 303)
            }
        default:
            throw ISyncError("\(audio.codec) cannot be sent to the iPhone without conversion.")
        }

        var samples: Int64 = 0
        if codec == .alac, let ts = audio.durationTS, ts > 0, audio.timeBase == "1/\(audio.sampleRate)" {
            samples = ts
        } else if let seconds = probe.bestDuration {
            samples = Int64((seconds * Double(audio.sampleRate)).rounded())
        }
        guard samples > 0 else { throw ISyncError("Could not determine the song's duration.") }

        let bits = codec == .alac ? (audio.bitsPerSample > 0 ? audio.bitsPerSample : 16) : 0
        let bitRate: Int
        if codec == .alac {
            // Apple sends the PCM rate for ALAC (1411 for 16-bit/44.1 kHz stereo).
            bitRate = Int((Int64(audio.sampleRate) * Int64(bits) * Int64(audio.channels) + 500) / 1000)
        } else {
            let bps = audio.bitRate ?? probe.formatBitRate ?? 0
            bitRate = max(1, Int((Double(bps) / 1000).rounded()))
        }
        return AudioFormatInfo(codec: codec, sampleRate: audio.sampleRate, channels: audio.channels,
                               bitsPerSample: bits, bitRateKbps: bitRate, sampleCount: samples)
    }
}

/// How a source file gets to the phone.
enum ConversionPlan: Equatable {
    /// Already playable by the iPhone (MP3, AAC or ALAC in M4A): sent byte-for-byte.
    case copy
    /// AAC or ALAC audio in another container (ADTS, Matroska, CAF …): rewrapped into M4A.
    case remux
    /// Lossless audio re-encoded as ALAC.
    case encodeALAC(bits: Int, sampleRate: Int?, downmix: Bool)
    /// Lossy audio the iPhone can't play (Ogg Vorbis, Opus, WMA …) re-encoded as 256 kbps AAC.
    case encodeAAC(sampleRate: Int?, downmix: Bool)

    static let losslessCodecs: Set<String> = [
        "flac", "alac", "wavpack", "ape", "tta", "mlp", "truehd", "mp4als", "shorten", "tak",
        "wmalossless", "dsd_lsbf", "dsd_msbf", "dsd_lsbf_planar", "dsd_msbf_planar", "s302m", "ralf",
    ]

    static func isLossless(_ codec: String) -> Bool {
        losslessCodecs.contains(codec) || codec.hasPrefix("pcm_")
    }

    static func plan(for probe: ProbeResult, source: URL) throws -> ConversionPlan {
        let audio = probe.audio
        let ext = source.pathExtension.lowercased()
        if ext == "m4p" || audio.codecTag == "drms" {
            throw ISyncError("Copy-protected (DRM) files can't be synced.")
        }
        guard audio.sampleRate > 0, audio.channels > 0 else {
            throw ISyncError("The audio stream is not readable.")
        }
        let stereoOrMono = audio.channels <= 2
        let downmix = !stereoOrMono

        if isLossless(audio.codec) {
            let validALACDepth = [16, 20, 24, 32].contains(audio.bitsPerSample)
            if audio.codec == "alac", probe.isMP4Family, stereoOrMono, validALACDepth {
                return ["m4a", "mp4", "m4b"].contains(ext) && !probe.hasVideo ? .copy : .remux
            }
            let isDSD = audio.codec.hasPrefix("dsd_")
            let isFloat = ["flt", "fltp", "dbl", "dblp"].contains(audio.sampleFormat ?? "")
            let bits = (audio.bitsPerSample > 0 && audio.bitsPerSample <= 16 && !isFloat && !isDSD) ? 16 : 24
            var rate: Int?
            if isDSD {
                rate = 88200
            } else if audio.sampleRate > 384_000 {
                rate = 192_000
            }
            return .encodeALAC(bits: bits, sampleRate: rate, downmix: downmix)
        }

        switch audio.codec {
        case "mp3":
            let bitRate = audio.bitRate ?? probe.formatBitRate ?? 0
            if probe.formatName == "mp3", ext == "mp3", !probe.hasVideo, stereoOrMono, audio.sampleRate <= 48000, bitRate <= 320_000 {
                return .copy
            }
        case "aac":
            let profile = audio.profile?.lowercased() ?? "lc"
            let supported = ["lc", "he-aac", "he-aacv2"].contains(profile)
            if supported, stereoOrMono, audio.sampleRate <= 96000 {
                if probe.isMP4Family, ["m4a", "mp4", "m4b"].contains(ext), !probe.hasVideo {
                    return .copy
                }
                return .remux
            }
        default:
            break
        }
        return .encodeAAC(sampleRate: audio.sampleRate > 48000 ? 48000 : nil, downmix: downmix)
    }

    var summary: String {
        switch self {
        case .copy: return "Already compatible"
        case .remux: return "Rewrap as M4A"
        case .encodeALAC: return "Convert to ALAC"
        case .encodeAAC: return "Convert to AAC"
        }
    }
}

/// A file ready to be uploaded to the phone, with everything its catalogue entry needs.
struct PreparedTrack {
    var uploadURL: URL
    var isTemporary: Bool
    var format: AudioFormatInfo
    var tags: TagSet
    /// The JPEG registered as the track's artwork on the phone.
    var phoneCover: Data?
    /// `artwork_checksum`: picture count plus summed container sizes (rustunes docs, chapter 04 §10.1).
    var artworkChecksum: UInt32
    var fileSize: Int64

    var fileExtension: String { format.fileExtension }
}

enum Converter {
    /// Converts (or simply validates) one source file for the phone.
    static func prepare(source: URL, probe: ProbeResult, plan: ConversionPlan, tools: FFTools,
                        workDirectory: URL, isCancelled: @escaping () -> Bool = { false }) throws -> PreparedTrack {
        let tags = probe.tags
        let pictureDirectory = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pictureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pictureDirectory) }
        let covers = try CoverArt.extract(from: source, probe: probe, tools: tools, workDirectory: pictureDirectory)

        var uploadURL = source
        var isTemporary = false
        var outputProbe = probe
        if plan != .copy {
            let output = workDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            var arguments = ["-v", "error", "-nostdin", "-y", "-i", source.path,
                             "-map", "0:a:0", "-map_metadata", "-1", "-map_chapters", "-1", "-vn"]
            switch plan {
            case .copy:
                break
            case .remux:
                arguments += ["-c:a", "copy"]
            case let .encodeALAC(bits, sampleRate, downmix):
                arguments += ["-c:a", "alac"]
                arguments += bits <= 16 ? ["-sample_fmt", "s16p"] : ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24"]
                if let sampleRate { arguments += ["-ar", String(sampleRate)] }
                if downmix { arguments += ["-ac", "2"] }
            case let .encodeAAC(sampleRate, downmix):
                arguments += tools.hasAudioToolboxAAC ? ["-c:a", "aac_at", "-b:a", "256k"] : ["-c:a", "aac", "-b:a", "256k"]
                if let sampleRate { arguments += ["-ar", String(sampleRate)] }
                if downmix { arguments += ["-ac", "2"] }
            }
            arguments += ["-f", "ipod", output.path]
            logInfo("ffmpeg \(arguments.joined(separator: " "))")
            let result: ProcessRunner.Output
            do {
                result = try ProcessRunner.run(tools.ffmpeg, arguments, timeout: 3600, isCancelled: isCancelled)
            } catch {
                // Stopped or timed out part-way: don't leave the half-written file behind.
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: output)
                let reason = result.stderrString.split(separator: "\n").suffix(2).joined(separator: " ")
                throw ISyncError("Conversion failed: \(reason)")
            }
            do {
                try MP4Tagger.write(tags: tags, covers: covers, to: output)
                outputProbe = try ProbeResult.probe(output, tools: tools)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            uploadURL = output
            isTemporary = true
        }

        let format = try AudioFormatInfo.from(outputProbe)
        let phoneCover = covers.first.flatMap(CoverArt.phoneJPEG)
        var checksum: UInt32 = 0
        if let phoneCover {
            // One picture: MP4 counts the whole `data` atom (payload + 16), ID3 the APIC payload.
            let container = format.fileExtension == "m4a" ? phoneCover.count + 16 : phoneCover.count
            checksum = UInt32(truncatingIfNeeded: 1 + container)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: uploadURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return PreparedTrack(uploadURL: uploadURL, isTemporary: isTemporary, format: format, tags: tags,
                             phoneCover: phoneCover, artworkChecksum: checksum, fileSize: size)
    }
}
