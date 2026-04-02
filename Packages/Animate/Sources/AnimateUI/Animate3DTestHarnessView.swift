import AppKit
import SceneKit
import SwiftUI
import simd
import ProjectKit

@available(macOS 26.0, *)
struct Animate3DTestHarnessView: View {
    @Bindable var store: AnimateStore
    @Bindable var harnessState: Animate3DTestHarnessState
    var scenario: Animate3DPreviewScenario
    var snapshot: Animate3DFrameSnapshot
    var assetBridgeStatuses: [Animate3DCharacterAssetBridgeStatus]
    var packageCutoutPlans: [Animate3DCharacterPackageCutoutPlan]
    @Binding var selectedDebugGuide: Animate3DDebugGuideSelection?

    private let adapter = Animate3DSceneAdapter()
    @State private var cachedMotionTrails: [Animate3DMotionTrail] = []
    @State private var cachedCameraPathPoints: [SIMD3<Double>] = []
    @State private var cachedCameraFocusPoints: [SIMD3<Double>] = []
    @State private var cachedShotAnchors: [Animate3DShotAnchor] = []
    @State private var debugOrbitRecenterSeed: Int = 0
    @State private var hoveredDebugGizmo: Animate3DDebugGizmo?
    @State private var selectedDebugGizmo: Animate3DDebugGizmo?
    @State private var hoveredDebugGuide: Animate3DDebugGuideSelection?

    private var usesSharedTransport: Bool {
        scenario.sourceKind == .selectedTimeline
    }

    private var effectiveRawFrame: Int {
        usesSharedTransport
            ? clampedFrame(store.currentFrame)
            : clampedFrame(harnessState.previewFrame)
    }

    private var isTransportPlaying: Bool {
        usesSharedTransport ? store.isPlaying : harnessState.isPlaying
    }

    private var transportBadgeTitle: String {
        usesSharedTransport ? "Shared Transport" : "Local Preview"
    }

    private var motionTrails: [Animate3DMotionTrail] {
        harnessState.showsMotionPaths ? cachedMotionTrails : []
    }

    private var cameraPathPoints: [SIMD3<Double>] {
        harnessState.showsCameraPath ? cachedCameraPathPoints : []
    }

    private var cameraFocusPoints: [SIMD3<Double>] {
        harnessState.showsCameraPath ? cachedCameraFocusPoints : []
    }

    private var shotAnchors: [Animate3DShotAnchor] {
        harnessState.showsShotLabels ? cachedShotAnchors : []
    }

