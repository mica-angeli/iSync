import XCTest
import AVFoundation
@testable import iSync

final class TagSetTests: XCTestCase {
    func testNormalisesVorbisCommentsAsReportedByFFprobe() {
        let tags = TagSet(raw: [
            ("TITLE", "Test Sóng"), ("ARTIST", "Artist A"), ("ALBUM", "Album X"), ("album_artist", "AA"),
            ("track", "3"), ("TRACKTOTAL", "12"), ("disc", "1"), ("DISCTOTAL", "2"), ("DATE", "2019-05-01"),
            ("GENRE", "Rock"), ("COMPOSER", "Comp"), ("MUSICBRAINZ_TRACKID", "abc-123"),
            ("REPLAYGAIN_TRACK_GAIN", "-6.5 dB"), ("ARTISTSORT", "Artist, A"), ("COMPILATION", "1"),
            ("LYRICS", "la la"), ("encoder", "Lavf"), ("CUSTOM_THING", "kept"),
        ])
        XCTAssertEqual(tags.title, "Test Sóng")
        XCTAssertEqual(tags.artist, "Artist A")
        XCTAssertEqual(tags.albumArtist, "AA")
        XCTAssertEqual(tags.track, 3)
        XCTAssertEqual(tags.trackTotal, 12)
        XCTAssertEqual(tags.disc, 1)
        XCTAssertEqual(tags.discTotal, 2)
        XCTAssertEqual(tags.year, 2019)
        XCTAssertEqual(tags.sortArtist, "Artist, A")
        XCTAssertTrue(tags.compilation)
        XCTAssertEqual(tags.lyrics, "la la")
        XCTAssertEqual(tags.extras, [
            .init(name: "MusicBrainz Track Id", value: "abc-123"),
            .init(name: "replaygain_track_gain", value: "-6.5 dB"),
            .init(name: "CUSTOM_THING", value: "kept"),
        ])
    }

    func testID3StyleValues() {
        let tags = TagSet(raw: [("track", "07/9"), ("disc", "2/1"), ("genre", "(17)"), ("lyrics-eng", "words"), ("TSO2", "Sorted")])
        XCTAssertEqual(tags.track, 7)
        XCTAssertEqual(tags.trackTotal, 9)
        XCTAssertEqual(tags.disc, 2)
        XCTAssertNil(tags.discTotal, "a total below the number is dropped")
        XCTAssertEqual(tags.genre, "Rock")
        XCTAssertEqual(tags.lyrics, "words")
        XCTAssertEqual(tags.sortAlbumArtist, "Sorted")
    }
}

final class ConversionPlanTests: XCTestCase {
    private func probe(codec: String, format: String, rate: Int = 44100, channels: Int = 2, bits: Int = 16,
                       sampleFormat: String = "s16", profile: String? = nil, bitRate: Int? = nil) -> ProbeResult {
        ProbeResult(formatName: format, duration: 3, formatBitRate: bitRate,
                    audio: .init(index: 0, codec: codec, profile: profile, sampleRate: rate, channels: channels,
                                 sampleFormat: sampleFormat, bitsPerSample: bits, bitRate: bitRate, duration: 3,
                                 durationTS: nil, timeBase: nil, codecTag: nil),
                    pictures: [], rawTags: [])
    }

