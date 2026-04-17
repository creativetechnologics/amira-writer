import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
public final class AnimateWorkspaceController: ObservableObject {
    let store = AnimateStore()
    private var loadedProjectPath: String?
    private var loadRequestID: UInt64 = 0
    /// Most recent project URL the host has selected. Written from Opera's
    /// shell on every project switch so the loopback API can activate the
    /// correct project when an external request arrives before any UI mode
    /// has triggered lazy loading.
    private var apiHostProjectURL: URL?
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?
    @Published public private(set) var isSelectionRestorePending = false

    public init() {
        store.disableExternalFileWatch = true
        _ = RunPodLORAService.shared
        _ = RunPodMouthSyncService.shared
        RunPodLORAService.shared.setActiveAnimateURL(store.animateURL)
        RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
        activeProjectPath = store.owpURL?.standardizedFileURL.path
        selectedScenePath = currentSelectionPath()
        saveIndicator = store.saveIndicator
        observeSaveIndicator()
        observeSelectionPath()
        // Loopback HTTP API for external agents (curated Places generation, etc.).
        // Idempotent; safe if the shell re-inits or AnimateApp runs standalone.
        AnimateAPIServer.startIfNeeded(store: store)
        // Let the API hydrate the active project on demand, bypassing Opera's
        // lazy mode-switch gate. `apiHostProjectURL` is refreshed from the shell.
        AnimateAPIServer.projectActivator = { [weak self] in
            guard let self else { return }
            guard let url = self.apiHostProjectURL else { return }
            _ = await self.ensureProjectLoaded(url)
        }
    }

    /// Called by the Opera shell whenever the active project URL changes so
    /// the loopback API can hydrate the correct project without waiting for a
    /// UI mode switch into Places/Animate.
    public func setAPIHostProjectURL(_ url: URL?) {
        apiHostProjectURL = url
    }

    public var isDirty: Bool { store.saveIndicator == .unsavedChanges }

    public var drawThingsHost: String { store.drawThingsPlaceConfig.apiHost }
    public var drawThingsPort: Int { store.drawThingsPlaceConfig.apiPort }

    /// Whether any RunPod-backed Animate workflow currently has an active pod.
    public var isRunPodActive: Bool {
        RunPodLORAService.shared.podStatus.isActive || RunPodMouthSyncService.shared.podStatus.isActive
    }

    /// Manual emergency stop for all active RunPod-backed Animate jobs.
    public func terminateRunPodPods() {
        RunPodLORAService.shared.terminateAllPods()
        RunPodMouthSyncService.shared.terminateAllPods()
    }

    /// Diagnostic: run a codex CLI test to verify the prompt service works.
    /// Returns the prompt string on success, throws on failure.
    public static func runCodexDiagnostic() async throws -> String {
        try await ImagineScenePromptService.runDiagnosticTest()
    }

    public func suspendBackgroundWork() {
        store.suspendBackgroundWork()
    }

    public func save() {
        store.save()
    }

    /// Returns the title-bar Gemini activity badge bound to this workspace's store.
    /// Exposed here so the top-level Opera shell can host it without needing
    /// direct access to the internal AnimateStore type.
    public func geminiStatusBadgeView() -> some View {
        GeminiStatusBadge(store: store)
    }

    /// Returns the global-settings gear button bound to this workspace's store.
    public func globalSettingsGearView() -> some View {
        GlobalSettingsGear(store: store)
    }

    /// Returns the project-wide All Images page bound to this workspace's store.
    /// Hosted by the Opera shell so users can browse every image in the project
    /// (Places, Canvas, Characters, Scene Shots, Map 3D Captures) from one surface.
    public func allProjectImagesPageView(onDismiss: @escaping () -> Void) -> some View {
        AllProjectImagesPageView(store: store, onDismiss: onDismiss)
    }

    public func setSelectionRestorePending(_ isPending: Bool) {
        isSelectionRestorePending = isPending
    }

    @discardableResult
    public func applySelectionPath(_ relativePath: String?) -> Bool {
        guard let relativePath,
              let scene = store.scenes.first(where: { $0.owpSongPath == relativePath }) else {
            return false
        }
        if store.selectedSceneID != scene.id {
            store.selectedSceneID = scene.id
        }
        return true
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        loadRequestID &+= 1
        let requestID = loadRequestID
        if loadedProjectPath == normalizedPath,
           store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            activeProjectPath = normalizedPath
            RunPodLORAService.shared.setActiveAnimateURL(store.animateURL)
            RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
            store.resumeBackgroundWork()
            // Refresh scene data from disk so authored shots survive re-entry
            store.reloadScenesFromDisk()
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Animate workspace from disk…"
        defer {
            if requestID == loadRequestID {
                isLoadingProject = false
            }
        }

        if store.isLoadingProject,
           store.owpURL?.standardizedFileURL.path != normalizedPath {
            while store.isLoadingProject {
                guard requestID == loadRequestID else { return nil }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        await Task.yield()
        guard requestID == loadRequestID else { return nil }
        await store.openOWP(url: normalizedURL)
        while store.isLoadingProject {
            guard requestID == loadRequestID else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard requestID == loadRequestID else { return nil }
        loadStatusMessage = store.statusMessage

        if store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            loadedProjectPath = normalizedPath
            activeProjectPath = normalizedPath
            RunPodLORAService.shared.setActiveAnimateURL(store.animateURL)
            RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
            return nil
        }

        let message = store.loadErrorMessage ?? store.statusMessage
        loadedProjectPath = store.owpURL?.standardizedFileURL.path
        activeProjectPath = store.owpURL?.standardizedFileURL.path

        return message
    }

    public func currentSelectionPath() -> String? {
        store.selectedScene?.owpSongPath
    }

    public func setDefaultAudioPath(_ path: String?, for sceneID: UUID) {
        store.setDefaultAudioPath(path, for: sceneID)
    }

    public func songPath(for sceneID: UUID) -> String? {
        store.scenes.first(where: { $0.id == sceneID })?.owpSongPath
    }

    /// Explicitly reload Animate/scenes.json from disk, refreshing authored shot data.
    public func reloadScenesFromDisk() {
        store.reloadScenesFromDisk()
    }

    /// Returns all scenes as (id, owpSongPath, hasAudio) tuples for cross-module coordination.
    public func sceneAudioStatus() -> [(id: UUID, songPath: String, hasAudio: Bool)] {
        store.scenes.map { scene in
            (id: scene.id, songPath: scene.owpSongPath, hasAudio: !(scene.defaultAudioPath ?? "").isEmpty)
        }
    }

    private func observeSaveIndicator() {
        withObservationTracking {
            _ = store.saveIndicator
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saveIndicator = self.store.saveIndicator
                self.observeSaveIndicator()
            }
        }

        saveIndicator = store.saveIndicator
    }

    private func observeSelectionPath() {
        withObservationTracking {
            _ = currentSelectionPath()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedScenePath = self.currentSelectionPath()
                self.observeSelectionPath()
            }
        }

        selectedScenePath = currentSelectionPath()
    }
}

