import AppKit
import SwiftUI
import AnimateUI
import MixUI
import ProjectKit
import ScoreUI
import WriteUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
enum OperaMode: String, CaseIterable, Identifiable {
    case write
    case score
    case mix
    case characters
    case places
    case props
    case scenes
    case animate
    case allImages
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .score: return "Score"
        case .mix: return "Mix"
        case .characters: return "Characters"
        case .places: return "Places"
        case .props: return "Props"
        case .scenes: return "Scenes"
        case .animate: return "Animate"
        case .allImages: return "All Images"
        case .canvas: return "Canvas"
        }
    }

    var subtitle: String {
        switch self {
        case .write: return "Libretto and scene drafting"
        case .score: return "Playback, orchestration, and export"
        case .mix: return "DAW timeline, Suno comping, and polish"
        case .characters: return "Character design, reference workflow, and asset generation"
        case .places: return "Background plates, locations, and set imagery"
        case .props: return "Scene objects, vehicles, and interactive props"
        case .scenes: return "Scene image generation"
        case .animate: return "Staging, scenes, and timeline animation"
        case .allImages: return "Every generated image across the project"
        case .canvas: return "Free-form image generation canvas"
        }
    }

    var systemImage: String {
        switch self {
        case .write: return "text.book.closed"
        case .score: return "music.note.list"
        case .mix: return "slider.horizontal.3"
        case .characters: return "person.2"
        case .places: return "map"
        case .props: return "shippingbox"
        case .scenes: return "film.stack"
        case .animate: return "sparkles.tv"
        case .allImages: return "photo.on.rectangle.angled"
        case .canvas: return "paintpalette"
        }
    }

    /// Whether this mode appears as a button in the main sidebar tab bar.
    /// Canvas is accessed via the paint-palette toolbar button, not the sidebar.
    var isSidebarVisible: Bool {
        self != .canvas
    }
}

enum OperaShellSignals {
    static let openProjectFromDisk = Notification.Name("novotro.opera.openProjectFromDisk")
    static let openProjectFromURL = Notification.Name("novotro.opera.openProjectFromURL")
    static let openRecentProjects = Notification.Name("novotro.opera.openRecentProjects")
    static let saveProject = Notification.Name("novotro.opera.saveProject")

    /// Called by OperaShellView to register a closure the AppDelegate uses to check dirty state.
    @MainActor static var hasUnsavedChanges: (() -> Bool)?
    /// Called by the AppDelegate to trigger a save before quit.
    @MainActor static var saveAll: (() -> Void)?
}

private enum OperaRecentProjectsStore {
    private static let storageKey = "novotro.opera.recentProjectPaths"
    private static let legacyStorageKeys = [
        "recentProjectPaths"
    ]
    private static let maxProjects = 12
    private static let controlFileCandidates = [
        "Metadata/project.json",
        "project.json"
    ]

    static func recentProjects(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let primaryPaths = userDefaults.array(forKey: storageKey) as? [String] ?? []
        let legacyPaths = legacyStorageKeys.flatMap { key in
            userDefaults.array(forKey: key) as? [String] ?? []
        }
        let storedPaths = primaryPaths + legacyPaths
        var seen: Set<String> = []
        var urls: [URL] = []

        for path in storedPaths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard let resolvedURL = resolvedProjectURL(url, fileManager: fileManager) else { continue }
            urls.append(resolvedURL)
        }

        let normalizedPaths = urls.map(\.path)
        if normalizedPaths != primaryPaths {
            userDefaults.set(urls.map(\.path), forKey: storageKey)
        }

        return urls
    }

    @discardableResult
    static func noteProject(
        _ url: URL,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard let resolvedURL = resolvedProjectURL(normalized, fileManager: fileManager) else {
            return recentProjects(userDefaults: userDefaults, fileManager: fileManager)
        }
        var urls = recentProjects(userDefaults: userDefaults)
        urls.removeAll { $0.path == resolvedURL.path }
        urls.insert(resolvedURL, at: 0)
        let trimmed = Array(urls.prefix(maxProjects))
        userDefaults.set(trimmed.map(\.path), forKey: storageKey)
        return trimmed
    }

    static func resolvedProjectURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        if isDirectlySupportedProjectURL(normalized, fileManager: fileManager) {
            return normalized
        }

        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let parentName = normalized.deletingLastPathComponent().lastPathComponent
        let candidateSuffixes = [
            [normalized.lastPathComponent],
            parentName.isEmpty ? [] : [parentName],
            parentName.isEmpty ? [] : [parentName, normalized.lastPathComponent]
        ].filter { !$0.isEmpty }

        for root in [homeURL] {
            for suffix in candidateSuffixes {
                let candidate = suffix.reduce(root) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: true)
                }
                let standardizedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
                if isDirectlySupportedProjectURL(standardizedCandidate, fileManager: fileManager) {
                    return standardizedCandidate
                }
            }
        }

        return nil
    }

    private static func isDirectlySupportedProjectURL(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return controlFileCandidates.contains { candidate in
            fileManager.fileExists(atPath: url.appendingPathComponent(candidate).path)
        }
    }
}

@available(macOS 26.0, *)
private enum OperaModal: String, Identifiable {
    case recentProjects

    var id: String { rawValue }
}

