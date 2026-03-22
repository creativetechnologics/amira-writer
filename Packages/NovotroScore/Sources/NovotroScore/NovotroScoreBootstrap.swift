#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
public enum NovotroScoreBootstrap {
    @MainActor
    public static func main(arguments: [String] = CommandLine.arguments) {
        if arguments.contains("--self-test") {
            let code = LyricsSyncSelfTest.run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(code)
        }

        if arguments.contains("--test-engine") {
            let code = MusicEngineTests.run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(code)
        }

        if arguments.contains("--debug") {
            let code = CLIDebugHarness.run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(code)
        }

        #if canImport(MLXLLM)
        if arguments.contains("--test-llm-load") {
            let code = LLMLoadTest.run()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(code)
        }
        #endif

        if arguments.contains("--api-only") {
            let port = parseAPIPort(arguments: arguments) ?? 19847
            let store = ScoreStore()
            store.apiServerPort = port
            store.startAPIServer()
            store.restoreLastProject()
            print("Novotro Score API server running on localhost:\(port) (headless mode)")
            print("Press Ctrl+C to stop.")
            dispatchMain()
        }

        if arguments.contains("--headless-export-wav") {
            guard let exportRequest = parseHeadlessExportRequest(arguments: arguments) else {
                fflush(stdout)
                fflush(stderr)
                Darwin.exit(2)
            }

            let store = ScoreStore()
            Task { @MainActor in
                let code = await runHeadlessExport(request: exportRequest, store: store)
                fflush(stdout)
                fflush(stderr)
                Darwin.exit(code)
            }
            dispatchMain()
        }

        NovotroScoreApp.main()
    }

    static func parseAPIPort(arguments: [String] = CommandLine.arguments) -> UInt16? {
        guard let idx = arguments.firstIndex(of: "--api-port"), idx + 1 < arguments.count,
              let port = UInt16(arguments[idx + 1]) else { return nil }
        return port
    }

    struct HeadlessExportRequest: Sendable {
        var projectPath: String
        var outputPath: String
        var songRelativePath: String?
        var songIndex: Int?
        var startTick: Int?
        var endTick: Int?
        var overrideSF2Path: String?
    }

    static func parseHeadlessExportRequest(
        arguments: [String] = CommandLine.arguments
    ) -> HeadlessExportRequest? {
        guard arguments.contains("--headless-export-wav") else { return nil }

        func value(after flag: String) -> String? {
            guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
            return arguments[idx + 1]
        }

        guard let projectPath = value(after: "--project"),
              let outputPath = value(after: "--output") else {
            fputs(
                """
                Missing required arguments for --headless-export-wav.
                Usage:
                  NovotroScore --headless-export-wav --project /path/to/project.owp --output /path/to/out.wav [--song-path Songs/1.01.0 - OVERTURE.ows | --song-index 0] [--start-tick 0] [--end-tick 48000] [--override-sf2 /path/to/file.sf2]
                """,
                stderr
            )
            return nil
        }

        let songIndex = value(after: "--song-index").flatMap(Int.init)
        let startTick = value(after: "--start-tick").flatMap(Int.init)
        let endTick = value(after: "--end-tick").flatMap(Int.init)

        return HeadlessExportRequest(
            projectPath: projectPath,
            outputPath: outputPath,
            songRelativePath: value(after: "--song-path"),
            songIndex: songIndex,
            startTick: startTick,
            endTick: endTick,
            overrideSF2Path: value(after: "--override-sf2")
        )
    }

    @MainActor
    static func runHeadlessExport(
        request: HeadlessExportRequest,
        store: ScoreStore
    ) async -> Int32 {
        func fail(_ message: String) -> Int32 {
            fputs(message + "\n", stderr)
            return 1
        }

        let projectURL = URL(fileURLWithPath: request.projectPath)
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            return fail("Project not found: \(request.projectPath)")
        }

