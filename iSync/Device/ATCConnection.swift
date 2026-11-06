import Foundation

/// One message of the AirTraffic (`com.apple.atc`) sync protocol: a property-list dictionary with
/// `Command`, `Session` and optional `Params`.
struct ATCMessage {
    let raw: [String: Any]

    var command: String { raw["Command"] as? String ?? "" }
    var session: Int? { (raw["Session"] as? NSNumber)?.intValue }
    var params: [String: Any] { raw["Params"] as? [String: Any] ?? [:] }

    init(_ raw: [String: Any]) { self.raw = raw }

    init(command: String, session: Int, params: [String: Any]? = nil) {
        var raw: [String: Any] = ["Command": command, "Session": session]
        if let params { raw["Params"] = params }
        self.raw = raw
    }
}

/// Framing for the ATC service: a little-endian u32 length followed by a binary property list.
/// (Unlike most lockdown services, whose length prefix is big-endian.)
final class ATCConnection {
    static let maximumFrame = 16 << 20

    private let transport: ServiceTransport
    private var broken = false

    init(transport: ServiceTransport) {
        self.transport = transport
    }

    func close() {
        transport.close()
    }

    static func frame(_ message: ATCMessage) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: message.raw, format: .binary, options: 0)
        var data = Data(capacity: body.count + 4)
        data.appendLE(UInt32(body.count))
        data.append(body)
        return data
    }

    func send(_ message: ATCMessage) throws {
        guard !broken else { throw ISyncError("The sync connection is no longer usable.") }
        do {
            try transport.send(Self.frame(message))
            logDebug("ATC → \(message.command) (session \(message.session ?? -1))")
        } catch {
            broken = true
            throw error
        }
    }

    /// Reads the next message. Any error leaves the connection unusable, because a partial frame
    /// would desynchronise the stream.
    func receive(timeout: TimeInterval) throws -> ATCMessage {
        guard !broken else { throw ISyncError("The sync connection is no longer usable.") }
        do {
            let header = try transport.receive(count: 4, timeout: timeout)
            let length = Int(header.readLE(UInt32.self, at: 0))
            guard length > 0, length <= Self.maximumFrame else {
                throw ISyncError("The iPhone sent an invalid sync message (\(length) bytes).")
            }
            let body = try transport.receive(count: length, timeout: timeout)
            guard let dictionary = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] else {
                throw ISyncError("The iPhone sent a sync message that is not a dictionary.")
            }
            let message = ATCMessage(dictionary)
            logDebug("ATC ← \(message.command) (session \(message.session ?? -1))")
            return message
        } catch {
            broken = true
            throw error
        }
    }
}
