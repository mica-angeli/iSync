import Foundation

/// Keeps a Wi-Fi connection to the phone alive.
///
/// Over Wi-Fi the phone closes `com.apple.atc` on the first message unless the host also holds a
/// `com.apple.mobile.heartbeat` connection and answers its periodic "Marco" with "Polo"
/// (rustunes docs, chapter 02 §16). Not needed over USB.
final class HeartbeatKeeper {
    private let transport: ServiceTransport
    private let stopLock = NSLock()
    private var stopped = false

    init(device: AppleDevice) throws {
        transport = try device.startService("com.apple.mobile.heartbeat")
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "iSync heartbeat"
        thread.start()
    }

    deinit { stop() }

    func stop() {
        stopLock.lock()
        let already = stopped
        stopped = true
        stopLock.unlock()
        if !already { transport.close() }
    }

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    /// Lockdown-style framing: big-endian u32 length + property list.
    private func receive() throws -> [String: Any] {
        let header = try transport.receive(count: 4, timeout: 120)
        let length = Int(header.readBE(UInt32.self, at: 0))
        guard length > 0, length < 1 << 20 else { throw ISyncError("Invalid heartbeat message.") }
        let body = try transport.receive(count: length, timeout: 30)
        return try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] ?? [:]
    }

    private func send(_ message: [String: Any]) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        try transport.send(frame)
    }

    private func loop() {
        while !isStopped {
            do {
                let message = try receive()
                if message["Command"] as? String == "Marco" {
                    try send(["Command": "Polo"])
                }
            } catch {
                if !isStopped { logWarning("Heartbeat ended: \(error.localizedDescription)") }
                return
            }
        }
    }
}