        let outputURL = URL(fileURLWithPath: request.outputPath)
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return fail("Failed to create output directory: \(error.localizedDescription)")
        }

        if let overrideSF2Path = request.overrideSF2Path {
            let ext = URL(fileURLWithPath: overrideSF2Path).pathExtension.lowercased()
            guard ["sf2", "sf3", "dls"].contains(ext) else {
                return fail("overrideSF2Path must be .sf2, .sf3, or .dls")
            }
            guard FileManager.default.fileExists(atPath: overrideSF2Path) else {
                return fail("overrideSF2Path not found: \(overrideSF2Path)")
            }
        }

        print("Opening project: \(request.projectPath)")
        await store.loadProject(url: projectURL, preferService: false)

        guard store.projectURL != nil else {
            return fail("Failed to load project: \(request.projectPath)")
        }
        guard !store.songAssets.isEmpty else {
            return fail("Project contains no songs: \(request.projectPath)")
        }

        let targetAsset: MidiAsset
        if let songPath = request.songRelativePath {
            guard let asset = store.songAssets.first(where: { $0.relativePath == songPath }) else {
                return fail("Song not found by relative path: \(songPath)")
            }
            targetAsset = MidiAsset(id: asset.id, relativePath: asset.relativePath, data: Data())
        } else if let songIndex = request.songIndex {
            guard store.songAssets.indices.contains(songIndex) else {
                return fail("Song index out of range: \(songIndex)")
            }
            let asset = store.songAssets[songIndex]
            targetAsset = MidiAsset(id: asset.id, relativePath: asset.relativePath, data: Data())
        } else if let selected = store.selectedMidiAsset {
            targetAsset = selected
        } else {
            let asset = store.songAssets[0]
            targetAsset = MidiAsset(id: asset.id, relativePath: asset.relativePath, data: Data())
        }

        print("Selecting song: \(targetAsset.relativePath)")
        store.setSelectedMidi(id: targetAsset.id)

        let selectionLoaded = await ensureSongPlaybackLoaded(
            store: store,
            targetAsset: targetAsset,
            expectedSongID: targetAsset.id
        )
        guard selectionLoaded else {
            return fail("Timed out waiting for song to load: \(targetAsset.relativePath)")
        }

        let notes = store.pianoRollNotes
        guard !notes.isEmpty else {
            return fail("Selected song has no notes: \(targetAsset.relativePath)")
        }

        let startTick = max(0, request.startTick ?? 0)
        let defaultEndTick = notes.map { $0.startTick + $0.duration }.max() ?? 0
        let endTick = request.endTick ?? defaultEndTick
        guard endTick > startTick else {
            return fail("endTick (\(endTick)) must be greater than startTick (\(startTick))")
        }

        do {
            print("Rendering ticks \(startTick)...\(endTick) to \(outputURL.path)")
            try await store.renderChunkToWav(
                notes: notes,
                startTick: startTick,
                endTick: endTick,
                outputURL: outputURL,
                overrideSF2Path: request.overrideSF2Path
            )
            print("Exported \(targetAsset.displayName) to \(outputURL.path)")
            return 0
        } catch {
            return fail("Export failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func waitForSelectedSongLoad(
        store: ScoreStore,
        expectedSongID: UUID,
        timeoutSeconds: Double = 15.0
    ) async -> Bool {
        let iterations = max(1, Int(timeoutSeconds / 0.1))
        for _ in 0..<iterations {
            if store.selectedMidiID == expectedSongID,
               store.selectedMidiAsset?.id == expectedSongID,
               !store.pianoRollNotes.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return store.selectedMidiID == expectedSongID
            && store.selectedMidiAsset?.id == expectedSongID
            && !store.pianoRollNotes.isEmpty
    }

    @MainActor
    private static func ensureSongPlaybackLoaded(
        store: ScoreStore,
        targetAsset: MidiAsset,
        expectedSongID: UUID
    ) async -> Bool {
        if await waitForSelectedSongLoad(store: store, expectedSongID: expectedSongID, timeoutSeconds: 10.0) {
            print("Song playback ready in memory.")
            return true
        }

        print("Hydrating deferred playback for \(targetAsset.relativePath)...")
        guard await store.hydrateSongPlaybackIfNeeded(id: targetAsset.id) else {
            return false
        }

        let loaded = await waitForSelectedSongLoad(store: store, expectedSongID: expectedSongID, timeoutSeconds: 10.0)
        if loaded {
            print("Hydrated playback successfully.")
        }
        return loaded
    }
}

@available(macOS 26.0, *)
struct NovotroScoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = ScoreStore()
    @State private var showKeyboardShortcuts = false

    var body: some Scene {
        WindowGroup("Novotro Score") {
            ContentView(
                store: store
            )

                .sheet(isPresented: $showKeyboardShortcuts) {
                    KeyboardShortcutsView()
                }
                .onAppear {
                    if let port = NovotroScoreBootstrap.parseAPIPort() {
                        store.apiServerPort = port
                    }
                    store.startAPIServer()
                    Task { @MainActor in
                        if store.projectURL == nil {
                            store.restoreLastProject()
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            fileCommands
            editCommands
            playbackCommands
            helpCommands
        }
    }

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { openProjectFromDisk() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Import MusicXML...") { store.importMusicXMLWithPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Save") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.projectURL == nil)
            Divider()
            Button("Export Audio...") { store.exportFullMixToWavWithPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)
            Button("Export Rehearsal Track...") { store.exportRehearsalTrackWithPanel() }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)
            Button("Export Stems...") { store.exportStemsWithPanel() }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)
        }
    }

    @CommandsBuilder
    private var editCommands: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button("Redo") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
            Divider()
            Button("Select All Notes") { store.selectAllNotes() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Delete Selected Notes") { store.deleteSelectedNotes() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.selectedNoteIDs.isEmpty)
            Divider()
            Button("Quantize Selected") { store.quantizeSelectedNotes() }
                .keyboardShortcut("q", modifiers: .command)
                .disabled(store.selectedNoteIDs.isEmpty)
        }
    }

    @CommandsBuilder
    private var playbackCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Play / Stop") {
                if store.isPlaying { store.stopPlayback() } else { store.playPianoRoll(startTick: 0) }
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("Cycle Suno A/B Mode") {
                store.cycleSunoPlaybackMode()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
        }
    }

    @CommandsBuilder
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                showKeyboardShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)
        }
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
                await store.loadProject(url: url, preferService: false)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static let toggleInspectorNotification = Notification.Name("ToggleInspector")
    static let spacebarPlayPauseNotification = Notification.Name("SpacebarPlayPause")

    private var keyMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.configureWindow()
        }
        installSpacebarMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let isProjectPath = url.hasDirectoryPath || ext == "owp" || ext == "ows"
            guard isProjectPath else {
                continue
            }
            NotificationCenter.default.post(
                name: ScoreAppSignals.openFileNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
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
            NotificationCenter.default.post(name: Self.spacebarPlayPauseNotification, object: nil)
            return nil
        }
    }

    @MainActor
    private func configureWindow() {
        guard let window = NSApp.windows.first else { return }

        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        let button = NSButton(frame: .zero)
        button.image = NSImage(
            systemSymbolName: "sidebar.trailing",
            accessibilityDescription: "Toggle Inspector"
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = #selector(toggleInspector)
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 24))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 24),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .trailing
        vc.view = container
        window.addTitlebarAccessoryViewController(vc)
    }

    @objc private func toggleInspector() {
        NotificationCenter.default.post(name: Self.toggleInspectorNotification, object: nil)
    }
}

#elseif os(iOS)
import SwiftUI
import AVFoundation

@available(iOS 26.0, *)
public enum NovotroScoreBootstrap {
    @MainActor
    public static func main(arguments: [String] = CommandLine.arguments) {
        NovotroScoreApp_iOS.main()
    }
}

@available(iOS 26.0, *)
struct NovotroScoreApp_iOS: App {
    @State private var store = ScoreStore()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup("Novotro Score") {
            IOSContentView(store: store)

                .onAppear {
                    store.startAPIServer()
                    store.restoreLastProject()
                }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }
}
#endif