@available(macOS 26.0, *)
private enum OperaLoadState: Equatable {
    case idle
    case loading(mode: OperaMode, projectName: String, projectPath: String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

@available(macOS 26.0, *)
private enum OperaModeLoadResult {
    case success
    case failure(String)
    case timedOut
}

@available(macOS 26.0, *)
private struct PendingSceneSelectionRestore: Equatable {
    let projectPath: String
    let selectionPath: String?
}

@available(macOS 26.0, *)
struct OperaShellView: View {
    @Binding var selectedMode: OperaMode
    @StateObject private var progressCenter = ProjectOpenProgressCenter.shared
    @StateObject private var writeController = WriteWorkspaceController()
    @StateObject private var scoreController = ScoreWorkspaceController()
    @StateObject private var mixController = MixWorkspaceController()
    @StateObject private var animateController = AnimateWorkspaceController()
    @State private var activeProjectURL: URL?
    @State private var activeProjectTitle: String?
    @State private var renderedMode: OperaMode = .write
    @State private var activeModal: OperaModal?
    @State private var loadState: OperaLoadState = .idle
    @State private var recentProjects: [URL] = []
    @State private var activeProjectLoadError: String?
    @State private var isOpeningFromPanel = false
    @State private var didInitialize = false
    @State private var modeSwitchTask: Task<Void, Never>?
    @State private var workspacePrewarmTask: Task<Void, Never>?
    @State private var sceneSelectionByProjectPath: [String: String] = [:]
    @State private var pendingSceneSelectionRestores: [OperaMode: PendingSceneSelectionRestore] = [:]

    // Sidebar visibility (per-mode, shared with each mode's ContentView via same AppStorage key)
    @AppStorage("novotro.write.sidebarVisible") private var writeSidebarVisible: Bool = true
    @AppStorage("novotro.score.sidebarVisible") private var scoreSidebarVisible: Bool = true
    @AppStorage("novotro.animate.sidebarVisible") private var animateSidebarVisible: Bool = true
    @AppStorage("novotro.characters.sidebarVisible") private var charactersSidebarVisible: Bool = true
    @AppStorage("novotro.places.sidebarVisible") private var placesSidebarVisible: Bool = true
    @AppStorage("novotro.props.sidebarVisible") private var propsSidebarVisible: Bool = true
    @AppStorage("novotro.mix.sidebarVisible") private var mixSidebarVisible: Bool = true
    @AppStorage("novotro.imagine.sidebarVisible") private var imagineSidebarVisible: Bool = true
    @AppStorage("novotro.allImages.sidebarVisible") private var allImagesSidebarVisible: Bool = true
    @AppStorage("novotro.canvas.sidebarVisible") private var canvasSidebarVisible: Bool = true

    // Inspector visibility (per-mode, shared with each mode's ContentView via same AppStorage key)
    @AppStorage("novotro.write.showInspector") private var writeInspectorVisible: Bool = true
    @AppStorage("novotro.score.showInspector") private var scoreInspectorVisible: Bool = true
    @AppStorage("novotro.animate.showInspector") private var animateInspectorVisible: Bool = true
    @AppStorage("novotro.characters.showInspector") private var charactersInspectorVisible: Bool = true
    @AppStorage("novotro.places.showInspector") private var placesInspectorVisible: Bool = true
    @AppStorage("novotro.props.inspector.visible") private var propsInspectorVisible: Bool = true
    @AppStorage("novotro.mix.inspector.visible") private var mixInspectorVisible: Bool = true
    @AppStorage("novotro.imagine.showInspector") private var imagineInspectorVisible: Bool = true
    @AppStorage("novotro.allImages.showInspector") private var allImagesInspectorVisible: Bool = true
    @AppStorage("novotro.canvas.showInspector") private var canvasInspectorVisible: Bool = true
    private static let controlFileCandidates = [
        "Metadata/project.json",
        "project.json"
    ]
    private static let animateClusterModes: Set<OperaMode> = [
        .scenes, .characters, .places, .props, .animate, .allImages, .canvas
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.leading, 76)
                .padding(.trailing, 12)

            OperaChromeDivider()

            ZStack {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OperaChromeTheme.workspaceBackground)

                if case let .loading(mode, projectName, _) = loadState {
                    loadingOverlay(mode: mode, projectName: projectName)
                }
            }
        }
        .background(OperaChromeTheme.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .background(OperaWindowAccessor())
        .task {
            await initializeShellIfNeeded()
            // Seed the loopback API with whatever project is now active so
            // requests that arrive before a Places/Animate mode switch can
            // still hydrate the store.
            animateController.setAPIHostProjectURL(activeProjectURL)
            // Register dirty-state check for the AppDelegate's quit confirmation
            // Note: Characters and Places modes share animateController, so no separate dirty/save check needed.
            OperaShellSignals.hasUnsavedChanges = { [writeController, scoreController, mixController, animateController] in
                writeController.isDirty || scoreController.isDirty || mixController.isDirty || animateController.isDirty
            }
            OperaShellSignals.saveAll = { [writeController, scoreController, mixController, animateController] in
                writeController.save()
                scoreController.save()
                mixController.save()
                animateController.save()
            }
        }
        .task {
            // Bridge Score→Mix exports: when Score exports a WAV, register it in Mix.
            for await note in NotificationCenter.default.notifications(named: ScoreWorkspaceController.didExportSongToMix) {
                guard let wavURL = note.userInfo?["wavURL"] as? URL,
                      let songPath = note.userInfo?["songRelativePath"] as? String else { continue }
                if let activeProjectURL {
                    _ = await mixController.ensureProjectLoaded(activeProjectURL)
                }
                mixController.registerScoreExport(wavURL: wavURL, songRelativePath: songPath)
            }
        }
        .task {
            // Bridge Animate→Mix: flatten Mix audio for a scene and attach to Animate.
            await bridgeAnimateMixAudioRequests()
        }
        .task {
            // File-based remote control for diagnostics via SSH
            let commandPath = "/Volumes/Storage VIII/Programming/opera-command.txt"
            let fm = FileManager.default
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard fm.fileExists(atPath: commandPath),
                      let data = fm.contents(atPath: commandPath),
                      let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else { continue }
                try? fm.removeItem(atPath: commandPath)
                await MainActor.run {
                    switch command.lowercased() {
                    case "write":  selectedMode = .write
                    case "score":  selectedMode = .score
                    case "mix": selectedMode = .mix
                    case "scenes": selectedMode = .scenes
                    case "characters": selectedMode = .characters
                    case "places": selectedMode = .places
                    case "props": selectedMode = .props
                    case "animate": selectedMode = .animate
                    case "diag-drawthings":
                        let host = animateController.drawThingsHost
                        let port = animateController.drawThingsPort
                        Task { await runDrawThingsDiagnostic(host: host, port: port) }
                    case "diag-codex":
                        Task { await runCodexDiagnostic() }
                    default: break
                    }
                }
            }
        }
        .onChange(of: selectedMode) { _, newMode in
            modeSwitchTask?.cancel()
            modeSwitchTask = Task {
                await handleModeSelectionChange(newMode)
            }
        }
        .onChange(of: writeController.selectedScenePath) { _, newPath in
            captureSceneSelectionChange(
                newPath,
                from: .write,
                projectPath: writeController.activeProjectPath
            )
        }
        .onChange(of: scoreController.selectedScenePath) { _, newPath in
            captureSceneSelectionChange(
                newPath,
                from: .score,
                projectPath: scoreController.activeProjectPath
            )
        }
        .onChange(of: mixController.selectedScenePath) { _, newPath in
            captureSceneSelectionChange(
                newPath,
                from: .mix,
                projectPath: mixController.activeProjectPath
            )
        }
        .onChange(of: animateController.selectedScenePath) { _, newPath in
            // Characters, Places, Props, and Animate share animateController; route to whichever is active.
            let effectiveMode: OperaMode = (renderedMode == .characters || renderedMode == .places || renderedMode == .props || renderedMode == .scenes) ? renderedMode : .animate
            captureSceneSelectionChange(
                newPath,
                from: effectiveMode,
                projectPath: animateController.activeProjectPath
            )
        }
        .onChange(of: activeProjectURL) { _, newURL in
            // Keep the Animate-backed loopback API in sync with whichever project
            // the shell has active, so external agents can trigger generations
            // without the user first switching into Places/Animate.
            animateController.setAPIHostProjectURL(newURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openProjectFromDisk)) { _ in
            Task {
                await openProjectFromDisk()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openProjectFromURL)) { note in
            guard let rawURL = note.userInfo?["url"] as? URL else { return }
            Task {
                _ = await openProject(rawURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openRecentProjects)) { _ in
            recentProjects = OperaRecentProjectsStore.recentProjects()
            activeModal = .recentProjects
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.saveProject)) { _ in
            saveActiveWorkspace()
        }
        // Score/Mix ContentViews sync AppStorage ↔ store.showInspector
        // via their own onChange handlers, so no shell-level sync needed.
        .alert("Couldn't Open Project", isPresented: Binding(
            get: { activeProjectLoadError != nil },
            set: { isPresented in
                if !isPresented {
                    activeProjectLoadError = nil
                }
            }
        )) {
            Button("OK") {
                activeProjectLoadError = nil
            }
        } message: {
            Text(activeProjectLoadError ?? "The project could not be opened.")
        }
        .sheet(item: $activeModal) { modal in
            switch modal {
            case .recentProjects:
                recentProjectsSheet
            }
        }
    }

    private var activeSaveIndicator: SaveIndicatorState {
        switch renderedMode {
        case .write: return writeController.saveIndicator
        case .score: return scoreController.saveIndicator
        case .mix: return mixController.saveIndicator
        case .scenes: return animateController.saveIndicator
        case .characters: return animateController.saveIndicator
        case .places: return animateController.saveIndicator
        case .props: return animateController.saveIndicator
        case .animate: return animateController.saveIndicator
        case .allImages: return animateController.saveIndicator
        case .canvas: return animateController.saveIndicator
        }
    }

    private var currentSidebarVisible: Bool {
        switch renderedMode {
        case .write: return writeSidebarVisible
        case .score: return scoreSidebarVisible
        case .mix: return mixSidebarVisible
        case .scenes: return imagineSidebarVisible
        case .characters: return charactersSidebarVisible
        case .places: return placesSidebarVisible
        case .props: return propsSidebarVisible
        case .animate: return animateSidebarVisible
        case .allImages: return allImagesSidebarVisible
        case .canvas: return canvasSidebarVisible
        }
    }

    @MainActor
    private func bridgeAnimateMixAudioRequests() async {
        for await note in NotificationCenter.default.notifications(named: Notification.Name("Animate.RequestMixAudioFlatten")) {
            guard let sceneID = note.userInfo?["sceneID"] as? UUID else {
                NSLog("[Opera] Mix→Animate: no sceneID in notification")
                continue
            }
            guard let scenePath = animateController.songPath(for: sceneID) else {
                NSLog("[Opera] Mix→Animate: no songPath for sceneID %@", sceneID.uuidString)
                continue
            }
            NSLog("[Opera] Mix→Animate: flattening scene %@", scenePath)
            await flattenAndAttachMixAudio(sceneID: sceneID, scenePath: scenePath)
        }
    }

    private func flattenAndAttachMixAudio(sceneID: UUID, scenePath: String) async {
        guard mixController.hasLoadedProject else {
            NSLog("[Opera] Mix→Animate: Mix project not loaded")
            return
        }
        do {
            let wavURL = try await mixController.flattenSceneAudio(scenePath: scenePath)
            let projectPath = mixController.activeProjectPath ?? ""
            let relativePath = wavURL.path.replacingOccurrences(of: projectPath + "/", with: "")
            animateController.setDefaultAudioPath(relativePath, for: sceneID)
            NSLog("[Opera] Mix→Animate: attached %@ to scene %@", relativePath, scenePath)
        } catch {
            NSLog("[Opera] Mix→Animate flatten failed for scene %@: %@", scenePath, error.localizedDescription)
        }
    }

    /// Auto-populate Animate audio from Mix for all scenes that have Mix sessions with clips.
    private func autoPopulateAnimateAudioFromMix() async {
        guard mixController.hasLoadedProject else { return }
        let scenesWithClips = Set(mixController.scenesWithClips())
        let sceneStatus = animateController.sceneAudioStatus()
        var populatedCount = 0

        for entry in sceneStatus {
            // Skip scenes that already have audio attached
            guard !entry.hasAudio else { continue }
            guard scenesWithClips.contains(entry.songPath) else { continue }

            await flattenAndAttachMixAudio(sceneID: entry.id, scenePath: entry.songPath)
            populatedCount += 1
        }

        if populatedCount > 0 {
            NSLog("[Opera] Auto-populated %d Animate scenes with Mix audio", populatedCount)
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch renderedMode {
            case .write: writeSidebarVisible.toggle()
            case .score: scoreSidebarVisible.toggle()
            case .mix: mixSidebarVisible.toggle()
            case .scenes: imagineSidebarVisible.toggle()
            case .characters: charactersSidebarVisible.toggle()
            case .places: placesSidebarVisible.toggle()
            case .props: propsSidebarVisible.toggle()
            case .animate: animateSidebarVisible.toggle()
            case .allImages: allImagesSidebarVisible.toggle()
            case .canvas: canvasSidebarVisible.toggle()
            }
        }
    }

    private var currentInspectorVisible: Bool {
        switch renderedMode {
        case .write: return writeInspectorVisible
        case .score: return scoreInspectorVisible
        case .mix: return mixInspectorVisible
        case .scenes: return imagineInspectorVisible
        case .characters: return charactersInspectorVisible
        case .places: return placesInspectorVisible
        case .props: return propsInspectorVisible
        case .animate: return animateInspectorVisible
        case .allImages: return allImagesInspectorVisible
        case .canvas: return canvasInspectorVisible
        }
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch renderedMode {
            case .write: writeInspectorVisible.toggle()
            case .score: scoreInspectorVisible.toggle()
            case .mix: mixInspectorVisible.toggle()
            case .scenes: imagineInspectorVisible.toggle()
            case .characters: charactersInspectorVisible.toggle()
            case .places: placesInspectorVisible.toggle()
            case .props: propsInspectorVisible.toggle()
            case .animate: animateInspectorVisible.toggle()
            case .allImages: allImagesInspectorVisible.toggle()
            case .canvas: canvasInspectorVisible.toggle()
        }
    }
    }

    private var tabBar: some View {
        HStack(spacing: 14) {
            OperaChromeCompactSaveIndicator(state: activeSaveIndicator)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                // RunPod status indicator
                if animateController.isRunPodActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("RunPod")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1), in: Capsule())
                }

                ForEach(OperaMode.allCases.filter(\.isSidebarVisible)) { mode in
                    OperaModeButton(
                        mode: mode,
                        isSelected: selectedMode == mode
                    ) {
                        selectedMode = mode
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                animateController.vertexCreditTitleBarView()
                animateController.geminiStatusBadgeView()
                animateController.storyboardURLButtonView()

                OperaChromeActionButton(
                    systemImage: "paintpalette",
                    isSelected: selectedMode == .canvas
                ) {
                    selectedMode = .canvas
                }

                animateController.globalSettingsGearView()

                OperaChromeActionButton(
                    systemImage: currentSidebarVisible ? "sidebar.left" : "sidebar.right",
                    isSelected: currentSidebarVisible
                ) {
                    toggleSidebar()
                }
                OperaChromeActionButton(
                    systemImage: "info.circle",
                    isSelected: currentInspectorVisible
                ) {
                    toggleInspector()
                }
            }
        }
        .frame(height: 36)
        .background(OperaChromeTheme.headerBackground)
    }

    @ViewBuilder
    private var mainContent: some View {
        if activeProjectURL == nil {
            OperaChromeEmptyState(
                systemImage: "music.quarternote.3",
                title: "Choose A Project To Begin",
                message: "Use the File menu or Recent Projects to open a local OWP project folder."
            )
        } else {
            activeWorkspace
        }
    }

    @ViewBuilder
    private var activeWorkspace: some View {
        switch renderedMode {
        case .write:
            WriteWorkspace(controller: writeController)
        case .score:
            ScoreWorkspace(controller: scoreController)
        case .mix:
            MixWorkspace(controller: mixController)
        case .scenes:
            ScenesWorkspace(controller: animateController)
        case .characters:
            CharactersWorkspace(controller: animateController)
        case .places:
            PlacesWorkspace(controller: animateController)
        case .props:
            PropsWorkspace(controller: animateController)
        case .animate:
            AnimateWorkspace(controller: animateController)
        case .allImages:
            AllProjectImagesWorkspace(controller: animateController)
        case .canvas:
            CanvasWorkspace(controller: animateController)
        }
    }

    private var recentProjectsSheet: some View {
        OperaRecentProjectsSheet(
            recentProjects: recentProjects,
            activeProjectURL: activeProjectURL,
            isLoading: loadState.isLoading,
            openingProjectPath: activeLoadingProjectPath,
            loadingProjectName: activeLoadingProjectName,
            loadingStatusMessage: activeLoadDetail,
            loadingSnapshot: activeLoadSnapshot
        ) { url in
            Task {
                _ = await openProject(url)
            }
        }
        .interactiveDismissDisabled(loadState.isLoading)
    }

    @ViewBuilder
    private func loadingOverlay(mode: OperaMode, projectName: String) -> some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            OperaProjectLoadingPanel(
                title: "Opening \(projectName)",
                message: activeLoadDetail(for: mode),
                accent: modeAccent(for: mode),
                snapshot: activeLoadSnapshot
            )
            .padding(.horizontal, 64)
        }
    }

    @MainActor
    private func initializeShellIfNeeded() async {
        guard !didInitialize else { return }
        didInitialize = true
        renderedMode = selectedMode
        recentProjects = OperaRecentProjectsStore.recentProjects()
        if activeProjectURL == nil,
           let mostRecentProject = recentProjects.first {
            let opened = await openProject(mostRecentProject)
            if !opened {
                recentProjects = OperaRecentProjectsStore.recentProjects()
                activeModal = .recentProjects
            }
        } else if activeProjectURL == nil {
            activeModal = .recentProjects
        }
    }

    @MainActor
    private func resolveProjectURL(for url: URL) throws -> URL {
        let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           Self.hasControlFile(at: normalizedURL) {
            return normalizedURL
        }

        if let repairedURL = OperaRecentProjectsStore.resolvedProjectURL(normalizedURL) {
            return repairedURL
        }

        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
            throw RuntimeError.projectNotFound
        }
        guard isDirectory.boolValue else {
            throw RuntimeError.unsupportedSelection
        }
        guard Self.hasControlFile(at: normalizedURL) else {
            throw RuntimeError.missingControlFile
        }
        return normalizedURL
    }

    @MainActor
    private func openProject(_ url: URL) async -> Bool {
        let normalizedURL: URL
        do {
            normalizedURL = try resolveProjectURL(for: url)
        } catch {
            activeProjectLoadError = error.localizedDescription
            return false
        }
        return await openProject(normalizedURL, displayName: displayName(for: normalizedURL))
    }

    @MainActor
    private func openProject(_ url: URL, displayName: String) async -> Bool {
        let normalizedURL = url.standardizedFileURL
        let requestedMode = selectedMode
        workspacePrewarmTask?.cancel()
        beginSceneSelectionRestore(for: requestedMode, projectURL: normalizedURL)
        loadState = .loading(mode: requestedMode, projectName: displayName, projectPath: normalizedURL.path)
        progressCenter.start(
            projectURL: normalizedURL,
            phaseTitle: "Preparing Project Open",
            detail: "Starting the \(requestedMode.title) workspace for \(displayName)."
        )
        activeProjectLoadError = nil
        await Task.yield()

        let loadResult = await loadForDisplayTransition(mode: requestedMode, projectURL: normalizedURL) { error in
            reconcileBackgroundDisplayLoad(
                error: error,
                mode: requestedMode,
                projectURL: normalizedURL
            )
        }
        if case let .failure(error) = loadResult {
            clearSceneSelectionRestore(for: requestedMode, projectURL: normalizedURL)
            activeProjectLoadError = error
            progressCenter.finish(projectURL: normalizedURL)
            loadState = .idle
            return false
        }

        if case .success = loadResult {
            finishSceneSelectionRestore(for: requestedMode, projectURL: normalizedURL)
        }

        activeProjectURL = normalizedURL
        activeProjectTitle = displayName
        renderedMode = requestedMode
        activeModal = nil
        recentProjects = OperaRecentProjectsStore.noteProject(normalizedURL)
        switch loadResult {
        case .success:
            scheduleIdleWorkspacePrewarm(for: normalizedURL, activeMode: requestedMode)
            progressCenter.finish(projectURL: normalizedURL)
            loadState = .idle
        case .timedOut:
            scheduleIdleWorkspacePrewarm(for: normalizedURL, activeMode: requestedMode)
            progressCenter.update(
                projectURL: normalizedURL,
                phaseTitle: "Opening Workspace",
                detail: "\(requestedMode.title) is still loading local project data. Showing the workspace now and applying updates when loading completes."
            )
            progressCenter.finish(projectURL: normalizedURL)
            loadState = .idle
        case .failure:
            break
        }

        if selectedMode != requestedMode {
            modeSwitchTask?.cancel()
            modeSwitchTask = Task {
                await handleModeSelectionChange(selectedMode)
            }
        }
        return true
    }

    @MainActor
    private func runCodexDiagnostic() async {
        let resultPath = "/Volumes/Storage VIII/Programming/opera-diag-result.txt"
        var lines: [String] = []
        lines.append("=== Codex CLI Diagnostic ===")
        lines.append("Time: \(Date())")

        do {
            let response = try await AnimateWorkspaceController.runCodexDiagnostic()
            lines.append("RESULT: SUCCESS")
            lines.append("")
            lines.append("Response:")
            lines.append(response)
        } catch {
            lines.append("RESULT: FAILED")
            lines.append("Error: \(error.localizedDescription)")
        }

        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
    }

    private func runDrawThingsDiagnostic(host: String, port: Int) async {
        let resultPath = "/Volumes/Storage VIII/Programming/opera-diag-result.txt"
        var lines: [String] = []
        lines.append("=== DrawThings Diagnostic ===")
        lines.append("Time: \(Date())")
        lines.append("Host: \(host)")
        lines.append("Port: \(port)")

        // DNS resolution
        let hostOnly = host
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        lines.append("Hostname to resolve: \(hostOnly)")

        // URLSession test
        guard var components = URLComponents(string: host) else {
            lines.append("URL PARSE FAILED for: \(host)")
            try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
            return
        }
        if components.scheme == nil { components.scheme = "http" }
        components.port = port
        components.path = "/sdapi/v1/options"
        guard let url = components.url else {
            lines.append("URL BUILD FAILED")
            try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
            return
        }
        lines.append("Test URL: \(url.absoluteString)")

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            lines.append("HTTP Status: \(statusCode)")
            lines.append("Response size: \(data.count) bytes")
            lines.append("RESULT: SUCCESS")
        } catch {
            let nsError = error as NSError
            lines.append("CONNECTION ERROR: \(error.localizedDescription)")
            lines.append("Error domain: \(nsError.domain)")
            lines.append("Error code: \(nsError.code)")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                lines.append("Underlying: \(underlying.domain) code=\(underlying.code) \(underlying.localizedDescription)")
            }
            lines.append("RESULT: FAILED")
        }

        // Also try direct IP fallback
        lines.append("")
        lines.append("--- Direct IP test ---")
        let directURL = URL(string: "http://192.168.28.54:7860/sdapi/v1/options")!
        do {
            var req = URLRequest(url: directURL)
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            lines.append("Direct IP HTTP Status: \(statusCode)")
            lines.append("Direct IP Response size: \(data.count) bytes")
            lines.append("Direct IP RESULT: SUCCESS")
        } catch {
            lines.append("Direct IP ERROR: \(error.localizedDescription)")
            lines.append("Direct IP RESULT: FAILED")
        }

        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
    }

    private func handleModeSelectionChange(_ newMode: OperaMode) async {
        guard didInitialize else { return }
        guard let activeProjectURL else {
            renderedMode = newMode
            return
        }
        guard newMode != renderedMode else { return }
        let modeSwitchSignpost = PerfSignposts.begin(
            .modeSwitch,
            "\(renderedMode.rawValue)→\(newMode.rawValue)"
        )
        defer { PerfSignposts.end(.modeSwitch, token: modeSwitchSignpost) }
        workspacePrewarmTask?.cancel()
        beginSceneSelectionRestore(for: newMode, projectURL: activeProjectURL)

        // Suspend background watchers on the mode we're leaving so they don't
        // contend with the incoming mode's database and file-system access.
        switch renderedMode {
        case .write: writeController.suspendBackgroundWork()
        case .score: scoreController.suspendBackgroundWork()
        case .mix: mixController.suspendBackgroundWork()
        case .scenes: animateController.suspendBackgroundWork()
        case .characters: animateController.suspendBackgroundWork()
        case .places: animateController.suspendBackgroundWork()
        case .props: animateController.suspendBackgroundWork()
        case .animate: animateController.suspendBackgroundWork()
        case .allImages: animateController.suspendBackgroundWork()
        case .canvas: animateController.suspendBackgroundWork()
        }

        let projectName = activeProjectTitle ?? displayName(for: activeProjectURL)
        loadState = .loading(mode: newMode, projectName: projectName, projectPath: activeProjectURL.path)
        progressCenter.start(
            projectURL: activeProjectURL,
            phaseTitle: "Switching Workspace",
            detail: "Preparing the \(newMode.title) tools for \(projectName)."
        )
        activeProjectLoadError = nil
        await Task.yield()
        guard !Task.isCancelled else {
            clearSceneSelectionRestore(for: newMode, projectURL: activeProjectURL)
            progressCenter.finish(projectURL: activeProjectURL)
            loadState = .idle
            return
        }

        let loadResult = await loadForDisplayTransition(mode: newMode, projectURL: activeProjectURL) { error in
            reconcileBackgroundDisplayLoad(
                error: error,
                mode: newMode,
                projectURL: activeProjectURL
            )
        }

        guard !Task.isCancelled else {
            clearSceneSelectionRestore(for: newMode, projectURL: activeProjectURL)
            progressCenter.finish(projectURL: activeProjectURL)
            loadState = .idle
            return
        }

        switch loadResult {
        case .success:
            finishSceneSelectionRestore(for: newMode, projectURL: activeProjectURL)
            renderedMode = newMode
            scheduleIdleWorkspacePrewarm(for: activeProjectURL, activeMode: newMode)
            // When switching to Animate, ensure Mix is loaded then auto-populate audio
            if newMode == .animate {
                Task {
                    _ = await load(mode: .mix, projectURL: activeProjectURL)
                    await autoPopulateAnimateAudioFromMix()
                }
            }
        case let .failure(error):
            clearSceneSelectionRestore(for: newMode, projectURL: activeProjectURL)
            activeProjectLoadError = error
            selectedMode = renderedMode
        case .timedOut:
            renderedMode = newMode
            scheduleIdleWorkspacePrewarm(for: activeProjectURL, activeMode: newMode)
            progressCenter.update(
                projectURL: activeProjectURL,
                phaseTitle: "Switching Workspace",
                detail: "\(newMode.title) is still loading local project data. Showing the workspace now and applying updates when loading completes."
            )
        }

        progressCenter.finish(projectURL: activeProjectURL)
        loadState = .idle
    }

    @MainActor
    private func load(mode: OperaMode, projectURL: URL) async -> String? {
        switch mode {
        case .write:
            return await writeController.ensureProjectLoaded(projectURL)
        case .score:
            return await scoreController.ensureProjectLoaded(projectURL)
        case .mix:
            return await mixController.ensureProjectLoaded(projectURL)
        case .scenes:
            return await animateController.ensureProjectLoaded(projectURL)
        case .characters:
            return await animateController.ensureProjectLoaded(projectURL)
        case .places:
            return await animateController.ensureProjectLoaded(projectURL)
        case .props:
            return await animateController.ensureProjectLoaded(projectURL)
        case .animate:
            return await animateController.ensureProjectLoaded(projectURL)
        case .allImages:
            return await animateController.ensureProjectLoaded(projectURL)
        case .canvas:
            return await animateController.ensureProjectLoaded(projectURL)
        }
    }

    @MainActor
    private func scheduleIdleWorkspacePrewarm(for projectURL: URL, activeMode: OperaMode) {
        workspacePrewarmTask?.cancel()
        let normalizedURL = projectURL.standardizedFileURL
        let projectPath = normalizedURL.path

        workspacePrewarmTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let canPrewarmScore = await MainActor.run(resultType: Bool.self) {
                activeProjectURL?.standardizedFileURL.path == projectPath && loadState == .idle
            }
            guard canPrewarmScore else {
                return
            }

            if activeMode != .score {
                _ = await load(mode: .score, projectURL: normalizedURL)
            }

            guard !Task.isCancelled else { return }

            if !Self.animateClusterModes.contains(activeMode) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let canPrewarmAnimate = await MainActor.run(resultType: Bool.self) {
                    activeProjectURL?.standardizedFileURL.path == projectPath && loadState == .idle
                }
                guard canPrewarmAnimate else {
                    return
                }
                _ = await load(mode: .scenes, projectURL: normalizedURL)
            }
        }
    }

    @MainActor
    private func loadForDisplayTransition(
        mode: OperaMode,
        projectURL: URL,
        onBackgroundCompletion: (@MainActor (String?) -> Void)? = nil
    ) async -> OperaModeLoadResult {
        guard mode == .score || mode == .animate || mode == .characters || mode == .places || mode == .props || mode == .mix || mode == .scenes || mode == .allImages || mode == .canvas else {
            if let error = await load(mode: mode, projectURL: projectURL) {
                return .failure(error)
            }
            return .success
        }

        let modeLoadTask = Task { await load(mode: mode, projectURL: projectURL) }
        let timeoutNanoseconds: UInt64 = 350_000_000

        let result = await withTaskGroup(of: OperaModeLoadResult.self, returning: OperaModeLoadResult.self) { group in
            group.addTask {
                if let error = await modeLoadTask.value {
                    return .failure(error)
                }
                return .success
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            let first = await group.next() ?? .success
            group.cancelAll()
            return first
        }

        if case .timedOut = result {
            Task {
                let error = await modeLoadTask.value
                if let onBackgroundCompletion {
                    await MainActor.run {
                        onBackgroundCompletion(error)
                    }
                }
            }
        }

        return result
    }

    @MainActor
    private func reconcileBackgroundDisplayLoad(error: String?, mode: OperaMode, projectURL: URL) {
        let normalizedProjectPath = projectURL.standardizedFileURL.path
        if let activeProjectPath = activeProjectURL?.standardizedFileURL.path,
           activeProjectPath != normalizedProjectPath {
            clearSceneSelectionRestore(for: mode, projectURL: projectURL)
            return
        }

        if let error {
            clearSceneSelectionRestore(for: mode, projectURL: projectURL)
            guard renderedMode == mode || selectedMode == mode else { return }
            activeProjectLoadError = error
            return
        }

        finishSceneSelectionRestore(for: mode, projectURL: projectURL)
    }

    private func beginSceneSelectionRestore(for mode: OperaMode, projectURL: URL) {
        let normalizedProjectPath = projectURL.standardizedFileURL.path
        pendingSceneSelectionRestores[mode] = PendingSceneSelectionRestore(
            projectPath: normalizedProjectPath,
            selectionPath: sceneSelectionByProjectPath[normalizedProjectPath]
        )
        setSelectionRestorePending(true, for: mode)
    }

    private func clearSceneSelectionRestore(for mode: OperaMode, projectURL: URL) {
        let normalizedProjectPath = projectURL.standardizedFileURL.path
        guard pendingSceneSelectionRestores[mode]?.projectPath == normalizedProjectPath else { return }
        pendingSceneSelectionRestores.removeValue(forKey: mode)
        setSelectionRestorePending(false, for: mode)
    }

    private func finishSceneSelectionRestore(for mode: OperaMode, projectURL: URL) {
        let normalizedProjectPath = projectURL.standardizedFileURL.path
        guard let pending = pendingSceneSelectionRestores[mode],
              pending.projectPath == normalizedProjectPath else {
            return
        }
        defer {
            pendingSceneSelectionRestores.removeValue(forKey: mode)
            setSelectionRestorePending(false, for: mode)
        }

        guard controllerProjectPath(for: mode) == normalizedProjectPath else { return }
        guard sceneSelectionByProjectPath[normalizedProjectPath] == pending.selectionPath else { return }

        let didApplySelection = applySelectionPath(pending.selectionPath, to: mode)
        let resolvedPath = didApplySelection ? pending.selectionPath : currentSceneSelectionPath(for: mode)

        if let resolvedPath,
           !resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sceneSelectionByProjectPath[normalizedProjectPath] = resolvedPath
        } else {
            sceneSelectionByProjectPath.removeValue(forKey: normalizedProjectPath)
        }
    }

    private func captureSceneSelectionChange(_ path: String?, from mode: OperaMode, projectPath: String?) {
        guard renderedMode == mode else { return }
        guard let projectPath,
              projectPath == activeProjectURL?.standardizedFileURL.path else {
            return
        }
        if let pending = pendingSceneSelectionRestores[mode], pending.projectPath == projectPath {
            return
        }
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            sceneSelectionByProjectPath.removeValue(forKey: projectPath)
            return
        }
        sceneSelectionByProjectPath[projectPath] = path
    }

    private func controllerProjectPath(for mode: OperaMode) -> String? {
        switch mode {
        case .write:
            return writeController.activeProjectPath
        case .score:
            return scoreController.activeProjectPath
        case .mix:
            return mixController.activeProjectPath
        case .scenes:
            return animateController.activeProjectPath
        case .characters:
            return animateController.activeProjectPath
        case .places:
            return animateController.activeProjectPath
        case .props:
            return animateController.activeProjectPath
        case .animate:
            return animateController.activeProjectPath
        case .allImages:
            return animateController.activeProjectPath
        case .canvas:
            return animateController.activeProjectPath
        }
    }

    private func currentSceneSelectionPath(for mode: OperaMode) -> String? {
        switch mode {
        case .write:
            return writeController.currentSelectionPath()
        case .score:
            return scoreController.currentSelectionPath()
        case .mix:
            return mixController.currentSelectionPath()
        case .scenes:
            return animateController.currentSelectionPath()
        case .characters:
            return animateController.currentSelectionPath()
        case .places:
            return animateController.currentSelectionPath()
        case .props:
            return animateController.currentSelectionPath()
        case .animate:
            return animateController.currentSelectionPath()
        case .allImages:
            return nil
        case .canvas:
            return nil
        }
    }

    @discardableResult
    private func applySelectionPath(_ relativePath: String?, to mode: OperaMode) -> Bool {
        switch mode {
        case .write:
            return writeController.applySelectionPath(relativePath)
        case .score:
            return scoreController.applySelectionPath(relativePath)
        case .mix:
            return mixController.applySelectionPath(relativePath)
        case .scenes:
            return animateController.applySelectionPath(relativePath)
        case .characters:
            return animateController.applySelectionPath(relativePath)
        case .places:
            return animateController.applySelectionPath(relativePath)
        case .props:
            return animateController.applySelectionPath(relativePath)
        case .animate:
            return animateController.applySelectionPath(relativePath)
        case .allImages:
            return false
        case .canvas:
            return false
        }
    }

    private func setSelectionRestorePending(_ isPending: Bool, for mode: OperaMode) {
        switch mode {
        case .write, .score, .allImages, .canvas:
            return
        case .mix:
            mixController.setSelectionRestorePending(isPending)
        case .scenes:
            animateController.setSelectionRestorePending(isPending)
        case .characters:
            animateController.setSelectionRestorePending(isPending)
        case .places:
            animateController.setSelectionRestorePending(isPending)
        case .props:
            animateController.setSelectionRestorePending(isPending)
        case .animate:
            animateController.setSelectionRestorePending(isPending)
        }
    }

    private func openProjectFromDisk() async {
        guard !isOpeningFromPanel else { return }
        isOpeningFromPanel = true
        defer { isOpeningFromPanel = false }

        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Choose a local Amira project folder."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = defaultProjectDirectory()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.folder]

        if panel.runModal() == .OK,
           let url = panel.url {
            _ = await openProject(url)
        }
    }

    private func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func hasControlFile(at projectURL: URL) -> Bool {
        controlFileCandidates.contains { candidate in
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(candidate).path)
        }
    }

    private func defaultProjectDirectory() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let candidateProjectRoots: [URL] = [
            home.appendingPathComponent("Amira - A Modern Opera", isDirectory: true),
            home.appendingPathComponent("Amira", isDirectory: true)
        ]

        if let exactMatch = candidateProjectRoots.first(where: { candidate in
            FileManager.default.fileExists(atPath: candidate.path) && Self.hasControlFile(at: candidate)
        }) {
            return exactMatch
        }

        if let existsCandidate = candidateProjectRoots.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return existsCandidate
        }
        return home
    }

    private var activeLoadingProjectPath: String? {
        guard case let .loading(_, _, projectPath) = loadState else { return nil }
        return projectPath
    }

    private var activeLoadingProjectName: String? {
        guard case let .loading(_, projectName, _) = loadState else { return nil }
        return projectName
    }

    private var activeLoadDetail: String? {
        guard case let .loading(mode, _, _) = loadState else { return nil }
        return activeLoadDetail(for: mode)
    }

    private var activeLoadSnapshot: ProjectOpenProgressCenter.Snapshot? {
        progressCenter.snapshot(for: activeLoadingProjectPath)
    }

    private func activeLoadDetail(for mode: OperaMode) -> String {
        if let detail = activeLoadSnapshot?.detail,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }

        let message = loadStatusMessage(for: mode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty, message != "Ready" {
            return message
        }

        switch mode {
        case .write:
            return "Opening the libretto workspace from local files."
        case .score:
            return "Loading playback and orchestration data from local files."
        case .mix:
            return "Loading mix sessions, Suno file browser, and arrangement lanes from local files."
        case .scenes:
            return "Loading scene image generation data."
        case .characters:
            return "Loading character data, inspiration images, and reference workflow assets."
        case .places:
            return "Loading background plates, locations, and set imagery."
        case .props:
            return "Loading prop and object data from local files."
        case .animate:
            return "Loading scene, character, and timeline data from local files."
        case .allImages:
            return "Scanning every generated image across the project."
        case .canvas:
            return "Loading canvas and free-form generation data."
        }
    }

    private func loadStatusMessage(for mode: OperaMode) -> String {
        switch mode {
        case .write:
            return writeController.loadStatusMessage
        case .score:
            return scoreController.loadStatusMessage
        case .mix:
            return mixController.loadStatusMessage
        case .scenes:
            return animateController.loadStatusMessage
        case .characters:
            return animateController.loadStatusMessage
        case .places:
            return animateController.loadStatusMessage
        case .props:
            return animateController.loadStatusMessage
        case .animate:
            return animateController.loadStatusMessage
        case .allImages:
            return animateController.loadStatusMessage
        case .canvas:
            return animateController.loadStatusMessage
        }
    }

    private func modeAccent(for mode: OperaMode) -> Color {
        switch mode {
        case .write:
            return OperaChromeTheme.accent
        case .score:
            return Color(red: 0.72, green: 0.78, blue: 0.46)
        case .mix:
            return Color(red: 0.77, green: 0.49, blue: 0.26)
        case .scenes:
            return Color(red: 0.72, green: 0.58, blue: 0.82)
        case .characters:
            return Color(red: 0.55, green: 0.72, blue: 0.82)
        case .places:
            return Color(red: 0.62, green: 0.76, blue: 0.55)
        case .props:
            return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .animate:
            return Color(red: 0.72, green: 0.58, blue: 0.82)
        case .allImages:
            return Color(red: 0.66, green: 0.66, blue: 0.78)
        case .canvas:
            return Color(red: 0.72, green: 0.58, blue: 0.82)
        }
    }

    private func saveActiveWorkspace() {
        guard activeProjectURL != nil else { return }

        switch renderedMode {
        case .write:
            writeController.save()
        case .score:
            scoreController.save()
        case .mix:
            mixController.save()
        case .scenes:
            animateController.save()
        case .characters:
            animateController.save()
        case .places:
            animateController.save()
        case .props:
            animateController.save()
        case .animate:
            animateController.save()
        case .allImages:
            animateController.save()
        case .canvas:
            animateController.save()
        }
    }
}

