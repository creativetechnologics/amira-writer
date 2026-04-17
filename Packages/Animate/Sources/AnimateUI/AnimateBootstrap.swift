import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
public enum AnimateBootstrap {
    @MainActor
    public static func main() {
        AnimateApp.main()
    }
}

@available(macOS 26.0, *)
struct AnimateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = AnimateStore()

    var body: some Scene {
        WindowGroup("Animate") {
            ContentView(store: store)
                .task {
                    await restoreLastProjectIfNeeded()
                    AnimateAPIServer.startIfNeeded(store: store)
                }
                .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.openFileNotification)) { notification in
                    guard let url = notification.userInfo?["url"] as? URL else { return }
                    Task { @MainActor in
                        await store.openOWP(url: url)
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1400, height: 900)
        .commands {
            fileCommands
            viewCommands
            animationCommands
        }
    }

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { openProjectFromDisk() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Save") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.owpURL == nil)
        }
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandMenu("View") {
            let pages = AnimatePage.allCases.filter { $0 != .script && $0 != .characters && $0 != .places && $0 != .props }
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                Button(page.rawValue) {
                    NotificationCenter.default.post(
                        name: AnimateAppSignals.switchPageNotification,
                        object: nil,
                        userInfo: ["page": page]
                    )
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }

    @CommandsBuilder
    private var animationCommands: some Commands {
        CommandMenu("Animation") {
            Button("Export Video...") {
                store.showExportSheet = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(store.owpURL == nil)
        }
    }

    @MainActor
    private func restoreLastProjectIfNeeded() async {
        guard store.owpURL == nil else {
            return
        }
        store.restoreLastProject()
    }

    @MainActor
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
                await store.openOWP(url: url)
            }
        }
    }
}

@available(macOS 26.0, *)
class AnimateDocumentController: NSDocumentController {

    override func openDocument(_ sender: Any?) {
        NotificationCenter.default.post(
            name: AnimateAppSignals.openFileNotification,
            object: nil,
            userInfo: ["action": "openPanel"]
        )
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let ext = url.pathExtension.lowercased()
        if url.hasDirectoryPath || ext == "owp" || ext == "ows" {
            NotificationCenter.default.post(
                name: AnimateAppSignals.openFileNotification,
                object: nil,
                userInfo: ["url": url]
            )
            completionHandler(nil, false, nil)
        } else {
            completionHandler(nil, false, nil)
        }
    }

    override var documentClassNames: [String] { [] }
    override var defaultType: String? { nil }
}

@available(macOS 26.0, *)
class AppDelegate: NSObject, NSApplicationDelegate {
    static let toggleInspectorNotification = Notification.Name("ToggleInspector")
    static let spacebarPlayPauseNotification = Notification.Name("SpacebarPlayPause")
    static let switchPageNotification = Notification.Name("SwitchPage")

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = AnimateDocumentController()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if url.hasDirectoryPath || ext == "owp" || ext == "ows" {
                NotificationCenter.default.post(
                    name: AnimateAppSignals.openFileNotification,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.configureWindow() }
        installSpacebarMonitor()
    }

    private func installSpacebarMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49 else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
                return event
            }
            if let responder = event.window?.value(forKey: "firstResponder") as? NSResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            NotificationCenter.default.post(
                name: AppDelegate.spacebarPlayPauseNotification,
                object: nil
            )
            return nil
        }
    }

    @MainActor private func configureWindow() {
        guard let window = NSApp.windows.first else { return }
        window.titlebarSeparatorStyle = .none
    }

    @objc private func toggleInspector() {
        NotificationCenter.default.post(name: Self.toggleInspectorNotification, object: nil)
    }
}
