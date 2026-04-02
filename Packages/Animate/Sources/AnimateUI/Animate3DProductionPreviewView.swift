import AppKit
import SceneKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct Animate3DProductionPreviewView: View {
    typealias PreflightOwner = Animate3DGenerationQueueActionSupport.PreflightOwner

    @Bindable var store: AnimateStore
    @Bindable var harnessState: Animate3DTestHarnessState
    let scenario: Animate3DPreviewScenario
    let status: Animate3DProductionStatus
    let renderer: ScenePreviewRenderer
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var preflightOwner: PreflightOwner?
    @State private var preflightOwnersByDraftID: [UUID: PreflightOwner] = [:]
    @State private var showPreflight = false
    @State private var registryEditorContext: Animate3DRegistryEditorContext?

    private var displayFrame: Int {
        scenario.sourceKind == .selectedTimeline ? store.currentFrame : harnessState.previewFrame
    }

    private var visiblePerformanceStatuses: [Animate3DCharacterPerformanceStatus] {
        renderer.characterPerformanceStatuses.filter(\.isVisible)
    }

    private var selectedScene: AnimationScene? {
        if let sceneID = scenario.sceneID {
            return store.scenes.first(where: { $0.id == sceneID })
        }
        return store.selectedScene
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

    private var visiblePriorityQueueItems: [Animate3DGenerationQueueItem] {
        Array(prioritizedQueueItems.prefix(3))
    }

    private var visibleDraftableQueueItems: [Animate3DGenerationQueueItem] {
        visiblePriorityQueueItems.filter(\.isBatchDraftable)
    }

    private var visibleQueueableItems: [Animate3DGenerationQueueItem] {
        visibleDraftableQueueItems.filter { !itemIsQueued($0) }
    }

    private var allQueueableItems: [Animate3DGenerationQueueItem] {
        prioritizedQueueItems.filter { $0.isBatchDraftable && !itemIsQueued($0) }
    }

    private var hiddenQueueItemCount: Int {
        max(prioritizedQueueItems.count - visiblePriorityQueueItems.count, 0)
    }

    private var visibleQueuedCount: Int {
        visiblePriorityQueueItems.filter { itemIsQueued($0) }.count
    }

    private var visibleManualCount: Int {
        visiblePriorityQueueItems.filter { !$0.isBatchDraftable }.count
    }

    private var prioritizedQueueItems: [Animate3DGenerationQueueItem] {
        Animate3DGenerationQueueActionSupport.prioritizedItems(
            from: status.generationQueueItems,
            pinnedKeys: harnessState.pinnedGenerationQueueItemKeys,
            skippedKeys: harnessState.skippedGenerationQueueItemKeys
        )
    }

    private var pinnedVisibleCount: Int {
        visiblePriorityQueueItems.filter { harnessState.pinnedGenerationQueueItemKeys.contains($0.stableKey) }.count
    }

    private var skippedQueueItemCount: Int {
        status.generationQueueItems.filter { harnessState.skippedGenerationQueueItemKeys.contains($0.stableKey) }.count
    }

    private var overriddenVisibleCount: Int {
        visiblePriorityQueueItems.filter {
            harnessState.generationDraftOverride(for: $0.stableKey).hasVisibleChanges
        }.count
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
                    resetPreflightState()
                    showPreflight = false
                }
            )
        }
        .sheet(item: $registryEditorContext) { context in
            if let projectURL {
                Animate3DRegistryEditorSheet(
                    projectURL: projectURL,
                    context: context,
                    onClose: { registryEditorContext = nil }
                )
            }
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
                        scene: selectedScene,
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
                .disabled(!hasMissing3DDrafts || selectedScene == nil)

                Button("Preflight All Drafts") {
                    openAllGenerationPreflight()
                }
                .buttonStyle(.bordered)
                .disabled(allQueueableItems.isEmpty || selectedScene == nil)

                Button("Queue Visible Drafts") {
                    queueVisibleDrafts()
                }
                .buttonStyle(.borderedProminent)
                .disabled(visibleQueueableItems.isEmpty || selectedScene == nil)

                Button("Preflight Visible Drafts") {
                    openVisibleGenerationPreflight()
                }
                .buttonStyle(.bordered)
                .disabled(visibleQueueableItems.isEmpty || selectedScene == nil)

                if skippedQueueItemCount > 0 {
                    Button("Restore Skipped") {
                        harnessState.restoreSkippedGenerationQueueItems()
                    }
                    .buttonStyle(.bordered)
                }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority 3D Gaps")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(OperaChromeTheme.textTertiary)

                        HStack(spacing: 8) {
                            badge("Shown \(visiblePriorityQueueItems.count)/\(prioritizedQueueItems.count)", tint: .white.opacity(0.22))
                            if !visibleDraftableQueueItems.isEmpty {
                                badge("Draft \(visibleDraftableQueueItems.count)", tint: .blue)
                            }
                            if visibleQueuedCount > 0 {
                                badge("Queued \(visibleQueuedCount)", tint: .green)
                            }
                            if visibleManualCount > 0 {
                                badge("Manual \(visibleManualCount)", tint: .gray)
                            }
                            if pinnedVisibleCount > 0 {
                                badge("Pinned \(pinnedVisibleCount)", tint: .pink)
                            }
                            if skippedQueueItemCount > 0 {
                                badge("Skipped \(skippedQueueItemCount)", tint: .red)
                            }
                            if overriddenVisibleCount > 0 {
                                badge("Overrides \(overriddenVisibleCount)", tint: .purple)
                            }
                            if hiddenQueueItemCount > 0 {
                                badge("+\(hiddenQueueItemCount) more", tint: .orange)
                            }
                        }
                    }

                    ForEach(visiblePriorityQueueItems, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                badge(item.kind.title, tint: item.isBatchDraftable ? .blue : .gray)
                                if itemIsQueued(item) {
                                    badge("Queued", tint: .green)
                                }
                                if generationDraftOverride(for: item).isLocked {
                                    badge("Locked", tint: .purple)
                                }
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
                            Text("Provider: \(effectiveProviderHint(for: item))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button(isPinned(item) ? "Unpin" : "Pin") {
                                    harnessState.togglePinnedGenerationQueueItem(item.stableKey)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(isSkipped(item) ? "Restore" : "Skip") {
                                    harnessState.toggleSkippedGenerationQueueItem(item.stableKey)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if item.isBatchDraftable {
                                    Button("Preflight") {
                                        openGenerationPreflight(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Queue") {
                                        queueGenerationItem(item)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(itemIsQueued(item))
                                }

                                if let manifestContext = manifestEditorContext(for: item) {
                                    Button("Edit Registry") {
                                        registryEditorContext = manifestContext
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                } else {
                                    Button("Reveal") {
                                        revealGenerationItem(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            if isPinned(item) || generationDraftOverride(for: item).hasVisibleChanges {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Provider override", text: providerOverrideBinding(for: item))
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Prompt appendix / extra constraints", text: promptAppendixBinding(for: item), axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(2...4)
                                    Toggle("Lock override", isOn: lockedOverrideBinding(for: item))
                                        .toggleStyle(.checkbox)
                                }
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

    private var projectURL: URL? {
        store.workingOWPURL ?? store.owpURL
    }

    private func isPinned(_ item: Animate3DGenerationQueueItem) -> Bool {
        harnessState.pinnedGenerationQueueItemKeys.contains(item.stableKey)
    }

    private func isSkipped(_ item: Animate3DGenerationQueueItem) -> Bool {
        harnessState.skippedGenerationQueueItemKeys.contains(item.stableKey)
    }

    private func generationDraftOverride(for item: Animate3DGenerationQueueItem) -> Animate3DGenerationDraftOverride {
        harnessState.generationDraftOverride(for: item.stableKey)
    }

    private func providerOverrideBinding(for item: Animate3DGenerationQueueItem) -> Binding<String> {
        Binding(
            get: { generationDraftOverride(for: item).providerHintOverride },
            set: { harnessState.setProviderHintOverride($0, for: item.stableKey) }
        )
    }

    private func promptAppendixBinding(for item: Animate3DGenerationQueueItem) -> Binding<String> {
        Binding(
            get: { generationDraftOverride(for: item).promptAppendix },
            set: { harnessState.setPromptAppendix($0, for: item.stableKey) }
        )
    }

    private func lockedOverrideBinding(for item: Animate3DGenerationQueueItem) -> Binding<Bool> {
        Binding(
            get: { generationDraftOverride(for: item).isLocked },
            set: { harnessState.setGenerationDraftLocked($0, for: item.stableKey) }
        )
    }

    private func effectiveProviderHint(for item: Animate3DGenerationQueueItem) -> String {
        Animate3DGenerationQueueActionSupport.effectiveProviderHint(
            for: item,
            overridesByStableKey: harnessState.generationDraftOverridesByStableKey
        )
    }

    private func itemIsQueued(_ item: Animate3DGenerationQueueItem) -> Bool {
        Animate3DGenerationQueueActionSupport.isQueued(item: item, store: store)
    }

    private func queueGenerationItem(_ item: Animate3DGenerationQueueItem) {
        let queued = Animate3DGenerationQueueActionSupport.queue(
            item: item,
            scene: selectedScene,
            status: status,
            store: store,
            overridesByStableKey: harnessState.generationDraftOverridesByStableKey
        )
        store.statusMessage = queued > 0
            ? "Queued \(item.title)"
            : "\(item.title) is already queued or still requires manual authoring"
    }

    private func openGenerationPreflight(_ item: Animate3DGenerationQueueItem) {
        guard let result = Animate3DGenerationQueueActionSupport.draft(
            for: item,
            scene: selectedScene,
            status: status,
            store: store,
            overridesByStableKey: harnessState.generationDraftOverridesByStableKey
        ) else {
            store.statusMessage = "No draftable Gemini request exists for \(item.title)."
            return
        }
        preflightDrafts = [result.draft]
        preflightOwner = result.owner
        preflightOwnersByDraftID = [result.draft.id: result.owner]
        showPreflight = true
    }

    private func revealGenerationItem(_ item: Animate3DGenerationQueueItem) {
        guard let projectURL else { return }
        Animate3DGenerationQueueActionSupport.reveal(item: item, projectURL: projectURL)
    }

    private func manifestEditorContext(
        for item: Animate3DGenerationQueueItem
    ) -> Animate3DRegistryEditorContext? {
        guard let projectURL else { return nil }
        return Animate3DGenerationQueueActionSupport.manifestEditorContext(
            for: item,
            projectURL: projectURL
        )
    }

    private func manifestRelativePath(for kind: Animate3DRegistryManifestKind) -> String? {
        guard let projectURL else { return nil }
        return Animate3DGenerationQueueActionSupport.manifestRelativePath(
            for: kind,
            projectURL: projectURL
        )
    }

    private func resetPreflightState() {
        preflightDrafts = []
        preflightOwner = nil
        preflightOwnersByDraftID = [:]
    }

    private func openGenerationPreflight(
        for items: [Animate3DGenerationQueueItem],
        emptyMessage: String
    ) {
        var drafts: [GeminiGenerationDraft] = []
        var ownersByDraftID: [UUID: PreflightOwner] = [:]

        for item in items {
            guard let result = Animate3DGenerationQueueActionSupport.draft(
                for: item,
                scene: selectedScene,
                status: status,
                store: store,
                overridesByStableKey: harnessState.generationDraftOverridesByStableKey
            ) else {
                continue
            }
            drafts.append(result.draft)
            ownersByDraftID[result.draft.id] = result.owner
        }

        guard !drafts.isEmpty else {
            store.statusMessage = emptyMessage
            return
        }

        preflightDrafts = drafts
        preflightOwner = drafts.count == 1 ? ownersByDraftID[drafts[0].id] : nil
        preflightOwnersByDraftID = ownersByDraftID
        showPreflight = true
    }

    private func openAllGenerationPreflight() {
        openGenerationPreflight(
            for: allQueueableItems,
            emptyMessage: "No draftable 3D requests available for preflight."
        )
    }

    private func openVisibleGenerationPreflight() {
        openGenerationPreflight(
            for: visibleQueueableItems,
            emptyMessage: "No visible draftable 3D requests available for preflight."
        )
    }

    private func queueVisibleDrafts() {
        let queued = Animate3DGenerationQueueActionSupport.queue(
            items: visibleQueueableItems,
            scene: selectedScene,
            status: status,
            store: store,
            overridesByStableKey: harnessState.generationDraftOverridesByStableKey
        )
        store.statusMessage = queued > 0
            ? "Queued \(queued) visible 3D draft\(queued == 1 ? "" : "s")"
            : "Visible 3D gaps are already queued or require manual authoring"
    }

    private func queuePreflightDrafts(_ drafts: [GeminiGenerationDraft]) {
        let queued = Animate3DGenerationQueueActionSupport.queuePreflightDrafts(
            drafts,
            ownersByDraftID: preflightOwnersByDraftID,
            fallbackOwner: preflightOwner,
            store: store
        )
        store.statusMessage = queued > 0
            ? "Queued \(queued) 3D preflight draft\(queued == 1 ? "" : "s")"
            : "No 3D preflight drafts were queueable"
        resetPreflightState()
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