private enum RuntimeError: LocalizedError {
    case projectNotFound
    case missingControlFile
    case unsupportedSelection

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "Could not find the selected project."
        case .missingControlFile:
            return "This folder does not look like an OWP project. Expected Metadata/project.json or project.json."
        case .unsupportedSelection:
            return "Please pick an OWP project folder."
        }
    }
}

@available(macOS 26.0, *)
private struct OperaModeButton: View {
    let mode: OperaMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(mode.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(mode.subtitle)
    }

    private var backgroundColor: Color {
        if isSelected {
            return OperaChromeTheme.selection
        }
        if isHovered {
            return OperaChromeTheme.hover
        }
        return .clear
    }

    private var borderColor: Color {
        isSelected ? OperaChromeTheme.accent.opacity(0.26) : Color.clear
    }
}

@available(macOS 26.0, *)
private struct OperaRecentProjectsSheet: View {
    let recentProjects: [URL]
    let activeProjectURL: URL?
    let isLoading: Bool
    let openingProjectPath: String?
    let loadingProjectName: String?
    let loadingStatusMessage: String?
    let loadingSnapshot: ProjectOpenProgressCenter.Snapshot?
    let onOpenProject: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            OperaChromeTheme.workspaceBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Projects")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text("Pick a recent project to jump straight back in.")
                        .font(.system(size: 13))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                if isLoading, let loadingProjectName {
                    OperaProjectLoadingPanel(
                        title: "Opening \(loadingProjectName)",
                        message: loadingStatusMessage ?? "Opening from local disk.",
                        accent: OperaChromeTheme.accent,
                        snapshot: loadingSnapshot
                    )
                }

