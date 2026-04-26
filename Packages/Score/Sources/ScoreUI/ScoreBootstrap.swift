#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
public enum ScoreBootstrap {
    private static var displayBinaryName: String {
        guard let raw = CommandLine.arguments.first else { return "Score" }
        let executable = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        return executable.isEmpty ? "Score" : executable
    }

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
            print("\(displayBinaryName) API server running on localhost:\(port) (headless mode)")
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

        ScoreApp.main()
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
                  \(displayBinaryName) --headless-export-wav --project /path/to/project.owp --output /path/to/out.wav [--song-path Songs/1.01.0 - OVERTURE.ows | --song-index 0] [--start-tick 0] [--end-tick 48000] [--override-sf2 /path/to/file.sf2]
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

        var targetAsset: MidiAsset
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

        if let preloadedAsset = preloadHeadlessSongAsset(
            store: store,
            relativePath: targetAsset.relativePath
        ),
           let songIndex = store.songAssets.firstIndex(where: { $0.relativePath == targetAsset.relativePath }) {
            store.songAssets[songIndex] = preloadedAsset
            targetAsset = MidiAsset(
                id: preloadedAsset.id,
                relativePath: preloadedAsset.relativePath,
                data: Data()
            )
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
        if await waitForSelectedSongLoad(store: store, expectedSongID: expectedSongID, timeoutSeconds: 120.0) {
            print("Song playback ready in memory.")
            return true
        }

        print("Hydrating deferred playback for \(targetAsset.relativePath)...")
        guard await store.hydrateSongPlaybackIfNeeded(id: targetAsset.id) else {
            if activateFallbackPlayableVersion(store: store, expectedSongID: expectedSongID) {
                let recovered = await waitForSelectedSongLoad(
                    store: store,
                    expectedSongID: expectedSongID,
                    timeoutSeconds: 10.0
                )
                if recovered {
                    print("Recovered playback from fallback version.")
                    return true
                }
            }
            return false
        }

        let loaded = await waitForSelectedSongLoad(store: store, expectedSongID: expectedSongID, timeoutSeconds: 120.0)
        if loaded {
            print("Hydrated playback successfully.")
            return true
        }
        if activateFallbackPlayableVersion(store: store, expectedSongID: expectedSongID) {
            let recovered = await waitForSelectedSongLoad(
                store: store,
                expectedSongID: expectedSongID,
                timeoutSeconds: 10.0
            )
            if recovered {
                print("Recovered playback from fallback version.")
                return true
            }
        }
        return false
    }

    @MainActor
    private static func activateFallbackPlayableVersion(
        store: ScoreStore,
        expectedSongID: UUID
    ) -> Bool {
        guard let songIndex = store.songAssets.firstIndex(where: { $0.id == expectedSongID }) else {
            return false
        }

        let currentPlaybackHasNotes = !(store.songAssets[songIndex].document.activeVersion()?.playback?.notes.isEmpty ?? true)
        if currentPlaybackHasNotes {
            return false
        }

        guard let fallbackVersion = store.songAssets[songIndex].document.versions.first(where: {
            !($0.playback?.notes.isEmpty ?? true)
        }) else {
            return false
        }

        store.songAssets[songIndex].document.activeVersionID = fallbackVersion.id
        store.setSelectedMidi(id: expectedSongID, stopPlaybackBeforeSelect: false)
        return true
    }

    // MARK: - Headless Full-Mix export (AMIRA_HEADLESS_FULLMIX_EXPORT)

