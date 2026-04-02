import SceneKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct Animate3DProductionPreviewView: View {
    struct PreflightOwner {
        var characterID: UUID?
        var characterSlug: String?
        var displayName: String
        var outputRootRelativePath: String?

        @MainActor
        init(item: Animate3DGenerationQueueItem, store: AnimateStore) {
            if let slug = item.characterSlug,
               let character = store.characters.first(where: { $0.assetFolderSlug == slug || $0.owpSlug == slug }) {
                characterID = character.id
                characterSlug = character.assetFolderSlug
                displayName = character.name
                outputRootRelativePath = nil
            } else {
                characterID = nil
                characterSlug = nil
                displayName = item.characterName ?? "Environment"
                let trimmed = item.targetRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.hasPrefix("Animate/")
                    ? String(trimmed.dropFirst("Animate/".count))
                    : trimmed
                let directory = normalized.hasSuffix("/")
                    ? normalized
                    : (normalized as NSString).deletingLastPathComponent
                let cleaned = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                outputRootRelativePath = cleaned.isEmpty
                    ? "3d/generation-queue-batches"
                    : "\(cleaned)/batch-queue-batches"
            }
        }
    }

    @Bindable var store: AnimateStore
    @Bindable var harnessState: Animate3DTestHarnessState
    let scenario: Animate3DPreviewScenario
    let status: Animate3DProductionStatus
    let renderer: ScenePreviewRenderer
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var preflightOwner: PreflightOwner?
    @State private var showPreflight = false

    private var displayFrame: Int {
        scenario.sourceKind == .selectedTimeline ? store.currentFrame : harnessState.previewFrame
    }

    private var visiblePerformanceStatuses: [Animate3DCharacterPerformanceStatus] {
        renderer.characterPerformanceStatuses.filter(\.isVisible)
    }

    private var hasMissing3DDrafts: Bool {
        draftableQueueCount > 0
    }

    private var draftableQueueCount: Int {
        status.generationQueueItems.filter(\.isBatchDraftable).count
    }

    private var nextDraftableQueueItem: Animate3DGenerationQueueItem? {
        prioritizedQueueItems.first(where: \.isBatchDraftable)
    }

    private var prioritizedQueueItems: [Animate3DGenerationQueueItem] {
        status.generationQueueItems
            .sorted { lhs, rhs in
                if lhs.isBatchDraftable != rhs.isBatchDraftable {
                    return lhs.isBatchDraftable && !rhs.isBatchDraftable
                }
                let lhsHasContext = !(lhs.contextSummary?.isEmpty ?? true)
                let rhsHasContext = !(rhs.contextSummary?.isEmpty ?? true)
                if lhsHasContext != rhsHasContext {
                    return lhsHasContext && !rhsHasContext
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )

                ProductionSceneViewRepresentable(
                    renderer: renderer,
                    frame: displayFrame,
                    showsGround: harnessState.showsGrid,
                    debugOrbitEnabled: harnessState.debugOrbitEnabled
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(16)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        badge("Production", tint: .blue)
                        badge("Cel", tint: .pink)
                        badge(harnessState.playbackStyle.title, tint: .purple)
                        if status.planLoaded {
                            badge("\(status.characterCount) Char", tint: .green)
                            badge("\(status.propCount) Prop", tint: .orange)
                        }
                    }

                    Text(status.sceneName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Frame \(displayFrame + 1) / \(max(status.totalFrames, 1))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))

                    if !visiblePerformanceStatuses.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(visiblePerformanceStatuses.prefix(2)) { performanceStatus in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        badge(performanceStatus.characterName, tint: .white.opacity(0.24))
                                        if let bundle = performanceStatus.resolvedBundleCostumeName, !bundle.isEmpty {
                                            badge(bundle, tint: .white.opacity(0.16))
                                        }
                                        Text("\(performanceStatus.activeExpressionCue)\(performanceStatus.usingExpressionPreset ? "✓" : "") • \(performanceStatus.activeVisemeCue)\(performanceStatus.usingVisemePreset ? "✓" : "")")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.82))
                                            .lineLimit(1)
                                    }
                                    if let authoredLine = authoredResolutionLine(for: performanceStatus) {
                                        Text(authoredLine)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.66))
                                            .lineLimit(1)
                                    }
                                    Text(overlayTelemetry(for: performanceStatus))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.62))
                                        .lineLimit(2)
                                    if let modelSourcePath = performanceStatus.modelSourcePath {
                                        Text(modelSourcePath)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .aspectRatio(21.0 / 9.0, contentMode: .fit)
            .padding(.horizontal, 18)
            .padding(.top, 12)

            shotStrip
                .padding(.horizontal, 18)
                .padding(.top, 12)

            footerControls
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .background(OperaChromeTheme.workspaceBackground)
        .sheet(isPresented: $showPreflight) {
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $preflightDrafts,
                title: "Preview 3D Generation Draft",
                confirmTitle: "Queue Draft",
                onConfirm: { drafts, _ in
                    queuePreflightDrafts(drafts)
                    showPreflight = false
                },
                onCancel: {
                    preflightOwner = nil
                    showPreflight = false
                }
            )
        }
    }

    private var previewHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PRODUCTION PREVIEW")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text(status.sceneName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(scenario.sourceSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Models \(status.modelBackedCharacterCount)/\(max(status.characterCount, 1))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Text("Face Profiles \(status.performanceProfileCount)/\(max(status.characterCount, 1))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                if let worldChunkTitle = status.worldChunkTitle {
                    Text("World \(worldChunkTitle)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
        }
    }

    private var shotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scenario.shotMarkers) { shot in
                    let isActive = displayFrame >= shot.startFrame && displayFrame <= shot.endFrame
                    Button {
                        harnessState.seek(to: shot.startFrame, scenario: scenario, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shot.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(shot.startFrame + 1)–\(shot.endFrame + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    harnessState.step(by: -1, scenario: scenario, store: store)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    harnessState.togglePlayback(for: scenario, store: store)
                } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    harnessState.step(by: 1, scenario: scenario, store: store)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.bordered)

                Picker("Cadence", selection: $harnessState.playbackStyle) {
                    ForEach(Animate3DPlaybackStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Toggle("Ground", isOn: $harnessState.showsGrid)
                    .toggleStyle(.checkbox)
                Toggle("Orbit", isOn: $harnessState.debugOrbitEnabled)
                    .toggleStyle(.checkbox)

                Spacer(minLength: 12)

                Button("Queue Missing 3D Drafts") {
                    let queued = Animate3DAssetGapQueueService(store: store).queueMissingDrafts(
                        scene: store.selectedScene,
                        status: status
                    )
                    let skipped = max(status.generationQueueItems.count - draftableQueueCount, 0)
                    if queued > 0 {
                        store.statusMessage = skipped > 0
                            ? "Queued \(queued) 3D draft\(queued == 1 ? "" : "s"); \(skipped) registry-only item\(skipped == 1 ? "" : "s") still need manual authoring."
                            : "Queued \(queued) 3D generation draft\(queued == 1 ? "" : "s")"
                    } else {
                        store.statusMessage = draftableQueueCount > 0
                            ? "All Gemini-draftable 3D gaps are already in the batch queue"
                            : "No missing 3D drafts to queue"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasMissing3DDrafts || store.selectedScene == nil)

                Button("Preflight Next Draft") {
                    openGenerationPreflight()
                }
                .buttonStyle(.bordered)
                .disabled(nextDraftableQueueItem == nil || store.selectedScene == nil)
            }

            if !status.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                }
            }

            if !prioritizedQueueItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Priority 3D Gaps")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(OperaChromeTheme.textTertiary)

                    ForEach(prioritizedQueueItems.prefix(3), id: \.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                badge(item.kind.title, tint: item.isBatchDraftable ? .blue : .gray)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(OperaChromeTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            Text(item.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let contextSummary = item.contextSummary, !contextSummary.isEmpty {
                                Text(contextSummary)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private func badge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.26)))
            .foregroundStyle(.white)
    }

    private func overlayTelemetry(for status: Animate3DCharacterPerformanceStatus) -> String {
        var parts: [String] = []
        parts.append("merged \(status.profileSourceCount)")
        parts.append("expr \(status.expressionPresetCount)")
        parts.append("vis \(status.visemePresetCount)")
        if let mouthProfileID = status.mouthProfileID, !mouthProfileID.isEmpty {
            parts.append("mouth \(mouthProfileID)")
        }
        return parts.joined(separator: " • ")
    }

    private func authoredResolutionLine(for status: Animate3DCharacterPerformanceStatus) -> String? {
        var parts: [String] = []
        if status.sourceExpressionCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
            var label = "expr \(status.sourceExpressionCue)→\(status.activeExpressionCue)"
            if let behaviorCue = status.expressionBehaviorCue,
               behaviorCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
                label += " [\(behaviorCue)]"
            }
            if let provenance = status.expressionCueProvenance, !provenance.isEmpty {
                label += " {\(provenance)}"
            }
            parts.append(label)
        } else if let resolvedExpressionPresetCue = status.resolvedExpressionPresetCue,
                  resolvedExpressionPresetCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
            parts.append("expr→\(resolvedExpressionPresetCue)")
        } else if let provenance = status.expressionCueProvenance, !provenance.isEmpty {
            parts.append("expr {\(provenance)}")
        }
        if status.sourceVisemeCue.caseInsensitiveCompare(status.activeVisemeCue) != .orderedSame {
            var label = "vis \(status.sourceVisemeCue)→\(status.activeVisemeCue)"
            if let provenance = status.visemeCueProvenance, !provenance.isEmpty {
                label += " {\(provenance)}"
            }
            parts.append(label)
        } else if let resolvedVisemePresetCue = status.resolvedVisemePresetCue,
                  resolvedVisemePresetCue.caseInsensitiveCompare(status.activeVisemeCue) != .orderedSame {
            parts.append("vis→\(resolvedVisemePresetCue)")
        } else if let provenance = status.visemeCueProvenance, !provenance.isEmpty {
            parts.append("vis {\(provenance)}")
        }
        if let motionTitle = status.resolvedMotionTitle, !motionTitle.isEmpty {
            var label = "motion \(motionTitle)"
            if let provenance = status.motionProvenance, !provenance.isEmpty {
                label += " {\(provenance)}"
            }
            parts.append(label)
        }
        var holdLabel = "hold x\(status.resolvedHoldMultiplier)"
        if let provenance = status.holdProvenance, !provenance.isEmpty {
            holdLabel += " {\(provenance)}"
        }
        parts.append(holdLabel)
        if let motionHintSummary = status.motionHintSummary, !motionHintSummary.isEmpty {
            parts.append("hints \(motionHintSummary)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func openGenerationPreflight() {
        guard let item = nextDraftableQueueItem,
              let draft = Animate3DAssetGapQueueService(store: store).draft(
                for: item,
                scene: store.selectedScene,
                status: status
              ) else {
            store.statusMessage = "No draftable 3D request available for preflight."
            return
        }
        preflightDrafts = [draft]
        preflightOwner = PreflightOwner(item: item, store: store)
        showPreflight = true
    }

    private func queuePreflightDrafts(_ drafts: [GeminiGenerationDraft]) {
        guard let owner = preflightOwner else { return }
        for draft in drafts {
            if let characterID = owner.characterID {
                store.addToBatchQueue(
                    characterID: characterID,
                    characterName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    characterSlug: owner.characterSlug
                )
            } else if let outputRootRelativePath = owner.outputRootRelativePath {
                store.addToBatchQueue(
                    pipelineName: owner.displayName,
                    draftTitle: draft.title,
                    draft: draft,
                    outputRootRelativePath: outputRootRelativePath
                )
            }
        }
        store.statusMessage = "Queued \(drafts.count) 3D preflight draft\(drafts.count == 1 ? "" : "s")"
        preflightOwner = nil
    }
}