    private var visiblePoseReadouts: [(name: String, profile: Animate3DPlaceholderPoseProfile)] {
        snapshot.characters
            .filter { $0.visible && $0.opacity > 0.001 }
            .map { ($0.name, Animate3DPlaceholderPoseProfile.evaluate($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleAssetBridgeReadouts: [Animate3DCharacterAssetBridgeStatus] {
        assetBridgeStatuses
            .filter(\.isVisibleAtCurrentFrame)
            .prefix(3)
            .map { $0 }
    }

    private var backgroundImageURL: URL? {
        // Try sync packet's approved image path first (live scene data)
        if let imagePath = scenario.syncPacket?.backgroundApprovedImagePath {
            if let url = store.resolvedCharacterAssetURL(for: imagePath) {
                return url
            }
        }
        // Fall back to looking up by backgroundName in the store's backgrounds
        if let bgName = scenario.backgroundName,
           let bg = store.backgrounds.first(where: {
               $0.name.lowercased() == bgName.lowercased()
           }),
           let approvedPath = bg.resolvedApprovedImagePath {
            return store.resolvedCharacterAssetURL(for: approvedPath)
        }
        return nil
    }

    private var activeCutoutCharacterCount: Int {
        packageCutoutPlans.count
    }

    private var bridgeReadyCount: Int {
        assetBridgeStatuses.filter { $0.readiness == .ready }.count
    }

    private var bridgePartialCount: Int {
        assetBridgeStatuses.filter { $0.readiness == .partial }.count
    }

    private var bridgeMissingCount: Int {
        assetBridgeStatuses.filter { $0.readiness == .missing }.count
    }

    private var bridgeUnavailableCount: Int {
        assetBridgeStatuses.filter { $0.readiness == .unavailable }.count
    }

    private var motionTrailTaskKey: String {
        [
            String(scenario.hashValue),
            String(scenario.totalFrames),
            harnessState.playbackStyle.rawValue,
            String(harnessState.showsMotionPaths)
        ].joined(separator: "|")
    }

    private var cameraPathTaskKey: String {
        [
            String(scenario.hashValue),
            String(scenario.totalFrames),
            harnessState.playbackStyle.rawValue,
            String(harnessState.showsCameraPath)
        ].joined(separator: "|")
    }

    private var shotAnchorTaskKey: String {
        [
            String(scenario.hashValue),
            String(scenario.shotMarkers.hashValue),
            String(harnessState.showsShotLabels)
        ].joined(separator: "|")
    }

    private var frameSliderBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveRawFrame) },
            set: { setFrame(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            previewSurface

            Divider()

            footerControls
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(OperaChromeTheme.workspaceBackground)
        .task(id: motionTrailTaskKey) {
            guard harnessState.showsMotionPaths else {
                cachedMotionTrails = []
                return
            }

            cachedMotionTrails = await adapter.motionTrails(
                for: scenario,
                store: store,
                playbackStyle: harnessState.playbackStyle
            )
        }
        .task(id: cameraPathTaskKey) {
            guard harnessState.showsCameraPath else {
                cachedCameraPathPoints = []
                cachedCameraFocusPoints = []
                return
            }

            let sampled = await sampleCameraPath()
            cachedCameraPathPoints = sampled.cameraPoints
            cachedCameraFocusPoints = sampled.focusPoints
        }
        .task(id: shotAnchorTaskKey) {
            guard harnessState.showsShotLabels else {
                cachedShotAnchors = []
                return
            }

            cachedShotAnchors = sampleShotAnchors()
        }
        .onAppear {
            synchronizeLocalPreviewFrame()
        }
        .onChange(of: store.currentFrame) { _, _ in
            synchronizeLocalPreviewFrame()
        }
        .onChange(of: store.isPlaying) { _, isPlaying in
            harnessState.isPlaying = isPlaying
        }
        .onChange(of: scenario.id) { _, _ in
            hoveredDebugGizmo = nil
            selectedDebugGizmo = nil
            hoveredDebugGuide = nil
            selectedDebugGuide = nil
            synchronizeLocalPreviewFrame()
        }
        .onDisappear {
            if usesSharedTransport {
                store.stopPlayback()
            }
            harnessState.stopPlayback()
            hoveredDebugGizmo = nil
            hoveredDebugGuide = nil
            selectedDebugGuide = nil
        }
    }

    private var previewSurface: some View {
        ZStack {
            Color.black.opacity(0.94)

            ZStack(alignment: .topLeading) {
                Animate3DSceneRepresentable(
                    scenario: scenario,
                    snapshot: snapshot,
                    packageCutoutPlans: packageCutoutPlans,
                    motionTrails: motionTrails,
                    cameraPathPoints: cameraPathPoints,
                    cameraFocusPoints: cameraFocusPoints,
                    shotAnchors: shotAnchors,
                    backgroundImageURL: backgroundImageURL,
                    onShotAnchorSelected: { anchorID in
                        guard let shot = scenario.shotMarkers.first(where: { $0.id == anchorID }) else { return }
                        jumpToShot(shot)
                    },
                    selectedDebugGizmo: selectedDebugGizmo,
                    onDebugGizmoHovered: { gizmo in
                        hoveredDebugGizmo = gizmo
                    },
                    onDebugGizmoSelected: { gizmo in
                        selectedDebugGizmo = gizmo
                        if gizmo == .camera, harnessState.debugOrbitEnabled {
                            requestOrbitRecenter()
                        }
                    },
                    selectedDebugGuideID: selectedDebugGuide?.id,
                    onDebugGuideHovered: { guide in
                        hoveredDebugGuide = guide
                    },
                    onDebugGuideSelected: { guide in
                        selectedDebugGuide = guide
                    },
                    showsGrid: harnessState.showsGrid,
                    showsFrustum: harnessState.showsFrustum,
                    showsCameraPath: harnessState.showsCameraPath,
                    debugOrbitEnabled: harnessState.debugOrbitEnabled,
                    debugOrbitRecenterSeed: debugOrbitRecenterSeed,
                    showsRigLabels: harnessState.showsRigLabels,
                    showsFocusMarker: harnessState.showsFocusMarker,
                    showsAttachmentGuides: harnessState.showsAttachmentGuides,
                    showsMotionPaths: harnessState.showsMotionPaths,
                    showsShotLabels: harnessState.showsShotLabels
                )
                .overlay(alignment: .topLeading) {
                    overlaySummary
                        .padding(16)
                }
            }
            .aspectRatio(21.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OperaChromeTheme.workspaceBackground)
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("3D TRANSLATION TEST")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text(scenario.sceneName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(scenario.sourceSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Picker("Source", selection: $harnessState.scenarioMode) {
                ForEach(Animate3DScenarioMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Picker("Exposure", selection: $harnessState.playbackStyle) {
                ForEach(Animate3DPlaybackStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
    }

    private var overlaySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                badge(scenario.sourceKind.title, tint: .blue)
                badge(transportBadgeTitle, tint: usesSharedTransport ? .green : .gray)
                badge("Base \(scenario.baseFPS) fps", tint: .purple)
                badge("Display \(harnessState.playbackStyle.targetVisualFPS) fps", tint: .mint)
                if scenario.diagnostics.attachmentCount > 0 {
                    badge("Attach \(scenario.diagnostics.attachmentCount)", tint: .pink)
                }
                if !motionTrails.isEmpty {
                    badge("Paths \(motionTrails.count)", tint: .teal)
                }
                if !cameraPathPoints.isEmpty {
                    badge("Camera Path", tint: .cyan)
                }
                if !shotAnchors.isEmpty {
                    badge("Anchors \(shotAnchors.count)", tint: .indigo)
                }
                if !assetBridgeStatuses.isEmpty {
                    badge("Bridge \(bridgeReadyCount)/\(assetBridgeStatuses.count) Ready", tint: assetBridgeBadgeTint)
                    if bridgePartialCount > 0 {
                        badge("Partial \(bridgePartialCount)", tint: .yellow)
                    }
                    if bridgeMissingCount > 0 {
                        badge("Pkg Missing \(bridgeMissingCount)", tint: .orange)
                    }
                    if bridgeUnavailableCount > 0 {
                        badge("Unlinked \(bridgeUnavailableCount)", tint: .gray)
                    }
                }
                if harnessState.showsPackageCutouts, activeCutoutCharacterCount > 0 {
                    badge("Cutouts \(activeCutoutCharacterCount)", tint: .green)
                }
                if harnessState.debugOrbitEnabled {
                    badge("Orbit", tint: .yellow)
                    if harnessState.debugOrbitAutoRecenter {
                        badge("Auto Recenter", tint: .brown)
                    }
                }
                if let gizmo = activeDebugGizmo {
                    badge("\(selectedDebugGizmo == gizmo ? "Inspect" : "Hover") \(gizmo.title)", tint: gizmo.badgeColor)
                }
                if let guide = activeDebugGuide {
                    badge("\(selectedDebugGuide?.id == guide.id ? "Inspect" : "Hover") \(guide.kind.title)", tint: debugGuideTint(for: guide.kind))
                }
                if !scenario.diagnostics.unsupportedTrackNames.isEmpty {
                    badge("Unsupported \(scenario.diagnostics.unsupportedTrackNames.count)", tint: .red)
                }
                if let shotTitle = snapshot.activeShotTitle ?? snapshot.camera.shot?.displayName {
                    badge(shotTitle, tint: .orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Frame \(snapshot.displayFrame + 1) / \(max(snapshot.totalFrames, 1))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                if let focus = snapshot.camera.focusCharacterName {
                    Text("Camera: \(snapshot.camera.shotLabel) · focus \(focus)")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                } else {
                    Text("Camera: \(snapshot.camera.shotLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                if let beatNotes = snapshot.camera.beatNotes,
                   !beatNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Notes: \(beatNotes)")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .lineLimit(2)
                }
                if !visiblePoseReadouts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(visiblePoseReadouts.prefix(3)), id: \.name) { item in
                            Text("\(item.name): \(item.profile.shortSummary)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                if !visibleAssetBridgeReadouts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleAssetBridgeReadouts) { status in
                            Text(overlayAssetBridgeSummary(for: status))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                if let gizmo = activeDebugGizmo {
                    ForEach(debugGizmoDetailLines(for: gizmo), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                if let guide = activeDebugGuide {
                    ForEach(debugGuideDetailLines(for: guide), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground.opacity(0.92))
            )
        }
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    stepFrame(by: -1)
                } label: {
                    Label("Back", systemImage: "chevron.backward.2")
                }
                .buttonStyle(.bordered)

                Button {
                    togglePlayback()
                } label: {
                    Label(isTransportPlaying ? "Pause" : "Play", systemImage: isTransportPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    stepFrame(by: 1)
                } label: {
                    Label("Forward", systemImage: "chevron.forward.2")
                }
                .buttonStyle(.bordered)

                Button("Reset") {
                    resetPlayback()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 12)

                Toggle("Grid", isOn: $harnessState.showsGrid)
                    .toggleStyle(.checkbox)
                Toggle("Camera", isOn: $harnessState.showsFrustum)
                    .toggleStyle(.checkbox)
                Toggle("CamPath", isOn: $harnessState.showsCameraPath)
                    .toggleStyle(.checkbox)
                Toggle("Orbit", isOn: $harnessState.debugOrbitEnabled)
                    .toggleStyle(.checkbox)
                Toggle("AutoRec", isOn: $harnessState.debugOrbitAutoRecenter)
                    .toggleStyle(.checkbox)
                    .disabled(!harnessState.debugOrbitEnabled)
                Toggle("Labels", isOn: $harnessState.showsRigLabels)
                    .toggleStyle(.checkbox)
                Toggle("Focus", isOn: $harnessState.showsFocusMarker)
                    .toggleStyle(.checkbox)
                Toggle("Attach", isOn: $harnessState.showsAttachmentGuides)
                    .toggleStyle(.checkbox)
                Toggle("Paths", isOn: $harnessState.showsMotionPaths)
                    .toggleStyle(.checkbox)
                Toggle("Shots", isOn: $harnessState.showsShotLabels)
                    .toggleStyle(.checkbox)
                Toggle("Pkg", isOn: $harnessState.showsPackageCutouts)
                    .toggleStyle(.checkbox)

                Button("Recenter") {
                    requestOrbitRecenter()
                }
                .buttonStyle(.bordered)
                .disabled(!harnessState.debugOrbitEnabled)
            }

            HStack(alignment: .center, spacing: 12) {
                Text("0")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Slider(
                    value: frameSliderBinding,
                    in: 0...Double(max(0, scenario.totalFrames - 1)),
                    step: 1
                )
                Text("\(max(0, scenario.totalFrames - 1))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }

            if !scenario.shotMarkers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scenario.shotMarkers) { shot in
                            Button {
                                jumpToShot(shot)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shot.title)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("\(shot.startFrame)–\(shot.endFrame)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(OperaChromeTheme.textTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(shot.contains(frame: snapshot.displayFrame)
                                              ? Color.accentColor.opacity(0.18)
                                              : OperaChromeTheme.panelBackground)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.18))
            )
            .foregroundStyle(tint)
    }

    private func clampedFrame(_ frame: Int) -> Int {
        min(max(0, frame), max(0, scenario.totalFrames - 1))
    }

    private func setFrame(_ frame: Int) {
        let clamped = clampedFrame(frame)
        if usesSharedTransport {
            store.currentFrame = clamped
            harnessState.previewFrame = clamped
        } else {
            harnessState.previewFrame = clamped
        }
    }

    private func stepFrame(by delta: Int) {
        if usesSharedTransport {
            harnessState.step(by: delta, scenario: scenario, store: store)
        } else {
            setFrame(effectiveRawFrame + delta)
        }
    }

    private func resetPlayback() {
        if usesSharedTransport {
            harnessState.stopPlayback(syncing: store)
            harnessState.seek(to: 0, scenario: scenario, store: store)
        } else {
            harnessState.stopPlayback()
            harnessState.reset()
        }
    }

    private func togglePlayback() {
        if usesSharedTransport {
            harnessState.togglePlayback(for: scenario, store: store)
        } else {
            harnessState.togglePlayback(for: scenario)
        }
    }

    private func jumpToShot(_ shot: Animate3DShotMarker) {
        selectedDebugGizmo = nil
        if usesSharedTransport {
            harnessState.stopPlayback(syncing: store)
            harnessState.seek(to: shot.startFrame, scenario: scenario, store: store)
        } else {
            harnessState.stopPlayback()
            harnessState.previewFrame = clampedFrame(shot.startFrame)
        }
        if harnessState.debugOrbitEnabled && harnessState.debugOrbitAutoRecenter {
            requestOrbitRecenter()
        }
    }

    private func synchronizeLocalPreviewFrame() {
        guard usesSharedTransport else { return }
        let clamped = clampedFrame(store.currentFrame)
        if harnessState.previewFrame != clamped {
            harnessState.previewFrame = clamped
        }
        // Only stop when the store has actually stopped playing.  This method
        // fires on every store.currentFrame change, including timer-driven
        // frame advances during playback -- stopping here would immediately
        // kill the timer that startPlayback() just scheduled.
        if !store.isPlaying, harnessState.isPlaying {
            harnessState.stopPlayback()
        }
    }

    private func requestOrbitRecenter() {
        guard harnessState.debugOrbitEnabled else { return }
        debugOrbitRecenterSeed &+= 1
    }

    private var activeDebugGizmo: Animate3DDebugGizmo? {
        if let selectedDebugGizmo, isDebugGizmoVisible(selectedDebugGizmo) {
            return selectedDebugGizmo
        }
        if let hoveredDebugGizmo, isDebugGizmoVisible(hoveredDebugGizmo) {
            return hoveredDebugGizmo
        }
        return nil
    }

    private var activeDebugGuide: Animate3DDebugGuideSelection? {
        if let selectedDebugGuide, isDebugGuideVisible(selectedDebugGuide) {
            return selectedDebugGuide
        }
        if let hoveredDebugGuide, isDebugGuideVisible(hoveredDebugGuide) {
            return hoveredDebugGuide
        }
        return nil
    }

    private func isDebugGizmoVisible(_ gizmo: Animate3DDebugGizmo) -> Bool {
        switch gizmo {
        case .camera:
            return harnessState.debugOrbitEnabled || harnessState.showsFrustum || harnessState.showsCameraPath
        case .focus:
            return harnessState.showsFocusMarker
        }
    }

    private func debugGizmoDetailLines(for gizmo: Animate3DDebugGizmo) -> [String] {
        switch gizmo {
        case .camera:
            return [
                "Cam \(formatted(snapshot.camera.position)) · FOV \(Int(snapshot.camera.fieldOfView.rounded()))°",
                "Look \(formatted(snapshot.camera.lookAt))"
            ]
        case .focus:
            let offset = snapshot.camera.lookAt - snapshot.camera.position
            let distance = sqrt((offset.x * offset.x) + (offset.y * offset.y) + (offset.z * offset.z))
            return [
                "Focus \(formatted(snapshot.camera.lookAt))",
                "Cam→Focus \(String(format: "%.2f", distance))u"
            ]
        }
    }

    private func debugGuideDetailLines(for guide: Animate3DDebugGuideSelection) -> [String] {
        [guide.title] + guide.detailLines
    }

    private func isDebugGuideVisible(_ guide: Animate3DDebugGuideSelection) -> Bool {
        switch guide.kind {
        case .motionTrail:
            return harnessState.showsMotionPaths
        case .cameraPath, .focusPath, .cameraRay:
            return harnessState.showsCameraPath
        }
    }

    private func debugGuideTint(for kind: Animate3DDebugGuideKind) -> Color {
        switch kind {
        case .motionTrail:
            return .teal
        case .cameraPath:
            return .cyan
        case .focusPath:
            return .yellow
        case .cameraRay:
            return .mint
        }
    }

    private var assetBridgeBadgeTint: Color {
        if bridgeReadyCount == assetBridgeStatuses.count {
            return .green
        }
        if bridgeReadyCount > 0 {
            return .mint
        }
        if bridgePartialCount > 0 {
            return .yellow
        }
        if bridgeMissingCount > 0 {
            return .orange
        }
        return .gray
    }

    private func overlayAssetBridgeSummary(for status: Animate3DCharacterAssetBridgeStatus) -> String {
        let detail = status.currentSwapSummary ?? status.summary
        if let modeTag = cutoutModeTag(forCharacterID: status.id) {
            return "\(status.characterName): \(status.readiness.title.lowercased()) · \(detail) · \(modeTag)"
        }

        return "\(status.characterName): \(status.readiness.title.lowercased()) · \(detail)"
    }

    private func cutoutModeTag(forCharacterID characterID: String) -> String? {
        guard let plan = packageCutoutPlans.first(where: { $0.characterID == characterID }) else {
            return nil
        }

        switch plan.mode {
        case .rigLayers:
            return "rig"
        case .layeredParts:
            return "layered"
        case .wholeCharacter:
            return "whole"
        }
    }

    private func formatted(_ vector: SIMD3<Double>) -> String {
        "(\(String(format: "%.2f", vector.x)), \(String(format: "%.2f", vector.y)), \(String(format: "%.2f", vector.z)))"
    }

    private func sampleCameraPath() async -> (cameraPoints: [SIMD3<Double>], focusPoints: [SIMD3<Double>]) {
        guard scenario.totalFrames > 1 else {
            let singleSnapshot = adapter.frameSnapshot(
                for: scenario,
                store: store,
                rawFrame: effectiveRawFrame,
                playbackStyle: harnessState.playbackStyle
            )
            return ([singleSnapshot.camera.position], [singleSnapshot.camera.lookAt])
        }

        // Base sample step, then coarsen for large frame counts (cap ~250 samples).
        var sampleStep = max(
            1,
            Int(round(Double(max(scenario.baseFPS, 1)) / Double(max(min(harnessState.playbackStyle.targetVisualFPS, 12), 1))))
        )
        let maxSamples = 250
        if scenario.totalFrames / sampleStep > maxSamples {
            sampleStep = max(sampleStep, scenario.totalFrames / maxSamples)
        }

        var frames = Array(stride(from: 0, to: scenario.totalFrames, by: sampleStep))
        let lastFrame = max(0, scenario.totalFrames - 1)
        if frames.last != lastFrame {
            frames.append(lastFrame)
        }

        var cameraPoints: [SIMD3<Double>] = []
        var focusPoints: [SIMD3<Double>] = []

        // Yield periodically to prevent main-thread stalls on large scenes.
        let yieldInterval = 32
        for (iterIndex, frame) in frames.enumerated() {
            if iterIndex > 0, iterIndex.isMultiple(of: yieldInterval) {
                await Task.yield()
                if Task.isCancelled { return ([], []) }
            }

            let frameSnapshot = adapter.frameSnapshot(
                for: scenario,
                store: store,
                rawFrame: frame,
                playbackStyle: harnessState.playbackStyle
            )
            appendGuidePoint(frameSnapshot.camera.position, into: &cameraPoints)
            appendGuidePoint(frameSnapshot.camera.lookAt, into: &focusPoints)
        }

        return (cameraPoints, focusPoints)
    }

    private func sampleShotAnchors() -> [Animate3DShotAnchor] {
        scenario.shotMarkers.enumerated().map { index, shot in
            let frameSnapshot = adapter.frameSnapshot(
                for: scenario,
                store: store,
                rawFrame: shot.startFrame,
                playbackStyle: .onOnes
            )

            let lane = Double(index % 4)
            let side: Double = index.isMultiple(of: 2) ? -1 : 1
            let offset = SIMD3<Double>(
                side * (0.7 + (0.18 * lane)),
                0.9 + (0.16 * lane),
                -0.2 * Double(index % 3)
            )

            return Animate3DShotAnchor(
                id: shot.id,
                title: shot.title,
                startFrame: shot.startFrame,
                endFrame: shot.endFrame,
                cameraShot: shot.cameraShot,
                worldPosition: frameSnapshot.camera.lookAt + offset,
                focusPosition: frameSnapshot.camera.lookAt
            )
        }
    }

    private func appendGuidePoint(
        _ point: SIMD3<Double>,
        into points: inout [SIMD3<Double>]
    ) {
        let threshold = 0.025 * 0.025
        if let last = points.last {
            let delta = point - last
            let distanceSquared = (delta.x * delta.x) + (delta.y * delta.y) + (delta.z * delta.z)
            guard distanceSquared > threshold else { return }
        }
        points.append(point)
    }
}

@available(macOS 26.0, *)
private enum Animate3DDebugGizmo: String, Equatable {
    case camera
    case focus

    var title: String {
        switch self {
        case .camera: "Camera"
        case .focus: "Focus"
        }
    }

    var badgeColor: Color {
        switch self {
        case .camera: .cyan
        case .focus: .yellow
        }
    }
}

@available(macOS 26.0, *)
private struct Animate3DSceneRepresentable: NSViewRepresentable {
    var scenario: Animate3DPreviewScenario
    var snapshot: Animate3DFrameSnapshot
    var packageCutoutPlans: [Animate3DCharacterPackageCutoutPlan]
    var motionTrails: [Animate3DMotionTrail]
    var cameraPathPoints: [SIMD3<Double>]
    var cameraFocusPoints: [SIMD3<Double>]
    var shotAnchors: [Animate3DShotAnchor]
    var backgroundImageURL: URL?
    var onShotAnchorSelected: (String) -> Void
    var selectedDebugGizmo: Animate3DDebugGizmo?
    var onDebugGizmoHovered: (Animate3DDebugGizmo?) -> Void
    var onDebugGizmoSelected: (Animate3DDebugGizmo) -> Void
    var selectedDebugGuideID: String?
    var onDebugGuideHovered: (Animate3DDebugGuideSelection?) -> Void
    var onDebugGuideSelected: (Animate3DDebugGuideSelection?) -> Void
    var showsGrid: Bool
    var showsFrustum: Bool
    var showsCameraPath: Bool
    var debugOrbitEnabled: Bool
    var debugOrbitRecenterSeed: Int
    var showsRigLabels: Bool
    var showsFocusMarker: Bool
    var showsAttachmentGuides: Bool
    var showsMotionPaths: Bool
    var showsShotLabels: Bool

    func makeNSView(context: Context) -> Animate3DSceneView {
        let view = Animate3DSceneView(frame: .zero)
        view.onShotAnchorSelected = onShotAnchorSelected
        view.onDebugGizmoHovered = onDebugGizmoHovered
        view.onDebugGizmoSelected = onDebugGizmoSelected
        view.onDebugGuideHovered = onDebugGuideHovered
        view.onDebugGuideSelected = onDebugGuideSelected
        view.apply(
            scenario: scenario,
            snapshot: snapshot,
            packageCutoutPlans: packageCutoutPlans,
            motionTrails: motionTrails,
            cameraPathPoints: cameraPathPoints,
            cameraFocusPoints: cameraFocusPoints,
            shotAnchors: shotAnchors,
            backgroundImageURL: backgroundImageURL,
            selectedDebugGizmo: selectedDebugGizmo,
            selectedDebugGuideID: selectedDebugGuideID,
            showsGrid: showsGrid,
            showsFrustum: showsFrustum,
            showsCameraPath: showsCameraPath,
            debugOrbitEnabled: debugOrbitEnabled,
            debugOrbitRecenterSeed: debugOrbitRecenterSeed,
            showsRigLabels: showsRigLabels,
            showsFocusMarker: showsFocusMarker,
            showsAttachmentGuides: showsAttachmentGuides,
            showsMotionPaths: showsMotionPaths,
            showsShotLabels: showsShotLabels
        )
        return view
    }

    func updateNSView(_ nsView: Animate3DSceneView, context: Context) {
        nsView.onShotAnchorSelected = onShotAnchorSelected
        nsView.onDebugGizmoHovered = onDebugGizmoHovered
        nsView.onDebugGizmoSelected = onDebugGizmoSelected
        nsView.onDebugGuideHovered = onDebugGuideHovered
        nsView.onDebugGuideSelected = onDebugGuideSelected
        nsView.apply(
            scenario: scenario,
            snapshot: snapshot,
            packageCutoutPlans: packageCutoutPlans,
            motionTrails: motionTrails,
            cameraPathPoints: cameraPathPoints,
            cameraFocusPoints: cameraFocusPoints,
            shotAnchors: shotAnchors,
            backgroundImageURL: backgroundImageURL,
            selectedDebugGizmo: selectedDebugGizmo,
            selectedDebugGuideID: selectedDebugGuideID,
            showsGrid: showsGrid,
            showsFrustum: showsFrustum,
            showsCameraPath: showsCameraPath,
            debugOrbitEnabled: debugOrbitEnabled,
            debugOrbitRecenterSeed: debugOrbitRecenterSeed,
            showsRigLabels: showsRigLabels,
            showsFocusMarker: showsFocusMarker,
            showsAttachmentGuides: showsAttachmentGuides,
            showsMotionPaths: showsMotionPaths,
            showsShotLabels: showsShotLabels
        )
    }
}

@available(macOS 26.0, *)
@MainActor
private final class Animate3DSceneView: SCNView {
    fileprivate static let shotAnchorNodeNamePrefix = "animate3d-shot-anchor:"
    fileprivate static let debugGizmoNodeNamePrefix = "animate3d-debug-gizmo:"
    fileprivate static let debugGuideNodeNamePrefix = "animate3d-debug-guide:"
    private static let shotAnchorPointerNodeName = "shot-anchor-pointer"
    private static let shotAnchorTextNodeName = "shot-anchor-text"
    private static let shotAnchorDotNodeName = "shot-anchor-dot"
    private static let shotAnchorWorldPickNodeName = "shot-anchor-world-pick"
    private static let shotAnchorFocusPickNodeName = "shot-anchor-focus-pick"

    var onShotAnchorSelected: ((String) -> Void)?
    var onDebugGizmoHovered: ((Animate3DDebugGizmo?) -> Void)?
    var onDebugGizmoSelected: ((Animate3DDebugGizmo) -> Void)?
    var onDebugGuideHovered: ((Animate3DDebugGuideSelection?) -> Void)?
    var onDebugGuideSelected: ((Animate3DDebugGuideSelection?) -> Void)?

    private let sceneRoot = SCNScene()
    private let stageNode = SCNNode()
    private let gridNode = Animate3DSceneView.makeGridNode(size: 16, divisions: 16)
    private let cameraNode = SCNNode()
    private let cameraLookTargetNode = SCNNode()
    private let lightNode = SCNNode()
    private let fillLightNode = SCNNode()
    private let ambientLightNode = SCNNode()
    private let focusNode = SCNNode()
    private let focusMaterial = SCNMaterial()
    private let cameraGizmoNode = SCNNode()
    private let cameraGizmoMaterial = SCNMaterial()
    private let attachmentGuideContainer = SCNNode()
    private let motionTrailContainer = SCNNode()
    private let cameraPathContainer = SCNNode()
    private let shotAnchorContainer = SCNNode()
    private let shotLabelNode = SCNNode()
    private let shotLabelText = SCNText(string: "", extrusionDepth: 0)
    private let debugCameraNode = SCNNode()
    private let debugCameraLookTargetNode = SCNNode()
    private var rigNodes: [String: Animate3DWireRigNode] = [:]
    private var objectNodes: [String: Animate3DWirePropNode] = [:]
    private var loadedScenarioID: String?
    private var loadedBackgroundURL: URL?
    private var motionTrailSignature: Int?
    private var cameraPathSignature: Int?
    private var shotAnchorSignature: Int?
    private var attachmentGuideSignature: Int?
    private var isDebugOrbitActive = false
    private var lastDebugOrbitRecenterSeed: Int?
    private var mouseDownPoint: NSPoint?
    private var trackingAreaRef: NSTrackingArea?
    private var hoveredShotAnchorID: String?
    private var hoveredDebugGizmo: Animate3DDebugGizmo?
    private var hoveredDebugGuideID: String?
    private var currentShotAnchors: [Animate3DShotAnchor] = []
    private var currentShotAnchorFrame = 0
    private var currentShowsShotLabels = false
    private var currentSelectedDebugGizmo: Animate3DDebugGizmo?
    private var currentSelectedDebugGuideID: String?
    private var currentShowsFocusMarker = false
    private var currentShowsCameraGizmo = false
    private var currentShowsMotionPaths = false
    private var currentShowsCameraPath = false
    private var currentMotionTrails: [Animate3DMotionTrail] = []
    private var currentCameraPathPoints: [SIMD3<Double>] = []
    private var currentCameraFocusPoints: [SIMD3<Double>] = []
    private var debugGuideSelectionsByID: [String: Animate3DDebugGuideSelection] = [:]

    override init(frame frameRect: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frameRect, options: options)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let downPoint = mouseDownPoint
        mouseDownPoint = nil
        super.mouseUp(with: event)

        guard let downPoint else { return }
        let dx = location.x - downPoint.x
        let dy = location.y - downPoint.y
        guard ((dx * dx) + (dy * dy)) <= 25 else { return }
        if handleShotAnchorClick(at: location) {
            return
        }
        if handleDebugGizmoClick(at: location) {
            return
        }
        _ = handleDebugGuideClick(at: location)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredInteractivity(at: location)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredShotAnchorID(nil)
        setHoveredDebugGizmo(nil)
        setHoveredDebugGuideSelection(nil)
        super.mouseExited(with: event)
    }

    private func commonInit() {
        scene = sceneRoot
        backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        antialiasingMode = .none
        preferredFramesPerSecond = 24
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        rendersContinuously = false
        isPlaying = false
        isJitteringEnabled = false
        showsStatistics = false

        sceneRoot.rootNode.addChildNode(stageNode)
        stageNode.addChildNode(gridNode)

        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 4, 10)
        stageNode.addChildNode(cameraNode)
        stageNode.addChildNode(cameraLookTargetNode)
        pointOfView = cameraNode

        let debugCamera = SCNCamera()
        debugCamera.fieldOfView = 45
        debugCamera.zNear = 0.1
        debugCamera.zFar = 100
        debugCamera.wantsHDR = false
        debugCameraNode.camera = debugCamera
        debugCameraNode.position = cameraNode.position
        stageNode.addChildNode(debugCameraNode)
        stageNode.addChildNode(debugCameraLookTargetNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1200
        key.castsShadow = false
        lightNode.light = key
        lightNode.eulerAngles = SCNVector3(-0.8, 0.8, 0)
        stageNode.addChildNode(lightNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 450
        fill.castsShadow = false
        fillLightNode.light = fill
        fillLightNode.eulerAngles = SCNVector3(-0.45, -1.1, 0)
        stageNode.addChildNode(fillLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        ambient.color = NSColor(calibratedWhite: 0.85, alpha: 1)
        ambientLightNode.light = ambient
        stageNode.addChildNode(ambientLightNode)

        focusMaterial.lightingModel = .constant
        focusMaterial.diffuse.contents = NSColor.systemYellow
        focusMaterial.emission.contents = NSColor.systemYellow
        focusMaterial.fillMode = .lines
        focusMaterial.isDoubleSided = true
        focusNode.geometry = SCNSphere(radius: 0.18)
        focusNode.geometry?.materials = [focusMaterial]
        focusNode.name = Self.debugGizmoNodeNamePrefix + Animate3DDebugGizmo.focus.rawValue
        let focusPickTarget = Self.makeDebugGizmoPickTarget(radius: 0.3)
        focusNode.addChildNode(focusPickTarget)
        stageNode.addChildNode(focusNode)

        cameraGizmoMaterial.lightingModel = .constant
        cameraGizmoMaterial.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.92)
        cameraGizmoMaterial.emission.contents = NSColor.systemCyan.withAlphaComponent(0.92)
        cameraGizmoMaterial.fillMode = .lines
        cameraGizmoMaterial.isDoubleSided = true
        cameraGizmoNode.name = Self.debugGizmoNodeNamePrefix + Animate3DDebugGizmo.camera.rawValue

        let cameraBody = SCNNode(geometry: SCNBox(width: 0.28, height: 0.18, length: 0.2, chamferRadius: 0.02))
        cameraBody.geometry?.materials = [cameraGizmoMaterial]
        cameraGizmoNode.addChildNode(cameraBody)

        let cameraLens = SCNNode(geometry: SCNPyramid(width: 0.22, height: 0.16, length: 0.14))
        cameraLens.geometry?.materials = [cameraGizmoMaterial]
        cameraLens.position = SCNVector3(0, 0, -0.18)
        cameraLens.eulerAngles = SCNVector3(Float.pi / 2, 0, Float.pi)
        cameraGizmoNode.addChildNode(cameraLens)

        let cameraPickTarget = Self.makeDebugGizmoPickTarget(radius: 0.32)
        cameraGizmoNode.addChildNode(cameraPickTarget)
        stageNode.addChildNode(cameraGizmoNode)

        stageNode.addChildNode(attachmentGuideContainer)
        stageNode.addChildNode(motionTrailContainer)
        stageNode.addChildNode(cameraPathContainer)
        stageNode.addChildNode(shotAnchorContainer)

        shotLabelText.font = NSFont.systemFont(ofSize: 0.24, weight: .semibold)
        shotLabelText.flatness = 0.2
        shotLabelText.alignmentMode = "center"
        let shotMaterial = SCNMaterial()
        shotMaterial.lightingModel = .constant
        shotMaterial.diffuse.contents = NSColor.systemCyan
        shotMaterial.emission.contents = NSColor.systemCyan
        shotMaterial.isDoubleSided = true
        shotLabelText.materials = [shotMaterial]
        shotLabelNode.geometry = shotLabelText
        shotLabelNode.scale = SCNVector3(0.22, 0.22, 0.22)
        shotLabelNode.constraints = [SCNBillboardConstraint()]
        stageNode.addChildNode(shotLabelNode)
    }

    func apply(
        scenario: Animate3DPreviewScenario,
        snapshot: Animate3DFrameSnapshot,
        packageCutoutPlans: [Animate3DCharacterPackageCutoutPlan],
        motionTrails: [Animate3DMotionTrail],
        cameraPathPoints: [SIMD3<Double>],
        cameraFocusPoints: [SIMD3<Double>],
        shotAnchors: [Animate3DShotAnchor],
        backgroundImageURL: URL?,
        selectedDebugGizmo: Animate3DDebugGizmo?,
        selectedDebugGuideID: String?,
        showsGrid: Bool,
        showsFrustum: Bool,
        showsCameraPath: Bool,
        debugOrbitEnabled: Bool,
        debugOrbitRecenterSeed: Int,
        showsRigLabels: Bool,
        showsFocusMarker: Bool,
        showsAttachmentGuides: Bool,
        showsMotionPaths: Bool,
        showsShotLabels: Bool
    ) {
        if loadedScenarioID != scenario.id {
            rebuildScene(for: scenario)
            loadedScenarioID = scenario.id
            loadedBackgroundURL = nil
            lastDebugOrbitRecenterSeed = nil
            hoveredShotAnchorID = nil
            hoveredDebugGuideID = nil
            debugGuideSelectionsByID = [:]
        }

        updateBackground(backgroundImageURL)
        gridNode.isHidden = !showsGrid
        debugOptions = showsFrustum ? [.showCameras] : []
        updateDebugOrbit(
            snapshot.camera,
            debugOrbitEnabled: debugOrbitEnabled,
            debugOrbitRecenterSeed: debugOrbitRecenterSeed
        )
        updateCamera(snapshot.camera)

        let cutoutPlansByCharacterID = Dictionary(uniqueKeysWithValues: packageCutoutPlans.map { ($0.characterID, $0) })

        for character in snapshot.characters {
            rigNodes[character.id]?.apply(
                snapshot: character,
                frame: snapshot.displayFrame,
                showsLabel: showsRigLabels,
                cutoutPlan: cutoutPlansByCharacterID[character.id]
            )
        }

        for object in snapshot.objects {
            let attachPos = resolvedAttachmentTargetPosition(
                attachmentTarget: object.attachmentTarget
            )
            objectNodes[object.id]?.apply(
                snapshot: object,
                showsLabel: showsRigLabels,
                attachmentOverride: attachPos
            )
        }

        for (id, rigNode) in rigNodes where !snapshot.characters.contains(where: { $0.id == id }) {
            rigNode.rootNode.opacity = 0
        }

        for (id, objectNode) in objectNodes where !snapshot.objects.contains(where: { $0.id == id }) {
            objectNode.rootNode.opacity = 0
        }

        updateFocusMarker(
            lookAt: snapshot.camera.lookAt,
            showsFocusMarker: showsFocusMarker
        )
        rebuildAttachmentGuides(
            snapshot: snapshot,
            showsAttachmentGuides: showsAttachmentGuides
        )
        rebuildMotionTrails(
            motionTrails,
            showsMotionPaths: showsMotionPaths
        )
        rebuildCameraPath(
            cameraPathPoints: cameraPathPoints,
            focusPoints: cameraFocusPoints,
            showsCameraPath: showsCameraPath
        )
        currentShotAnchors = shotAnchors
        currentShotAnchorFrame = snapshot.displayFrame
        currentShowsShotLabels = showsShotLabels
        currentSelectedDebugGizmo = selectedDebugGizmo
        currentSelectedDebugGuideID = selectedDebugGuideID
        currentShowsFocusMarker = showsFocusMarker
        currentShowsCameraGizmo = debugOrbitEnabled || showsFrustum || showsCameraPath
        currentShowsMotionPaths = showsMotionPaths
        currentShowsCameraPath = showsCameraPath
        currentMotionTrails = motionTrails
        currentCameraPathPoints = cameraPathPoints
        currentCameraFocusPoints = cameraFocusPoints
        if !showsShotLabels {
            hoveredShotAnchorID = nil
        }
        if !showsMotionPaths, currentSelectedDebugGuideID?.hasPrefix("motion-trail:") == true {
            onDebugGuideSelected?(nil)
        }
        if !showsCameraPath,
           currentSelectedDebugGuideID?.hasPrefix("camera-") == true || currentSelectedDebugGuideID?.hasPrefix("focus-") == true {
            onDebugGuideSelected?(nil)
        }
        updateDebugGizmoVisibility()
        updateDebugGizmoAppearance()
        rebuildShotAnchors(
            shotAnchors,
            activeFrame: snapshot.displayFrame,
            showsShotLabels: showsShotLabels
        )
        updateShotLabel(
            snapshot: snapshot,
            showsShotLabels: showsShotLabels
        )

        needsDisplay = true
    }

    private func rebuildScene(for scenario: Animate3DPreviewScenario) {
        rigNodes.values.forEach { $0.rootNode.removeFromParentNode() }
        objectNodes.values.forEach { $0.rootNode.removeFromParentNode() }
        rigNodes = [:]
        objectNodes = [:]

        for (index, name) in scenario.castNames.enumerated() {
            let id = scenario.compiledScene?.characterSetups.first(where: { $0.characterName == name })?.id.uuidString
                ?? scenario.syncPacket?.cast.first(where: { $0.name == name })?.id
                ?? "character-\(index)-\(name)"
            let rig = Animate3DWireRigNode(name: name, colorIndex: index)
            rigNodes[id] = rig
            stageNode.addChildNode(rig.rootNode)
        }

        for (index, name) in scenario.objectNames.enumerated() {
            let id = scenario.compiledScene?.objectSetups.first(where: { $0.objectName == name })?.id.uuidString
                ?? scenario.syncPacket?.objects.first(where: { $0.name == name })?.id
                ?? "object-\(index)-\(name)"
            let prop = Animate3DWirePropNode(name: name, colorIndex: index)
            objectNodes[id] = prop
            stageNode.addChildNode(prop.rootNode)
        }
    }

    private func updateBackground(_ url: URL?) {
        guard url != loadedBackgroundURL else { return }
        loadedBackgroundURL = url

        if let url, let image = NSImage(contentsOf: url) {
            sceneRoot.background.contents = image
        } else {
            sceneRoot.background.contents = nil
        }
    }

    private func updateCamera(_ snapshot: Animate3DCameraSnapshot) {
        cameraNode.position = SCNVector3(
            Float(snapshot.position.x),
            Float(snapshot.position.y),
            Float(snapshot.position.z)
        )
        cameraLookTargetNode.position = SCNVector3(
            Float(snapshot.lookAt.x),
            Float(snapshot.lookAt.y),
            Float(snapshot.lookAt.z)
        )
        cameraNode.camera?.fieldOfView = CGFloat(snapshot.fieldOfView)
        cameraNode.simdOrientation = stableLookOrientation(
            position: cameraNode.simdPosition,
            target: cameraLookTargetNode.simdPosition
        )
        cameraGizmoNode.simdPosition = cameraNode.simdPosition
        cameraGizmoNode.simdOrientation = cameraNode.simdOrientation
    }

    private func updateDebugOrbit(
        _ snapshot: Animate3DCameraSnapshot,
        debugOrbitEnabled: Bool,
        debugOrbitRecenterSeed: Int
    ) {
        if debugOrbitEnabled {
            if !isDebugOrbitActive {
                recenterDebugCamera(from: snapshot)
                pointOfView = debugCameraNode
                allowsCameraControl = true
                isDebugOrbitActive = true
                lastDebugOrbitRecenterSeed = debugOrbitRecenterSeed
            } else if lastDebugOrbitRecenterSeed != debugOrbitRecenterSeed {
                recenterDebugCamera(from: snapshot)
                lastDebugOrbitRecenterSeed = debugOrbitRecenterSeed
            }
        } else if isDebugOrbitActive {
            allowsCameraControl = false
            pointOfView = cameraNode
            isDebugOrbitActive = false
            lastDebugOrbitRecenterSeed = nil
        }
    }

    private func recenterDebugCamera(from snapshot: Animate3DCameraSnapshot) {
        debugCameraNode.position = SCNVector3(
            Float(snapshot.position.x),
            Float(snapshot.position.y),
            Float(snapshot.position.z)
        )
        debugCameraLookTargetNode.position = SCNVector3(
            Float(snapshot.lookAt.x),
            Float(snapshot.lookAt.y),
            Float(snapshot.lookAt.z)
        )
        debugCameraNode.camera?.fieldOfView = CGFloat(snapshot.fieldOfView)
        debugCameraNode.simdOrientation = stableLookOrientation(
            position: debugCameraNode.simdPosition,
            target: debugCameraLookTargetNode.simdPosition
        )
    }

    private func stableLookOrientation(
        position: SIMD3<Float>,
        target: SIMD3<Float>
    ) -> simd_quatf {
        var forward = target - position
        let forwardLength = simd_length(forward)
        guard forwardLength > 0.0001 else {
            return simd_quatf()
        }

        forward /= forwardLength
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, up)) > 0.98 {
            up = SIMD3<Float>(0, 0, 1)
        }

        let right = simd_normalize(simd_cross(up, forward))
        let correctedUp = simd_normalize(simd_cross(forward, right))
        let basis = simd_float3x3(columns: (
            right,
            correctedUp,
            -forward
        ))
        return simd_quatf(basis)
    }

    private func updateFocusMarker(
        lookAt: SIMD3<Double>,
        showsFocusMarker: Bool
    ) {
        focusNode.position = SCNVector3(
            Float(lookAt.x),
            Float(lookAt.y),
            Float(lookAt.z)
        )
    }

    private func updateDebugGizmoVisibility() {
        focusNode.isHidden = !currentShowsFocusMarker
        cameraGizmoNode.isHidden = !currentShowsCameraGizmo

        if hoveredDebugGizmo == .focus, !currentShowsFocusMarker {
            setHoveredDebugGizmo(nil)
        } else if hoveredDebugGizmo == .camera, !currentShowsCameraGizmo {
            setHoveredDebugGizmo(nil)
        }
    }

    private func updateDebugGizmoAppearance() {
        let focusColor = debugGizmoColor(for: .focus)
        focusMaterial.diffuse.contents = focusColor
        focusMaterial.emission.contents = focusColor
        let focusScale: Float = currentSelectedDebugGizmo == .focus ? 1.28 : hoveredDebugGizmo == .focus ? 1.16 : 1.0
        focusNode.scale = SCNVector3(focusScale, focusScale, focusScale)

        let cameraColor = debugGizmoColor(for: .camera)
        cameraGizmoMaterial.diffuse.contents = cameraColor
        cameraGizmoMaterial.emission.contents = cameraColor
        let cameraScale: Float = currentSelectedDebugGizmo == .camera ? 1.24 : hoveredDebugGizmo == .camera ? 1.12 : 1.0
        cameraGizmoNode.scale = SCNVector3(cameraScale, cameraScale, cameraScale)
    }

    private func debugGizmoColor(for gizmo: Animate3DDebugGizmo) -> NSColor {
        switch gizmo {
        case .camera:
            if currentSelectedDebugGizmo == .camera {
                return NSColor.systemTeal.withAlphaComponent(0.98)
            }
            if hoveredDebugGizmo == .camera {
                return NSColor.systemMint.withAlphaComponent(0.95)
            }
            return NSColor.systemCyan.withAlphaComponent(0.92)
        case .focus:
            if currentSelectedDebugGizmo == .focus {
                return NSColor.systemOrange.withAlphaComponent(0.98)
            }
            if hoveredDebugGizmo == .focus {
                return NSColor.systemYellow.withAlphaComponent(1.0)
            }
            return NSColor.systemYellow.withAlphaComponent(0.92)
        }
    }

    private func rebuildAttachmentGuides(
        snapshot: Animate3DFrameSnapshot,
        showsAttachmentGuides: Bool
    ) {
        let signature = snapshot.objects.reduce(into: Hasher()) { hasher, object in
            hasher.combine(object.id)
            hasher.combine(object.visible)
            hasher.combine(object.opacity)
            hasher.combine(object.attachmentTarget)
            hasher.combine(object.worldPosition.x)
            hasher.combine(object.worldPosition.y)
            hasher.combine(object.worldPosition.z)
            if let target = resolvedAttachmentTargetPosition(
                attachmentTarget: object.attachmentTarget
            ) {
                hasher.combine(target.x)
                hasher.combine(target.y)
                hasher.combine(target.z)
            }
        }.finalize()

        guard showsAttachmentGuides else {
            attachmentGuideSignature = nil
            attachmentGuideContainer.childNodes.forEach { $0.removeFromParentNode() }
            return
        }

        guard attachmentGuideSignature != signature else { return }
        attachmentGuideSignature = signature
        attachmentGuideContainer.childNodes.forEach { $0.removeFromParentNode() }

        for object in snapshot.objects {
            guard let target = resolvedAttachmentTargetPosition(
                attachmentTarget: object.attachmentTarget
            ),
            let objectNode = objectNodes[object.id],
            objectNode.rootNode.opacity > 0.001
            else {
                continue
            }

            let start = objectNode.rootNode.presentation.worldPosition
            let line = Self.makeLineNode(
                from: start,
                to: target,
                color: NSColor.systemPink.withAlphaComponent(0.95)
            )
            attachmentGuideContainer.addChildNode(line)
        }
    }

    private func rebuildMotionTrails(
        _ motionTrails: [Animate3DMotionTrail],
        showsMotionPaths: Bool
    ) {
        let signature = motionTrails.reduce(into: Hasher()) { hasher, trail in
            hasher.combine(trail)
            hasher.combine("motion-trail:\(trail.id)" == currentSelectedDebugGuideID)
        }.finalize()

        guard showsMotionPaths else {
            motionTrailSignature = nil
            debugGuideSelectionsByID = debugGuideSelectionsByID.filter { !$0.key.hasPrefix("motion-trail:") }
            motionTrailContainer.childNodes.forEach { $0.removeFromParentNode() }
            return
        }

        guard motionTrailSignature != signature else { return }
        motionTrailSignature = signature
        motionTrailContainer.childNodes.forEach { $0.removeFromParentNode() }

        for trail in motionTrails where trail.points.count > 1 {
            let guideID = "motion-trail:\(trail.id)"
            let isHovered = hoveredDebugGuideID == guideID
            let isSelected = currentSelectedDebugGuideID == guideID
            let color = Animate3DWireRigNode.palette[trail.colorIndex % Animate3DWireRigNode.palette.count]
                .withAlphaComponent(isSelected ? 1.0 : isHovered ? 0.95 : (trail.kind == .character ? 0.95 : 0.7))
            let guideSelection = Animate3DDebugGuideSelection(
                id: guideID,
                kind: .motionTrail,
                title: trail.label,
                detailLines: [
                    trail.kind == .character ? "character trail" : "object trail",
                    "Samples \(trail.points.count)",
                    "Start \(Self.formatDebugGuidePoint(trail.points.first ?? .zero)) → End \(Self.formatDebugGuidePoint(trail.points.last ?? .zero))"
                ]
            )
            debugGuideSelectionsByID[guideID] = guideSelection

            let root = SCNNode()
            root.name = Self.debugGuideNodeNamePrefix + guideID
            let node = Self.makePolylineNode(points: trail.points, color: color)
            root.addChildNode(node)

            for point in trail.points {
                let marker = Self.makeDebugGuidePointNode(
                    position: point,
                    color: isSelected ? color.withAlphaComponent(0.28) : isHovered ? color.withAlphaComponent(0.14) : nil,
                    radius: isSelected ? 0.13 : 0.11
                )
                root.addChildNode(marker)
            }

            motionTrailContainer.addChildNode(root)
        }
    }

    private func rebuildCameraPath(
        cameraPathPoints: [SIMD3<Double>],
        focusPoints: [SIMD3<Double>],
        showsCameraPath: Bool
    ) {
        let signature = cameraPathPoints.reduce(into: Hasher()) { hasher, point in
            hasher.combine(point.x)
            hasher.combine(point.y)
            hasher.combine(point.z)
        }.finalize() ^ focusPoints.reduce(into: Hasher()) { hasher, point in
            hasher.combine(point.x)
            hasher.combine(point.y)
            hasher.combine(point.z)
        }.finalize() ^ {
            var hasher = Hasher()
            hasher.combine(currentSelectedDebugGuideID)
            return hasher.finalize()
        }()

        guard showsCameraPath else {
            cameraPathSignature = nil
            debugGuideSelectionsByID = debugGuideSelectionsByID.filter {
                !$0.key.hasPrefix("camera-path") && !$0.key.hasPrefix("focus-path") && !$0.key.hasPrefix("camera-ray:")
            }
            cameraPathContainer.childNodes.forEach { $0.removeFromParentNode() }
            return
        }

        guard cameraPathSignature != signature else { return }
        cameraPathSignature = signature
        cameraPathContainer.childNodes.forEach { $0.removeFromParentNode() }

        if cameraPathPoints.count > 1 {
            let guideID = "camera-path"
            let isHovered = hoveredDebugGuideID == guideID
            let isSelected = currentSelectedDebugGuideID == guideID
            debugGuideSelectionsByID[guideID] = Animate3DDebugGuideSelection(
                id: guideID,
                kind: .cameraPath,
                title: "Authored Camera Path",
                detailLines: [
                    "Samples \(cameraPathPoints.count)",
                    "Start \(Self.formatDebugGuidePoint(cameraPathPoints.first ?? .zero))",
                    "End \(Self.formatDebugGuidePoint(cameraPathPoints.last ?? .zero))"
                ]
            )
            let root = SCNNode()
            root.name = Self.debugGuideNodeNamePrefix + guideID
            let cameraLine = Self.makePolylineNode(
                points: cameraPathPoints,
                color: NSColor.systemCyan.withAlphaComponent(isSelected ? 1.0 : isHovered ? 0.95 : 0.95)
            )
            root.addChildNode(cameraLine)
            for point in cameraPathPoints {
                root.addChildNode(
                    Self.makeDebugGuidePointNode(
                        position: point,
                        color: isSelected ? NSColor.systemCyan.withAlphaComponent(0.24) : isHovered ? NSColor.systemCyan.withAlphaComponent(0.12) : nil,
                        radius: isSelected ? 0.12 : 0.1
                    )
                )
            }
            cameraPathContainer.addChildNode(root)
        }

        if focusPoints.count > 1 {
            let guideID = "focus-path"
            let isHovered = hoveredDebugGuideID == guideID
            let isSelected = currentSelectedDebugGuideID == guideID
            debugGuideSelectionsByID[guideID] = Animate3DDebugGuideSelection(
                id: guideID,
                kind: .focusPath,
                title: "Camera Focus Path",
                detailLines: [
                    "Samples \(focusPoints.count)",
                    "Start \(Self.formatDebugGuidePoint(focusPoints.first ?? .zero))",
                    "End \(Self.formatDebugGuidePoint(focusPoints.last ?? .zero))"
                ]
            )
            let root = SCNNode()
            root.name = Self.debugGuideNodeNamePrefix + guideID
            let focusLine = Self.makePolylineNode(
                points: focusPoints,
                color: NSColor.systemYellow.withAlphaComponent(isSelected ? 0.88 : isHovered ? 0.72 : 0.55)
            )
            root.addChildNode(focusLine)
            for point in focusPoints {
                root.addChildNode(
                    Self.makeDebugGuidePointNode(
                        position: point,
                        color: isSelected ? NSColor.systemYellow.withAlphaComponent(0.22) : isHovered ? NSColor.systemYellow.withAlphaComponent(0.12) : nil,
                        radius: isSelected ? 0.12 : 0.1
                    )
                )
            }
            cameraPathContainer.addChildNode(root)
        }

        let rayCount = min(cameraPathPoints.count, focusPoints.count)
        guard rayCount > 0 else { return }

        for index in 0..<rayCount {
            let guideID = "camera-ray:\(index)"
            let isHovered = hoveredDebugGuideID == guideID
            let isSelected = currentSelectedDebugGuideID == guideID
            debugGuideSelectionsByID[guideID] = Animate3DDebugGuideSelection(
                id: guideID,
                kind: .cameraRay,
                title: "Camera Ray \(index + 1)",
                detailLines: [
                    "Cam \(Self.formatDebugGuidePoint(cameraPathPoints[index]))",
                    "Focus \(Self.formatDebugGuidePoint(focusPoints[index]))"
                ]
            )
            let alpha = index == rayCount - 1 ? 0.85 : 0.22
            let root = SCNNode()
            root.name = Self.debugGuideNodeNamePrefix + guideID
            let ray = Self.makeLineNode(
                from: SCNVector3(
                    Float(cameraPathPoints[index].x),
                    Float(cameraPathPoints[index].y),
                    Float(cameraPathPoints[index].z)
                ),
                to: SCNVector3(
                    Float(focusPoints[index].x),
                    Float(focusPoints[index].y),
                    Float(focusPoints[index].z)
                ),
                color: NSColor.systemCyan.withAlphaComponent(isSelected ? 0.95 : isHovered ? 0.72 : alpha)
            )
            root.addChildNode(ray)
            let midpoint = (cameraPathPoints[index] + focusPoints[index]) * 0.5
            root.addChildNode(
                Self.makeDebugGuidePointNode(
                    position: midpoint,
                    color: isSelected ? NSColor.systemMint.withAlphaComponent(0.28) : isHovered ? NSColor.systemMint.withAlphaComponent(0.12) : nil,
                    radius: isSelected ? 0.14 : 0.11
                )
            )
            cameraPathContainer.addChildNode(root)
        }
    }

    private func rebuildShotAnchors(
        _ shotAnchors: [Animate3DShotAnchor],
        activeFrame: Int,
        showsShotLabels: Bool
    ) {
        let signature = shotAnchors.reduce(into: Hasher()) { hasher, anchor in
            hasher.combine(anchor)
            hasher.combine(anchor.isActive(frame: activeFrame))
        }.finalize()

        guard showsShotLabels else {
            shotAnchorSignature = nil
            shotAnchorContainer.childNodes.forEach { $0.removeFromParentNode() }
            return
        }

        guard shotAnchorSignature != signature else { return }
        shotAnchorSignature = signature
        shotAnchorContainer.childNodes.forEach { $0.removeFromParentNode() }

        for anchor in shotAnchors {
            let isActive = anchor.isActive(frame: activeFrame)
            let isHovered = anchor.id == hoveredShotAnchorID
            let titleColor = isActive
                ? NSColor.systemOrange.withAlphaComponent(0.95)
                : isHovered
                ? NSColor.systemIndigo.withAlphaComponent(0.95)
                : NSColor.systemBlue.withAlphaComponent(0.72)
            let pointerColor = isActive
                ? NSColor.systemOrange.withAlphaComponent(0.82)
                : isHovered
                ? NSColor.systemIndigo.withAlphaComponent(0.72)
                : NSColor.systemBlue.withAlphaComponent(0.38)

            let anchorRoot = SCNNode()
            anchorRoot.name = Self.shotAnchorNodeNamePrefix + anchor.id

            let pointer = Self.makeLineNode(
                from: SCNVector3(
                    Float(anchor.worldPosition.x),
                    Float(anchor.worldPosition.y - 0.16),
                    Float(anchor.worldPosition.z)
                ),
                to: SCNVector3(
                    Float(anchor.focusPosition.x),
                    Float(anchor.focusPosition.y),
                    Float(anchor.focusPosition.z)
                ),
                color: pointerColor
            )
            pointer.name = Self.shotAnchorPointerNodeName
            anchorRoot.addChildNode(pointer)

            let text = SCNText(string: anchor.title, extrusionDepth: 0.0)
            text.font = NSFont.systemFont(ofSize: 0.2, weight: isActive ? .bold : .semibold)
            text.flatness = 0.2
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = titleColor
            material.emission.contents = titleColor
            material.isDoubleSided = true
            text.materials = [material]

            let textNode = SCNNode(geometry: text)
            textNode.scale = SCNVector3(
                isActive ? 0.26 : isHovered ? 0.24 : 0.22,
                isActive ? 0.26 : isHovered ? 0.24 : 0.22,
                isActive ? 0.26 : isHovered ? 0.24 : 0.22
            )
            textNode.position = SCNVector3(
                Float(anchor.worldPosition.x),
                Float(anchor.worldPosition.y),
                Float(anchor.worldPosition.z)
            )
            textNode.name = Self.shotAnchorTextNodeName
            textNode.constraints = [SCNBillboardConstraint()]
            recenterTextNode(textNode)
            anchorRoot.addChildNode(textNode)

            let dot = SCNNode(geometry: SCNSphere(radius: isActive ? 0.11 : isHovered ? 0.095 : 0.08))
            let dotMaterial = SCNMaterial()
            dotMaterial.lightingModel = .constant
            dotMaterial.diffuse.contents = titleColor
            dotMaterial.emission.contents = titleColor
            dotMaterial.fillMode = .lines
            dot.geometry?.materials = [dotMaterial]
            dot.position = SCNVector3(
                Float(anchor.focusPosition.x),
                Float(anchor.focusPosition.y),
                Float(anchor.focusPosition.z)
            )
            dot.name = Self.shotAnchorDotNodeName
            anchorRoot.addChildNode(dot)

            let worldPickTarget = Self.makeShotAnchorPickTarget(
                radius: isHovered ? 0.42 : 0.34,
                color: isHovered ? titleColor.withAlphaComponent(0.06) : nil
            )
            worldPickTarget.position = textNode.position
            worldPickTarget.name = Self.shotAnchorWorldPickNodeName
            anchorRoot.addChildNode(worldPickTarget)

            let focusPickTarget = Self.makeShotAnchorPickTarget(
                radius: isHovered ? 0.24 : 0.18,
                color: nil
            )
            focusPickTarget.position = dot.position
            focusPickTarget.name = Self.shotAnchorFocusPickNodeName
            anchorRoot.addChildNode(focusPickTarget)

            shotAnchorContainer.addChildNode(anchorRoot)
        }
    }

    @discardableResult
    private func handleShotAnchorClick(at point: NSPoint) -> Bool {
        let hitResults = hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.boundingBoxOnly: false
        ])

        guard let anchorID = hitResults.compactMap({ shotAnchorID(for: $0.node) }).first else {
            return false
        }

        onShotAnchorSelected?(anchorID)
        return true
    }

    @discardableResult
    private func handleDebugGizmoClick(at point: NSPoint) -> Bool {
        let hitResults = hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.boundingBoxOnly: false
        ])

        guard let gizmo = hitResults.compactMap({ debugGizmo(for: $0.node) }).first else {
            return false
        }

        setHoveredDebugGizmo(gizmo)
        onDebugGizmoSelected?(gizmo)
        return true
    }

    @discardableResult
    private func handleDebugGuideClick(at point: NSPoint) -> Bool {
        let hitResults = hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.boundingBoxOnly: false
        ])

        guard let guide = hitResults.compactMap({ debugGuideSelection(for: $0.node) }).first else {
            return false
        }

        setHoveredDebugGuideSelection(guide)
        onDebugGuideSelected?(guide)
        return true
    }

    private func updateHoveredInteractivity(at point: NSPoint) {
        let hitResults = hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.boundingBoxOnly: false
        ])

        let hoveredAnchorID = currentShowsShotLabels
            ? hitResults.compactMap { shotAnchorID(for: $0.node) }.first
            : nil
        setHoveredShotAnchorID(hoveredAnchorID)

        if hoveredAnchorID != nil {
            setHoveredDebugGizmo(nil)
            setHoveredDebugGuideSelection(nil)
            return
        }

        let hoveredGizmo = hitResults.compactMap { debugGizmo(for: $0.node) }.first
        setHoveredDebugGizmo(hoveredGizmo)
        if hoveredGizmo != nil {
            setHoveredDebugGuideSelection(nil)
            return
        }

        let hoveredGuide = hitResults.compactMap { debugGuideSelection(for: $0.node) }.first
        setHoveredDebugGuideSelection(hoveredGuide)
    }

    private func setHoveredShotAnchorID(_ anchorID: String?) {
        guard hoveredShotAnchorID != anchorID else { return }
        hoveredShotAnchorID = anchorID
        updateShotAnchorAppearance(activeFrame: currentShotAnchorFrame)
        needsDisplay = true
    }

    private func setHoveredDebugGizmo(_ gizmo: Animate3DDebugGizmo?) {
        let visibleGizmo: Animate3DDebugGizmo?
        switch gizmo {
        case .camera where currentShowsCameraGizmo:
            visibleGizmo = gizmo
        case .focus where currentShowsFocusMarker:
            visibleGizmo = gizmo
        case nil:
            visibleGizmo = nil
        default:
            visibleGizmo = nil
        }

        guard hoveredDebugGizmo != visibleGizmo else { return }
        hoveredDebugGizmo = visibleGizmo
        updateDebugGizmoAppearance()
        onDebugGizmoHovered?(visibleGizmo)
        needsDisplay = true
    }

    private func setHoveredDebugGuideSelection(_ guide: Animate3DDebugGuideSelection?) {
        let visibleGuide: Animate3DDebugGuideSelection?
        if let guide, isDebugGuideIDVisible(guide.id) {
            visibleGuide = guide
        } else {
            visibleGuide = nil
        }

        guard hoveredDebugGuideID != visibleGuide?.id else { return }
        hoveredDebugGuideID = visibleGuide?.id
        onDebugGuideHovered?(visibleGuide)
        needsDisplay = true
    }

    private func updateShotAnchorAppearance(activeFrame: Int) {
        guard currentShowsShotLabels else { return }

        for anchor in currentShotAnchors {
            guard let anchorRoot = shotAnchorContainer.childNode(
                withName: Self.shotAnchorNodeNamePrefix + anchor.id,
                recursively: false
            ) else {
                continue
            }

            let isActive = anchor.isActive(frame: activeFrame)
            let isHovered = anchor.id == hoveredShotAnchorID
            let titleColor = isActive
                ? NSColor.systemOrange.withAlphaComponent(0.95)
                : isHovered
                ? NSColor.systemIndigo.withAlphaComponent(0.95)
                : NSColor.systemBlue.withAlphaComponent(0.72)
            let pointerColor = isActive
                ? NSColor.systemOrange.withAlphaComponent(0.82)
                : isHovered
                ? NSColor.systemIndigo.withAlphaComponent(0.72)
                : NSColor.systemBlue.withAlphaComponent(0.38)

            if let pointerMaterial = anchorRoot
                .childNode(withName: Self.shotAnchorPointerNodeName, recursively: false)?
                .geometry?
                .firstMaterial {
                pointerMaterial.diffuse.contents = pointerColor
                pointerMaterial.emission.contents = pointerColor
            }

            if let textNode = anchorRoot.childNode(withName: Self.shotAnchorTextNodeName, recursively: false),
               let text = textNode.geometry as? SCNText {
                text.font = NSFont.systemFont(ofSize: 0.2, weight: isActive ? .bold : .semibold)
                text.firstMaterial?.diffuse.contents = titleColor
                text.firstMaterial?.emission.contents = titleColor
                let scale: Float = isActive ? 0.26 : isHovered ? 0.24 : 0.22
                textNode.scale = SCNVector3(scale, scale, scale)
                recenterTextNode(textNode)
            }

            if let dotNode = anchorRoot.childNode(withName: Self.shotAnchorDotNodeName, recursively: false),
               let sphere = dotNode.geometry as? SCNSphere {
                sphere.radius = isActive ? 0.11 : isHovered ? 0.095 : 0.08
                sphere.firstMaterial?.diffuse.contents = titleColor
                sphere.firstMaterial?.emission.contents = titleColor
            }

            if let worldPickNode = anchorRoot.childNode(withName: Self.shotAnchorWorldPickNodeName, recursively: false),
               let sphere = worldPickNode.geometry as? SCNSphere {
                sphere.radius = isHovered ? 0.42 : 0.34
                let color = isHovered ? titleColor.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.001)
                sphere.firstMaterial?.diffuse.contents = color
                sphere.firstMaterial?.emission.contents = isHovered ? color : NSColor.clear
                worldPickNode.opacity = isHovered ? 0.18 : 0.001
            }

            if let focusPickNode = anchorRoot.childNode(withName: Self.shotAnchorFocusPickNodeName, recursively: false),
               let sphere = focusPickNode.geometry as? SCNSphere {
                sphere.radius = isHovered ? 0.24 : 0.18
            }
        }
    }

    private func shotAnchorID(for node: SCNNode?) -> String? {
        var currentNode = node
        while let current = currentNode {
            if let name = current.name,
               name.hasPrefix(Self.shotAnchorNodeNamePrefix) {
                return String(name.dropFirst(Self.shotAnchorNodeNamePrefix.count))
            }
            currentNode = current.parent
        }
        return nil
    }

    private func debugGizmo(for node: SCNNode?) -> Animate3DDebugGizmo? {
        var currentNode = node
        while let current = currentNode {
            if let name = current.name,
               name.hasPrefix(Self.debugGizmoNodeNamePrefix) {
                return Animate3DDebugGizmo(
                    rawValue: String(name.dropFirst(Self.debugGizmoNodeNamePrefix.count))
                )
            }
            currentNode = current.parent
        }
        return nil
    }

    private func debugGuideSelection(for node: SCNNode?) -> Animate3DDebugGuideSelection? {
        guard let guideID = debugGuideID(for: node) else { return nil }
        guard isDebugGuideIDVisible(guideID) else { return nil }
        return debugGuideSelectionsByID[guideID]
    }

    private func debugGuideID(for node: SCNNode?) -> String? {
        var currentNode = node
        while let current = currentNode {
            if let name = current.name,
               name.hasPrefix(Self.debugGuideNodeNamePrefix) {
                return String(name.dropFirst(Self.debugGuideNodeNamePrefix.count))
            }
            currentNode = current.parent
        }
        return nil
    }

    private func isDebugGuideIDVisible(_ guideID: String) -> Bool {
        if guideID.hasPrefix("motion-trail:") {
            return currentShowsMotionPaths
        }
        return currentShowsCameraPath
    }

    private static func makeShotAnchorPickTarget(
        radius: CGFloat,
        color: NSColor?
    ) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        let material = SCNMaterial()
        material.lightingModel = .constant
        let baseColor = color ?? NSColor.white.withAlphaComponent(0.001)
        material.diffuse.contents = baseColor
        material.emission.contents = color ?? NSColor.clear
        material.isDoubleSided = true
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.opacity = 0.001
        if color != nil {
            node.opacity = 0.18
        }
        return node
    }

