import SwiftUI
import AppKit

@main
struct iSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = SyncEngine()

    var body: some Scene {
        Window("iSync", id: "main") {
            ContentView(engine: engine)
                .frame(minWidth: 560, minHeight: 440)
                .onAppear {
                    appDelegate.engine = engine
                    engine.start()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") { AddMusicPanel.present(engine: engine) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                OpenLogButton()
            }
        }

        Window("iSync Log", id: "log") {
            LogView(engine: engine)
                .frame(minWidth: 620, minHeight: 320)
        }
    }
}

private struct OpenLogButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Log") { openWindow(id: "log") }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: SyncEngine?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine, MainActor.assumeIsolated({ engine.isRunning }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A sync is in progress"
        alert.informativeText = "Quitting now stops the sync. Songs already copied stay on the iPhone."
        alert.addButton(withTitle: "Keep Syncing")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let engine { MainActor.assumeIsolated { engine.cleanUp() } }
    }
}

@MainActor
enum AddMusicPanel {
    static func present(engine: SyncEngine) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to iPhone"
        panel.message = "Choose music files or folders to add to your iPhone."
        if panel.runModal() == .OK {
            engine.add(urls: panel.urls)
        }
    }
}
