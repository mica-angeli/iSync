import Foundation

/// Error returned by the phone's Apple File Conduit service.
struct AFCError: LocalizedError, Equatable {
    let code: UInt64
    let operation: String

    static let objectNotFound: UInt64 = 8
    static let objectExists: UInt64 = 16

    var errorDescription: String? {
        "The iPhone's file service refused \(operation): \(Self.name(of: code)) (AFC error \(code))."
    }

    static func name(of code: UInt64) -> String {
        switch code {
        case 1: return "unknown error"
        case 2: return "invalid header"
        case 3: return "no resources"
        case 4: return "read error"
        case 5: return "write error"
        case 6: return "unknown packet type"
        case 7: return "invalid argument"
        case 8: return "object not found"
        case 9: return "object is a directory"
        case 10: return "permission denied"
        case 11: return "service not connected"
        case 12: return "operation timed out"
        case 13: return "too much data"
        case 14: return "end of data"
        case 15: return "operation not supported"
        case 16: return "object exists"
        case 17: return "object busy"
        case 18: return "no space left on the iPhone"
        case 19: return "operation would block"
        case 20: return "I/O error"
        case 21: return "operation interrupted"
        case 22: return "operation in progress"
        case 23: return "internal error"
        default: return "error"
        }
    }
}

/// Client for the AFC (`com.apple.afc`) file service, rooted at the phone's media partition
/// (`/var/mobile/Media`). Implements the small subset of the wire protocol iSync needs.
final class AFCClient {
    enum Operation: UInt64 {
        case status = 0x01
        case data = 0x02
        case readDirectory = 0x03
        case removePath = 0x08
        case makeDirectory = 0x09
        case getFileInfo = 0x0A
        case fileOpen = 0x0D
        case fileOpenResult = 0x0E
        case fileRead = 0x0F
        case fileWrite = 0x10
        case fileClose = 0x14
        case renamePath = 0x18
    }

    enum OpenMode: UInt64 {
        case readOnly = 1
        /// Write only; creates the file and truncates it.
        case writeOnly = 3
    }

    struct Packet {
        var operation: UInt64
        var header: Data
        var payload: Data
    }

    static let magic = Data("CFA6LPAA".utf8)
    static let headerSize = 40
    static let readChunk = 1 << 20
    static let writeChunk = 1 << 17

    private let transport: ServiceTransport
    private var packetNumber: UInt64 = 0
    var timeout: TimeInterval = 60

    init(transport: ServiceTransport) {
        self.transport = transport
    }

    func close() {
        transport.close()
    }

    // MARK: Wire format

    static func encode(operation: UInt64, packetNumber: UInt64, header: Data, payload: Data) -> Data {
        var data = Data(capacity: headerSize + header.count + payload.count)
        data.append(magic)
        data.appendLE(UInt64(headerSize + header.count + payload.count))
        data.appendLE(UInt64(headerSize + header.count))
        data.appendLE(packetNumber)
        data.appendLE(operation)
        data.append(header)
        data.append(payload)
        return data
    }

    /// Parses the fixed 40-byte packet header, returning (entire length, this length, packet number, operation).
    static func decodeHeader(_ data: Data) throws -> (entire: UInt64, this: UInt64, number: UInt64, operation: UInt64) {
        guard data.count == headerSize, data.prefix(8) == magic else {
            throw ISyncError("The iPhone's file service sent a malformed reply.")
        }
        let entire = data.readLE(UInt64.self, at: 8)
        let this = data.readLE(UInt64.self, at: 16)
        guard this >= UInt64(headerSize), entire >= this, entire < (1 << 31) else {
            throw ISyncError("The iPhone's file service sent an invalid packet length.")
        }
        return (entire, this, data.readLE(UInt64.self, at: 24), data.readLE(UInt64.self, at: 32))
    }

    private func request(_ operation: Operation, header: Data = Data(), payload: Data = Data(), name: String) throws -> Packet {
        packetNumber += 1
        try transport.send(Self.encode(operation: operation.rawValue, packetNumber: packetNumber, header: header, payload: payload))
        let fixed = try transport.receive(count: Self.headerSize, timeout: timeout)
        let decoded = try Self.decodeHeader(fixed)
        let replyHeader = try transport.receive(count: Int(decoded.this) - Self.headerSize, timeout: timeout)
        let replyPayload = try transport.receive(count: Int(decoded.entire - decoded.this), timeout: timeout)
        if decoded.operation == Operation.status.rawValue {
            let code = replyHeader.count >= 8 ? replyHeader.readLE(UInt64.self, at: 0) : 1
            if code != 0 { throw AFCError(code: code, operation: name) }
        }
        return Packet(operation: decoded.operation, header: replyHeader, payload: replyPayload)
    }

    private static func cString(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(0)
        return data
    }