    /// Runs a headless full-mix WAV export using the last-used project.
    /// Called by the main Opera app when `AMIRA_HEADLESS_FULLMIX_EXPORT` is set.
    /// Logs `[HeadlessFullMix] done status=... bytes=... path=...` and calls
    /// `NSApplication.shared.terminate(nil)` when complete.
    @MainActor
    public static func runHeadlessFullMixExport(outputURL: URL, songHint: String?) async {
        NSLog("[Phase1cHook] runHeadlessFullMixExport entered")
        NSLog("[HeadlessFullMix] starting outputPath=%@", outputURL.path)

        // Prepare output directory
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[HeadlessFullMix] done status=error bytes=0 path=%@ reason=output-dir-failed: %@",
                  outputURL.path, error.localizedDescription)
            NSApplication.shared.terminate(nil)
            return
        }

        // Spin up a dedicated ScoreStore (does not affect any GUI store)
        NSLog("[Phase1cHook] runHeadlessFullMixExport awaiting project load")
        let store = ScoreStore()
        store.restoreLastProject()

        // Wait up to 30 s for the project to load
        let projectLoaded = await headlessWaitFor(timeout: 30) {
            store.projectURL != nil && !store.songAssets.isEmpty
        }
        guard projectLoaded else {
            NSLog("[HeadlessFullMix] done status=error bytes=0 path=%@ reason=project-load-timeout", outputURL.path)
            NSApplication.shared.terminate(nil)
            return
        }

        NSLog("[Phase1cHook] runHeadlessFullMixExport project loaded: %@", store.projectURL?.path ?? "(nil)")
        NSLog("[HeadlessFullMix] project loaded songs=%d", store.songAssets.count)

        // Select song
        var targetID: UUID?
        if let hint = songHint {
            targetID = store.songAssets.first(where: {
                $0.relativePath == hint
                    || $0.relativePath.contains(hint)
                    || $0.displayName == hint
            })?.id
        }
        if targetID == nil {
            targetID = store.songAssets.first?.id
        }
        guard let songID = targetID else {
            NSLog("[HeadlessFullMix] done status=error bytes=0 path=%@ reason=no-song", outputURL.path)
            NSApplication.shared.terminate(nil)
            return
        }

        let resolvedSongName = store.songAssets.first(where: { $0.id == songID })?.displayName ?? "(unknown)"
        NSLog("[Phase1cHook] runHeadlessFullMixExport resolved song: %@", resolvedSongName)
        store.setSelectedMidi(id: songID)

        // Wait up to 60 s for notes to load
        let notesLoaded = await headlessWaitFor(timeout: 60) { !store.pianoRollNotes.isEmpty }
        guard notesLoaded else {
            NSLog("[HeadlessFullMix] done status=error bytes=0 path=%@ reason=notes-load-timeout", outputURL.path)
            NSApplication.shared.terminate(nil)
            return
        }

        let songName = store.selectedMidiAsset?.displayName ?? store.songAssets.first?.displayName ?? "unknown"
        NSLog("[Phase1cHook] runHeadlessFullMixExport calling exportFullMixToWav")
        NSLog("[HeadlessFullMix] exporting song=%@ notes=%d", songName, store.pianoRollNotes.count)

        // Prevent macOS automatic termination / App Nap / sudden-termination from
        // killing the headless process mid-export (the process has no visible window,
        // so AppKit considers it idle and eligible for reaping).
        let activityOptions: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .latencyCritical,
            .idleSystemSleepDisabled
        ]
        let activity = ProcessInfo.processInfo.beginActivity(
            options: activityOptions,
            reason: "Headless WAV export"
        )
        ProcessInfo.processInfo.disableSuddenTermination()

        // Export using the same path as the GUI "Export Audio..." menu item
        await store.exportFullMixToWav(outputURL: outputURL)

        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.endActivity(activity)

        // Report result
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let status = fileSize > 0 ? "success" : "error"
        NSLog("[Phase1cHook] runHeadlessFullMixExport export done: %@", status)
        NSLog("[HeadlessFullMix] done status=%@ bytes=%lld path=%@", status, fileSize, outputURL.path)

        NSLog("[Phase1cHook] runHeadlessFullMixExport terminating app")
        NSApplication.shared.terminate(nil)
    }

    private static func headlessWaitFor(timeout: Double, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let steps = Int(timeout / 0.25)
        for _ in 0..<steps {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await MainActor.run(body: condition)
    }

    @MainActor
    private static func preloadHeadlessSongAsset(
        store: ScoreStore,
        relativePath: String
    ) -> OWSSongAsset? {
        guard let songIndex = store.songAssets.firstIndex(where: { $0.relativePath == relativePath }) else {
            return nil
        }

        let existing = store.songAssets[songIndex]
        guard let stub = store.songStubs.first(where: { $0.relativePath == relativePath }) else {
            return !(existing.document.activeVersion()?.playback?.notes.isEmpty ?? true) ? existing : nil
        }

        do {
            let asset = try loadActiveVersionOnlySongAsset(stub: stub)
            if !(asset.document.activeVersion()?.playback?.notes.isEmpty ?? true) {
                print("Preloaded active playback directly from \(relativePath).")
                return asset
            }
        } catch {
            print("Lightweight preload failed for \(relativePath): \(error.localizedDescription)")
        }

        return !(existing.document.activeVersion()?.playback?.notes.isEmpty ?? true) ? existing : nil
    }

    private static func loadActiveVersionOnlySongAsset(stub: SongStub) throws -> OWSSongAsset {
        let data = try Data(contentsOf: stub.fileURL, options: .mappedIfSafe)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersions = root["versions"] as? [Any] else {
            throw NSError(
                domain: "ScoreBootstrap",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Song file is missing a versions array."]
            )
        }

        let versions = rawVersions.compactMap { $0 as? [String: Any] }
        guard !versions.isEmpty else {
            throw NSError(
                domain: "ScoreBootstrap",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Song file has no decodable versions."]
            )
        }

        let activeVersionID = (root["activeVersionID"] as? String)?.uppercased()
        func hasPlaybackNotes(_ version: [String: Any]) -> Bool {
            guard let playback = version["playback"] as? [String: Any],
                  let notes = playback["notes"] as? [Any] else {
                return false
            }
            return !notes.isEmpty
        }

        struct PlaybackSummary {
            let noteCount: Int
            let maxEnd: Int
        }

        func playbackSummary(_ version: [String: Any]) -> PlaybackSummary? {
            guard let playback = version["playback"] as? [String: Any],
                  let notes = playback["notes"] as? [[String: Any]],
                  !notes.isEmpty else {
                return nil
            }

            let maxEnd = notes.reduce(0) { partial, note in
                let start = note["startTick"] as? Int ?? 0
                let duration = note["duration"] as? Int ?? 0
                return max(partial, start + duration)
            }
            return PlaybackSummary(noteCount: notes.count, maxEnd: maxEnd)
        }

        let activeVersion = activeVersionID.flatMap { id in
            versions.first { (($0["id"] as? String) ?? "").uppercased() == id }
        }
        let playableVersions = versions.compactMap { version -> ([String: Any], PlaybackSummary)? in
            guard let summary = playbackSummary(version) else { return nil }
            return (version, summary)
        }

        let selectedVersion: [String: Any]? = {
            if let activeVersion,
               let activeSummary = playbackSummary(activeVersion) {
                let fallbackCandidate = playableVersions
                    .filter { candidate in
                        let summary = candidate.1
                        return summary.noteCount >= max(200, activeSummary.noteCount * 2)
                            && summary.maxEnd > 0
                            && summary.maxEnd * 2 < activeSummary.maxEnd
                    }
                    .sorted { lhs, rhs in
                        if lhs.1.noteCount != rhs.1.noteCount {
                            return lhs.1.noteCount > rhs.1.noteCount
                        }
                        return lhs.1.maxEnd < rhs.1.maxEnd
                    }
                    .first

                if activeSummary.noteCount <= 200,
                   activeSummary.maxEnd > 1_000_000,
                   let fallbackCandidate {
                    if let label = fallbackCandidate.0["label"] as? String {
                        print("Using sane fallback playback version: \(label)")
                    }
                    return fallbackCandidate.0
                }

                return activeVersion
            }

            return playableVersions.first?.0 ?? versions.first
        }()

        guard let selectedVersion else {
            throw NSError(
                domain: "ScoreBootstrap",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not choose an export version."]
            )
        }

        if let selectedID = selectedVersion["id"] as? String {
            root["activeVersionID"] = selectedID
        }
        if root["instrumentMappings"] == nil {
            root["instrumentMappings"] = [:]
        }
        root["versions"] = [selectedVersion]

        let trimmedData = try JSONSerialization.data(withJSONObject: root, options: [])
        let document = try OWPProjectIO.configuredDecoder().decode(OWSSongDocument.self, from: trimmedData)
        return OWSSongAsset(relativePath: stub.relativePath, document: document)
    }
}

