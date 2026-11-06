import Foundation

/// Locates and runs `ffmpeg` / `ffprobe`.
///
/// iSync relies on FFmpeg for decoding every audio format (FLAC, Ogg, Opus, APE, WavPack, DSD, …)
/// and for encoding ALAC/AAC. Apps launched from Finder don't inherit the shell's `PATH`, so the
/// usual install locations are searched explicitly. A copy placed inside the app bundle
/// (`Contents/MacOS/ffmpeg`) or a path set in the `ffmpegPath` user default takes precedence.
struct FFTools: Sendable {
    let ffmpeg: URL
    let ffprobe: URL
    /// Whether this ffmpeg build has Apple's AudioToolbox AAC encoder (`aac_at`), which sounds
    /// better than FFmpeg's native one.
    let hasAudioToolboxAAC: Bool

    static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
    ]

    static func locate() throws -> FFTools {
        func find(_ name: String) -> URL? {
            var candidates = [URL]()
            if let override = UserDefaults.standard.string(forKey: "\(name)Path"), !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
            if let bundled = Bundle.main.url(forAuxiliaryExecutable: name) {
                candidates.append(bundled)
            }
            var directories = searchDirectories
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                directories += path.split(separator: ":").map(String.init)
            }
            candidates += directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        guard let ffmpeg = find("ffmpeg"), let ffprobe = find("ffprobe") else {
            throw ISyncError("iSync needs FFmpeg to read and convert music. Install it with Homebrew (“brew install ffmpeg”) and try again.")
        }
        let encoders = (try? ProcessRunner.run(ffmpeg, ["-hide_banner", "-encoders"], timeout: 30))?.stdoutString ?? ""
        let hasAT = encoders.split(separator: "\n").contains { $0.contains(" aac_at ") }
        logInfo("Using \(ffmpeg.path) (AudioToolbox AAC: \(hasAT ? "yes" : "no"))")
        return FFTools(ffmpeg: ffmpeg, ffprobe: ffprobe, hasAudioToolboxAAC: hasAT)
    }
}

/// Runs a command-line tool to completion.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs `executable` and waits for it, killing it after `timeout` seconds or when `isCancelled`
    /// returns true.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 3600,
                    isCancelled: @escaping () -> Bool = { false }) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently so a chatty tool can never block on a full pipe.
        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var killedReason: String?
        while process.isRunning {
            if isCancelled() {
                killedReason = "cancelled"
                process.terminate()
                break
            }
            if Date() > deadline {
                killedReason = "timed out"
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()
        if let killedReason {
            throw ISyncError("\(executable.lastPathComponent) \(killedReason).")
        }
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