    private static func makeDebugGizmoPickTarget(radius: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white.withAlphaComponent(0.001)
        material.emission.contents = NSColor.clear
        material.isDoubleSided = true
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.opacity = 0.001
        return node
    }

    private static func makeDebugGuidePointNode(
        position: SIMD3<Double>,
        color: NSColor?,
        radius: CGFloat
    ) -> SCNNode {
        let node = makeShotAnchorPickTarget(radius: radius, color: color)
        node.position = SCNVector3(Float(position.x), Float(position.y), Float(position.z))
        return node
    }

    private static func formatDebugGuidePoint(_ vector: SIMD3<Double>) -> String {
        "(\(String(format: "%.2f", vector.x)), \(String(format: "%.2f", vector.y)), \(String(format: "%.2f", vector.z)))"
    }

    private func updateShotLabel(
        snapshot: Animate3DFrameSnapshot,
        showsShotLabels: Bool
    ) {
        let components = [
            snapshot.activeShotTitle ?? snapshot.camera.shot?.displayName ?? snapshot.camera.shotLabel,
            snapshot.camera.focusCharacterName.map { "focus \($0)" },
            snapshot.camera.beatLabel,
            snapshot.camera.shotIntent
        ]
        .compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard showsShotLabels, !components.isEmpty else {
            shotLabelNode.isHidden = true
            return
        }

        shotLabelText.string = components.joined(separator: "\n")
        recenterTextNode(shotLabelNode)
        shotLabelNode.position = SCNVector3(
            Float(snapshot.camera.lookAt.x),
            Float(snapshot.camera.lookAt.y + 0.55),
            Float(snapshot.camera.lookAt.z)
        )
        shotLabelNode.isHidden = false
    }

