import Foundation
import os

/// A user-presentable error.
struct ISyncError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

/// Runs blocking work on a global queue so it never ties up Swift's cooperative thread pool
/// (device I/O and ffmpeg both block for long periods).
func offMain<T>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Application log: unified logging, a rolling file in ~/Library/Logs/iSync and an optional UI sink.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    enum Level: String { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    let fileURL: URL
    private let queue = DispatchQueue(label: "app.isync.log")
    private let logger = Logger(subsystem: "app.isync.iSync", category: "sync")
    private var handle: FileHandle?
    private var sink: ((Level, String) -> Void)?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/iSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("iSync.log")
        // Keep the previous run's log next to the new one.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let previous = dir.appendingPathComponent("iSync.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: fileURL, to: previous)
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    /// Install a callback that receives every log line (called on the main queue).
    func setSink(_ sink: ((Level, String) -> Void)?) {
        queue.sync { self.sink = sink }
    }

    func write(_ level: Level, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let now = Date()
        queue.async {
            let line = "\(self.formatter.string(from: now)) [\(level.rawValue)] \(message)\n"
            self.handle?.write(Data(line.utf8))
            if let sink = self.sink {
                DispatchQueue.main.async { sink(level, message) }
            }
        }
    }
}

func logDebug(_ message: @autoclosure () -> String) { AppLog.shared.write(.debug, message()) }
func logInfo(_ message: @autoclosure () -> String) { AppLog.shared.write(.info, message()) }
func logWarning(_ message: @autoclosure () -> String) { AppLog.shared.write(.warning, message()) }
func logError(_ message: @autoclosure () -> String) { AppLog.shared.write(.error, message()) }

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dest in
            let start = self.index(self.startIndex, offsetBy: offset)
            self.copyBytes(to: dest, from: start..<self.index(start, offsetBy: MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dest in
            let start = self.index(self.startIndex, offsetBy: offset)
            self.copyBytes(to: dest, from: start..<self.index(start, offsetBy: MemoryLayout<T>.size))
        }
        return T(bigEndian: value)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        var bytes = [UInt8]()
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(), let byte = UInt8(String([high, low]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
