import Foundation
import Observation
import SystemConfiguration

/// One dropped file and its progress through the pipeline.
@MainActor
@Observable
final class TrackItem: Identifiable {
    enum Status: Equatable {
        case queued
        case analyzing
        case waitingForDevice
        case checking
        case alreadyOnPhone
        case converting
        case readyToSync
        case syncing
        case synced
        case skipped(String)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .alreadyOnPhone, .synced, .skipped, .failed: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    var status: Status = .queued
    var title: String
    var subtitle = ""
    var formatDescription = ""
    var uploadProgress: Double?

    @ObservationIgnored var probe: ProbeResult?
    @ObservationIgnored var plan: ConversionPlan?
    @ObservationIgnored var prepared: PreparedTrack?
    @ObservationIgnored var pid: Int64?

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }

    var durationMs: Int? { probe?.bestDuration.map { Int($0 * 1000) } }

    func discardConvertedFile() {
        if let prepared, prepared.isTemporary {
            try? FileManager.default.removeItem(at: prepared.uploadURL)
        }
        prepared = nil
    }
}

/// Orchestrates everything: watching for iPhones, analysing dropped files, skipping songs the phone
/// already has, converting the rest and syncing them.
@MainActor
@Observable
final class SyncEngine {
    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let level: AppLog.Level
        let message: String
    }

    var items: [TrackItem] = []
    var devices: [AppleDevice] = []
    var deviceInfo: [String: DeviceInfo] = [:]
    var deviceProblem: String?
    var banner: String?
    var activity: String?
    var phoneProgress: Double?
    var isRunning = false
    var logLines: [LogLine] = []

    static let batchSize = 50
    nonisolated static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "m4b", "mp4", "aac", "alac", "wav", "wave", "w64", "rf64", "aif", "aiff", "aifc",
        "ogg", "oga", "opus", "spx", "wma", "ape", "wv", "tta", "tak", "dsf", "dff", "mka", "webm", "caf",
        "mpc", "mp2", "mp1", "ac3", "3gp",
    ]

    @ObservationIgnored private var tools: FFTools?
    @ObservationIgnored private let cancelFlag = CancelFlag()
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored let workDirectory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        workDirectory = caches.appendingPathComponent("app.isync.iSync/Converted", isDirectory: true)
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    // MARK: Devices

    /// The iPhone to sync with: a USB connection is preferred over Wi-Fi.
    var activeDevice: AppleDevice? {
        devices.first { $0.interface == .usb } ?? devices.first { $0.interface == .network }
    }

    var activeDeviceInfo: DeviceInfo? { activeDevice.flatMap { deviceInfo[$0.udid] } }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        AppLog.shared.setSink { [weak self] level, message in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logLines.append(LogLine(level: level, message: message))
                if self.logLines.count > 2000 { self.logLines.removeFirst(self.logLines.count - 2000) }
            }
        }
        logInfo("iSync \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") starting")
        let watcher = DeviceWatcher.shared
        watcher.onAttach = { [weak self] device in
            MainActor.assumeIsolated { self?.attached(device) }
        }
        watcher.onDetach = { [weak self] device in
            MainActor.assumeIsolated { self?.detached(device) }
        }
        do {
            try watcher.start()
        } catch {
            banner = error.localizedDescription
        }
    }

    private func attached(_ device: AppleDevice) {
        guard device.interface == .usb || device.interface == .network else { return }
        devices.removeAll { $0.udid == device.udid && $0.interface == device.interface }
        devices.append(device)
        identify(device)
    }

    /// Reads the phone's name and iOS version. A phone that is asleep (Wi-Fi) or waiting for the user
    /// to tap “Trust” fails at first, so keep trying for a while.
    private func identify(_ device: AppleDevice) {
        Task {
            for attempt in 1...30 {
                guard devices.contains(where: { $0 === device }) else { return }
                do {
                    let info = try await offMain { try device.readInfo() }
                    deviceInfo[device.udid] = info
                    deviceProblem = nil
                    logInfo("Connected to \(info.name) (\(info.productType), iOS \(info.productVersion)) over \(device.interface == .usb ? "USB" : "Wi-Fi")")
                    kick()
                    return
                } catch {
                    if attempt == 1 || attempt % 10 == 0 {
                        logWarning("Could not connect to the iPhone (attempt \(attempt)): \(error.localizedDescription)")
                    }
                    if device === activeDevice { deviceProblem = error.localizedDescription }
                    try? await Task.sleep(nanoseconds: UInt64(min(attempt, 5)) * 1_000_000_000)
                }
            }
        }
    }

    /// Tries again to talk to a connected phone that failed to identify.
    func reconnect() {
        guard let device = activeDevice else { return }
        deviceProblem = nil
        identify(device)
    }

    private func detached(_ device: AppleDevice) {
        devices.removeAll { $0 === device }
        if !devices.contains(where: { $0.udid == device.udid }) {
            deviceInfo[device.udid] = nil
            deviceProblem = nil
        }
    }

    // MARK: Adding files

    func add(urls: [URL]) {
        Task {
            let files = await offMainQuietly { Self.expand(urls) } ?? []
            let known = Set(items.map { $0.url.standardizedFileURL.path })
            let fresh = files.filter { !known.contains($0.standardizedFileURL.path) }
            guard !fresh.isEmpty else {
                if files.isEmpty { banner = "No music files found in what you dropped." }
                return
            }
            banner = nil
            items.append(contentsOf: fresh.map(TrackItem.init(url:)))
            logInfo("Queued \(fresh.count) file(s)")
            kick()
        }
    }

    private func offMainQuietly<T>(_ work: @escaping () -> T) async -> T? {
        try? await offMain { work() }
    }

    /// Expands folders recursively into audio files, sorted by path.
    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        var result = [URL]()
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found = [URL]()
                while let file = enumerator?.nextObject() as? URL {
                    if audioExtensions.contains(file.pathExtension.lowercased()) { found.append(file) }
                }
                result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty {
                result.append(url)
            } else {
                // Let ffprobe decide for unfamiliar extensions, but skip obvious non-audio.
                let ignored: Set<String> = ["jpg", "jpeg", "png", "gif", "txt", "log", "cue", "nfo", "pdf", "m3u", "m3u8", "pls", "accurip", "sfv", "md5", "db", "ini"]
                if !ignored.contains(url.pathExtension.lowercased()) { result.append(url) }
            }
        }
        return result
    }

    // MARK: Controls

    func cancel() {
        guard isRunning else { return }
        cancelFlag.set(true)
        activity = "Cancelling…"
        logInfo("Cancel requested")
    }

    func clearFinished() {
        for item in items where item.status.isFinished { item.discardConvertedFile() }
        items.removeAll { $0.status.isFinished }
    }

    func retryFailed() {
        for item in items {
            if case .failed = item.status {
                item.discardConvertedFile()
                item.uploadProgress = nil
                item.status = .queued
            }
        }
        kick()
    }

    func remove(_ item: TrackItem) {
        guard !isRunning || item.status.isFinished || item.status == .queued || item.status == .waitingForDevice else { return }
        item.discardConvertedFile()
        items.removeAll { $0 === item }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Songs that are waiting while nothing is running (e.g. after the phone could not be read).
    var canSyncNow: Bool {
        !isRunning && activeDeviceInfo != nil
            && items.contains { $0.status == .waitingForDevice || $0.status == .readyToSync || $0.status == .queued }
    }

    func syncNow() {
        banner = nil
        kick()
    }

    var hasFailures: Bool { items.contains { if case .failed = $0.status { return true } else { return false } } }

    var counts: (synced: Int, already: Int, failed: Int, pending: Int) {
        var synced = 0, already = 0, failed = 0, pending = 0
        for item in items {
            switch item.status {
            case .synced: synced += 1
            case .alreadyOnPhone: already += 1
            case .failed, .skipped: failed += 1
            default: pending += 1
            }
        }
        return (synced, already, failed, pending)
    }

    // MARK: Pipeline

    /// Starts the pipeline, or asks a running one to make another pass.
    func kick() {
        if isRunning {
            needsAnotherPass = true
            return
        }
        Task { await run() }
    }

    private func run() async {
        isRunning = true
        cancelFlag.set(false)
        // Keep the Mac awake while reading, converting and syncing; the display may still turn off.
        let keepAwake = SleepAssertion(reason: "iSync is converting and syncing music to an iPhone")
        defer {
            keepAwake.release()
            isRunning = false
            activity = nil
            phoneProgress = nil
        }
        repeat {
            needsAnotherPass = false
            do {
                try await pass()
            } catch {
                if cancelFlag.isCancelled {
                    logInfo("Cancelled")
                } else {
                    banner = error.localizedDescription
                    logError(error.localizedDescription)
                }
                for item in items where [.analyzing, .checking, .converting, .syncing].contains(item.status) {
                    item.status = cancelFlag.isCancelled ? .waitingForDevice : .failed(error.localizedDescription)
                }
                return
            }
        } while needsAnotherPass && !cancelFlag.isCancelled
        if cancelFlag.isCancelled {
            for item in items where !item.status.isFinished && item.status != .readyToSync { item.status = .waitingForDevice }
        }
    }

    private func pass() async throws {
        if tools == nil {
            activity = "Looking for FFmpeg…"
            tools = try await offMain { try FFTools.locate() }
        }
        guard let tools else { return }

        try await analyze(tools: tools)

        let waiting = items.filter { $0.status == .waitingForDevice || $0.status == .readyToSync }
        guard !waiting.isEmpty else { return }
        guard let device = activeDevice, deviceInfo[device.udid] != nil else {
            activity = nil
            logInfo("\(waiting.count) song(s) waiting for an iPhone")
            return
        }
        try await sync(device: device, tools: tools)
    }

    /// Probes queued files with ffprobe and decides how each one will be converted.
    private func analyze(tools: FFTools) async throws {
        let queued = items.filter { $0.status == .queued }
        guard !queued.isEmpty else { return }
        activity = "Reading \(queued.count) file(s)…"
        let cancel = cancelFlag
        try await forEachConcurrently(queued, limit: 6, isCancelled: { cancel.isCancelled }) { item in
            item.status = .analyzing
            let url = item.url
            do {
                let (probe, plan) = try await offMain { () throws -> (ProbeResult, ConversionPlan) in
                    let probe = try ProbeResult.probe(url, tools: tools)
                    return (probe, try ConversionPlan.plan(for: probe, source: url))
                }
                item.probe = probe
                item.plan = plan
                let tags = probe.tags
                if let title = tags.title { item.title = title }
                item.subtitle = [tags.artist ?? tags.albumArtist, tags.album].compactMap { $0 }.joined(separator: " — ")
                item.formatDescription = Self.describe(probe: probe, plan: plan)
                item.status = .waitingForDevice
            } catch {
                item.status = .skipped(error.localizedDescription)
                logWarning("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func describe(probe: ProbeResult, plan: ConversionPlan) -> String {
        let codec = probe.audio.codec.hasPrefix("pcm_") ? "PCM" : probe.audio.codec.uppercased()
        switch plan {
        case .copy: return "\(codec) · sent as is"
        case .remux: return "\(codec) · rewrapped as M4A"
        case let .encodeALAC(bits, _, downmix): return "\(codec) → ALAC \(bits)-bit\(downmix ? " stereo" : "")"
        case let .encodeAAC(_, downmix): return "\(codec) → AAC 256 kbps\(downmix ? " stereo" : "")"
        }
    }

    private func readLibrary(_ device: AppleDevice) async throws -> PhoneLibrarySnapshot {
        try await offMain {
            let fs = try device.openFileSystem()
            defer { fs.close() }
            return try PhoneLibrary.read(from: fs)
        }
    }

    private func sync(device: AppleDevice, tools: FFTools) async throws {
        activity = "Reading the iPhone's music library…"
        var snapshot = try await readLibrary(device)
        logInfo("Phone library: \(snapshot.tracks.count) songs, Media anchor \(snapshot.mediaAnchor), \(snapshot.awaitingAudio.count) awaiting audio")
        // Songs stay queued; the banner explains what to do (SyncSession refuses as well).
        guard snapshot.awaitingAudio.isEmpty else {
            throw ISyncError(SyncSession.awaitingAudioMessage(count: snapshot.awaitingAudio.count))
        }

        // Skip songs the phone already has (and duplicates within what was dropped).
        var index = DuplicateIndex(tracks: snapshot.tracks)
        for item in items where item.status == .waitingForDevice {
            guard let tags = item.probe?.tags else { continue }
            item.status = .checking
            if index.contains(tags, durationMs: item.durationMs) {
                item.status = .alreadyOnPhone
                logInfo("Already on the iPhone: \(item.title)")
            } else {
                index.insert(tags, durationMs: item.durationMs)
                item.status = .converting
            }
        }

        // Convert, and sync each batch as soon as it is converted while the rest keep converting.
        // Songs converted by an earlier, stopped run go first.
        let ready = items.filter { $0.status == .readyToSync }
        let toConvert = items.filter { $0.status == .converting }
        guard !ready.isEmpty || !toConvert.isEmpty else { return }
        if !toConvert.isEmpty { activity = "Converting \(toConvert.count) song(s)…" }
        let limit = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let libraryID = snapshot.libraryID ?? Self.fallbackLibraryID(for: device.udid)
        let hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        let cancel = cancelFlag
        do {
            try await prepareAndDeliver(
                ready: ready, pending: toConvert, limit: limit, batchSize: Self.batchSize,
                isCancelled: { cancel.isCancelled },
                prepare: { item, shouldStop in try await self.convert(item, tools: tools, isCancelled: shouldStop) },
                deliver: { batch in
                    snapshot = try await self.syncBatch(batch, device: device, snapshot: snapshot,
                                                        libraryID: libraryID, hostName: hostName)
                    let converting = self.items.filter { $0.status == .converting }.count
                    if converting > 0 { self.activity = "Converting \(converting) song(s)…" }
                })
        } catch {
            // Songs not converted yet wait for the next sync rather than failing with the phone's error.
            for item in items where item.status == .converting { item.status = .waitingForDevice }
            throw error
        }
    }

    /// Converts one song. Returns whether it is ready to sync; throws only when told to stop.
    private func convert(_ item: TrackItem, tools: FFTools, isCancelled: @escaping @Sendable () -> Bool) async throws -> Bool {
        guard let probe = item.probe, let plan = item.plan else { return false }
        let url = item.url
        let work = workDirectory
        do {
            let prepared = try await offMain {
                try Converter.prepare(source: url, probe: probe, plan: plan, tools: tools, workDirectory: work,
                                      isCancelled: isCancelled)
            }
            item.prepared = prepared
            item.formatDescription = Self.describe(probe: probe, plan: plan) + " · " + prepared.format.summary
            item.status = .readyToSync
            return true
        } catch {
            if isCancelled() { throw error }
            item.status = .failed(error.localizedDescription)
            logError("\(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Syncs one batch, then re-reads the library to confirm what landed. Returns the new snapshot.
    private func syncBatch(_ batch: [TrackItem], device: AppleDevice, snapshot: PhoneLibrarySnapshot,
                           libraryID: String, hostName: String) async throws -> PhoneLibrarySnapshot {
        if cancelFlag.isCancelled { throw ISyncError("Cancelled.") }
        var snapshot = snapshot
        var allocator = IdentityAllocator(snapshot: snapshot)
        var inserts = [PlannedInsert]()
        var itemsByPID = [Int64: TrackItem]()
        for item in batch {
            guard let prepared = item.prepared else { continue }
            let names = OperationFile.Names(tags: prepared.tags, fallbackTitle: item.url.deletingPathExtension().lastPathComponent)
            let groups = allocator.groupIDs(album: names.album, effectiveArtist: names.effectiveAlbumArtist)
            let insert = PlannedInsert(pid: allocator.newPID(), albumPID: groups.album, artistPID: groups.artist,
                                       artworkCacheID: prepared.phoneCover == nil ? nil : allocator.artwork(),
                                       track: prepared, fallbackTitle: item.url.lastPathComponent)
            item.pid = insert.pid
            item.status = .syncing
            item.uploadProgress = 0
            inserts.append(insert)
            itemsByPID[insert.pid] = item
        }
        guard !inserts.isEmpty else { return snapshot }
        let converting = items.filter { $0.status == .converting }.count
        logInfo("Syncing batch of \(inserts.count) song(s)" + (converting > 0 ? " while \(converting) more convert" : ""))
        activity = "Starting sync…"
        phoneProgress = nil

        let cancel = cancelFlag
        let events: (SyncSession.Event) -> Void = { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handle(event, items: itemsByPID) }
            }
        }
        let currentSnapshot = snapshot
        let outcome: SyncSession.Outcome
        do {
            outcome = try await offMain {
                let heartbeat = device.interface == .network ? try HeartbeatKeeper(device: device) : nil
                defer { heartbeat?.stop() }
                let fs = try device.openFileSystem()
                defer { fs.close() }
                let atc = ATCConnection(transport: try device.startService("com.apple.atc"))
                defer { atc.close() }
                let session = SyncSession(fs: fs, atc: atc, hostName: hostName, libraryID: libraryID,
                                          onEvent: events, isCancelled: { cancel.isCancelled })
                return try session.run(snapshot: currentSnapshot, inserts: inserts)
            }
        } catch {
            for item in itemsByPID.values { item.uploadProgress = nil }
            throw error
        }

        activity = "Confirming with the iPhone…"
        snapshot = try await readLibrary(device)
        var unconfirmed = outcome.delivered.filter { !snapshot.tracksWithFiles.contains($0) }
        if !unconfirmed.isEmpty {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            snapshot = try await readLibrary(device)
            unconfirmed = unconfirmed.filter { !snapshot.tracksWithFiles.contains($0) }
        }
        for (pid, item) in itemsByPID {
            item.uploadProgress = nil
            if outcome.delivered.contains(pid) && !unconfirmed.contains(pid) {
                item.status = .synced
                item.discardConvertedFile()
            } else if outcome.delivered.contains(pid) {
                item.status = .failed("Sent, but the iPhone didn't list it afterwards.")
            } else {
                item.status = .failed(outcome.failed[pid] ?? "Not delivered.")
            }
        }
        logInfo("Batch done: \(itemsByPID.values.filter { $0.status == .synced }.count) of \(itemsByPID.count) confirmed on the iPhone")
        return snapshot
    }

    private func handle(_ event: SyncSession.Event, items byPID: [Int64: TrackItem]) {
        switch event {
        case .phase(let text):
            activity = text
        case let .uploading(pid, sent, total):
            byPID[pid]?.uploadProgress = total > 0 ? Double(sent) / Double(total) : nil
        case .delivered(let pid):
            byPID[pid]?.uploadProgress = 1
        case .phoneProgress(let value):
            phoneProgress = value
        }
    }

    /// A stable library identity for a phone that has never been synced with Finder.
    static func fallbackLibraryID(for udid: String) -> String {
        let key = "libraryID.\(udid)"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let id = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
