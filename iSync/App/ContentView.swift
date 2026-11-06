import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let engine: SyncEngine
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader(engine: engine)
            Divider()
            if let banner = engine.banner {
                BannerView(text: banner) { engine.banner = nil }
            }
            Group {
                if engine.items.isEmpty {
                    DropZone(isTargeted: isTargeted)
                        .padding(20)
                } else {
                    TrackList(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            FooterBar(engine: engine)
        }
        .overlay {
            if isTargeted && !engine.items.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                var urls = [URL]()
                for provider in providers {
                    if let url = await provider.loadFileURL() { urls.append(url) }
                }
                engine.add(urls: urls)
            }
            return true
        }
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: - Header

private struct DeviceHeader: View {
    let engine: SyncEngine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.activeDevice == nil ? "iphone.slash" : "iphone")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(engine.activeDevice == nil ? Color.secondary : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                if let device = engine.activeDevice {
                    if let info = engine.activeDeviceInfo {
                        Text(info.name).font(.headline)
                        Text("iOS \(info.productVersion) · \(device.interface == .usb ? "USB" : "Wi-Fi")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if let problem = engine.deviceProblem {
                        Text("iPhone connected").font(.headline)
                        Text(problem).font(.subheadline).foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Text("Connecting…").font(.headline)
                        Text("Unlock your iPhone and tap “Trust” if asked.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No iPhone connected").font(.headline)
                    Text("Connect your iPhone with a USB cable.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if engine.activeDevice != nil, engine.activeDeviceInfo == nil, engine.deviceProblem != nil {
                Button("Try Again") { engine.reconnect() }
            }
            Button {
                AddMusicPanel.present(engine: engine)
            } label: {
                Label("Add Music", systemImage: "plus")
            }
            .help("Choose music files or folders (⌘O)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop music here")
                .font(.title2.weight(.semibold))
            Text("Files or folders in any format — FLAC, ALAC, WAV, AIFF, MP3, AAC, Ogg, Opus and more.\nSongs already on your iPhone are skipped; lossless music is converted to Apple Lossless.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background((isTargeted ? Color.accentColor.opacity(0.06) : Color.clear), in: RoundedRectangle(cornerRadius: 16))
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

// MARK: - Track list

private struct TrackList: View {
    let engine: SyncEngine

    var body: some View {
        List {
            ForEach(engine.items) { item in
                TrackRow(item: item)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Remove from List") { engine.remove(item) }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct TrackRow: View {
    let item: TrackItem

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: item.status)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                HStack(spacing: 6) {
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).lineLimit(1)
                    }
                    if !item.formatDescription.isEmpty {
                        Text(item.formatDescription).lineLimit(1).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let progress = item.uploadProgress, item.status == .syncing {
                ProgressView(value: progress)
                    .frame(width: 80)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220, alignment: .trailing)
                .help(statusText)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .analyzing: return "Reading…"
        case .waitingForDevice: return "Waiting for iPhone"
        case .checking: return "Checking iPhone…"
        case .alreadyOnPhone: return "Already on iPhone"
        case .converting: return "Converting…"
        case .readyToSync: return "Ready"
        case .syncing: return item.uploadProgress == 1 ? "Importing…" : "Copying…"
        case .synced: return "Synced"
        case .skipped(let reason): return reason
        case .failed(let reason): return reason
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .synced: return .green
        case .alreadyOnPhone: return .secondary
        case .failed: return .red
        case .skipped: return .orange
        default: return .secondary
        }
    }
}

private struct StatusIcon: View {
    let status: TrackItem.Status

    var body: some View {
        switch status {
        case .synced:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .alreadyOnPhone:
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .queued, .waitingForDevice, .readyToSync:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .analyzing, .checking, .converting, .syncing:
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let engine: SyncEngine

    var body: some View {
        HStack(spacing: 12) {
            if engine.isRunning {
                if let progress = engine.phoneProgress {
                    ProgressView(value: progress).frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if engine.isRunning {
                Button("Stop") { engine.cancel() }
            } else {
                if engine.hasFailures {
                    Button("Retry Failed") { engine.retryFailed() }
                }
                if engine.items.contains(where: { $0.status.isFinished }) {
                    Button("Clear Finished") { engine.clearFinished() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        if let activity = engine.activity { return activity }
        let counts = engine.counts
        guard !engine.items.isEmpty else {
            return engine.activeDevice == nil ? "Connect an iPhone to sync." : "Ready."
        }
        var parts = [String]()
        if counts.synced > 0 { parts.append("\(counts.synced) synced") }
        if counts.already > 0 { parts.append("\(counts.already) already on iPhone") }
        if counts.failed > 0 { parts.append("\(counts.failed) not synced") }
        if counts.pending > 0 {
            parts.append(engine.activeDevice == nil ? "\(counts.pending) waiting for iPhone" : "\(counts.pending) pending")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Log

struct LogView: View {
    let engine: SyncEngine

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(engine.logLines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.tertiary)
                        Text(line.message)
                            .foregroundStyle(color(line.level))
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(line.id)
                }
                .onChange(of: engine.logLines.count) {
                    if let last = engine.logLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text(AppLog.shared.fileURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Reveal Log File") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.fileURL]) }
            }
            .padding(10)
        }
    }

    private func color(_ level: AppLog.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .debug: return .secondary
        case .info: return .primary
        }
    }
}
