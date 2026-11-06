import Foundation
@testable import iSync

/// An in-memory iPhone: an AFC file system plus the phone's side of the AirTraffic protocol.
final class FakePhone: PhoneFileSystem, ServiceTransport {
    // MARK: File system

    var files = [String: Data]()
    var directories: Set<String> = ["", "iTunes_Control", "iTunes_Control/Music", "iTunes_Control/Music/F00",
                                    "iTunes_Control/Music/F01", "iTunes_Control/iTunes", "iTunes_Control/Sync"]

    private func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    func fileInfo(_ path: String) throws -> [String: String]? {
        if directories.contains(path) { return ["st_ifmt": "S_IFDIR", "st_size": "0"] }
        if let data = files[path] { return ["st_ifmt": "S_IFREG", "st_size": String(data.count)] }
        return nil
    }

    func listDirectory(_ path: String) throws -> [String] {
        guard directories.contains(path) else { throw AFCError(code: 8, operation: "listing \(path)") }
        let prefix = path.isEmpty ? "" : path + "/"
        let children = (Array(files.keys) + Array(directories)).filter { $0.hasPrefix(prefix) && $0 != path }
            .map { String($0.dropFirst(prefix.count)) }.filter { !$0.contains("/") && !$0.isEmpty }
        return Array(Set(children)).sorted()
    }

