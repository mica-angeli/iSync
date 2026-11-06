import Foundation

/// Runs one AirTraffic Media sync session that adds songs to the phone's library.
///
/// Message sequence (rustunes docs, chapter 02 §6 and §15):
/// `Ping` → (`SyncAllowed`) → `RequestingSync` → (`ReadyForSync`) → stage the signed operation file →
/// `FinishedSyncingMetadata` → (`AssetManifest`) → upload + `FileComplete` per song → (`SyncFinished`).
final class SyncSession {
    enum Event {
        case phase(String)
        case uploading(pid: Int64, sent: Int64, total: Int64)
        case delivered(pid: Int64)
        case phoneProgress(Double)
    }

    struct Outcome {
        /// Songs whose audio was handed to the phone.
        var delivered: Set<Int64> = []
        /// Songs that could not be delivered, with the reason.
        var failed: [Int64: String] = [:]
    }

    static let stagingDirectory = "iTunes_Control/Sync/Media"
    static let operationFile = stagingDirectory + "/Sync_00000000.plist"
    static let signatureFile = operationFile + ".cig"
    static let requestSession = 2

    private let fs: PhoneFileSystem
    private let atc: ATCConnection
    private let hostName: String
    private let libraryID: String
    private let onEvent: (Event) -> Void
    private let isCancelled: () -> Bool

    /// How long to wait for the phone between messages.
    var messageTimeout: TimeInterval = 300

    private var session = SyncSession.requestSession
    private var reservedPaths = Set<String>()
    private var musicFolders: [String] = []
    private var createdFolders = Set<String>()