                if recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("No recent projects yet.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        Text("Open a local OWP project folder from File > Open Project and it will appear here next time.")
                            .font(.system(size: 12))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OperaChromeTheme.panelBackground)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(recentProjects, id: \.path) { url in
                                Button {
                                    onOpenProject(url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Image(systemName: rowSymbolName(for: url))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(rowSymbolColor(for: url))
                                            Text(url.deletingPathExtension().lastPathComponent)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(OperaChromeTheme.textPrimary)
                                                .lineLimit(1)
                                        }
                                        Text(url.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(rowBackgroundColor(for: url))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                rowBorderColor(for: url),
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }

                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isLoading)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func rowSymbolName(for url: URL) -> String {
        if openingProjectPath == url.path {
            return "arrow.trianglehead.2.clockwise"
        }
        if activeProjectURL?.path == url.path {
            return "checkmark.circle.fill"
        }
        return "music.quarternote.3"
    }

    private func rowSymbolColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.warning
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.success
        }
        return OperaChromeTheme.textSecondary
    }

    private func rowBackgroundColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.accentMuted
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.selection
        }
        return OperaChromeTheme.panelBackground
    }

    private func rowBorderColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.accent.opacity(0.32)
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.accent.opacity(0.22)
        }
        return OperaChromeTheme.stroke
    }
}

