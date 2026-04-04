import SwiftUI
import ProjectKit

// MARK: - Public Workspace (consumed by OperaShellView)

@available(macOS 26.0, *)
public struct Animate3DWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            Animate3DWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening 3D Animate" : "Refreshing 3D Animate",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

// MARK: - Three-Panel Content

@available(macOS 26.0, *)
private struct Animate3DWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @StateObject private var productionCoordinator: Animate3DProductionCoordinator
    @State private var threeDScenario = Animate3DPreviewScenario.empty
    @State private var threeDScenarioSignature = ""
    @State private var threeDHarnessState = Animate3DTestHarnessState()
    @State private var selectedDebugGuide: Animate3DDebugGuideSelection?
    @State private var renderSnapshot = Animate3DFrameSnapshot.empty
    @State private var selectedShotIndex: Int?
    @State private var cachedAssetBridgeStatuses: [Animate3DCharacterAssetBridgeStatus] = []
    @State private var cachedPackageCutoutPlans: [Animate3DCharacterPackageCutoutPlan] = []

    private let scenarioAdapter = Animate3DSceneAdapter()
    private let assetBridgeService = Animate3DAssetBridgeService()
    private let packageCutoutService = Animate3DPackageCutoutService()

    init(store: AnimateStore) {
        self.store = store
        _productionCoordinator = StateObject(wrappedValue: Animate3DProductionCoordinator(store: store))
    }

    private var shotSeedingService: AnimateSceneShotSeedingService {
        AnimateSceneShotSeedingService(store: store)
    }

    @AppStorage("novotro.animate3d.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.animate3d.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.animate3d.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.animate3d.inspector.width") private var inspectorWidth: Double = 320
    @AppStorage("novotro.animate3d.showDirectionEditor") private var showDirectionEditor = false

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var scenarioSignature: String {
        makeScenarioSignature()
    }

    private var renderFrame: Int {
        let usesSharedTransport = threeDScenario.sourceKind == .selectedTimeline
        let rawFrame = usesSharedTransport ? store.currentFrame : threeDHarnessState.previewFrame
        return min(max(0, rawFrame), max(0, threeDScenario.totalFrames - 1))
    }

    private var renderPacketTaskKey: String {
        [
            String(threeDScenario.hashValue),
            String(renderFrame),
            threeDHarnessState.rendererMode.rawValue,
            threeDHarnessState.playbackStyle.rawValue,
            String(threeDHarnessState.showsPackageCutouts),
            String(threeDHarnessState.isPlaying)
        ].joined(separator: "|")
    }

    private var productionTaskKey: String {
        [
            scenarioSignature,
            threeDHarnessState.rendererMode.rawValue,
            store.selectedSceneID?.uuidString ?? "none",
            String(store.currentSongData?.extractLyrics().hashValue ?? 0),
            String(store.fps)
        ].joined(separator: "|")
    }

    private var usesProductionPreview: Bool {
        threeDHarnessState.rendererMode == .productionEngine &&
            store.selectedScene != nil &&
            threeDScenario.sourceKind != .fixture
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "cube",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
        .task(id: scenarioSignature) {
            refreshScenarioIfNeeded()
        }
        .task(id: renderPacketTaskKey) {
            refreshRenderPacket()
        }
        .task(id: productionTaskKey) {
            await refreshProductionPreviewIfNeeded()
        }
        .task(id: store.selectedSceneID) {
            guard let scene = store.selectedScene else { return }
            await prepareSelectedSceneFor3D(scene)
        }
        .onChange(of: threeDHarnessState.isPlaying) { _, isPlaying in
            if isPlaying {
                store.audioPlayer.play()
            } else {
                store.audioPlayer.pause()
            }
        }
        .sheet(isPresented: $store.show3DExportSheet) {
            Scene3DExportSheet(
                renderer: productionCoordinator.renderer,
                scenario: threeDScenario
            )
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    OperaChromeFlatPane(
                        headerPadding: OperaChromeSidebarMetrics.headerPadding
                    ) {
                        OperaChromePaneHeader(
                            eyebrow: "3D ANIMATE",
                            title: "Scenes",
                            subtitle: "\(store.scenes.count) staged"
                        ) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showDirectionEditor.toggle()
                                }
                            } label: {
                                Image(systemName: showDirectionEditor ? "chevron.down.circle.fill" : "square.text.square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(showDirectionEditor ? OperaChromeTheme.textPrimary : OperaChromeTheme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help(showDirectionEditor ? "Hide Direction Editor" : "Show Direction Editor")
                        }
                    } content: {
                        SidebarView(store: store)
                    }
                    .frame(maxHeight: showDirectionEditor ? .infinity : .infinity)

                    if showDirectionEditor {
                        Divider()
                        SceneDirectionEditorView(store: store)
                            .frame(minHeight: 320)
                    }
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("3D ANIMATE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(store.selectedScene?.name ?? "3D scene workspace")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Picker("Renderer", selection: $threeDHarnessState.rendererMode) {
                        ForEach(Animate3DRendererMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer(minLength: 10)
                }
            } content: {
                VStack(spacing: 0) {
                    Group {
                        if usesProductionPreview {
                            Animate3DProductionPreviewView(
                                store: store,
                                harnessState: threeDHarnessState,
                                scenario: threeDScenario,
                                status: productionCoordinator.status,
                                renderer: productionCoordinator.renderer
                            )
                        } else {
                            Animate3DTestHarnessView(
                                store: store,
                                harnessState: threeDHarnessState,
                                scenario: threeDScenario,
                                snapshot: renderSnapshot,
                                assetBridgeStatuses: cachedAssetBridgeStatuses,
                                packageCutoutPlans: cachedPackageCutoutPlans,
                                selectedDebugGuide: $selectedDebugGuide
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let scene = store.selectedScene, !scene.shots.isEmpty {
                        Divider()
                        ShotFilmstripView(store: store, shots: scene.shots, selectedShotIndex: $selectedShotIndex)
                        if let idx = selectedShotIndex, idx < scene.shots.count {
                            Divider()
                            ShotProductionStripView(store: store, scene: scene, shot: scene.shots[idx], shotIndex: idx)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "3D Animate"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    Animate3DInspectorView(
                        store: store,
                        scenario: threeDScenario,
                        snapshot: renderSnapshot,
                        assetBridgeStatuses: cachedAssetBridgeStatuses,
                        packageCutoutPlans: cachedPackageCutoutPlans,
                        selectedDebugGuide: selectedDebugGuide,
                        productionStatus: usesProductionPreview ? productionCoordinator.status : nil,
                        productionCharacterStatuses: usesProductionPreview ? productionCoordinator.renderer.characterPerformanceStatuses : [],
                        harnessState: threeDHarnessState
                    )
                }
                .frame(width: max(inspectorWidth, 320))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func refreshScenarioIfNeeded() {
        let signature = scenarioSignature
        guard signature != threeDScenarioSignature else { return }

        let scenario = scenarioAdapter.makeScenario(store: store, mode: threeDHarnessState.scenarioMode)
        let scenarioChanged = scenario.id != threeDScenario.id
        let shouldResetFrame = threeDHarnessState.autoResetOnScenarioChange && scenarioChanged

        if scenarioChanged {
            threeDHarnessState.stopPlayback(syncing: store)
            selectedDebugGuide = nil
        }

        threeDScenarioSignature = signature
        threeDScenario = scenario

        threeDHarnessState.prepareTransport(
            in: store,
            scenario: scenario,
            resetFrame: shouldResetFrame
        )
    }

    private func refreshRenderPacket() {
        store.syncAudioToCurrentFrame()
        if usesProductionPreview {
            productionCoordinator.render(frame: renderFrame)
        }

        let snapshot = scenarioAdapter.frameSnapshot(
            for: threeDScenario,
            store: store,
            rawFrame: renderFrame,
            playbackStyle: threeDHarnessState.playbackStyle
        )
        renderSnapshot = snapshot

        // Skip expensive asset-bridge and package-cutout computation while
        // playing back -- these are display-only diagnostics and recomputing
        // them every frame is the largest contributor to scrub/playback jitter.
        // They are refreshed automatically once playback stops (the task
        // re-fires because renderPacketTaskKey changes while isPlaying is
        // no longer true).
        guard !threeDHarnessState.isPlaying else { return }

        cachedAssetBridgeStatuses = assetBridgeService.bridgeStatuses(
            for: threeDScenario,
            snapshot: snapshot,
            store: store
        )
        cachedPackageCutoutPlans = threeDHarnessState.showsPackageCutouts
            ? packageCutoutService.cutoutPlans(
                for: threeDScenario,
                snapshot: snapshot,
                store: store
            )
            : []
    }

    private func refreshProductionPreviewIfNeeded() async {
        guard usesProductionPreview,
              let scene = store.selectedScene else {
            return
        }

        await productionCoordinator.refresh(
            scene: scene,
            lyrics: currentLyrics(for: scene),
            scenario: threeDScenario
        )
    }

    private func prepareSelectedSceneFor3D(_ scene: AnimationScene) async {
        await store.loadSongData(for: scene)
        store.loadSceneAudio()
        autoSeedShotsIfNeeded(for: scene)
        refreshScenarioIfNeeded()
    }

    private func autoSeedShotsIfNeeded(for scene: AnimationScene) {
        guard scene.id == store.selectedSceneID,
              scene.shots.isEmpty else {
            return
        }

        let lyrics = currentLyrics(for: scene)
        guard !lyrics.isEmpty else { return }

        let parseResult = SceneDirectionParser.parse(lyrics)
        let seeded = shotSeedingService.seededShots(
            for: scene,
            songData: store.currentSongData,
            parseResult: parseResult
        )

        guard !seeded.isEmpty else { return }

        store.replaceSelectedSceneShots(seeded)
        store.save()
        store.statusMessage = "Loaded \(seeded.count) scene-local shots for 3D Animate"
    }

    private func currentLyrics(for scene: AnimationScene) -> String {
        guard scene.id == store.selectedSceneID,
              let text = store.currentSongData?.extractLyrics() else {
            return ""
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeScenarioSignature() -> String {
        guard let scene = store.selectedScene else {
            return "scene:none|\(threeDHarnessState.scenarioMode.rawValue)|\(store.fps)"
        }

        let trackSignature = scene.tracks.values
            .map { "\($0.name):\($0.keyframes.count)" }
            .sorted()
            .joined(separator: ",")
        let shotSignature = scene.shots
            .map { "\($0.name):\($0.startFrame)-\($0.endFrame):\($0.cameraShot?.rawValue ?? "nil")" }
            .joined(separator: ",")
        let objectSignature = scene.objectSetups
            .map { "\($0.objectName):\($0.enterFrame)-\($0.exitFrame.map(String.init) ?? "nil")" }
            .joined(separator: ",")
        let characterSignature = scene.characterIDs.map(\.uuidString).joined(separator: ",")
        let lyricsSignature = store.currentSongData?.lyricsText.map { String($0.hashValue) } ?? "nil"
        let tempoSignature = store.currentSongData?.tempoEvents.first.map { String($0.bpm) } ?? "nil"

        return [
            scene.id.uuidString,
            scene.name,
            threeDHarnessState.scenarioMode.rawValue,
            String(store.fps),
            scene.backgroundID?.uuidString ?? "no-bg",
            characterSignature,
            objectSignature,
            trackSignature,
            shotSignature,
            lyricsSignature,
            tempoSignature
        ].joined(separator: "|")
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