// MARK: - Public Workspace (consumed by OperaShellView)

@available(macOS 26.0, *)
public struct AnimateWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            AnimateWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Animate" : "Refreshing Animate",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

// MARK: - Three-Panel Content

@available(macOS 26.0, *)
private struct AnimateWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var selectedShotIndex: Int?
    @StateObject private var waveformCache = AnimateAudioWaveformCache()

    @AppStorage("novotro.animate.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.animate.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.animate.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.animate.inspector.width") private var inspectorWidth: Double = 320

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var selectedShot: AnimationSceneShot? {
        guard let scene = store.selectedScene,
              let idx = selectedShotIndex,
              idx < scene.shots.count else { return nil }
        return scene.shots[idx]
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "sparkles.tv",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            // MARK: Left Sidebar
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ANIMATE",
                        title: "Scenes",
                        subtitle: "\(store.scenes.count) staged"
                    ) {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = false
                            }
                        }
                    }
                } content: {
                    SidebarView(store: store)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            // MARK: Main Content
            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    if !sidebarVisible {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = true
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ANIMATE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(store.selectedScene?.name ?? "Vidu animation workspace")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    if !inspectorVisible {
                        OperaChromeActionButton(systemImage: "sidebar.right") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = true
                            }
                        }
                    }
                }
            } content: {
                VStack(spacing: 0) {
                    // Video player area — 16:9 placeholder (TODO: AVPlayer integration)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if let shot = selectedShot,
                               let videoPath = shot.shotFrameGeneration?.viduOutputPath {
                                // TODO: AVPlayer integration
                                Text("Video: \(videoPath)")
                                    .foregroundStyle(.white)
                                    .font(.caption)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "film")
                                        .font(.largeTitle)
                                        .foregroundStyle(.white.opacity(0.3))
                                    Text("Select a shot and generate video")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                        }
                        .padding(16)

                    // Filmstrip + production strip for selected scene
                    if let scene = store.selectedScene, !scene.shots.isEmpty {
                        Divider()
                        ShotFilmstripView(store: store, shots: scene.shots, selectedShotIndex: $selectedShotIndex)
                        if let idx = selectedShotIndex, idx < scene.shots.count {
                            Divider()
                            ShotProductionStripView(store: store, scene: scene, shot: scene.shots[idx], shotIndex: idx)
                        }
                    }

                    // Audio waveform track — always visible when a scene is selected
                    if let scene = store.selectedScene {
                        Divider()
                        AudioWaveformTrackView(
                            store: store,
                            scene: scene,
                            waveformCache: waveformCache
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Right Inspector
            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Animate"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    AnimateViduInspectorView(store: store, selectedShot: selectedShot)
                }
                .frame(width: max(inspectorWidth, 320))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 320),
            600
        )
    }
}

// MARK: - Vidu Inspector Panel

@available(macOS 26.0, *)
private struct AnimateViduInspectorView: View {
    @Bindable var store: AnimateStore
    let selectedShot: AnimationSceneShot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Shot details
                if let shot = selectedShot {
                    shotDetailsSection(shot: shot)
                    Divider()
                    viduQueueSection(shot: shot)
                } else {
                    Text("Select a shot in the filmstrip to see details.")
                        .font(.system(size: 12))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .padding()
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func shotDetailsSection(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHOT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(shot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                if let camera = shot.cameraShot {
                    Label(camera.rawValue, systemImage: "camera")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                HStack(spacing: 4) {
                    Text("Frames \(shot.startFrame)–\(shot.endFrame)")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func viduQueueSection(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VIDU STATUS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            if let fg = shot.shotFrameGeneration {
                VStack(alignment: .leading, spacing: 4) {
                    statusRow(label: "First frame", ready: fg.firstFrameImagePath != nil)
                    statusRow(label: "Last frame", ready: fg.lastFrameImagePath != nil)
                    statusRow(label: "Video output", ready: fg.viduOutputPath != nil)

                    if let videoPath = fg.viduOutputPath {
                        Text(videoPath)
                            .font(.system(size: 10))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Text("No generation data yet. Use the production strip to set up first/last frames and generate video.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(label: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(ready ? Color.green : OperaChromeTheme.textTertiary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
        }
    }
}

@available(macOS 26.0, *)
struct AnimateWorkspaceLoadOverlay: View {
    let title: String
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OperaChromeTheme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        }
    }
}