    private func resolvedAttachmentTargetPosition(attachmentTarget: String?) -> SCNVector3? {
        guard let attachment = ObjectAttachmentReference.parse(attachmentTarget) else {
            return nil
        }

        switch attachment.kind {
        case .character:
            guard let rig = rigNodes.values.first(where: { $0.matches(targetName: attachment.targetName) }) else {
                return nil
            }
            return rig.anchorWorldPosition(anchor: attachment.anchor)
        case .object:
            guard let prop = objectNodes.values.first(where: { $0.matches(targetName: attachment.targetName) }) else {
                return nil
            }
            return prop.anchorWorldPosition(anchor: attachment.anchor)
        case .world:
            return worldAttachmentPosition(named: attachment.targetName, anchor: attachment.anchor)
        }
    }

    private func worldAttachmentPosition(named name: String, anchor: String?) -> SCNVector3 {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "center", "center_air":
            return SCNVector3(0, 1.3, 0)
        case "center_floor":
            return SCNVector3(0, 0, 0)
        case "left_floor", "stage_left":
            return SCNVector3(-3.1, 0, 0)
        case "right_floor", "stage_right":
            return SCNVector3(3.1, 0, 0)
        case "top_center", "upper_center":
            return SCNVector3(0, 2.8, -2.0)
        case "top_left":
            return SCNVector3(-3.5, 2.8, -2.0)
        case "top_right":
            return SCNVector3(3.5, 2.8, -2.0)
        default:
            if let anchor, !anchor.isEmpty {
                return worldAttachmentPosition(named: anchor, anchor: nil)
            }
            return SCNVector3(0, 0, 0)
        }
    }

    private static func makeLineNode(
        from start: SCNVector3,
        to end: SCNVector3,
        color: NSColor
    ) -> SCNNode {
        let vertices = [start, end]
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [UInt32] = [0, 1]
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: 1,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.fillMode = .lines
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func makePolylineNode(
        points: [SIMD3<Double>],
        color: NSColor
    ) -> SCNNode {
        let vertices = points.map { point in
            SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        }
        let source = SCNGeometrySource(vertices: vertices)
        var indices: [UInt32] = []
        for index in 0..<(vertices.count - 1) {
            indices.append(UInt32(index))
            indices.append(UInt32(index + 1))
        }
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: max(indices.count / 2, 0),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.fillMode = .lines
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func recenterTextNode(_ node: SCNNode) {
        let (minBounds, maxBounds) = node.boundingBox
        let width = maxBounds.x - minBounds.x
        node.pivot = SCNMatrix4MakeTranslation(minBounds.x + (width * 0.5), minBounds.y, 0)
    }

    private static func makeGridNode(size: Int, divisions: Int) -> SCNNode {
        let half = Float(size) * 0.5
        let step = Float(size) / Float(max(divisions, 1))
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []

        for index in 0...divisions {
            let offset = -half + (Float(index) * step)

            let verticalStart = UInt32(vertices.count)
            vertices.append(SCNVector3(offset, 0, -half))
            vertices.append(SCNVector3(offset, 0, half))
            indices.append(verticalStart)
            indices.append(verticalStart + 1)

            let horizontalStart = UInt32(vertices.count)
            vertices.append(SCNVector3(-half, 0, offset))
            vertices.append(SCNVector3(half, 0, offset))
            indices.append(horizontalStart)
            indices.append(horizontalStart + 1)
        }

        let source = SCNGeometrySource(vertices: vertices)
        let data = indices.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(calibratedWhite: 0.35, alpha: 1)
        material.emission.contents = NSColor(calibratedWhite: 0.35, alpha: 1)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(0, 0, 0)
        return node
    }
}

@available(macOS 26.0, *)
@MainActor
private final class Animate3DWireRigNode {
    let name: String
    let rootNode = SCNNode()
    private let torsoNode: SCNNode
    private let headNode: SCNNode
    private let hairNode: SCNNode
    private let neckNode: SCNNode
    private let hipNode: SCNNode
    private let leftShoulderNode: SCNNode
    private let rightShoulderNode: SCNNode
    private let leftElbowNode: SCNNode
    private let rightElbowNode: SCNNode
    private let leftWristNode: SCNNode
    private let rightWristNode: SCNNode
    private let leftKneeNode: SCNNode
    private let rightKneeNode: SCNNode
    // Composite arm/leg container nodes for pivot-based rotation
    private let leftArmNode = SCNNode()
    private let rightArmNode = SCNNode()
    private let leftLegNode = SCNNode()
    private let rightLegNode = SCNNode()
    private let shadowNode: SCNNode
    private let labelNode: SCNNode
    private let color: NSColor
    private let rootCutoutContainer = SCNNode()
    private let torsoCutoutContainer = SCNNode()
    private let headCutoutContainer = SCNNode()
    private let leftArmCutoutContainer = SCNNode()
    private let rightArmCutoutContainer = SCNNode()
    private let leftLegCutoutContainer = SCNNode()
    private let rightLegCutoutContainer = SCNNode()
    // Anime-style proportions: ~2.2 units tall, legs ~60% of height
    private let torsoBasePosition = SCNVector3(0, 1.28, 0)
    private let neckBasePosition = SCNVector3(0, 1.78, 0)
    private let headBasePosition = SCNVector3(0, 2.02, 0)
    private let hipBasePosition = SCNVector3(0, 0.88, 0)
    private let leftShoulderBasePosition = SCNVector3(-0.28, 1.70, 0)
    private let rightShoulderBasePosition = SCNVector3(0.28, 1.70, 0)
    private let leftArmBasePosition = SCNVector3(-0.28, 1.66, 0)
    private let rightArmBasePosition = SCNVector3(0.28, 1.66, 0)
    private let leftLegBasePosition = SCNVector3(-0.12, 0.86, 0)
    private let rightLegBasePosition = SCNVector3(0.12, 0.86, 0)
    private let labelBasePosition = SCNVector3(-0.4, 2.6, 0)
    private var cutoutNodesByID: [String: SCNNode] = [:]

    init(name: String, colorIndex: Int) {
        self.name = name
        self.color = Self.palette[colorIndex % Self.palette.count]
        let skinColor = color.blended(withFraction: 0.22, of: .white) ?? color
        let armColor = color.blended(withFraction: 0.08, of: .white) ?? color
        let legColor = color.blended(withFraction: 0.04, of: .black) ?? color
        let jointColor = color.blended(withFraction: 0.14, of: .black) ?? color
        let hairColor = color.blended(withFraction: 0.30, of: .black) ?? color

        // Torso: slimmer capsule for anime proportions
        torsoNode = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.14, height: 0.80),
            fillColor: color
        )
        // Head: slightly larger for anime style
        headNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.24),
            fillColor: skinColor
        )
        // Hair: flattened sphere on top/back of head
        hairNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.26),
            fillColor: hairColor
        )
        // Neck: small cylinder connecting head to torso
        neckNode = Self.makeToonBodyPartNode(
            geometry: SCNCylinder(radius: 0.06, height: 0.16),
            fillColor: skinColor
        )
        // Hip joint sphere at torso base
        hipNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.13),
            fillColor: color.blended(withFraction: 0.10, of: .black) ?? color
        )
        // Shoulder joints
        leftShoulderNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.065), fillColor: jointColor
        )
        rightShoulderNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.065), fillColor: jointColor
        )
        // Elbow joints
        leftElbowNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.052), fillColor: jointColor
        )
        rightElbowNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.052), fillColor: jointColor
        )
        // Wrist joints
        leftWristNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.045), fillColor: jointColor
        )
        rightWristNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.045), fillColor: jointColor
        )
        // Knee joints
        leftKneeNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.062), fillColor: jointColor
        )
        rightKneeNode = Self.makeToonBodyPartNode(
            geometry: SCNSphere(radius: 0.062), fillColor: jointColor
        )

        // Build composite arm nodes: upper arm, elbow, forearm, wrist
        let leftUpperArm = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.055, height: 0.44), fillColor: armColor
        )
        let leftForearm = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.048, height: 0.42), fillColor: armColor
        )
        leftUpperArm.position = SCNVector3(0, -0.22, 0)
        leftElbowNode.position = SCNVector3(0, -0.44, 0)
        leftForearm.position = SCNVector3(0, -0.64, 0)
        leftWristNode.position = SCNVector3(0, -0.86, 0)
        leftArmNode.addChildNode(leftUpperArm)
        leftArmNode.addChildNode(leftElbowNode)
        leftArmNode.addChildNode(leftForearm)
        leftArmNode.addChildNode(leftWristNode)

        let rightUpperArm = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.055, height: 0.44), fillColor: armColor
        )
        let rightForearm = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.048, height: 0.42), fillColor: armColor
        )
        rightUpperArm.position = SCNVector3(0, -0.22, 0)
        rightElbowNode.position = SCNVector3(0, -0.44, 0)
        rightForearm.position = SCNVector3(0, -0.64, 0)
        rightWristNode.position = SCNVector3(0, -0.86, 0)
        rightArmNode.addChildNode(rightUpperArm)
        rightArmNode.addChildNode(rightElbowNode)
        rightArmNode.addChildNode(rightForearm)
        rightArmNode.addChildNode(rightWristNode)

        // Build composite leg nodes: upper leg, knee, lower leg
        let leftUpperLeg = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.072, height: 0.48), fillColor: legColor
        )
        let leftLowerLeg = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.06, height: 0.46), fillColor: legColor
        )
        leftUpperLeg.position = SCNVector3(0, -0.24, 0)
        leftKneeNode.position = SCNVector3(0, -0.48, 0)
        leftLowerLeg.position = SCNVector3(0, -0.70, 0)
        leftLegNode.addChildNode(leftUpperLeg)
        leftLegNode.addChildNode(leftKneeNode)
        leftLegNode.addChildNode(leftLowerLeg)

        let rightUpperLeg = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.072, height: 0.48), fillColor: legColor
        )
        let rightLowerLeg = Self.makeToonBodyPartNode(
            geometry: SCNCapsule(capRadius: 0.06, height: 0.46), fillColor: legColor
        )
        rightUpperLeg.position = SCNVector3(0, -0.24, 0)
        rightKneeNode.position = SCNVector3(0, -0.48, 0)
        rightLowerLeg.position = SCNVector3(0, -0.70, 0)
        rightLegNode.addChildNode(rightUpperLeg)
        rightLegNode.addChildNode(rightKneeNode)
        rightLegNode.addChildNode(rightLowerLeg)

        shadowNode = Self.makeGroundShadowNode(width: 0.80, length: 0.50)

        let text = SCNText(string: name, extrusionDepth: 0.0)
        text.font = NSFont.systemFont(ofSize: 0.22, weight: .semibold)
        text.flatness = 0.2
        labelNode = SCNNode(geometry: text)

        configureLabel(labelNode.geometry)

        // Face plate on head
        let facePlate = SCNNode(
            geometry: SCNPlane(width: 0.16, height: 0.12)
        )
        facePlate.geometry?.materials = [Self.makeFillMaterial(
            color: NSColor.white.withAlphaComponent(0.92),
            multiply: NSColor(calibratedWhite: 0.96, alpha: 1)
        )]
        facePlate.position = SCNVector3(0, 0.0, 0.21)
        headNode.addChildNode(facePlate)

        // Torso detail plate (collar/shirt)
        let torsoPlate = SCNNode(
            geometry: SCNBox(width: 0.18, height: 0.30, length: 0.06, chamferRadius: 0.03)
        )
        torsoPlate.geometry?.materials = [Self.makeFillMaterial(
            color: color.blended(withFraction: 0.28, of: .white) ?? color,
            multiply: NSColor(calibratedWhite: 0.9, alpha: 1)
        )]
        torsoPlate.position = SCNVector3(0, 0.06, 0.12)
        torsoNode.addChildNode(torsoPlate)

        // Hair positioned on top/back of head, vertically squished to hemisphere
        headNode.addChildNode(hairNode)
        hairNode.position = SCNVector3(0, 0.12, -0.04)
        hairNode.scale = SCNVector3(1.0, 0.55, 1.05)

        // Cutout containers
        rootCutoutContainer.name = "animate3d-cutout-container-root"
        torsoCutoutContainer.name = "animate3d-cutout-container-torso"
        headCutoutContainer.name = "animate3d-cutout-container-head"
        leftArmCutoutContainer.name = "animate3d-cutout-container-left-arm"
        rightArmCutoutContainer.name = "animate3d-cutout-container-right-arm"
        leftLegCutoutContainer.name = "animate3d-cutout-container-left-leg"
        rightLegCutoutContainer.name = "animate3d-cutout-container-right-leg"
        rootNode.addChildNode(rootCutoutContainer)
        torsoNode.addChildNode(torsoCutoutContainer)
        headNode.addChildNode(headCutoutContainer)
        leftArmNode.addChildNode(leftArmCutoutContainer)
        rightArmNode.addChildNode(rightArmCutoutContainer)
        leftLegNode.addChildNode(leftLegCutoutContainer)
        rightLegNode.addChildNode(rightLegCutoutContainer)

        // Assemble skeleton hierarchy
        rootNode.addChildNode(shadowNode)
        rootNode.addChildNode(hipNode)
        rootNode.addChildNode(torsoNode)
        rootNode.addChildNode(neckNode)
        rootNode.addChildNode(headNode)
        rootNode.addChildNode(leftShoulderNode)
        rootNode.addChildNode(rightShoulderNode)
        rootNode.addChildNode(leftArmNode)
        rootNode.addChildNode(rightArmNode)
        rootNode.addChildNode(leftLegNode)
        rootNode.addChildNode(rightLegNode)
        rootNode.addChildNode(labelNode)

        // Set base positions
        shadowNode.position = SCNVector3(0, 0.02, 0)
        hipNode.position = hipBasePosition
        torsoNode.position = torsoBasePosition
        neckNode.position = neckBasePosition
        headNode.position = headBasePosition
        leftShoulderNode.position = leftShoulderBasePosition
        rightShoulderNode.position = rightShoulderBasePosition
        leftArmNode.position = leftArmBasePosition
        rightArmNode.position = rightArmBasePosition
        leftLegNode.position = leftLegBasePosition
        rightLegNode.position = rightLegBasePosition
        // Pivot at top of arm/leg containers so rotation swings from joint
        leftArmNode.pivot = SCNMatrix4MakeTranslation(0, 0, 0)
        rightArmNode.pivot = SCNMatrix4MakeTranslation(0, 0, 0)
        leftLegNode.pivot = SCNMatrix4MakeTranslation(0, 0, 0)
        rightLegNode.pivot = SCNMatrix4MakeTranslation(0, 0, 0)
        // Neutral pose: arms hang at sides, legs slightly apart
        leftArmNode.eulerAngles.z = CGFloat(0.06)
        rightArmNode.eulerAngles.z = CGFloat(-0.06)
        leftLegNode.eulerAngles.z = CGFloat(0.03)
        rightLegNode.eulerAngles.z = CGFloat(-0.03)
        labelNode.position = labelBasePosition
        labelNode.scale = SCNVector3(0.28, 0.28, 0.28)
        labelNode.constraints = [SCNBillboardConstraint()]

        // Upgrade wireframe primitives to mannequin humanoid
        upgradeToMannequin()
    }

    // MARK: - Mannequin Upgrade

    /// Replaces the old capsule/sphere wireframe geometry with a proper mannequin
    /// humanoid from `Animate3DModelFactory`. The mannequin parts are placed as
    /// children of the existing animation container nodes so breathing, walking,
    /// and pose evaluation continue to work unchanged.
    private func upgradeToMannequin() {
        let mannequin = Animate3DModelFactory.makeHumanoidPlaceholder(
            color: color,
            label: nil  // label is handled by the existing labelNode
        )

        // Helper: find a named child in the flat mannequin hierarchy
        func part(_ name: String) -> SCNNode? {
            mannequin.childNode(withName: name, recursively: true)
        }

        // Hide old wireframe geometry on container nodes (but keep cutout containers visible).
        // The old geometry children don't have names starting with "animate3d-cutout-container-"
        // so we can identify them by exclusion.
        func hideOldGeometry(on container: SCNNode) {
            for child in container.childNodes {
                guard !(child.name?.hasPrefix("animate3d-cutout-container-") ?? false) else { continue }
                child.isHidden = true
            }
        }

        hideOldGeometry(on: torsoNode)
        hideOldGeometry(on: headNode)
        hideOldGeometry(on: neckNode)
        hideOldGeometry(on: hipNode)
        hideOldGeometry(on: leftShoulderNode)
        hideOldGeometry(on: rightShoulderNode)
        hideOldGeometry(on: leftArmNode)
        hideOldGeometry(on: rightArmNode)
        hideOldGeometry(on: leftLegNode)
        hideOldGeometry(on: rightLegNode)

        // Place mannequin parts as children of existing container nodes.
        // Each part's position is offset relative to its container's base position
        // so it appears at the correct absolute location when the container is at
        // its base position.

        // -- HEAD container at headBasePosition (0, 2.02, 0) --
        if let headPart = part("head") {
            headPart.removeFromParentNode()
            // Factory head at (0, 1.82) → local = (0, 1.82 - 2.02) = (0, -0.20)
            headPart.position = SCNVector3(0, -0.20, 0)
            headNode.addChildNode(headPart)
        }

        // -- NECK container at neckBasePosition (0, 1.78, 0) --
        if let neckPart = part("neck") {
            neckPart.removeFromParentNode()
            // Factory neck at (0, 1.72) → local = (0, -0.06)
            neckPart.position = SCNVector3(0, -0.06, 0)
            neckNode.addChildNode(neckPart)
        }

        // -- TORSO container at torsoBasePosition (0, 1.28, 0) --
        if let torsoPart = part("torso") {
            torsoPart.removeFromParentNode()
            // Factory torso (chest) at (0, 1.48) → local = (0, 0.20)
            torsoPart.position = SCNVector3(0, 0.20, 0)
            torsoNode.addChildNode(torsoPart)
        }
        if let waistPart = part("waist") {
            waistPart.removeFromParentNode()
            // Factory waist at (0, 1.24) → local = (0, -0.04)
            waistPart.position = SCNVector3(0, -0.04, 0)
            torsoNode.addChildNode(waistPart)
        }

        // -- HIP container at hipBasePosition (0, 0.88, 0) --
        if let hipsPart = part("hips") {
            hipsPart.removeFromParentNode()
            // Factory hips at (0, 1.12) → local = (0, 0.24)
            hipsPart.position = SCNVector3(0, 0.24, 0)
            hipNode.addChildNode(hipsPart)
        }

        // -- SHOULDER containers --
        // leftShoulderBasePosition (-0.28, 1.70, 0)
        if let lShoulderPart = part("leftShoulder") {
            lShoulderPart.removeFromParentNode()
            // Factory leftShoulder at (-0.22, 1.62) → local = (0.06, -0.08)
            lShoulderPart.position = SCNVector3(0.06, -0.08, 0)
            leftShoulderNode.addChildNode(lShoulderPart)
        }
        // rightShoulderBasePosition (0.28, 1.70, 0)
        if let rShoulderPart = part("rightShoulder") {
            rShoulderPart.removeFromParentNode()
            // Factory rightShoulder at (0.22, 1.62) → local = (-0.06, -0.08)
            rShoulderPart.position = SCNVector3(-0.06, -0.08, 0)
            rightShoulderNode.addChildNode(rShoulderPart)
        }

        // -- LEFT ARM container at leftArmBasePosition (-0.28, 1.66, 0) --
        // Children are positioned relative to the arm container's origin:
        //   leftUpperArm at (0, -0.22), leftElbow at (0, -0.44), leftForearm at (0, -0.64), leftWrist at (0, -0.86)
        // Factory positions (absolute): leftUpperArm (-0.22, 1.46), leftElbow (-0.22, 1.30),
        //   leftForearm (-0.22, 1.14), leftHand (-0.22, 0.96)
        // Offset from arm base: x = -0.22 - (-0.28) = 0.06; y = factoryY - 1.66
        if let lUpperArm = part("leftUpperArm") {
            lUpperArm.removeFromParentNode()
            lUpperArm.position = SCNVector3(0.06, 1.46 - 1.66, 0)
            leftArmNode.addChildNode(lUpperArm)
        }
        if let lElbow = part("leftElbow") {
            lElbow.removeFromParentNode()
            lElbow.position = SCNVector3(0.06, 1.30 - 1.66, 0)
            leftArmNode.addChildNode(lElbow)
        }
        if let lForearm = part("leftForearm") {
            lForearm.removeFromParentNode()
            lForearm.position = SCNVector3(0.06, 1.14 - 1.66, 0)
            leftArmNode.addChildNode(lForearm)
        }
        if let lHand = part("leftHand") {
            lHand.removeFromParentNode()
            lHand.position = SCNVector3(0.06, 0.96 - 1.66, 0)
            leftArmNode.addChildNode(lHand)
        }

        // -- RIGHT ARM container at rightArmBasePosition (0.28, 1.66, 0) --
        // Factory right arm x = 0.22, offset x = 0.22 - 0.28 = -0.06
        if let rUpperArm = part("rightUpperArm") {
            rUpperArm.removeFromParentNode()
            rUpperArm.position = SCNVector3(-0.06, 1.46 - 1.66, 0)
            rightArmNode.addChildNode(rUpperArm)
        }
        if let rElbow = part("rightElbow") {
            rElbow.removeFromParentNode()
            rElbow.position = SCNVector3(-0.06, 1.30 - 1.66, 0)
            rightArmNode.addChildNode(rElbow)
        }
        if let rForearm = part("rightForearm") {
            rForearm.removeFromParentNode()
            rForearm.position = SCNVector3(-0.06, 1.14 - 1.66, 0)
            rightArmNode.addChildNode(rForearm)
        }
        if let rHand = part("rightHand") {
            rHand.removeFromParentNode()
            rHand.position = SCNVector3(-0.06, 0.96 - 1.66, 0)
            rightArmNode.addChildNode(rHand)
        }

        // -- LEFT LEG container at leftLegBasePosition (-0.12, 0.86, 0) --
        // Factory left leg x = -0.10, offset x = -0.10 - (-0.12) = 0.02
        if let lThigh = part("leftThigh") {
            lThigh.removeFromParentNode()
            lThigh.position = SCNVector3(0.02, 0.88 - 0.86, 0)
            leftLegNode.addChildNode(lThigh)
        }
        if let lKnee = part("leftKnee") {
            lKnee.removeFromParentNode()
            lKnee.position = SCNVector3(0.02, 0.67 - 0.86, 0)
            leftLegNode.addChildNode(lKnee)
        }
        if let lShin = part("leftShin") {
            lShin.removeFromParentNode()
            lShin.position = SCNVector3(0.02, 0.44 - 0.86, 0)
            leftLegNode.addChildNode(lShin)
        }
        if let lFoot = part("leftFoot") {
            lFoot.removeFromParentNode()
            lFoot.position = SCNVector3(0.02, 0.025 - 0.86, 0.03)
            leftLegNode.addChildNode(lFoot)
        }

        // -- RIGHT LEG container at rightLegBasePosition (0.12, 0.86, 0) --
        // Factory right leg x = 0.10, offset x = 0.10 - 0.12 = -0.02
        if let rThigh = part("rightThigh") {
            rThigh.removeFromParentNode()
            rThigh.position = SCNVector3(-0.02, 0.88 - 0.86, 0)
            rightLegNode.addChildNode(rThigh)
        }
        if let rKnee = part("rightKnee") {
            rKnee.removeFromParentNode()
            rKnee.position = SCNVector3(-0.02, 0.67 - 0.86, 0)
            rightLegNode.addChildNode(rKnee)
        }
        if let rShin = part("rightShin") {
            rShin.removeFromParentNode()
            rShin.position = SCNVector3(-0.02, 0.44 - 0.86, 0)
            rightLegNode.addChildNode(rShin)
        }
        if let rFoot = part("rightFoot") {
            rFoot.removeFromParentNode()
            rFoot.position = SCNVector3(-0.02, 0.025 - 0.86, 0.03)
            rightLegNode.addChildNode(rFoot)
        }
    }

    func apply(
        snapshot: Animate3DCharacterSnapshot,
        frame: Int,
        showsLabel: Bool,
        cutoutPlan: Animate3DCharacterPackageCutoutPlan?
    ) {
        rootNode.position = SCNVector3(
            Float(snapshot.worldPosition.x),
            Float(snapshot.worldPosition.y),
            Float(snapshot.worldPosition.z)
        )
        rootNode.eulerAngles.y = CGFloat(snapshot.yawDegrees * .pi / 180.0)
        rootNode.opacity = CGFloat(snapshot.visible ? snapshot.opacity : 0)
        labelNode.isHidden = !showsLabel

        let profile = Animate3DPlaceholderPoseProfile.evaluate(snapshot)
        let isWalking = profile.tags.contains("walk")
        let isPointing = profile.tags.contains("point")
        let isPresenting = profile.tags.contains("present")
        let isListening = profile.tags.contains("listen")
        let isTriumphant = profile.tags.contains("triumph")
        let isSad = profile.tags.contains("sad")
        let isIntense = profile.tags.contains("intense")
        let isSurprised = profile.tags.contains("surprise")
        let isSpeaking = profile.tags.contains("speaking")
        let phase = Float(frame) / 6.0
        let breath = sin(phase * 0.45) * 0.025
        let breathShoulder = sin(phase * 0.45) * 0.008
        let sway = sin(phase * 0.33) * 0.06
        let walkCycle = isWalking ? sin(phase) : Float(0)
        let walkSwing = walkCycle * 0.55
        let curiousTilt: Float = profile.tags.contains("curious") ? 0.18 : 0

        // Idle weight shift: subtle lateral hip sway
        let idleWeightShift = (!isWalking) ? sin(phase * 0.22) * 0.015 : Float(0)
        let idleHipTilt = (!isWalking) ? sin(phase * 0.22) * 0.025 : Float(0)

        var torsoPitch: Float = 0
        var torsoRoll: Float = sway * 0.14
        var torsoYaw: Float = 0
        var hipYaw: Float = 0
        var headPitch: Float = isSpeaking ? sin(phase * 1.15) * 0.05 : 0
        var headRoll: Float = curiousTilt
        var leftArmRoll: Float = 0.06 + (sway * 0.15)
        var rightArmRoll: Float = -0.06 - (sway * 0.15)
        var leftArmPitch: Float = 0
        var rightArmPitch: Float = 0
        var leftLegRoll: Float = 0.03 + (sway * 0.05)
        var rightLegRoll: Float = -0.03 - (sway * 0.05)
        var leftLegPitch: Float = 0
        var rightLegPitch: Float = 0
        var torsoYOffset: Float = breath
        var headYOffset: Float = breath * 0.85
        var shoulderLift: Float = breathShoulder
        var shadowScaleX: Float = 1
        var shadowScaleZ: Float = 1
        var hipXOffset: Float = idleWeightShift
        var hipRoll: Float = idleHipTilt

        if isWalking {
            torsoPitch += 0.06
            // Counter-rotation: shoulders twist opposite to hips
            torsoYaw = -walkCycle * 0.12
            hipYaw = walkCycle * 0.10
            hipRoll = walkCycle * 0.04
            torsoRoll += sway * 0.08
            // Arms swing opposite to legs (natural gait)
            leftArmPitch = walkSwing * 0.8
            rightArmPitch = isPointing ? 0 : -walkSwing * 0.8
            leftArmRoll = 0.10
            rightArmRoll = isPointing ? -1.1 : -0.10
            // Legs swing for walking
            leftLegPitch = -walkSwing * 0.65
            rightLegPitch = walkSwing * 0.65
            leftLegRoll = 0.03
            rightLegRoll = -0.03
            // Vertical bounce
            torsoYOffset += abs(sin(phase * 0.5)) * 0.04
            headYOffset += abs(sin(phase * 0.5)) * 0.025
            // Hip sway side to side during walk
            hipXOffset = walkCycle * 0.03
            shadowScaleX = 1.06
            shadowScaleZ = 0.94
        }

        if isPointing {
            rightArmRoll = -1.1
            rightArmPitch = 0
            leftArmRoll = max(leftArmRoll, 0.20)
            torsoRoll -= 0.1
            headRoll += 0.08
        } else if isPresenting {
            leftArmRoll = 0.88 + (sin(phase * 0.7) * 0.05)
            rightArmRoll = -0.88 - (sin(phase * 0.7) * 0.05)
            leftArmPitch = 0
            rightArmPitch = 0
            torsoPitch -= 0.04
            shoulderLift += 0.025
            shadowScaleX = max(shadowScaleX, 1.06)
        }

        if isListening {
            headRoll += 0.12
            torsoRoll += 0.06
            leftArmRoll = min(leftArmRoll, 0.06)
            rightArmRoll = max(rightArmRoll, -0.06)
        }

        if isTriumphant {
            leftArmRoll = 1.20
            rightArmRoll = -1.20
            leftArmPitch = -0.2
            rightArmPitch = -0.2
            torsoPitch -= 0.05
            headPitch -= 0.06
            torsoYOffset += 0.04
            shadowScaleX = 1.10
        }

        if isSurprised {
            leftArmRoll = max(leftArmRoll, 0.60)
            rightArmRoll = min(rightArmRoll, -0.60)
            headPitch -= 0.14
            torsoYOffset += 0.04
            headYOffset += 0.04
        }

        if isSad {
            torsoPitch += 0.12
            headPitch += 0.18
            leftArmRoll = min(leftArmRoll, 0.03)
            rightArmRoll = max(rightArmRoll, -0.03)
            torsoYOffset -= 0.03
            shoulderLift -= 0.015
            shadowScaleX = max(shadowScaleX, 1.04)
        } else if isIntense {
            torsoPitch -= 0.03
            headRoll += sway * 0.1
            leftArmRoll += 0.08
            rightArmRoll -= 0.08
        }

        if isSpeaking && !isPresenting && !isPointing {
            leftArmPitch += sin(phase * 1.3) * 0.12
            rightArmPitch -= cos(phase * 1.3) * 0.08
            leftArmRoll += sin(phase * 1.3) * 0.10
            rightArmRoll -= cos(phase * 1.3) * 0.06
        }

        // Apply positions with offsets
        torsoNode.position = SCNVector3(
            torsoBasePosition.x + CGFloat(hipXOffset * 0.3),
            torsoBasePosition.y + CGFloat(torsoYOffset),
            torsoBasePosition.z
        )
        neckNode.position = SCNVector3(
            neckBasePosition.x + CGFloat(hipXOffset * 0.2),
            neckBasePosition.y + CGFloat(torsoYOffset * 0.9),
            neckBasePosition.z
        )
        headNode.position = SCNVector3(
            headBasePosition.x + CGFloat(hipXOffset * 0.15),
            headBasePosition.y + CGFloat(headYOffset),
            headBasePosition.z
        )
        hipNode.position = SCNVector3(
            hipBasePosition.x + CGFloat(hipXOffset),
            hipBasePosition.y + CGFloat(torsoYOffset * 0.3),
            hipBasePosition.z
        )
        leftShoulderNode.position = SCNVector3(
            leftShoulderBasePosition.x,
            leftShoulderBasePosition.y + CGFloat(shoulderLift + torsoYOffset * 0.8),
            leftShoulderBasePosition.z
        )
        rightShoulderNode.position = SCNVector3(
            rightShoulderBasePosition.x,
            rightShoulderBasePosition.y + CGFloat(shoulderLift + torsoYOffset * 0.8),
            rightShoulderBasePosition.z
        )
        leftArmNode.position = SCNVector3(
            leftArmBasePosition.x,
            leftArmBasePosition.y + CGFloat(shoulderLift + torsoYOffset * 0.7),
            leftArmBasePosition.z
        )
        rightArmNode.position = SCNVector3(
            rightArmBasePosition.x,
            rightArmBasePosition.y + CGFloat(shoulderLift + torsoYOffset * 0.7),
            rightArmBasePosition.z
        )
        leftLegNode.position = SCNVector3(
            leftLegBasePosition.x + CGFloat(hipXOffset * 0.6),
            leftLegBasePosition.y,
            leftLegBasePosition.z
        )
        rightLegNode.position = SCNVector3(
            rightLegBasePosition.x + CGFloat(hipXOffset * 0.6),
            rightLegBasePosition.y,
            rightLegBasePosition.z
        )
        labelNode.position = SCNVector3(
            labelBasePosition.x,
            labelBasePosition.y + CGFloat(headYOffset * 0.25),
            labelBasePosition.z
        )

        // Apply rotations
        torsoNode.eulerAngles.x = CGFloat(torsoPitch)
        torsoNode.eulerAngles.y = CGFloat(torsoYaw)
        torsoNode.eulerAngles.z = CGFloat(torsoRoll)
        hipNode.eulerAngles.y = CGFloat(hipYaw)
        hipNode.eulerAngles.z = CGFloat(hipRoll)
        neckNode.eulerAngles.x = CGFloat(headPitch * 0.4)
        headNode.eulerAngles.x = CGFloat(headPitch)
        headNode.eulerAngles.z = CGFloat(headRoll)
        leftArmNode.eulerAngles.x = CGFloat(leftArmPitch)
        rightArmNode.eulerAngles.x = CGFloat(rightArmPitch)
        leftArmNode.eulerAngles.z = CGFloat(leftArmRoll)
        rightArmNode.eulerAngles.z = CGFloat(rightArmRoll)
        leftLegNode.eulerAngles.x = CGFloat(leftLegPitch)
        rightLegNode.eulerAngles.x = CGFloat(rightLegPitch)
        leftLegNode.eulerAngles.z = CGFloat(leftLegRoll)
        rightLegNode.eulerAngles.z = CGFloat(rightLegRoll)
        shadowNode.opacity = CGFloat(snapshot.visible ? max(0.14, snapshot.opacity * 0.2) : 0)
        shadowNode.scale = SCNVector3(
            shadowScaleX,
            1.0,
            shadowScaleZ
        )
        updatePackageCutouts(cutoutPlan)
    }

    func matches(targetName: String) -> Bool {
        let normalizedSelf = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTarget = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedSelf == normalizedTarget
    }

    func anchorWorldPosition(anchor: String?) -> SCNVector3 {
        let normalizedAnchor = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let node: SCNNode
        switch normalizedAnchor {
        case "head", "head_top":
            node = headNode
        case "hand_left", "left_hand":
            node = leftArmNode
        case "hand_right", "right_hand":
            node = rightArmNode
        case "shoulder_left", "left_shoulder":
            node = leftShoulderNode
        case "shoulder_right", "right_shoulder":
            node = rightShoulderNode
        case "waist", "belt":
            node = hipNode
        default:
            node = torsoNode
        }

        var local = node.presentation.worldPosition
        switch normalizedAnchor {
        case "head", "head_top":
            local.y += 0.28
        case "hand_left", "left_hand":
            local.x -= 0.18
            local.y -= 0.80
        case "hand_right", "right_hand":
            local.x += 0.18
            local.y -= 0.80
        case "shoulder_left", "left_shoulder":
            break
        case "shoulder_right", "right_shoulder":
            break
        case "waist", "belt":
            break
        default:
            break
        }
        return local
    }

    private func configureLabel(_ geometry: SCNGeometry?) {
        geometry?.materials = [Self.makeLabelMaterial(color: color)]
    }

    fileprivate static let palette: [NSColor] = [
        .systemPink, .systemTeal, .systemOrange, .systemMint, .systemPurple, .systemYellow
    ]

    private static func makeFillMaterial(color: NSColor, multiply: NSColor? = nil) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = color
        material.multiply.contents = multiply ?? NSColor(calibratedWhite: 0.88, alpha: 1)
        material.emission.contents = color.withAlphaComponent(0.1)
        material.isDoubleSided = true
        material.specular.contents = NSColor.black
        material.shininess = 0
        return material
    }

    private static func makeOutlineMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black.withAlphaComponent(0.98)
        material.emission.contents = NSColor.black.withAlphaComponent(0.98)
        material.cullMode = .front
        material.isDoubleSided = false
        return material
    }

    private static func makeLabelMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.blended(withFraction: 0.2, of: .white) ?? color
        material.emission.contents = color.withAlphaComponent(0.8)
        material.isDoubleSided = true
        return material
    }

    private static func makeToonBodyPartNode(
        geometry: SCNGeometry,
        fillColor: NSColor
    ) -> SCNNode {
        let container = SCNNode()

        let fillGeometry = (geometry.copy() as? SCNGeometry) ?? geometry
        fillGeometry.materials = [makeFillMaterial(color: fillColor)]
        let fillNode = SCNNode(geometry: fillGeometry)
        fillNode.renderingOrder = 10
        container.addChildNode(fillNode)

        let outlineGeometry = (geometry.copy() as? SCNGeometry) ?? geometry
        outlineGeometry.materials = [makeOutlineMaterial()]
        let outlineNode = SCNNode(geometry: outlineGeometry)
        outlineNode.scale = SCNVector3(1.08, 1.08, 1.08)
        outlineNode.renderingOrder = 0
        container.addChildNode(outlineNode)

        return container
    }

    private func updatePackageCutouts(
        _ plan: Animate3DCharacterPackageCutoutPlan?
    ) {
        let activeLayerIDs = Set(plan?.layers.map(\.id) ?? [])

        for layerID in Array(cutoutNodesByID.keys) where !activeLayerIDs.contains(layerID) {
            cutoutNodesByID[layerID]?.removeFromParentNode()
            cutoutNodesByID.removeValue(forKey: layerID)
        }

        guard let plan else {
            applyPlaceholderBlend(for: nil)
            return
        }

        for layer in plan.layers {
            let node = cutoutNodesByID[layer.id] ?? makeCutoutNode()
            cutoutNodesByID[layer.id] = node

            let targetContainer = cutoutContainer(for: layer.anchor)
            if node.parent !== targetContainer {
                node.removeFromParentNode()
                targetContainer.addChildNode(node)
            }

            applyCutoutLayer(layer, to: node)
        }

        applyPlaceholderBlend(for: plan)
    }

    private func applyPlaceholderBlend(
        for plan: Animate3DCharacterPackageCutoutPlan?
    ) {
        let coveredAnchors = Set(plan?.layers.map(\.anchor) ?? [])
        let dimAllParts = plan?.mode == .wholeCharacter

        setBaseChildOpacity(for: headNode, opacity: dimAllParts || coveredAnchors.contains(.head) ? 0.12 : 1)
        setBaseChildOpacity(for: torsoNode, opacity: dimAllParts || coveredAnchors.contains(.torso) ? 0.14 : 1)
        setBaseChildOpacity(for: leftArmNode, opacity: dimAllParts || coveredAnchors.contains(.leftArm) ? 0.16 : 1)
        setBaseChildOpacity(for: rightArmNode, opacity: dimAllParts || coveredAnchors.contains(.rightArm) ? 0.16 : 1)
        setBaseChildOpacity(for: leftLegNode, opacity: dimAllParts || coveredAnchors.contains(.leftLeg) ? 0.18 : 1)
        setBaseChildOpacity(for: rightLegNode, opacity: dimAllParts || coveredAnchors.contains(.rightLeg) ? 0.18 : 1)
        // Also dim connecting parts when whole character is covered
        let connectorOpacity: CGFloat = dimAllParts ? 0.14 : 1
        neckNode.opacity = connectorOpacity
        hipNode.opacity = connectorOpacity
        leftShoulderNode.opacity = connectorOpacity
        rightShoulderNode.opacity = connectorOpacity
    }

    private func setBaseChildOpacity(
        for parent: SCNNode,
        opacity: CGFloat
    ) {
        for child in parent.childNodes where !(child.name?.hasPrefix("animate3d-cutout-container-") ?? false) {
            child.opacity = opacity
        }
    }

    private func applyCutoutLayer(
        _ layer: Animate3DPackageCutoutLayer,
        to node: SCNNode
    ) {
        let plane = (node.geometry as? SCNPlane) ?? SCNPlane(width: 1, height: 1)
        plane.width = CGFloat(layer.planeSize.x)
        plane.height = CGFloat(layer.planeSize.y)
        if plane.materials.isEmpty {
            plane.materials = [Self.makeCutoutMaterial()]
        }

        if let image = Self.cutoutImage(for: layer.assetURL),
           let material = plane.firstMaterial {
            material.diffuse.contents = image
            material.emission.contents = image
            material.transparent.contents = image
        }

        node.geometry = plane
        node.position = SCNVector3(
            Float(layer.localPosition.x),
            Float(layer.localPosition.y),
            Float(layer.localPosition.z)
        )
        node.opacity = CGFloat(layer.opacity)
        node.renderingOrder = 180
        node.castsShadow = false
    }

    private func cutoutContainer(
        for anchor: Animate3DPackageCutoutAnchor
    ) -> SCNNode {
        switch anchor {
        case .root:
            return rootCutoutContainer
        case .head:
            return headCutoutContainer
        case .torso:
            return torsoCutoutContainer
        case .leftArm:
            return leftArmCutoutContainer
        case .rightArm:
            return rightArmCutoutContainer
        case .leftLeg:
            return leftLegCutoutContainer
        case .rightLeg:
            return rightLegCutoutContainer
        }
    }

    private func makeCutoutNode() -> SCNNode {
        let node = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        node.geometry?.materials = [Self.makeCutoutMaterial()]
        node.renderingOrder = 180
        node.castsShadow = false
        return node
    }

    private static func makeCutoutMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.white
        material.emission.contents = NSColor.white
        material.transparent.contents = NSColor.white
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.blendMode = .alpha
        return material
    }

    private static func cutoutImage(for url: URL) -> NSImage? {
        if let cached = cutoutImageCache.object(forKey: url as NSURL) {
            return cached
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        cutoutImageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func makeGroundShadowNode(width: CGFloat, length: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: width, height: length)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black.withAlphaComponent(0.16)
        material.emission.contents = NSColor.black.withAlphaComponent(0.08)
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.renderingOrder = -10
        return node
    }

    private static let cutoutImageCache = NSCache<NSURL, NSImage>()
}

