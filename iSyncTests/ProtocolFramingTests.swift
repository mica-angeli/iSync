import XCTest
@testable import iSync

/// A transport that replays scripted bytes and records what was sent.
final class ScriptedTransport: ServiceTransport {
    var incoming = Data()
    var sent = Data()
    func send(_ data: Data) throws { sent.append(data) }
    func receive(count: Int, timeout: TimeInterval) throws -> Data {
        guard incoming.count >= count else { throw ISyncError("eof") }
        let chunk = incoming.prefix(count)
        incoming.removeFirst(count)
        return Data(chunk)
    }
    func close() {}
}

final class ProtocolFramingTests: XCTestCase {
    func testATCFrameIsLittleEndianBinaryPlist() throws {
        let message = ATCMessage(command: "Ping", session: 1)
        let frame = try ATCConnection.frame(message)
        let length = Int(frame.readLE(UInt32.self, at: 0))
        XCTAssertEqual(length, frame.count - 4)
        XCTAssertEqual(frame.subdata(in: 4..<12), Data("bplist00".utf8))

        let transport = ScriptedTransport()
        transport.incoming = frame
        let connection = ATCConnection(transport: transport)
        let decoded = try connection.receive(timeout: 1)
        XCTAssertEqual(decoded.command, "Ping")
        XCTAssertEqual(decoded.session, 1)
    }
}
