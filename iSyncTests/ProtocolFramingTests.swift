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
    func testAFCPacketLayout() throws {
        let packet = AFCClient.encode(operation: 0x0A, packetNumber: 7, header: Data("a\0".utf8), payload: Data([1, 2, 3]))
        XCTAssertEqual(packet.prefix(8), Data("CFA6LPAA".utf8))
        XCTAssertEqual(packet.readLE(UInt64.self, at: 8), 40 + 2 + 3)
        XCTAssertEqual(packet.readLE(UInt64.self, at: 16), 40 + 2)
        XCTAssertEqual(packet.readLE(UInt64.self, at: 24), 7)
        XCTAssertEqual(packet.readLE(UInt64.self, at: 32), 0x0A)
        let header = try AFCClient.decodeHeader(packet.prefix(40))
        XCTAssertEqual(header.entire, 45)
        XCTAssertEqual(header.this, 42)
    }

    func testAFCFileInfoAndNotFound() throws {
        let transport = ScriptedTransport()
        // Reply 1: DATA with attributes.
        let attributes = Data("st_size\u{0}123\u{0}st_ifmt\u{0}S_IFREG\u{0}".utf8)
        transport.incoming.append(AFCClient.encode(operation: 2, packetNumber: 1, header: Data(), payload: attributes))
        // Reply 2: STATUS 8 (object not found).
        var status = Data(); status.appendLE(UInt64(8))
        transport.incoming.append(AFCClient.encode(operation: 1, packetNumber: 2, header: status, payload: Data()))
        let afc = AFCClient(transport: transport)
        XCTAssertEqual(try afc.fileInfo("x")?["st_size"], "123")
        XCTAssertNil(try afc.fileInfo("y"))
        // The request carried the NUL-terminated path in its header area.
        XCTAssertEqual(transport.sent.readLE(UInt64.self, at: 32), 0x0A)
        XCTAssertEqual(transport.sent.subdata(in: 40..<42), Data("x\0".utf8))
    }

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
