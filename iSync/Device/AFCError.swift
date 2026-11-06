import Foundation

/// Error returned by the phone's Apple File Conduit service.
struct AFCError: LocalizedError, Equatable {
    let code: UInt64
    let operation: String
    var detail: String?

    static let objectNotFound: UInt64 = 8
    static let objectExists: UInt64 = 16
    static let noSpaceLeft: UInt64 = 18

    var errorDescription: String? {
        if code == Self.noSpaceLeft {
            return "The iPhone is out of storage space."
        }
        return "The iPhone's file service refused \(operation): \(detail ?? "AFC error \(code)")."
    }
}
