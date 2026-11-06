import XCTest
import SwiftUI
@testable import iSync

/// Renders the main window offscreen for visual review. Runs only when TEST_RUNNER_ISYNC_SNAPSHOT_DIR
/// (seen by the test as ISYNC_SNAPSHOT_DIR) names an output folder.
@MainActor
final class UISnapshotTests: XCTestCase {
    private func render(_ view: some View, size: CGSize, to name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ISYNC_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_ISYNC_SNAPSHOT_DIR to render snapshots")
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(view, size: size, appearance: appearance, to: URL(fileURLWithPath: directory)
                .appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
        }
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    func testRenderEmptyAndBusyStates() throws {
        let empty = SyncEngine()
        try render(ContentView(engine: empty), size: CGSize(width: 640, height: 480), to: "empty.png")

        let busy = SyncEngine()
        let samples: [(String, String, String, TrackItem.Status, Double?)] = [
            ("Hey Jude", "The Beatles — 1", "FLAC → ALAC 24-bit · ALAC 24-bit/96 kHz", .synced, nil),
            ("Clair de Lune", "Debussy — Suite bergamasque", "MP3 · sent as is", .alreadyOnPhone, nil),
            ("Night Drive", "Synthwave Co — Neon", "OPUS → AAC 256 kbps", .syncing, 0.42),
            ("Track 04", "Unknown", "WAV → ALAC 16-bit", .converting, nil),
            ("Broken.flac", "", "", .failed("Conversion failed: Invalid data found"), nil),
            ("Cover Letter.pdf", "", "", .skipped("Not a readable audio file"), nil),
        ]
        for (title, subtitle, format, status, progress) in samples {
            let item = TrackItem(url: URL(fileURLWithPath: "/tmp/\(title)"))
            item.title = title; item.subtitle = subtitle; item.formatDescription = format
            item.status = status; item.uploadProgress = progress
            busy.items.append(item)
        }
        busy.banner = "The iPhone is busy syncing with another computer or app (error 9)."
        try render(ContentView(engine: busy), size: CGSize(width: 640, height: 480), to: "busy.png")
    }
}