    func makeDirectory(_ path: String) throws {
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            directories.insert(current)
        }
    }

    func removePath(_ path: String) throws {
        guard files.removeValue(forKey: path) != nil || directories.remove(path) != nil else {
            throw AFCError(code: 8, operation: "removing \(path)")
        }
    }

    func renamePath(_ from: String, to: String) throws {
        guard let data = files.removeValue(forKey: from) else { throw AFCError(code: 8, operation: "renaming \(from)") }
        guard directories.contains(parent(to)) else { throw AFCError(code: 8, operation: "renaming to \(to)") }
        files[to] = data
    }

    func readFile(_ path: String, limit: Int) throws -> Data {
        guard let data = files[path] else { throw AFCError(code: 8, operation: "reading \(path)") }
        return data
    }

    func download(_ path: String, to url: URL) throws {
        try readFile(path, limit: .max).write(to: url)
    }

    func writeFile(_ path: String, data: Data) throws {
        guard directories.contains(parent(path)) else { throw AFCError(code: 8, operation: "writing \(path)") }
        files[path] = data
    }

    func upload(_ url: URL, to path: String, progress: ((Int64) -> Void)?) throws {
        let data = try Data(contentsOf: url)
        try writeFile(path, data: data)
        progress?(Int64(data.count))
    }

    func close() {}

    // MARK: AirTraffic (phone side)

    let grappaReply: Data
    var mediaAnchor = 41
    var disabledAssetTypes = ["Photo", "Movie"]
    /// Extra manifest entries for songs the host didn't send (the phone does this in real sessions).
    var foreignRequests: [(assetID: String, parts: Int)] = [("123456789", 2), ("-987654321", 4)]

    private(set) var received = [ATCMessage]()
    private(set) var completions = [String: String]()   // AssetID → AssetPath
    private(set) var refusals = [String: Int]()          // AssetID → ErrorCode
    private(set) var stagedOperations: [String: Any]?
    private(set) var signatureValid = false
    /// End like the iOS 27.2 phone did in a live session: `IdleExit` instead of `SyncFinished`.
    var endsWithIdleExit = false
    private var outgoing = Data()
    private var expected = Set<String>()
    private var sentFinalPing = false

    init(grappaReply: Data) {
        self.grappaReply = grappaReply
    }

    private func reply(_ command: String, session: Int, params: [String: Any]? = nil) {
        var raw: [String: Any] = ["Command": command, "Session": session, "Type": 0, "Id": received.count]
        if let params { raw["Params"] = params }
        outgoing.append(try! ATCConnection.frame(ATCMessage(raw)))
    }

    func send(_ data: Data) throws {
        var buffer = data
        while buffer.count >= 4 {
            let length = Int(buffer.readLE(UInt32.self, at: 0))
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeFirst(4 + length)
            let message = ATCMessage(try PropertyListSerialization.propertyList(from: body, format: nil) as! [String: Any])
            received.append(message)
            try handle(message)
        }
    }

    func receive(count: Int, timeout: TimeInterval) throws -> Data {
        guard outgoing.count >= count else { throw ISyncError("FakePhone: nothing more to say (timeout)") }
        let chunk = outgoing.prefix(count)
        outgoing.removeFirst(count)
        return Data(chunk)
    }

    private func handle(_ message: ATCMessage) throws {
        switch message.command {
        case "Ping":
            reply("Pong", session: 2)
            reply("Capabilities", session: 2, params: ["GrappaSupportInfo": ["version": 1, "deviceType": 0, "protocolVersion": 1]])
            reply("InstalledAssets", session: 2, params: ["Application": ["_Deleted": []]])
            reply("AssetMetrics", session: 2, params: ["Media": ["Music": ["_Count": 1, "_PhysicalSize": 1]]])
            reply("SyncAllowed", session: 2, params: ["ManualSync": true, "AutoSync": true, "DisabledAssetTypes": disabledAssetTypes])
        case "RequestingSync":
            reply("ReadyForSync", session: 2, params: [
                "DataclassAnchors": ["Media": String(mediaAnchor), "Book": "0"],
                "DeviceInfo": ["Grappa": grappaReply],
            ])
        case "FinishedSyncingMetadata":
            let operations = try readFile(SyncSession.operationFile, limit: .max)
            let signature = try readFile(SyncSession.signatureFile, limit: .max)
            signatureValid = try GrappaSigner(reply: grappaReply).sign(operations) == signature
            stagedOperations = try PropertyListSerialization.propertyList(from: operations, format: nil) as? [String: Any]
            // The phone consumes the staged files.
            files.removeValue(forKey: SyncSession.operationFile)
            files.removeValue(forKey: SyncSession.signatureFile)
            var manifest = [[String: Any]]()
            for operation in stagedOperations?["operations"] as? [[String: Any]] ?? [] where operation["operation"] as? String == "insert_track" {
                let pid = (operation["pid"] as! NSNumber).int64Value
                let item = operation["item"] as! [String: Any]
                let parts = item["artwork_cache_id"] != nil ? 3 : 1
                manifest.append(["AssetType": "Music", "IsDownload": true, "AssetID": String(pid), "Variant": ["AssetParts": parts]])
                expected.insert(String(pid))
            }
            for request in foreignRequests {
                manifest.append(["AssetType": "Music", "IsDownload": true, "AssetID": request.assetID, "Variant": ["AssetParts": request.parts]])
                expected.insert(request.assetID)
            }
            reply("Progress", session: 2, params: ["OverallProgress": 0.1])
            reply("AssetManifest", session: 2, params: ["AssetManifest": ["Media": manifest]])
        case "FileComplete":
            let assetID = message.params["AssetID"] as! String
            completions[assetID] = message.params["AssetPath"] as? String
            // The phone moves the staged audio to its permanent location.
            if let path = message.params["AssetPath"] as? String, !path.isEmpty,
               let data = files.removeValue(forKey: "Airlock/Media/\(assetID)") {
                files[path] = data
            }
            finishIfDone()
        case "FileError":
            refusals[message.params["AssetID"] as! String] = (message.params["ErrorCode"] as? NSNumber)?.intValue
            finishIfDone()
        case "Pong":
            reply(endsWithIdleExit ? "IdleExit" : "SyncFinished", session: 2)
        default:
            break
        }
    }

    private func finishIfDone() {
        guard !sentFinalPing, Set(completions.keys).union(refusals.keys).isSuperset(of: expected) else { return }
        sentFinalPing = true
        // Real phones sometimes ping while importing; the host must answer before SyncFinished arrives.
        reply("Ping", session: 2)
    }
}
