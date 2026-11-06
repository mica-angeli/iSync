import Foundation

/// File access to the phone's media partition (`/var/mobile/Media`), as exposed by the AFC service.
protocol PhoneFileSystem: AnyObject {
    /// Attributes of the item at `path` (`st_size`, `st_ifmt` …), or nil when nothing exists there.
    func fileInfo(_ path: String) throws -> [String: String]?
    /// Directory entries, excluding `.` and `..`.
    func listDirectory(_ path: String) throws -> [String]
    /// Creates a directory (and missing parents); succeeds if it already exists.
    func makeDirectory(_ path: String) throws
    func removePath(_ path: String) throws
    func renamePath(_ from: String, to: String) throws
    /// Reads a whole file into memory, failing beyond `limit` bytes.
    func readFile(_ path: String, limit: Int) throws -> Data
    /// Copies a file from the phone to a local URL.
    func download(_ path: String, to url: URL) throws
    /// Creates or replaces a file.
    func writeFile(_ path: String, data: Data) throws
    /// Streams a local file to the phone, reporting the bytes sent so far.
    func upload(_ url: URL, to path: String, progress: ((Int64) -> Void)?) throws
    func close()
}

extension PhoneFileSystem {
    func exists(_ path: String) throws -> Bool { try fileInfo(path) != nil }

    func isDirectory(_ path: String) throws -> Bool { try fileInfo(path)?["st_ifmt"] == "S_IFDIR" }

    func fileSize(_ path: String) throws -> UInt64? {
        guard let size = try fileInfo(path)?["st_size"] else { return nil }
        return UInt64(size)
    }

    func readFile(_ path: String) throws -> Data { try readFile(path, limit: 64 << 20) }
}