@available(macOS 26.0, *)
struct ScoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = ScoreStore()
    @State private var showKeyboardShortcuts = false

    var body: some Scene {
        WindowGroup("Score") {
            ContentView(
                store: store
            )

                .sheet(isPresented: $showKeyboardShortcuts) {
                    KeyboardShortcutsView()
                }
                .onAppear {
                    if let port = ScoreBootstrap.parseAPIPort() {
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
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)
            Button("Export Rehearsal Track...") { store.exportRehearsalTrackWithPanel() }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)
            Button("Export Stems...") { store.exportStemsWithPanel() }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)
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
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let windowNumber = event.windowNumber

            guard MainActor.assumeIsolated({
                Self.shouldTogglePlayback(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    windowNumber: windowNumber
                )
            }) else { return event }
            NotificationCenter.default.post(name: ScoreAppSignals.spacebarPlayPauseNotification, object: nil)
            return nil
        }
    }

    @MainActor
    private static func shouldTogglePlayback(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        windowNumber: Int
    ) -> Bool {
        guard keyCode == 49 else { return false }

        let mods = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }

        // Only handle space when the main Score workspace window owns the key event.
        // This keeps sheets, dialogs, and other temporary UI in control of the key.
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              window === NSApp.mainWindow else { return false }

        if let responder = window.firstResponder {
            if responder is NSText || responder is NSTextView || responder is NSTextField {
                return false
            }
        }

        return true
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
        NotificationCenter.default.post(name: ScoreAppSignals.toggleInspectorNotification, object: nil)
    }
}

#elseif os(iOS)
import SwiftUI
import AVFoundation

@available(iOS 26.0, *)
public enum ScoreBootstrap {
    @MainActor
    public static func main(arguments: [String] = CommandLine.arguments) {
        ScoreApp.main()
    }
}

@available(iOS 26.0, *)
struct ScoreApp: App {
    @State private var store = ScoreStore()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup("Score") {
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
