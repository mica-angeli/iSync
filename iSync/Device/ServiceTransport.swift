import Foundation

/// A bidirectional byte stream to a lockdown service on the phone.
///
/// The production implementation wraps an `AMDServiceConnectionRef`; tests substitute an in-memory
/// simulation of the phone.
protocol ServiceTransport: AnyObject {
    func send(_ data: Data) throws
    /// Reads exactly `count` bytes, failing if the stream closes or `timeout` elapses first.
    func receive(count: Int, timeout: TimeInterval) throws -> Data
    func close()
}

/// A service connection opened with `AMDeviceSecureStartService`. MobileDevice transparently handles
/// TLS when the service requires it.
final class MobileDeviceConnection: ServiceTransport, @unchecked Sendable {
    private let connection: OpaquePointer
    private let md: MobileDeviceLibrary
    private let name: String
    private let stateLock = NSLock()
    private var invalidated = false
    private var timedOut = false

    init(connection: OpaquePointer, library: MobileDeviceLibrary, name: String) {
        self.connection = connection
        self.md = library
        self.name = name
        // A send on a socket the phone has closed must not raise SIGPIPE and kill the app.
        let socket = library.connectionGetSocket(connection)
        if socket >= 0 {
            var on: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    deinit {
        close()
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(connection)).release()
    }

    private var isInvalidated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidated
    }

    func send(_ data: Data) throws {
        guard !isInvalidated else { throw ISyncError("The connection to \(name) is closed.") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = md.connectionSend(connection, base + offset, raw.count - offset)
                if sent <= 0 {
                    throw ISyncError("Lost the connection to the iPhone while sending (\(name)).")
                }
                offset += sent
            }
        }
    }

    func receive(count: Int, timeout: TimeInterval) throws -> Data {
        guard !isInvalidated else { throw ISyncError("The connection to \(name) is closed.") }
        guard count > 0 else { return Data() }
        // A watchdog closes the connection if the phone stays silent too long; this reliably
        // unblocks the read whether or not the connection is TLS-wrapped.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.timedOut = true
            self.stateLock.unlock()
            self.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        var buffer = Data(count: count)
        var offset = 0
        var failure: Error?
        buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let received = md.connectionReceive(connection, base + offset, count - offset)
                if received <= 0 {
                    stateLock.lock()
                    let expired = timedOut
                    stateLock.unlock()
                    failure = ISyncError(expired
                        ? "The iPhone stopped responding (\(name) timed out after \(Int(timeout)) s)."
                        : "The iPhone closed the connection (\(name)).")
                    return
                }
                offset += received
            }
        }
        if let failure { throw failure }
        return buffer
    }

    func close() {
        stateLock.lock()
        let already = invalidated
        invalidated = true
        stateLock.unlock()
        if !already {
            md.connectionInvalidate(connection)
        }
    }
}