@available(macOS 26.0, *)
@MainActor
private final class Animate3DWirePropNode {
    let name: String
    let rootNode = SCNNode()
    private let bodyNode: SCNNode
    private let shadowNode: SCNNode
    private let labelNode: SCNNode

    /// Base dimensions for prop box (proportional to character rig ~2.2 units tall).
    private static let baseWidth: CGFloat = 0.4
    private static let baseHeight: CGFloat = 0.35
    private static let baseLength: CGFloat = 0.4

    init(name: String, colorIndex: Int) {
        self.name = name
        let color = Animate3DWireRigNode.palette[colorIndex % Animate3DWireRigNode.palette.count].withAlphaComponent(0.85)

        // Use factory-built prop geometry (desk, chair, book, camera, or generic)
        bodyNode = Animate3DModelFactory.propForObjectName(name)

        shadowNode = Self.makeGroundShadowNode(
            width: Self.baseWidth + 0.04,
            length: Self.baseLength + 0.04
        )
        let text = SCNText(string: name, extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 0.18, weight: .semibold)
        text.flatness = 0.2
        labelNode = SCNNode(geometry: text)

        labelNode.geometry?.materials = [Self.makeLabelMaterial(color: color)]

        rootNode.addChildNode(shadowNode)
        rootNode.addChildNode(bodyNode)
        rootNode.addChildNode(labelNode)
        shadowNode.position = SCNVector3(0, 0.02, 0)
        // Place body so bottom edge sits on the ground (Y = half-height).
        bodyNode.position = SCNVector3(0, Float(Self.baseHeight * 0.5), 0)
        labelNode.position = SCNVector3(-0.2, Float(Self.baseHeight + 0.12), 0)
        labelNode.scale = SCNVector3(0.22, 0.22, 0.22)
        labelNode.constraints = [SCNBillboardConstraint()]
    }