    func testPlans() throws {
        let flac = URL(fileURLWithPath: "/x/a.flac")
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "flac", format: "flac"), source: flac),
                       .encodeALAC(bits: 16, sampleRate: nil, downmix: false))
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "flac", format: "flac", rate: 96000, bits: 24, sampleFormat: "s32"), source: flac),
                       .encodeALAC(bits: 24, sampleRate: nil, downmix: false))
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "pcm_f32le", format: "wav", channels: 6, bits: 32, sampleFormat: "flt"), source: URL(fileURLWithPath: "/x/a.wav")),
                       .encodeALAC(bits: 24, sampleRate: nil, downmix: true))
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "dsd_lsbf_planar", format: "dsf", rate: 352800, bits: 0, sampleFormat: "fltp"), source: URL(fileURLWithPath: "/x/a.dsf")),
                       .encodeALAC(bits: 24, sampleRate: 88200, downmix: false))
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "alac", format: "mov,mp4,m4a,3gp,3g2,mj2"), source: URL(fileURLWithPath: "/x/a.m4a")), .copy)
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "mp3", format: "mp3", bitRate: 320_000), source: URL(fileURLWithPath: "/x/a.mp3")), .copy)
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "aac", format: "mov,mp4,m4a,3gp,3g2,mj2", profile: "LC", bitRate: 256_000), source: URL(fileURLWithPath: "/x/a.m4a")), .copy)
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "aac", format: "aac", profile: "LC"), source: URL(fileURLWithPath: "/x/a.aac")), .remux)
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "opus", format: "ogg", rate: 48000), source: URL(fileURLWithPath: "/x/a.opus")),
                       .encodeAAC(sampleRate: nil, downmix: false))
        XCTAssertEqual(try ConversionPlan.plan(for: probe(codec: "vorbis", format: "ogg", rate: 96000, channels: 6), source: URL(fileURLWithPath: "/x/a.ogg")),
                       .encodeAAC(sampleRate: 48000, downmix: true))
        XCTAssertThrowsError(try ConversionPlan.plan(for: probe(codec: "aac", format: "mov,mp4,m4a,3gp,3g2,mj2"), source: URL(fileURLWithPath: "/x/a.m4p")))
    }
}

/// End-to-end conversions with the real ffmpeg (skipped when it isn't installed).
final class ConverterTests: XCTestCase {
    private var tools: FFTools!
    private var work: URL!