    private static func strings(in data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast(data.last == 0 ? 1 : 0)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Paths

    /// Returns the file's attributes, or nil if nothing exists at `path`.
    func fileInfo(_ path: String) throws -> [String: String]? {
        do {
            let reply = try request(.getFileInfo, header: Self.cString(path), name: "reading information about \(path)")
            let parts = Self.strings(in: reply.payload)
            var info = [String: String]()
            var index = 0
            while index + 1 < parts.count {
                info[parts[index]] = parts[index + 1]
                index += 2
            }
            return info
        } catch let error as AFCError where error.code == AFCError.objectNotFound {
            return nil
        }
    }

    func exists(_ path: String) throws -> Bool {
        try fileInfo(path) != nil
    }

    func isDirectory(_ path: String) throws -> Bool {
        try fileInfo(path)?["st_ifmt"] == "S_IFDIR"
    }

    func fileSize(_ path: String) throws -> UInt64? {
        guard let info = try fileInfo(path), let size = info["st_size"] else { return nil }
        return UInt64(size)
    }

    /// Lists a directory, excluding `.` and `..`.
    func listDirectory(_ path: String) throws -> [String] {
        let reply = try request(.readDirectory, header: Self.cString(path), name: "listing \(path)")
        return Self.strings(in: reply.payload).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    func makeDirectory(_ path: String) throws {
        do {
            _ = try request(.makeDirectory, header: Self.cString(path), name: "creating \(path)")
        } catch let error as AFCError where error.code == AFCError.objectExists {
            return
        }
    }

    func removePath(_ path: String) throws {
        _ = try request(.removePath, header: Self.cString(path), name: "removing \(path)")
    }

    func renamePath(_ from: String, to: String) throws {
        var header = Self.cString(from)
        header.append(Self.cString(to))
        _ = try request(.renamePath, header: header, name: "renaming \(from)")
    }

    // MARK: Files

    private func open(_ path: String, mode: OpenMode) throws -> UInt64 {
        var header = Data()
        header.appendLE(mode.rawValue)
        header.append(Self.cString(path))
        let reply = try request(.fileOpen, header: header, name: "opening \(path)")
        guard reply.operation == Operation.fileOpenResult.rawValue, reply.header.count >= 8 else {
            throw ISyncError("The iPhone's file service did not open \(path).")
        }
        return reply.header.readLE(UInt64.self, at: 0)
    }

    private func closeFile(_ handle: UInt64, path: String) throws {
        var header = Data()
        header.appendLE(handle)
        _ = try request(.fileClose, header: header, name: "closing \(path)")
    }

    private func read(_ handle: UInt64, length: Int, path: String) throws -> Data {
        var header = Data()
        header.appendLE(handle)
        header.appendLE(UInt64(length))
        return try request(.fileRead, header: header, name: "reading \(path)").payload
    }

    private func write(_ handle: UInt64, _ data: Data, path: String) throws {
        var header = Data()
        header.appendLE(handle)
        _ = try request(.fileWrite, header: header, payload: data, name: "writing \(path)")
    }

    /// Reads a whole file into memory (bounded by `limit`).
    func readFile(_ path: String, limit: Int = 64 << 20) throws -> Data {
        let handle = try open(path, mode: .readOnly)
        defer { try? closeFile(handle, path: path) }
        var result = Data()
        while true {
            let chunk = try read(handle, length: Self.readChunk, path: path)
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count > limit {
                throw ISyncError("\(path) on the iPhone is unexpectedly large.")
            }
        }
        return result
    }

    /// Copies a file from the phone to a local URL.
    func download(_ path: String, to url: URL, limit: Int = 2 << 30) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let handle = try open(path, mode: .readOnly)
        defer { try? closeFile(handle, path: path) }
        var total = 0
        while true {
            let chunk = try read(handle, length: Self.readChunk, path: path)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            total += chunk.count
            if total > limit {
                throw ISyncError("\(path) on the iPhone is unexpectedly large.")
            }
        }
    }

    /// Creates or replaces a file with `data`.
    func writeFile(_ path: String, data: Data) throws {
        let handle = try open(path, mode: .writeOnly)
        var closed = false
        defer { if !closed { try? closeFile(handle, path: path) } }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.writeChunk, data.count)
            try write(handle, data.subdata(in: offset..<end), path: path)
            offset = end
        }
        closed = true
        try closeFile(handle, path: path)
    }

    /// Streams a local file to the phone, reporting the bytes sent so far.
    func upload(_ url: URL, to path: String, progress: ((Int64) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let handle = try open(path, mode: .writeOnly)
        var closed = false
        defer { if !closed { try? closeFile(handle, path: path) } }
        var sent: Int64 = 0
        while let chunk = try input.read(upToCount: Self.writeChunk), !chunk.isEmpty {
            try write(handle, chunk, path: path)
            sent += Int64(chunk.count)
            progress?(sent)
        }
        closed = true
        try closeFile(handle, path: path)
    }
}