    func apply(
        snapshot: Animate3DObjectSnapshot,
        showsLabel: Bool,
        attachmentOverride: SCNVector3? = nil
    ) {
        let scale = Float(max(0.3, min(snapshot.scale, 3.0)))

        // Use attachment override position when available, otherwise use world position.
        if let attachPos = attachmentOverride {
            rootNode.position = attachPos
        } else {
            rootNode.position = SCNVector3(
                Float(snapshot.worldPosition.x),
                Float(snapshot.worldPosition.y),
                Float(snapshot.worldPosition.z)
            )
        }
        rootNode.eulerAngles.y = CGFloat(snapshot.yawDegrees * .pi / 180.0)
        rootNode.opacity = CGFloat(snapshot.visible ? snapshot.opacity : 0)

        // Apply scale from snapshot to body and shadow.
        bodyNode.scale = SCNVector3(scale, scale, scale)
        bodyNode.position = SCNVector3(0, Float(Self.baseHeight * 0.5) * scale, 0)
        shadowNode.scale = SCNVector3(scale, 1, scale)

        labelNode.isHidden = !showsLabel
        shadowNode.opacity = CGFloat(snapshot.visible ? max(0.12, snapshot.opacity * 0.18) : 0)

        // Hide shadow for attached (held/carried) objects since they are not on the ground.
        if attachmentOverride != nil {
            shadowNode.isHidden = true
        } else {
            shadowNode.isHidden = false
        }
    }

