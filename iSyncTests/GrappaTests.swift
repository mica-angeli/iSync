import XCTest
@testable import iSync

final class GrappaTests: XCTestCase {
    private func vectors() throws -> [[String: Data]] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "grappa-fixed-vectors", withExtension: "plist"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]])
    }

    func testIndependentlyVerifiedVectorsMatchEveryStage() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.count, 4)
        for vector in vectors {
            XCTAssertEqual(vector["request"], GrappaSigner.hostRequest)
            let reply = try XCTUnwrap(vector["reply"])
            XCTAssertEqual(Data(try GrappaSigner.decode(reply: reply)), vector["decoded"])
            let signer = try GrappaSigner(reply: reply)
            XCTAssertEqual(Data(signer.key), vector["key"])
            XCTAssertEqual(signer.sign(try XCTUnwrap(vector["operation"])), vector["sidecar"])
        }
    }

    func testRejectsMalformedReplies() throws {
        let reply = try XCTUnwrap(vectors()[0]["reply"])
        for length in [0, 1, 18, 82, 84, 4096] {
            var malformed = reply
            if length < reply.count { malformed = reply.prefix(length) } else { malformed.append(Data(count: length - reply.count)) }
            XCTAssertThrowsError(try GrappaSigner(reply: malformed), "length \(length)")
        }
        for index in [0, 1, 18] {
            var malformed = reply
            malformed[index] ^= 1
            XCTAssertThrowsError(try GrappaSigner(reply: malformed), "byte \(index)")
        }
    }

    func testSignatureCoversExactBytes() throws {
        let signer = try GrappaSigner(reply: XCTUnwrap(vectors()[0]["reply"]))
        let a = signer.sign(Data("<plist/>\n".utf8))
        XCTAssertEqual(a.count, 21)
        XCTAssertEqual(a.first, 1)
        XCTAssertNotEqual(a, signer.sign(Data("<plist/>".utf8)))
    }
}