    override func setUpWithError() throws {
        do { tools = try FFTools.locate() } catch { throw XCTSkip("ffmpeg is not installed") }
        work = FileManager.default.temporaryDirectory.appendingPathComponent("iSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func ffmpeg(_ arguments: [String]) throws {
        let result = try ProcessRunner.run(tools.ffmpeg, ["-v", "error", "-nostdin", "-y"] + arguments)
        XCTAssertEqual(result.status, 0, result.stderrString)
    }

    /// A 2-second tagged FLAC with a JPEG front cover and a PNG back cover.
    private func makeFLAC(bits: Int = 16, rate: Int = 44100) throws -> URL {
        let front = work.appendingPathComponent("front.jpg")
        let back = work.appendingPathComponent("back.png")
        let plain = work.appendingPathComponent("plain.flac")
        let flac = work.appendingPathComponent("song.flac")
        try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=320x320:d=1", "-frames:v", "1", front.path])
        try ffmpeg(["-f", "lavfi", "-i", "color=c=blue:s=200x200:d=1", "-frames:v", "1", back.path])
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=\(rate)", "-ac", "2",
                    "-sample_fmt", bits > 16 ? "s32" : "s16", "-c:a", "flac"]
                   + (bits > 16 ? ["-bits_per_raw_sample", "24"] : [])
                   + ["-metadata", "TITLE=Tëst Song", "-metadata", "ARTIST=Artist A", "-metadata", "ALBUM=Album X",
                      "-metadata", "ALBUMARTIST=Album Artist", "-metadata", "TRACKNUMBER=3", "-metadata", "TRACKTOTAL=12",
                      "-metadata", "DISCNUMBER=1", "-metadata", "DISCTOTAL=2", "-metadata", "DATE=2019-05-01",
                      "-metadata", "GENRE=Rock", "-metadata", "COMPOSER=Comp", "-metadata", "MUSICBRAINZ_TRACKID=abc-123",
                      "-metadata", "ARTISTSORT=Artist, A", "-metadata", "LYRICS=la la", plain.path])
        // Note: the PNG is stored first but marked as the back cover; the JPEG is the front cover.
        try ffmpeg(["-i", plain.path, "-i", back.path, "-i", front.path, "-map", "0:a", "-map", "1", "-map", "2",
                    "-c", "copy", "-disposition:v:0", "attached_pic", "-disposition:v:1", "attached_pic",
                    "-metadata:s:v:0", "comment=Cover (back)", "-metadata:s:v:1", "comment=Cover (front)", flac.path])
        return flac
    }

    func testFLACBecomesTaggedALACWithAllCovers() throws {
        let flac = try makeFLAC()
        let probe = try ProbeResult.probe(flac, tools: tools)
        XCTAssertEqual(probe.pictures.count, 2)
        XCTAssertEqual(probe.frontPicture?.codec, "mjpeg")
        let plan = try ConversionPlan.plan(for: probe, source: flac)
        XCTAssertEqual(plan, .encodeALAC(bits: 16, sampleRate: nil, downmix: false))

        let prepared = try Converter.prepare(source: flac, probe: probe, plan: plan, tools: tools, workDirectory: work)
        XCTAssertTrue(prepared.isTemporary)
        XCTAssertEqual(prepared.fileExtension, "m4a")
        XCTAssertEqual(prepared.format.audioFormat, 601)
        XCTAssertEqual(prepared.format.sampleRate, 44100)
        XCTAssertEqual(prepared.format.bitsPerSample, 16)
        XCTAssertEqual(prepared.format.bitRateKbps, 1411)
        XCTAssertEqual(prepared.format.sampleCount, 88200)
        XCTAssertEqual(prepared.format.totalTimeMs, 2000)
        let cover = try XCTUnwrap(prepared.phoneCover)
        XCTAssertTrue(CoverArt.isJPEG(cover))
        XCTAssertEqual(prepared.artworkChecksum, UInt32(cover.count + 17))

        // Read the result back with ffprobe: lossless audio, every tag, both pictures.
        let out = try ProbeResult.probe(prepared.uploadURL, tools: tools)
        XCTAssertEqual(out.audio.codec, "alac")
        XCTAssertEqual(out.pictures.count, 2)
        XCTAssertEqual(out.pictures.first?.codec, "mjpeg", "front cover first")
        let tags = Dictionary(out.rawTags.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(tags["title"], "Tëst Song")
        XCTAssertEqual(tags["artist"], "Artist A")
        XCTAssertEqual(tags["album"], "Album X")
        XCTAssertEqual(tags["album_artist"], "Album Artist")
        XCTAssertEqual(tags["track"], "3/12")
        XCTAssertEqual(tags["disc"], "1/2")
        XCTAssertEqual(tags["date"], "2019-05-01")
        XCTAssertEqual(tags["genre"], "Rock")
        XCTAssertEqual(tags["composer"], "Comp")
        XCTAssertEqual(tags["sort_artist"], "Artist, A")
        XCTAssertEqual(tags["lyrics"], "la la")
        XCTAssertEqual(tags["musicbrainz track id"], "abc-123")

        // Apple's own metadata reader understands the atoms.
        let asset = AVURLAsset(url: prepared.uploadURL)
        let semaphore = DispatchSemaphore(value: 0)
        var items = [AVMetadataItem]()
        Task {
            items = (try? await asset.loadMetadata(for: .iTunesMetadata)) ?? []
            semaphore.signal()
        }
        semaphore.wait()
        func value(_ identifier: AVMetadataIdentifier) -> AVMetadataItem? {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first
        }
        XCTAssertEqual(value(.iTunesMetadataSongName)?.stringValue, "Tëst Song")
        XCTAssertEqual(value(.iTunesMetadataArtist)?.stringValue, "Artist A")
        XCTAssertEqual(value(.iTunesMetadataAlbumArtist)?.stringValue, "Album Artist")
        XCTAssertNotNil(value(.iTunesMetadataTrackNumber)?.dataValue)
        XCTAssertEqual(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).count, 2)

        // The decoded audio is bit-identical to the FLAC.
        func md5(_ url: URL) throws -> String {
            try ProcessRunner.run(tools.ffmpeg, ["-v", "error", "-i", url.path, "-map", "0:a", "-f", "md5", "-"]).stdoutString
        }
        XCTAssertEqual(try md5(flac), try md5(prepared.uploadURL))
    }

    func testHighResolutionFLACKeeps24Bits() throws {
        let flac = try makeFLAC(bits: 24, rate: 96000)
        let probe = try ProbeResult.probe(flac, tools: tools)
        let prepared = try Converter.prepare(source: flac, probe: probe, plan: try ConversionPlan.plan(for: probe, source: flac),
                                             tools: tools, workDirectory: work)
        XCTAssertEqual(prepared.format.bitsPerSample, 24)
        XCTAssertEqual(prepared.format.sampleRate, 96000)
        XCTAssertEqual(prepared.format.bitRateKbps, 4608)
        XCTAssertEqual(prepared.format.sampleCount, 192000)
    }

    func testMP3IsSentUnchanged() throws {
        let mp3 = work.appendingPathComponent("song.mp3")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "192k",
                    "-metadata", "title=MP3 Song", "-metadata", "artist=Someone", mp3.path])
        let probe = try ProbeResult.probe(mp3, tools: tools)
        let plan = try ConversionPlan.plan(for: probe, source: mp3)
        XCTAssertEqual(plan, .copy)
        let prepared = try Converter.prepare(source: mp3, probe: probe, plan: plan, tools: tools, workDirectory: work)
        XCTAssertEqual(prepared.uploadURL, mp3)
        XCTAssertFalse(prepared.isTemporary)
        XCTAssertEqual(prepared.format.audioFormat, 301)
        XCTAssertEqual(prepared.format.kind, "MPEG audio file")
        XCTAssertEqual(prepared.format.bitRateKbps, 192)
        XCTAssertEqual(prepared.tags.title, "MP3 Song")
    }

    func testOpusBecomesAAC() throws {
        let opus = work.appendingPathComponent("song.opus")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-ac", "2", "-c:a", "libopus",
                    "-metadata", "title=Opus Song", "-metadata", "artist=Someone", opus.path])
        let probe = try ProbeResult.probe(opus, tools: tools)
        XCTAssertEqual(probe.tags.title, "Opus Song", "Ogg keeps tags on the stream")
        let plan = try ConversionPlan.plan(for: probe, source: opus)
        let prepared = try Converter.prepare(source: opus, probe: probe, plan: plan, tools: tools, workDirectory: work)
        XCTAssertEqual(prepared.format.audioFormat, 502)
        XCTAssertEqual(prepared.format.kind, "AAC audio file")
        let out = try ProbeResult.probe(prepared.uploadURL, tools: tools)
        XCTAssertEqual(out.tags.title, "Opus Song")
        XCTAssertEqual(out.tags.artist, "Someone")
    }
}

final class VideoPlanTests: XCTestCase {
    func testMovieFilesAreNeverSentAsIs() throws {
        var probe = ProbeResult(formatName: "mov,mp4,m4a,3gp,3g2,mj2", duration: 3, formatBitRate: 256_000,
                                audio: .init(index: 1, codec: "aac", profile: "LC", sampleRate: 44100, channels: 2,
                                             sampleFormat: "fltp", bitsPerSample: 0, bitRate: 256_000, duration: 3,
                                             durationTS: nil, timeBase: nil, codecTag: nil),
                                pictures: [], rawTags: [])
        let url = URL(fileURLWithPath: "/x/clip.mp4")
        XCTAssertEqual(try ConversionPlan.plan(for: probe, source: url), .copy)
        probe.hasVideo = true
        XCTAssertEqual(try ConversionPlan.plan(for: probe, source: url), .remux)
    }
}