    func matches(targetName: String) -> Bool {
        let normalizedSelf = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTarget = targetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedSelf == normalizedTarget
    }

    func anchorWorldPosition(anchor: String?) -> SCNVector3 {
        let scale = CGFloat(bodyNode.scale.y)
        let halfH = Self.baseHeight * 0.5 * scale
        let halfW = Self.baseWidth * 0.5 * scale
        var position = bodyNode.presentation.worldPosition
        switch anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "top":
            position.y += halfH
        case "bottom":
            position.y -= halfH
        case "left":
            position.x -= halfW
        case "right":
            position.x += halfW
        case "top_left":
            position.x -= halfW * 0.8
            position.y += halfH * 0.8
        case "top_right":
            position.x += halfW * 0.8
            position.y += halfH * 0.8
        case "bottom_left":
            position.x -= halfW * 0.8
            position.y -= halfH * 0.8
        case "bottom_right":
            position.x += halfW * 0.8
            position.y -= halfH * 0.8
        default:
            break
        }
        return position
    }

    private static func makeToonPropBodyNode(
        geometry: SCNGeometry,
        fillColor: NSColor
    ) -> SCNNode {
        let container = SCNNode()

        let fillGeometry = (geometry.copy() as? SCNGeometry) ?? geometry
        fillGeometry.materials = [makeFillMaterial(color: fillColor)]
        let fillNode = SCNNode(geometry: fillGeometry)
        fillNode.renderingOrder = 10
        container.addChildNode(fillNode)

        let outlineGeometry = (geometry.copy() as? SCNGeometry) ?? geometry
        outlineGeometry.materials = [makeOutlineMaterial()]
        let outlineNode = SCNNode(geometry: outlineGeometry)
        outlineNode.scale = SCNVector3(1.06, 1.06, 1.06)
        outlineNode.renderingOrder = 0
        container.addChildNode(outlineNode)

        let plateWidth = Self.baseWidth * 0.65
        let topPlate = SCNNode(geometry: SCNBox(
            width: plateWidth,
            height: 0.04,
            length: plateWidth,
            chamferRadius: 0.02
        ))
        topPlate.geometry?.materials = [makeFillMaterial(
            color: fillColor.blended(withFraction: 0.25, of: .white) ?? fillColor
        )]
        topPlate.position = SCNVector3(0, Float(Self.baseHeight * 0.5 - 0.04), 0)
        container.addChildNode(topPlate)

        return container
    }

    private static func makeFillMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = color
        material.multiply.contents = NSColor(calibratedWhite: 0.9, alpha: 1)
        material.emission.contents = color.withAlphaComponent(0.08)
        material.specular.contents = NSColor.black
        material.shininess = 0
        material.isDoubleSided = true
        return material
    }

    private static func makeOutlineMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black.withAlphaComponent(0.98)
        material.emission.contents = NSColor.black.withAlphaComponent(0.98)
        material.cullMode = .front
        material.isDoubleSided = false
        return material
    }

    private static func makeLabelMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.blended(withFraction: 0.18, of: .white) ?? color
        material.emission.contents = color.withAlphaComponent(0.78)
        material.isDoubleSided = true
        return material
    }

    private static func makeGroundShadowNode(width: CGFloat, length: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: width, height: length)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black.withAlphaComponent(0.14)
        material.emission.contents = NSColor.black.withAlphaComponent(0.06)
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.renderingOrder = -10
        return node
    }
}
