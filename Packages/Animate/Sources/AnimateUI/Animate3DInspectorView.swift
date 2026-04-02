import AppKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct Animate3DInspectorView: View {
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
    let scenario: Animate3DPreviewScenario
    let snapshot: Animate3DFrameSnapshot
    let assetBridgeStatuses: [Animate3DCharacterAssetBridgeStatus]
    let packageCutoutPlans: [Animate3DCharacterPackageCutoutPlan]
    let selectedDebugGuide: Animate3DDebugGuideSelection?
    let productionStatus: Animate3DProductionStatus?
    let productionCharacterStatuses: [Animate3DCharacterPerformanceStatus]
    @Bindable var harnessState: Animate3DTestHarnessState
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var preflightOwner: PreflightOwner?
    @State private var showPreflight = false
    @State private var registryEditorContext: Animate3DRegistryEditorContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                productionSection
                validationSection
                diagnosticsSection
                blockingSection
                assetBridgeSection
                guideSection
                testSection
                playbackSection
                castSection
                objectSection
                shotSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var projectURL: URL? {
        store.workingOWPURL ?? store.owpURL
    }

    private var selectedScene: AnimationScene? {
        if let sceneID = scenario.sceneID {
            return store.scenes.first(where: { $0.id == sceneID })
        }
        return store.selectedScene
    }

    private var sourceSection: some View {
        sectionCard(title: "Source") {
            VStack(alignment: .leading, spacing: 8) {
                inspectorRow(label: "Kind", value: scenario.sourceKind.title)
                inspectorRow(label: "Scene", value: scenario.sceneName)
                inspectorRow(label: "Summary", value: scenario.sourceSummary)
                inspectorRow(label: "Base FPS", value: "\(scenario.baseFPS)")
                inspectorRow(label: "Total Frames", value: "\(scenario.totalFrames)")
                inspectorRow(label: "Parsed Directions", value: "\(scenario.parsedDirectionCount)")
                inspectorRow(label: "Parse Errors", value: "\(scenario.parseErrorCount)")
            }
        }
    }

    @ViewBuilder
    private var productionSection: some View {
        if let productionStatus {
            sectionCard(title: "Production Engine") {
                VStack(alignment: .leading, spacing: 10) {
                    inspectorRow(label: "Renderer", value: productionStatus.rendererModeTitle)
                    inspectorRow(label: "Plan", value: productionStatus.planLoaded ? "Loaded" : "Not Loaded")
                    if let worldChunkTitle = productionStatus.worldChunkTitle {
                        inspectorRow(label: "World", value: worldChunkTitle)
                    }
                    if let styleProfileTitle = productionStatus.styleProfileTitle {
                        inspectorRow(label: "Style", value: styleProfileTitle)
                    }
                    if let lightRigTitle = productionStatus.lightRigTitle {
                        inspectorRow(label: "Light Rig", value: lightRigTitle)
                    }
                    if let atmospherePresetTitle = productionStatus.atmospherePresetTitle {
                        inspectorRow(label: "Atmosphere", value: atmospherePresetTitle)
                    }
                    inspectorRow(label: "Camera Presets", value: "\(productionStatus.cameraPresetCount)")
                    inspectorRow(label: "Characters", value: "\(productionStatus.characterCount)")
                    inspectorRow(label: "Props", value: "\(productionStatus.propCount)")
                    inspectorRow(
                        label: "Models",
                        value: "\(productionStatus.modelBackedCharacterCount)/\(max(productionStatus.characterCount, 1))"
                    )
                    inspectorRow(
                        label: "Face Profiles",
                        value: "\(productionStatus.performanceProfileCount)/\(max(productionStatus.characterCount, 1))"
                    )
                    if !productionCharacterStatuses.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Facial Runtime")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            ForEach(productionCharacterStatuses) { status in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(status.characterName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        if status.isVisible {
                                            statusPill(text: "VISIBLE", tint: .blue)
                                        }
                                        Spacer()
                                        statusPill(text: status.driverMode.title.uppercased(), tint: productionDriverTint(status.driverMode))
                                    }
                                    inspectorRow(label: "Expression", value: status.activeExpressionCue)
                                    inspectorRow(label: "Viseme", value: status.activeVisemeCue)
                                    if status.sourceExpressionCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
                                        inspectorRow(label: "Source Expr", value: status.sourceExpressionCue)
                                    }
                                    if let behaviorCue = status.expressionBehaviorCue,
                                       behaviorCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
                                        inspectorRow(label: "Expr Drive", value: behaviorCue)
                                    }
                                    if let provenance = status.expressionCueProvenance, !provenance.isEmpty {
                                        inspectorRow(label: "Expr Provenance", value: provenance)
                                    }
                                    if status.sourceVisemeCue.caseInsensitiveCompare(status.activeVisemeCue) != .orderedSame {
                                        inspectorRow(label: "Source Viseme", value: status.sourceVisemeCue)
                                    }
                                    if let provenance = status.visemeCueProvenance, !provenance.isEmpty {
                                        inspectorRow(label: "Vis Provenance", value: provenance)
                                    }
                                    if let modelFileName = status.modelFileName {
                                        inspectorRow(label: "Model", value: modelFileName)
                                    }
                                    if let modelSourcePath = status.modelSourcePath {
                                        Text(modelSourcePath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let profileSourceFileName = status.profileSourceFileName {
                                        inspectorRow(label: "Profile", value: profileSourceFileName)
                                    } else {
                                        inspectorRow(label: "Profile", value: "No authored profile loaded")
                                    }
                                    inspectorRow(label: "Merged Sources", value: "\(status.profileSourceCount)")
                                    inspectorRow(label: "Expr Presets", value: "\(status.expressionPresetCount)")
                                    inspectorRow(label: "Viseme Presets", value: "\(status.visemePresetCount)")
                                    inspectorRow(
                                        label: "Overlay Use",
                                        value: overlayUsageSummary(for: status)
                                    )
                                    if let resolvedExpressionPresetCue = status.resolvedExpressionPresetCue,
                                       resolvedExpressionPresetCue.caseInsensitiveCompare(status.activeExpressionCue) != .orderedSame {
                                        inspectorRow(label: "Authored Expr", value: resolvedExpressionPresetCue)
                                    }
                                    if let resolvedVisemePresetCue = status.resolvedVisemePresetCue,
                                       resolvedVisemePresetCue.caseInsensitiveCompare(status.activeVisemeCue) != .orderedSame {
                                        inspectorRow(label: "Authored Viseme", value: resolvedVisemePresetCue)
                                    }
                                    if let mouthProfileID = status.mouthProfileID, !mouthProfileID.isEmpty {
                                        inspectorRow(label: "Mouth Profile", value: mouthProfileID)
                                    }
                                    if let profileSourcePath = status.profileSourcePath {
                                        Text(profileSourcePath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !status.profileSourcePaths.isEmpty {
                                        Text(status.profileSourcePaths.joined(separator: "\n"))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let resolvedBundleSourcePath = status.resolvedBundleSourcePath {
                                        inspectorRow(label: "Registry File", value: resolvedBundleSourcePath)
                                    }
                                    if !status.resolvedBundleAssetPaths.isEmpty {
                                        Text("Bundle Paths:\n\(status.resolvedBundleAssetPaths.joined(separator: "\n"))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                                )
                            }
                        }
                    }
                    if !productionStatus.bundleReadiness.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bundle Readiness")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            ForEach(productionStatus.bundleReadiness) { readiness in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(readiness.characterName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        statusPill(
                                            text: readiness.isReady ? "READY" : "MISSING",
                                            tint: readiness.isReady ? .green : .orange
                                        )
                                    }
                                    if let preferredCostumeName = readiness.preferredCostumeName,
                                       !preferredCostumeName.isEmpty {
                                        inspectorRow(label: "Costume", value: preferredCostumeName)
                                    }
                                    if let resolvedBundleCostumeName = readiness.resolvedBundleCostumeName,
                                       !resolvedBundleCostumeName.isEmpty {
                                        inspectorRow(label: "Bundle", value: resolvedBundleCostumeName)
                                    }
                                    if let resolvedBundleSourcePath = readiness.resolvedBundleSourcePath,
                                       !resolvedBundleSourcePath.isEmpty {
                                        inspectorRow(label: "Registry File", value: resolvedBundleSourcePath)
                                    }
                                    inspectorRow(label: "Files", value: "\(readiness.totalFileCount)")
                                    if !readiness.readyCategories.isEmpty {
                                        Text("Ready: \(readiness.readyCategories.map(\.displayName).joined(separator: ", "))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !readiness.registryBackedCategories.isEmpty {
                                        Text("Registry: \(readiness.registryBackedCategories.map(\.displayName).joined(separator: ", "))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !readiness.resolvedBundleAssetPaths.isEmpty {
                                        Text("Resolved Paths:\n\(readiness.resolvedBundleAssetPaths.joined(separator: "\n"))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !readiness.missingCategories.isEmpty {
                                        Text("Missing: \(readiness.missingCategories.map(\.displayName).joined(separator: ", "))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                                )
                            }
                        }
                    }
                    if !productionStatus.generationQueueItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Generation Queue")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            ForEach(productionStatus.generationQueueItems.prefix(8), id: \.id) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        statusPill(
                                            text: item.isBatchDraftable ? "DRAFT" : "MANUAL",
                                            tint: item.isBatchDraftable ? .blue : .gray
                                        )
                                        statusPill(text: item.kind.title.uppercased(), tint: .orange)
                                    }
                                    Text(item.summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        if item.isBatchDraftable {
                                            Button("Preflight") {
                                                openGenerationPreflight(item, status: productionStatus)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            Button("Queue") {
                                                queueGenerationItem(item, status: productionStatus)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
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
                                    if let manifestKind = item.manifestKind {
                                        Text("Registry: \(manifestKind.rawValue)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let queueContext = queueBundleContext(for: item) {
                                        Text(queueContext)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let placeName = item.placeName ?? item.sceneName {
                                        Text("Context: \(placeName)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(item.targetRelativePath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                                )
                            }
                        }
                    }
                    if !productionStatus.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Warnings")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            ForEach(productionStatus.warnings, id: \.self) { warning in
                                Text("• \(warning)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var validationSection: some View {
        sectionCard(title: "Validation") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statusPill(text: scenario.validation.ready ? "Ready" : "Needs Work", tint: scenario.validation.ready ? .green : .orange)
                    Text(scenario.validation.summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                if !scenario.validation.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scenario.validation.checks, id: \.id) { check in
                            validationRow(check)
                        }
                    }
                }

                if !scenario.validation.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Warnings")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        ForEach(Array(scenario.validation.warnings.enumerated()), id: \.offset) { _, warning in
                            Text("• \(warning)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var playbackSection: some View {
        sectionCard(title: "Playback") {
            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(label: "Renderer", value: harnessState.rendererMode.title)
                inspectorRow(label: "Current Mode", value: harnessState.playbackStyle.title)
                inspectorRow(label: "Visual FPS", value: "\(harnessState.playbackStyle.targetVisualFPS)")
                inspectorRow(label: "Debug Orbit", value: harnessState.debugOrbitEnabled ? "Enabled" : "Authored Camera")
                inspectorRow(label: "Orbit Recenter", value: harnessState.debugOrbitAutoRecenter ? "On Shot Jump" : "Manual")
                inspectorRow(label: "Recommendation", value: "24 fps base timeline, default preview on twos")
                Text(harnessState.playbackStyle.recommendation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticsSection: some View {
        sectionCard(title: "Translation Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(label: "Character Tracks", value: "\(scenario.diagnostics.characterTrackCount)")
                inspectorRow(label: "Object Tracks", value: "\(scenario.diagnostics.objectTrackCount)")
                inspectorRow(label: "Camera Tracks", value: "\(scenario.diagnostics.cameraTrackCount)")
                inspectorRow(label: "Shot Segments", value: "\(scenario.diagnostics.shotSegmentCount)")
                inspectorRow(label: "Focus Cues", value: "\(scenario.diagnostics.focusCueCount)")
                inspectorRow(label: "Beat Cues", value: "\(scenario.diagnostics.beatCueCount)")
                inspectorRow(label: "Notes Cues", value: "\(scenario.diagnostics.noteCueCount)")
                inspectorRow(label: "Attachments", value: "\(scenario.diagnostics.attachmentCount)")

                if scenario.diagnostics.unsupportedTrackNames.isEmpty {
                    emptyLabel("No unsupported populated track families detected for this scenario.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unsupported / Ignored")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        ForEach(scenario.diagnostics.unsupportedTrackNames, id: \.self) { trackName in
                            pillRow(trackName)
                        }
                    }
                }
            }
        }
    }

    private var blockingSection: some View {
        sectionCard(title: "Current Blocking") {
            VStack(alignment: .leading, spacing: 10) {
                inspectorRow(label: "Display Frame", value: "\(snapshot.displayFrame + 1) / \(max(snapshot.totalFrames, 1))")
                inspectorRow(
                    label: "Active Shot",
                    value: snapshot.activeShotTitle ?? snapshot.camera.shot?.displayName ?? snapshot.camera.shotLabel
                )

                if visibleCharacters.isEmpty {
                    emptyLabel("No visible placeholder characters at this frame.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleCharacters) { character in
                            let profile = Animate3DPlaceholderPoseProfile.evaluate(character)
                            let cutoutPlan = cutoutPlan(for: character)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(character.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if let cutoutPlan {
                                        statusPill(
                                            text: cutoutModeBadgeText(for: cutoutPlan.mode),
                                            tint: cutoutModeTint(cutoutPlan.mode)
                                        )
                                    }
                                    statusPill(text: profile.primaryTag.capitalized, tint: poseTint(profile.primaryTag))
                                }

                                Text(profile.shortSummary)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                if let cutoutPlan {
                                    Text("Cutout: \(cutoutModeSummary(for: cutoutPlan.mode))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if !profile.cueText.isEmpty {
                                    Text("Cue: \(profile.cueText)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                            )
                        }
                    }
                }
            }
        }
    }

    private var guideSection: some View {
        sectionCard(title: "Guide Inspect") {
            if let selectedDebugGuide {
                VStack(alignment: .leading, spacing: 10) {
                    inspectorRow(label: "Kind", value: selectedDebugGuide.kind.title)
                    inspectorRow(label: "Title", value: selectedDebugGuide.title)
                    ForEach(selectedDebugGuide.detailLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                            )
                    }
                }
            } else {
                emptyLabel("Click a motion trail, camera path, focus path, or camera ray in the 3D viewport to inspect it.")
            }
        }
    }

    private var assetBridgeSection: some View {
        sectionCard(title: "Asset Bridge") {
            if assetBridgeStatuses.isEmpty {
                emptyLabel(assetBridgeEmptyState)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(assetBridgeStatuses) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 8) {
                                Text(status.characterName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                if status.isVisibleAtCurrentFrame {
                                    statusPill(text: "VISIBLE", tint: .blue)
                                }
                                Spacer()
                                statusPill(
                                    text: status.readiness.title.uppercased(),
                                    tint: assetBridgeTint(status.readiness)
                                )
                            }

                            Text(status.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let assetFolderSlug = status.assetFolderSlug {
                                inspectorRow(label: "Storage", value: "characters/\(assetFolderSlug)/packages")
                            }
                            if let selectionSlug = status.selectionSlug {
                                inspectorRow(label: "Selection Key", value: selectionSlug)
                            }

                            inspectorRow(label: "Reference Source", value: status.referenceSummary)

                            if let activePackageName = status.activePackageName {
                                inspectorRow(label: "Package", value: activePackageName)
                            }

                            if status.packageCount > 0 {
                                inspectorRow(
                                    label: "Coverage",
                                    value: "\(status.packageCount) package(s) · \(status.assetCount) assets · \(status.blueprintCount) blueprints"
                                )
                            }

                            if let currentSwapSummary = status.currentSwapSummary {
                                inspectorRow(label: "Current Swap", value: currentSwapSummary)
                            }

                            inspectorRow(label: "Current Cues", value: status.currentCueSummary)

                            if status.errorCount > 0 || status.warningCount > 0 {
                                inspectorRow(
                                    label: "Validation",
                                    value: "\(status.errorCount) errors · \(status.warningCount) warnings"
                                )
                            }

                            ForEach(Array(status.detailLines.prefix(3).enumerated()), id: \.offset) { _, line in
                                Text("• \(line)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                        )
                    }
                }
            }
        }
    }

    private var testSection: some View {
        sectionCard(title: "Validation Test") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This pane verifies that Animate’s existing camera, direction, and timing data can be reconstructed inside a placeholder 3D stage before we swap in real cel-shaded character rigs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                criteriaRow(
                    title: "Blocking → world space",
                    detail: "Character and prop placements must map into stable 3D coordinates without obvious drift."
                )
                criteriaRow(
                    title: "Camera → 3D framing",
                    detail: "Shot sizes, focus targets, and simple pans/zooms must read correctly in 3D composition."
                )
                criteriaRow(
                    title: "Timing → anime playback",
                    detail: "Keep a 24 fps master timeline while previewing mostly on twos, with ones/threes available for action and holds."
                )
                criteriaRow(
                    title: "Scene data → runtime preview",
                    detail: "Selected-scene tracks, parsed libretto directions, or the built-in fixture must all produce a navigable placeholder preview."
                )
            }
        }
    }

    private var castSection: some View {
        sectionCard(title: "Cast") {
            if scenario.castNames.isEmpty {
                emptyLabel("No cast yet. Select a scene or use the fixture.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(scenario.castNames, id: \.self) { name in
                        pillRow(name)
                    }
                }
            }
        }
    }

    private var objectSection: some View {
        sectionCard(title: "Objects") {
            if scenario.objectNames.isEmpty {
                emptyLabel("No props or set pieces are staged yet.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(scenario.objectNames, id: \.self) { name in
                        pillRow(name)
                    }
                }
            }
        }
    }

    private var shotSection: some View {
        sectionCard(title: "Shots") {
            if scenario.shotMarkers.isEmpty {
                emptyLabel("No shot markers detected.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(scenario.shotMarkers) { shot in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(shot.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if let cameraShot = shot.cameraShot {
                                    statusPill(text: cameraShot.displayName, tint: .blue)
                                }
                            }
                            Text(shot.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(shot.startFrame)–\(shot.endFrame) • \(shot.provenance)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
            }
        }
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        )
    }

    private func inspectorRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func validationRow(_ check: Animate3DValidationCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(checkTint(for: check).opacity(0.9))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    statusPill(text: check.severity.rawValue.uppercased(), tint: checkTint(for: check))
                }
                Text(check.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pillRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            )
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func criteriaRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        )
    }

    private func statusPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    private func productionDriverTint(_ mode: CharacterPerformanceDriverMode) -> Color {
        switch mode {
        case .profileMapped:
            .green
        case .hybridFallback:
            .orange
        case .generatedOverlay:
            .purple
        }
    }

    private func checkTint(for check: Animate3DValidationCheck) -> Color {
        switch check.severity {
        case .info:
            return check.passed ? .green : .gray
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private func queueGenerationItem(
        _ item: Animate3DGenerationQueueItem,
        status: Animate3DProductionStatus
    ) {
        let queued = Animate3DAssetGapQueueService(store: store).queue(
            item: item,
            scene: selectedScene,
            status: status
        )
        store.statusMessage = queued > 0
            ? "Queued \(item.title)"
            : "\(item.title) is already queued or still requires manual authoring"
    }

    private func openGenerationPreflight(
        _ item: Animate3DGenerationQueueItem,
        status: Animate3DProductionStatus
    ) {
        guard let draft = Animate3DAssetGapQueueService(store: store).draft(
            for: item,
            scene: selectedScene,
            status: status
        ) else {
            store.statusMessage = "No draftable Gemini request exists for \(item.title)."
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

    private func revealGenerationItem(_ item: Animate3DGenerationQueueItem) {
        guard let projectURL else { return }
        let trimmed = item.targetRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            projectURL.appendingPathComponent(trimmed)
        ])
    }

    private func manifestEditorContext(
        for item: Animate3DGenerationQueueItem
    ) -> Animate3DRegistryEditorContext? {
        guard let manifestKind = item.manifestKind,
              let relativePath = manifestRelativePath(for: manifestKind) else {
            return nil
        }
        return Animate3DRegistryEditorContext(
            kind: manifestKind,
            title: item.kind.title,
            relativePath: relativePath
        )
    }

    private func manifestRelativePath(for kind: Animate3DRegistryManifestKind) -> String? {
        guard let projectURL else { return nil }
        let index = ProjectDatabaseBridge.loadAnimate3DRegistryIndexFromDisk(projectURL: projectURL) ?? Animate3DRegistryIndex()
        switch kind {
        case .assetRegistry:
            return index.assetRegistryPath
        case .characterRegistry:
            return index.characterRegistryPath
        case .motionRegistry:
            return index.motionRegistryPath
        case .worldCatalog:
            return index.worldCatalogPath
        case .styleProfiles:
            return index.styleProfilesPath
        case .cameraPresets:
            return index.cameraPresetsPath
        case .lightRigs:
            return index.lightRigsPath
        case .atmospherePresets:
            return index.atmospherePresetsPath
        }
    }

    private func queueBundleContext(for item: Animate3DGenerationQueueItem) -> String? {
        guard let productionStatus,
              let characterSlug = item.characterSlug,
              let readiness = productionStatus.bundleReadiness.first(where: { $0.characterSlug == characterSlug }) else {
            if let manifestKind = item.manifestKind,
               let relativePath = manifestRelativePath(for: manifestKind) {
                return "Registry File: \(relativePath)"
            }
            return nil
        }

        var lines: [String] = []
        if let sourcePath = readiness.resolvedBundleSourcePath {
            lines.append("Registry File: \(sourcePath)")
        }
        if let resolvedPath = resolvedBundlePath(for: item.kind, readiness: readiness) {
            lines.append("Resolved Path: \(resolvedPath)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func overlayUsageSummary(
        for status: Animate3DCharacterPerformanceStatus
    ) -> String {
        switch (status.usingExpressionPreset, status.usingVisemePreset) {
        case (true, true):
            return "expression + mouth"
        case (true, false):
            return "expression"
        case (false, true):
            return "mouth"
        case (false, false):
            return "fallback"
        }
    }

    private func resolvedBundlePath(
        for kind: Animate3DGenerationQueueItem.Kind,
        readiness: Animate3DCharacterBundleReadinessStatus
    ) -> String? {
        let paths = readiness.resolvedBundleAssetPaths
        func first(containing fragment: String) -> String? {
            paths.first { $0.localizedCaseInsensitiveContains(fragment) }
        }
        switch kind {
        case .bodyModel:
            return first(containing: "/models/") ?? first(containing: ".glb") ?? first(containing: ".usdz") ?? first(containing: ".obj")
        case .faceRig:
            return first(containing: "/face-rigs/")
        case .mouthProfile:
            return first(containing: "/mouth-profiles/")
        case .expressionLibrary:
            return first(containing: "/expressions/")
        case .motionSet:
            return first(containing: "/motions/")
        case .materialProfile:
            return first(containing: "/materials/")
        case .worldChunk, .worldPreviewImage, .worldMesh, .lightRig, .atmospherePreset, .styleProfile, .cameraPresetLibrary:
            return nil
        }
    }

    private var visibleCharacters: [Animate3DCharacterSnapshot] {
        snapshot.characters
            .filter { $0.visible && $0.opacity > 0.001 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func cutoutPlan(
        for character: Animate3DCharacterSnapshot
    ) -> Animate3DCharacterPackageCutoutPlan? {
        packageCutoutPlans.first { plan in
            plan.characterID == character.characterUUID?.uuidString ||
            plan.characterID == character.id ||
            plan.characterName == character.name
        }
    }

    private func cutoutModeBadgeText(
        for mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> String {
        switch mode {
        case .rigLayers:
            return "RIG"
        case .layeredParts:
            return "LAYERED"
        case .wholeCharacter:
            return "WHOLE"
        }
    }

    private func cutoutModeSummary(
        for mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> String {
        switch mode {
        case .rigLayers:
            return "Rig-derived layered cutouts"
        case .layeredParts:
            return "Package-layer cutouts"
        case .wholeCharacter:
            return "Whole-character fallback card"
        }
    }

    private func cutoutModeTint(
        _ mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> Color {
        switch mode {
        case .rigLayers:
            return .cyan
        case .layeredParts:
            return .mint
        case .wholeCharacter:
            return .orange
        }
    }

    private func poseTint(_ tag: String) -> Color {
        switch tag {
        case "walk":
            return .teal
        case "point":
            return .orange
        case "present":
            return .mint
        case "listen":
            return .blue
        case "triumph":
            return .yellow
        case "surprise":
            return .pink
        case "sad":
            return .indigo
        case "intense":
            return .red
        case "speaking":
            return .purple
        case "curious":
            return .brown
        default:
            return .gray
        }
    }

    private var assetBridgeEmptyState: String {
        if scenario.castNames.isEmpty {
            return "No linked scene cast is available for package-bridge checks yet."
        }

        if scenario.sourceKind == .fixture {
            return "Fixture mode stays placeholder-only. Switch to a project scene to inspect exact package-backed swap readiness."
        }

        return "Link real project characters to the scene cast to inspect package-backed swap readiness."
    }

    private func assetBridgeTint(_ readiness: Animate3DAssetBridgeReadiness) -> Color {
        switch readiness {
        case .unavailable:
            return .gray
        case .missing:
            return .orange
        case .partial:
            return .yellow
        case .ready:
            return .green
        }
    }
}