@available(macOS 26.0, *)
private struct OperaProjectLoadingPanel: View {
    let title: String
    let message: String
    let accent: Color
    let snapshot: ProjectOpenProgressCenter.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(snapshot?.phaseTitle ?? "Project Load In Progress")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .tracking(1.2)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = snapshot?.progressSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
            }

            OperaLoadBar(accent: accent, snapshot: snapshot)

            if let currentItemPath = snapshot?.currentItemPath {
                Text(currentItemPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text("The workspace will update as soon as local indexing finishes.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)

                Spacer()

                if let snapshot {
                    HStack(spacing: 8) {
                        if let fraction = snapshot.fractionCompleted {
                            Text(String(format: "%.0f%%", fraction * 100))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(snapshot.elapsedDescription(referenceDate: timeline.date))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OperaChromeTheme.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
    }
}

@available(macOS 26.0, *)
private struct OperaLoadBar: View {
    let accent: Color
    let snapshot: ProjectOpenProgressCenter.Snapshot?

    var body: some View {
        if let fraction = snapshot?.fractionCompleted {
            GeometryReader { geometry in
                let clamped = min(max(fraction, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.stroke)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.35),
                                    accent.opacity(0.95),
                                    Color.white.opacity(0.45),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * clamped, 8))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule(style: .continuous))
        } else {
            OperaIndeterminateLoadBar(accent: accent)
        }
    }
}

@available(macOS 26.0, *)
private struct OperaIndeterminateLoadBar: View {
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let width = max(geometry.size.width, 1)
                let cycle = timeline.date.timeIntervalSinceReferenceDate
                let progress = cycle.truncatingRemainder(dividingBy: 1.8) / 1.8
                let capsuleWidth = max(88, width * 0.28)
                let travel = width + capsuleWidth
                let offset = progress * travel - capsuleWidth

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.stroke)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.22),
                                    accent.opacity(0.95),
                                    Color.white.opacity(0.55),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: capsuleWidth)
                        .offset(x: offset)
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule(style: .continuous))
    }
}