    init(fs: PhoneFileSystem, atc: ATCConnection, hostName: String, libraryID: String,
         onEvent: @escaping (Event) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }) {
        self.fs = fs
        self.atc = atc
        self.hostName = hostName
        self.libraryID = libraryID
        self.onEvent = onEvent
        self.isCancelled = isCancelled
    }

    // MARK: Messages

    static func requestingSync(anchor: Int, hostName: String, libraryID: String) -> ATCMessage {
        // The compatibility profile Apple's own host sends (and the phone has accepted from rustunes).
        ATCMessage(command: "RequestingSync", session: requestSession, params: [
            "Dataclasses": ["Media", "Book", "Keybag"],
            "DataclassAnchors": ["Media": String(anchor), "VoiceMemo": "1"],
            "HostInfo": [
                "Grappa": GrappaSigner.hostRequest,
                "Version": "13.2.4.123",
                "LibraryID": libraryID,
                "SyncHostName": hostName,
                "SyncedDataclasses": ["Media"],
                "SyncedAssetTypes": ["Music"],
                "WindowsOSVersion": "10.0",
                "Type": "iTunes",
                "Wakeable": 0,
            ] as [String: Any],
        ])
    }

    static func finishedSyncingMetadata(session: Int, anchor: Int) -> ATCMessage {
        ATCMessage(command: "FinishedSyncingMetadata", session: session, params: [
            "DataclassAnchors": ["Media": String(anchor), "VoiceMemo": "1"],
            "SyncTypes": ["Media": 1, "Book": 0, "Keybag": 1],
        ])
    }

    static func fileComplete(session: Int, assetID: String, path: String) -> ATCMessage {
        ATCMessage(command: "FileComplete", session: session, params: [
            "AssetID": assetID, "Dataclass": "Media", "AssetPath": path,
        ])
    }

    static func fileError(session: Int, assetID: String, code: Int) -> ATCMessage {
        ATCMessage(command: "FileError", session: session, params: [
            "AssetID": assetID, "Dataclass": "Media", "ErrorCode": code, "ErrorIsVisible": false,
        ])
    }

    /// Human-readable `SyncFailed` reasons (phone-side codes, rustunes docs chapter 09 §6.3).
    static func describeSyncFailure(_ message: ATCMessage) -> String {
        let code = (message.params["ErrorCode"] as? NSNumber)?.intValue ?? -1
        switch code {
        case 2: return "The sync was cancelled."
        case 4: return "The iPhone did not accept this Mac's sync signature (error 4)."
        case 9: return "The iPhone is busy syncing with another computer or app (error 9). Wait for it to finish, or quit Finder's sync, and try again."
        case 12: return "The iPhone requires a newer sync protocol version (error 12)."
        case 14: return "The iPhone is out of storage space (error 14)."
        case 23: return "The iPhone rejected the sync request as invalid (error 23)."
        default: return "The iPhone refused the sync (error \(code))."
        }
    }

    // MARK: Session

    /// Reads messages until one named in `commands` arrives, answering pings on the way.
    private func waitFor(_ commands: Set<String>, timeout: TimeInterval) throws -> ATCMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isCancelled() { throw ISyncError("Cancelled.") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ISyncError("The iPhone did not answer (waiting for \(commands.sorted().joined(separator: "/"))).")
            }
            let message = try atc.receive(timeout: remaining)
            if commands.contains(message.command) { return message }
            switch message.command {
            case "SyncFailed":
                throw ISyncError(Self.describeSyncFailure(message))
            case "ConnectionInvalid":
                throw ISyncError("The iPhone ended the sync connection.")
            case "Ping":
                try atc.send(ATCMessage(command: "Pong", session: message.session ?? session))
            default:
                continue
            }
        }
    }

    func run(snapshot: PhoneLibrarySnapshot, inserts: [PlannedInsert]) throws -> Outcome {
        precondition(!inserts.isEmpty)
        musicFolders = snapshot.musicFolders

        // 1. Handshake.
        onEvent(.phase("Connecting to the iPhone's sync service…"))
        try atc.send(ATCMessage(command: "Ping", session: 1))
        let allowed = try waitFor(["SyncAllowed"], timeout: 60)
        if let disabled = allowed.params["DisabledAssetTypes"] as? [String], disabled.contains("Music") {
            throw ISyncError("The iPhone isn't accepting music from a computer. If “Sync Library” is turned on in Settings › Apps › Music, the iPhone only takes music from iCloud; turn it off to add music from this Mac.")
        }
        try atc.send(Self.requestingSync(anchor: snapshot.mediaAnchor, hostName: hostName, libraryID: libraryID))
        let ready = try waitFor(["ReadyForSync"], timeout: 120)
        session = ready.session ?? Self.requestSession
        let anchors = ready.params["DataclassAnchors"] as? [String: Any]
        let readyAnchor = (anchors?["Media"] as? String).flatMap { Int($0) }
            ?? (anchors?["Media"] as? NSNumber)?.intValue
            ?? snapshot.mediaAnchor
        if readyAnchor != snapshot.mediaAnchor {
            logWarning("Media anchor changed from \(snapshot.mediaAnchor) to \(readyAnchor); using the phone's value")
        }
        guard let grappa = (ready.params["DeviceInfo"] as? [String: Any])?["Grappa"] as? Data else {
            throw ISyncError("The iPhone did not complete the sync handshake (no Grappa reply).")
        }
        let signer = try GrappaSigner(reply: grappa)

        // 2. Stage the signed operation file.
        onEvent(.phase("Sending song information…"))
        try fs.makeDirectory(Self.stagingDirectory)
        let leftovers = try fs.listDirectory(Self.stagingDirectory)
        guard leftovers.isEmpty else {
            throw ISyncError("The iPhone has an unfinished sync from another app (\(leftovers.joined(separator: ", "))). Sync it with Finder once, then try again.")
        }
        let revision = readyAnchor + 1
        let operations = try OperationFile.build(revision: revision, databasePID: snapshot.databasePID,
                                                 primaryContainerPID: snapshot.primaryContainerPID, inserts: inserts)
        let signature = signer.sign(operations)
        try fs.writeFile(Self.operationFile, data: operations)
        try fs.writeFile(Self.signatureFile, data: signature)
        guard try fs.readFile(Self.operationFile) == operations, try fs.readFile(Self.signatureFile) == signature else {
            throw ISyncError("The song information could not be written to the iPhone intact.")
        }
        for directory in ["Airlock", "Airlock/Media", "Airlock/Media/Artwork"] {
            try fs.makeDirectory(directory)
        }
        try atc.send(Self.finishedSyncingMetadata(session: session, anchor: revision))
        logInfo("Staged \(inserts.count) song(s) at revision \(revision); waiting for the asset manifest")

        // 3. Deliver what the phone asks for.
        var outcome = Outcome()
        var answered = Set<String>()
        let byAssetID = Dictionary(uniqueKeysWithValues: inserts.map { ($0.assetID, $0) })
        receiving: while true {
            if isCancelled() { throw ISyncError("Cancelled.") }
            let message = try atc.receive(timeout: messageTimeout)
            switch message.command {
            case "Progress":
                if let value = (message.params["OverallProgress"] as? NSNumber)?.doubleValue {
                    onEvent(.phoneProgress(value))
                }
            case "Ping":
                try atc.send(ATCMessage(command: "Pong", session: message.session ?? session))
            case "AssetManifest":
                try handleManifest(message, inserts: byAssetID, answered: &answered, outcome: &outcome)
                onEvent(.phase("Waiting for the iPhone to finish importing…"))
            case "SyncFinished":
                break receiving
            case "SyncFailed":
                throw ISyncError(Self.describeSyncFailure(message))
            case "ConnectionInvalid":
                throw ISyncError("The iPhone ended the sync connection.")
            default:
                continue
            }
        }
        for insert in inserts where !outcome.delivered.contains(insert.pid) && outcome.failed[insert.pid] == nil {
            outcome.failed[insert.pid] = "The iPhone did not ask for this song."
        }
        logInfo("Sync finished: \(outcome.delivered.count) delivered, \(outcome.failed.count) failed")
        return outcome
    }

    // MARK: Assets

    private func handleManifest(_ message: ATCMessage, inserts: [String: PlannedInsert],
                                answered: inout Set<String>, outcome: inout Outcome) throws {
        let manifest = message.params["AssetManifest"] as? [String: Any] ?? [:]
        let entries = manifest["Media"] as? [[String: Any]] ?? []
        logInfo("Asset manifest with \(entries.count) request(s)")
        var foreign = [String]()
        for entry in entries {
            guard (entry["IsDownload"] as? Bool) ?? true else { continue }
            let raw = entry["AssetID"] as? String ?? (entry["AssetID"] as? NSNumber)?.stringValue ?? ""
            let assetID = raw.split(separator: ":").last.map(String.init) ?? raw
            guard !assetID.isEmpty, !answered.contains(assetID) else { continue }
            let parts = ((entry["Variant"] as? [String: Any])?["AssetParts"] as? NSNumber)?.intValue ?? 1
            if let insert = inserts[assetID] {
                answered.insert(assetID)
                try deliver(insert, parts: parts, outcome: &outcome)
            } else {
                foreign.append(assetID)
            }
        }
        // Requests for other songs' artwork or Genius data: decline them as Apple's host does.
        for assetID in foreign where !answered.contains(assetID) {
            answered.insert(assetID)
            try atc.send(Self.fileError(session: session, assetID: assetID, code: 16))
        }
    }

    private func deliver(_ insert: PlannedInsert, parts: Int, outcome: inout Outcome) throws {
        let assetID = insert.assetID
        let track = insert.track
        if parts & 2 != 0, insert.artworkCacheID != nil, let cover = track.phoneCover {
            let path = "Airlock/Media/Artwork/\(assetID)"
            try fs.writeFile(path, data: cover)
            guard try fs.fileSize(path) == UInt64(cover.count) else {
                throw ISyncError("Artwork for “\(insert.fallbackTitle)” did not arrive intact.")
            }
        }
        guard parts & 1 != 0 else {
            // Only artwork (or Genius/lyrics data, which iSync doesn't provide) was requested.
            if parts & 2 != 0 {
                try atc.send(Self.fileComplete(session: session, assetID: assetID, path: ""))
            } else {
                try atc.send(Self.fileError(session: session, assetID: assetID, code: 16))
            }
            return
        }

        guard FileManager.default.isReadableFile(atPath: track.uploadURL.path) else {
            outcome.failed[insert.pid] = "The converted file is missing."
            try atc.send(Self.fileError(session: session, assetID: assetID, code: 3))
            return
        }
        let staging = "Airlock/Media/\(assetID).\(track.fileExtension)"
        let staged = "Airlock/Media/\(assetID)"
        onEvent(.phase("Copying songs to the iPhone…"))
        try fs.upload(track.uploadURL, to: staging) { [onEvent] sent in
            onEvent(.uploading(pid: insert.pid, sent: sent, total: track.fileSize))
        }
        guard try fs.fileSize(staging) == UInt64(track.fileSize) else {
            throw ISyncError("“\(insert.fallbackTitle)” did not arrive on the iPhone intact.")
        }
        try fs.renamePath(staging, to: staged)
        let permanent = try permanentPath(extension: track.fileExtension)
        try atc.send(Self.fileComplete(session: session, assetID: assetID, path: permanent))
        outcome.delivered.insert(insert.pid)
        onEvent(.delivered(pid: insert.pid))
        logInfo("Delivered \(assetID) as \(permanent)")
    }

    /// A free `iTunes_Control/Music/Fnn/XXXX.ext` path, the naming scheme Apple's host uses.
    private func permanentPath(extension ext: String) throws -> String {
        if musicFolders.isEmpty {
            musicFolders = (try? fs.listDirectory("iTunes_Control/Music"))?.filter {
                $0.count == 3 && $0.hasPrefix("F") && $0.dropFirst().allSatisfy(\.isNumber)
            } ?? []
            if musicFolders.isEmpty { musicFolders = (0..<50).map { String(format: "F%02d", $0) } }
        }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for _ in 0..<200 {
            let folder = musicFolders.randomElement()!
            let name = String((0..<4).map { _ in letters.randomElement()! })
            let path = "iTunes_Control/Music/\(folder)/\(name).\(ext)"
            guard !reservedPaths.contains(path), try fs.fileInfo(path) == nil else { continue }
            if !createdFolders.contains(folder) {
                try fs.makeDirectory("iTunes_Control/Music/\(folder)")
                createdFolders.insert(folder)
            }
            reservedPaths.insert(path)
            return path
        }
        throw ISyncError("Could not find a free file name on the iPhone.")
    }
}
