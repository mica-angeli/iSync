import Foundation
import CommonCrypto

/// Signs ATC operation files (`Sync_00000000.plist.cig`).
///
/// The phone hands the host an 83-byte Grappa blob in `ReadyForSync.DeviceInfo.Grappa` in reply to the
/// fixed 84-byte host request sent in `RequestingSync.HostInfo.Grappa`. The signature is derived from
/// that reply with standard AES and HMAC-SHA1. This is the public calculation documented by the
/// rustunes project (docs/02-atc-sync-protocol.md, section 11.4); it is not Apple's own signer, but the
/// phone accepts it for the fixed request below.
struct GrappaSigner {
    /// The fixed host request. Only replies to exactly this request can be signed.
    static let hostRequest = Data([
        0x01, 0x01, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x04, 0x40, 0xbc, 0x27, 0x85, 0xe0, 0xdb, 0xf1, 0x66, 0x36, 0x1e, 0x07, 0x98, 0x0a,
        0x5e, 0xa4, 0x8d, 0xba, 0x95, 0xb3, 0xb8, 0xea, 0x26, 0x5d, 0x62, 0xae, 0xfe, 0xa5, 0x1b, 0xb7,
        0xb1, 0x90, 0xe0, 0xb7, 0x71, 0x26, 0x29, 0x0a, 0xd3, 0x9b, 0xb1, 0x3f, 0xec, 0xc0, 0x8c, 0x25,
        0xa9, 0x56, 0x1c, 0x51, 0x7a, 0xc1, 0x1e, 0x64, 0x90, 0x5d, 0xa0, 0x29, 0xe6, 0x1b, 0xdf, 0xd0,
        0xba, 0x22, 0xc3, 0x13,
    ])

    private static let wrapKey: [UInt8] = [
        0x77, 0x76, 0xeb, 0x98, 0xab, 0x6c, 0xe6, 0x02, 0xe8, 0xe8, 0x92, 0xe4, 0x1b, 0xa7, 0xe9, 0x15,
    ]
    private static let keyXor: [UInt8] = [
        0xc6, 0xc7, 0xc4, 0xc5, 0xca, 0xcb, 0xc8, 0xc9, 0xce, 0xcf, 0xcc, 0xcd, 0xb2, 0xb3, 0xb0, 0xb1,
    ]
    private static let tagXor: [UInt8] = [
        0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xe8,
        0xe9, 0xea, 0xeb, 0xec,
    ]

    let key: [UInt8]
    private let tagMask: [UInt8]

    /// Decrypts the 64-byte body of a Ready blob.
    static func decode(reply: Data) throws -> [UInt8] {
        let bytes = [UInt8](reply)
        guard bytes.count == 83 else {
            throw ISyncError("The iPhone sent an unsupported sync handshake (\(bytes.count) bytes).")
        }
        guard bytes[0] == 1, bytes[1] == 1, bytes[18] == 0x40 else {
            throw ISyncError("The iPhone sent an unsupported sync handshake envelope.")
        }
        let iv = Array(bytes[2..<18])
        let ciphertext = Array(bytes[19..<83])
        let key = [UInt8](repeating: 0x95, count: 16)
        return try aes(operation: CCOperation(kCCDecrypt), options: 0, key: key, iv: iv, input: ciphertext)
    }

    init(reply: Data) throws {
        let decoded = try Self.decode(reply: reply)
        var preKey = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            preKey[i] = decoded[1 + i] ^ decoded[39 + i] ^ Self.keyXor[i]
        }
        key = try Self.aes(operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionECBMode), key: Self.wrapKey, iv: nil, input: preKey)
        var mask = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            mask[i] = decoded[18 + i] ^ Self.tagXor[i]
        }
        tagMask = mask
    }

    /// Signs the exact serialised bytes of an operation file, producing the 21-byte `.cig` sidecar.
    func sign(_ operation: Data) -> Data {
        var tag = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        operation.withUnsafeBytes { raw in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, raw.baseAddress, raw.count, &tag)
        }
        var sidecar = Data([1])
        for i in 0..<20 {
            sidecar.append(tag[i] ^ tagMask[i])
        }
        return sidecar
    }

    private static func aes(operation: CCOperation, options: CCOptions, key: [UInt8], iv: [UInt8]?, input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, iv, input, input.count,
                             &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else {
            throw ISyncError("Could not compute the sync signature (CommonCrypto status \(status)).")
        }
        return output
    }
}
