import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NovotroWriteAppSignals {
    static let openProject = Notification.Name("novotro.write.openProject")
}

@available(macOS 26.0, *)
@main
struct NovotroWriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = ScriptStore()

    var body: some Scene {
        WindowGroup("Novotro Write") {
            ContentView(
                store: store,
                appName: "Novotro Write"
            )
                .task {
                    await restoreLastProjectIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NovotroWriteAppSignals.openProject)) { note in
                    guard let url = note.userInfo?["url"] as? URL else { return }
                    Task { @MainActor in
                        await loadProject(url, preferService: false)
                    }
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            fileCommands
            ProjectWindowCommands(store: store)
        }

        Window("Show Change Log", id: GlobalChangeLogWindowView.windowID) {
            GlobalChangeLogWindowView(store: store)

        }
        .defaultSize(width: 980, height: 760)
    }

    // MARK: - File Menu Commands

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") {
                openProjectFromDisk()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Save") {
                store.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(store.projectURL == nil)
        }
    }

    private func restoreLastProjectIfNeeded() async {
        guard store.projectURL == nil else { return }
        store.restoreLastProject()
    }

    @MainActor
    private func loadProject(_ url: URL, preferService: Bool) async {
        await store.loadProject(url: url, preferService: preferService)
    }

    private func openProjectFromDisk() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.title = "Open Project Folder"
            panel.message = "Choose the local Amira project folder from disk."
            panel.prompt = "Open"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false

            if let owpType = UTType(filenameExtension: "owp"),
               let owsType = UTType(filenameExtension: "ows") {
                panel.allowedContentTypes = [.folder, owpType, owsType]
            } else {
                panel.allowedContentTypes = [.folder]
            }

            if panel.runModal() == .OK,
               let url = panel.url {
                await loadProject(url, preferService: false)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ProjectWindowCommands: Commands {
    let store: ScriptStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Project") {
            Button("Show Change Log") {
                openWindow(id: GlobalChangeLogWindowView.windowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(store.projectURL == nil)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static let openProjectNotification = NovotroWriteAppSignals.openProject

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let isProjectPath = url.hasDirectoryPath || ext == "owp" || ext == "ows"
            guard isProjectPath else { continue }
            NotificationCenter.default.post(
                name: Self.openProjectNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }
}
