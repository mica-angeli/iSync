import Foundation

/// The phone's file service through Apple's own AFC client in MobileDevice.framework
/// (`AFCConnectionCreate`, `AFCFileRefOpen`, `AFCDirectoryRead`, …) — the same code Finder uses.
final class MobileDeviceAFC: PhoneFileSystem {
    /// Late-bound AFC entry points.
    private struct API {
        typealias ConnectionCreate = @convention(c) (CFAllocator?, Int32, UInt8, UnsafeMutableRawPointer?, UInt32) -> OpaquePointer?
        typealias ConnectionSetSecureContext = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?) -> Int32
        typealias ConnectionInvalidate = @convention(c) (OpaquePointer) -> Int32
        typealias FileRefOpen = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<OpaquePointer?>) -> Int32
        typealias FileRefRead = @convention(c) (OpaquePointer, OpaquePointer, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> Int32
        typealias FileRefWrite = @convention(c) (OpaquePointer, OpaquePointer, UnsafeRawPointer, Int) -> Int32
        typealias FileRefClose = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
        typealias DirectoryOpen = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>) -> Int32
        typealias DirectoryRead = @convention(c) (OpaquePointer, OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        typealias DirectoryClose = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
        typealias PathOperation = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Int32
        typealias RenamePath = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        typealias FileInfoOpen = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>) -> Int32
        typealias KeyValueRead = @convention(c) (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        typealias KeyValueClose = @convention(c) (OpaquePointer) -> Int32
        typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
        typealias GetSecureIOContext = @convention(c) (OpaquePointer) -> UnsafeMutableRawPointer?

        let connectionCreate: ConnectionCreate
        let connectionSetSecureContext: ConnectionSetSecureContext
        let connectionInvalidate: ConnectionInvalidate
        let fileRefOpen: FileRefOpen
        let fileRefRead: FileRefRead
        let fileRefWrite: FileRefWrite
        let fileRefClose: FileRefClose
        let directoryOpen: DirectoryOpen
        let directoryRead: DirectoryRead
        let directoryClose: DirectoryClose
        let directoryCreate: PathOperation
        let removePath: PathOperation
        let renamePath: RenamePath
        let fileInfoOpen: FileInfoOpen
        let keyValueRead: KeyValueRead
        let keyValueClose: KeyValueClose
        let errorString: ErrorString?
        let getSecureIOContext: GetSecureIOContext?

        static let shared: Result<API, Error> = Result {
            guard let handle = MobileDeviceLibrary.searchPaths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else {
                throw ISyncError("Apple's MobileDevice framework could not be loaded.")
            }
            func symbol<T>(_ name: String) throws -> T {
                guard let pointer = dlsym(handle, name) else {
                    throw ISyncError("MobileDevice.framework does not export \(name).")
                }
                return unsafeBitCast(pointer, to: T.self)
            }
            return API(
                connectionCreate: try symbol("AFCConnectionCreate"),
                connectionSetSecureContext: try symbol("AFCConnectionSetSecureContext"),
                connectionInvalidate: try symbol("AFCConnectionInvalidate"),
                fileRefOpen: try symbol("AFCFileRefOpen"),
                fileRefRead: try symbol("AFCFileRefRead"),
                fileRefWrite: try symbol("AFCFileRefWrite"),
                fileRefClose: try symbol("AFCFileRefClose"),
                directoryOpen: try symbol("AFCDirectoryOpen"),
                directoryRead: try symbol("AFCDirectoryRead"),
                directoryClose: try symbol("AFCDirectoryClose"),
                directoryCreate: try symbol("AFCDirectoryCreate"),
                removePath: try symbol("AFCRemovePath"),
                renamePath: try symbol("AFCRenamePath"),
                fileInfoOpen: try symbol("AFCFileInfoOpen"),
                keyValueRead: try symbol("AFCKeyValueRead"),
                keyValueClose: try symbol("AFCKeyValueClose"),
                errorString: try? symbol("AFCErrorString"),
                getSecureIOContext: try? symbol("AMDServiceConnectionGetSecureIOContext")
            )
        }
    }

    /// AFC file open modes.
    private enum Mode: UInt64 {
        case readOnly = 1
        case writeOnlyCreateTruncate = 3
    }

    static let objectNotFound: Int32 = 8
    static let objectExists: Int32 = 16
    static let chunkSize = 1 << 20

    private let api: API
    private let service: MobileDeviceConnection
    private let connection: OpaquePointer
    private var closed = false

    /// Opens AFC over an already started `com.apple.afc` service connection.
    init(service: MobileDeviceConnection, timeout: UInt32 = 60) throws {
        api = try API.shared.get()
        self.service = service
        // The service connection keeps ownership of the socket (closeOnInvalidate = false).
        guard let connection = api.connectionCreate(nil, service.socket, 0, nil, timeout) else {
            throw ISyncError("Could not open the iPhone's file service.")
        }
        self.connection = connection
        if let context = service.secureIOContext(api.getSecureIOContext) {
            _ = api.connectionSetSecureContext(connection, context)
        }
    }

    deinit {
        close()
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(connection)).release()
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = api.connectionInvalidate(connection)
        service.close()
    }

    private func describe(_ code: Int32) -> String {
        if let text = api.errorString?(code) { return "\(String(cString: text)) (\(code))" }
        return "AFC error \(code)"
    }

    private func check(_ code: Int32, _ action: @autoclosure () -> String) throws {
        guard code == 0 else {
            throw AFCError(code: UInt64(UInt32(bitPattern: code)), operation: action(), detail: describe(code))
        }
    }

    // MARK: PhoneFileSystem

    func fileInfo(_ path: String) throws -> [String: String]? {
        var info: OpaquePointer?
        let code = path.withCString { api.fileInfoOpen(connection, $0, &info) }
        if code == Self.objectNotFound { return nil }
        try check(code, "reading information about \(path)")
        guard let info else { return nil }
        defer { _ = api.keyValueClose(info) }
        var result = [String: String]()
        while true {
            var key: UnsafeMutablePointer<CChar>?
            var value: UnsafeMutablePointer<CChar>?
            guard api.keyValueRead(info, &key, &value) == 0, let key, let value else { break }
            result[String(cString: key)] = String(cString: value)
        }
        return result
    }

    func listDirectory(_ path: String) throws -> [String] {
        var directory: OpaquePointer?
        try check(path.withCString { api.directoryOpen(connection, $0, &directory) }, "listing \(path)")
        guard let directory else { return [] }
        defer { _ = api.directoryClose(connection, directory) }
        var names = [String]()
        while true {
            var name: UnsafeMutablePointer<CChar>?
            guard api.directoryRead(connection, directory, &name) == 0, let name else { break }
            let entry = String(cString: name)
            if entry != "." && entry != ".." && !entry.isEmpty { names.append(entry) }
        }
        return names
    }

    func makeDirectory(_ path: String) throws {
        let code = path.withCString { api.directoryCreate(connection, $0) }
        if code == 0 || code == Self.objectExists { return }
        // Whatever the code, an existing directory is what the caller wanted.
        if (try? isDirectory(path)) == true { return }
        try check(code, "creating \(path)")
    }

    func removePath(_ path: String) throws {
        try check(path.withCString { api.removePath(connection, $0) }, "removing \(path)")
    }

    func renamePath(_ from: String, to: String) throws {
        let code = from.withCString { fromC in to.withCString { toC in api.renamePath(connection, fromC, toC) } }
        try check(code, "renaming \(from)")
    }

    private func open(_ path: String, _ mode: Mode) throws -> OpaquePointer {
        var ref: OpaquePointer?
        try check(path.withCString { api.fileRefOpen(connection, $0, mode.rawValue, &ref) }, "opening \(path)")
        guard let ref else { throw ISyncError("The iPhone's file service did not open \(path).") }
        return ref
    }

    /// Reads up to `chunkSize` bytes; an empty result means end of file.
    private func readChunk(_ ref: OpaquePointer, path: String) throws -> Data {
        var buffer = Data(count: Self.chunkSize)
        var length = Self.chunkSize
        let code = buffer.withUnsafeMutableBytes { api.fileRefRead(connection, ref, $0.baseAddress!, &length) }
        try check(code, "reading \(path)")
        return buffer.prefix(length)
    }

    private func writeChunk(_ ref: OpaquePointer, _ data: Data, path: String) throws {
        let code = data.withUnsafeBytes { api.fileRefWrite(connection, ref, $0.baseAddress!, data.count) }
        try check(code, "writing \(path)")
    }

    func readFile(_ path: String, limit: Int) throws -> Data {
        let ref = try open(path, .readOnly)
        defer { _ = api.fileRefClose(connection, ref) }
        var result = Data()
        while true {
            let chunk = try readChunk(ref, path: path)
            if chunk.isEmpty { break }
            result.append(chunk)
            if result.count > limit { throw ISyncError("\(path) on the iPhone is unexpectedly large.") }
        }
        return result
    }

    func download(_ path: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let ref = try open(path, .readOnly)
        defer { _ = api.fileRefClose(connection, ref) }
        while true {
            let chunk = try readChunk(ref, path: path)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
    }

    func writeFile(_ path: String, data: Data) throws {
        let ref = try open(path, .writeOnlyCreateTruncate)
        var offset = 0
        do {
            while offset < data.count {
                let end = min(offset + Self.chunkSize, data.count)
                try writeChunk(ref, data.subdata(in: offset..<end), path: path)
                offset = end
            }
        } catch {
            _ = api.fileRefClose(connection, ref)
            throw error
        }
        try check(api.fileRefClose(connection, ref), "closing \(path)")
    }

    func upload(_ url: URL, to path: String, progress: ((Int64) -> Void)?) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let ref = try open(path, .writeOnlyCreateTruncate)
        var sent: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                try writeChunk(ref, chunk, path: path)
                sent += Int64(chunk.count)
                progress?(sent)
            }
        } catch {
            _ = api.fileRefClose(connection, ref)
            throw error
        }
        try check(api.fileRefClose(connection, ref), "closing \(path)")
    }
}