@available(macOS 26.0, *)
private struct ProductionSceneViewRepresentable: NSViewRepresentable {
    let renderer: ScenePreviewRenderer
    let frame: Int
    let showsGround: Bool
    let debugOrbitEnabled: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = renderer.sceneKitScene
        view.pointOfView = renderer.pointOfView
        view.backgroundColor = .black
        view.rendersContinuously = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .none
        view.allowsCameraControl = debugOrbitEnabled
        view.preferredFramesPerSecond = 24
        if CelShadingTechnique.makeTechnique(settings: renderer.celShadingSettings) != nil {
            CelShadingTechnique.apply(to: view, settings: renderer.celShadingSettings)
        } else {
            CelShadingTechnique.applyPerMaterialFallback(
                to: renderer.sceneKitScene,
                settings: renderer.celShadingSettings
            )
        }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== renderer.sceneKitScene {
            view.scene = renderer.sceneKitScene
        }
        if !debugOrbitEnabled {
            view.pointOfView = renderer.pointOfView
        }
        view.allowsCameraControl = debugOrbitEnabled
        CelShadingTechnique.apply(to: view, settings: renderer.celShadingSettings)
        renderer.renderFrame(frame)
        renderer.sceneKitScene.rootNode.childNode(withName: "ground", recursively: true)?.isHidden = !showsGround
    }
}