private struct OperaWindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var isRepositioningTrafficLights = false


        func attach(to view: NSView) {
            self.view = view
            Task { @MainActor [weak self] in
                self?.installIfPossible()
            }
        }

        private func installIfPossible() {
            guard let view else { return }
            guard let resolvedWindow = view.window else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(20))
                    self?.installIfPossible()
                }
                return
            }
            guard window !== resolvedWindow else { return }

            window = resolvedWindow
            applyConfiguration()
            configureObservers(for: resolvedWindow)

            applyBurst()
        }

        private func applyConfiguration() {
            guard let window else { return }
            window.minSize = NSSize(width: 760, height: 560)
            window.isOpaque = false
            window.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.96)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            repositionTrafficLights()
        }

        /// Vertically centers the traffic light buttons to align with content
        /// in our 36px custom tab bar.
        ///
        /// Measured geometry (non-flipped NSTitlebarView, 32px tall):
        ///   - Default button y = 9 (centered in 32px: (32-14)/2 = 9)
        ///   - Our tab bar is 36px, so text center is at 18px from top
        ///   - Target button center = 18px from top = 14px from bottom
        ///   - Target button y = 14 - 7 = 7 (non-flipped, y from bottom)
        ///
        /// Non-flipped coords: y=0 at bottom, decreasing y moves DOWN on screen.
        private func repositionTrafficLights() {
            guard !isRepositioningTrafficLights else { return }
            isRepositioningTrafficLights = true
            defer { isRepositioningTrafficLights = false }

            guard let window else { return }
            let tabBarHeight: CGFloat = 36
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

            for type in buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                guard let superview = button.superview else { continue }

                let buttonHeight = button.frame.height
                let superviewHeight = superview.bounds.height

                let targetY: CGFloat
                if superview.isFlipped {
                    // Flipped: y=0 at top, increasing y moves DOWN
                    targetY = (tabBarHeight - buttonHeight) / 2
                } else {
                    // Non-flipped: y=0 at bottom, decreasing y moves DOWN
                    // We want button center at tabBarHeight/2 from the top of the superview.
                    // From bottom: center = superviewHeight - tabBarHeight/2
                    // Origin = center - buttonHeight/2
                    targetY = superviewHeight - (tabBarHeight + buttonHeight) / 2
                }

                if abs(button.frame.origin.y - targetY) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
                }
            }
        }

        private func configureObservers(for window: NSWindow) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            // Window-level events that may reset traffic light positions
            let windowNames: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEndSheetNotification,
                NSWindow.didResizeNotification
            ]

            for name in windowNames {
                let observer = NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.applyConfiguration()
                        self?.applyBurst()
                    }
                }
                observers.append(observer)
            }

            // Observe the titlebar view's frame changes — macOS resets button
            // positions during layout, so we re-apply after each change.
            if let closeButton = window.standardWindowButton(.closeButton),
               let titlebarView = closeButton.superview {
                titlebarView.postsFrameChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: titlebarView,
                    queue: .main
                ) { [weak self] _ in
                    // Defer to run after macOS completes its own layout pass
                    DispatchQueue.main.async { [weak self] in
                        self?.repositionTrafficLights()
                    }
                }
                observers.append(observer)
            }
        }



        private func applyBurst() {
            for delay in [0.02, 0.08, 0.15, 0.30, 0.50] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.applyConfiguration()
                }
            }
        }
    }
}
