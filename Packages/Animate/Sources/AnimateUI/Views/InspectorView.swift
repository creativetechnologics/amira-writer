import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct InspectorView: View {
    @Bindable var store: AnimateStore
    var currentPage: AnimatePage
    @Bindable var animateWorkspaceState: AnimateWorkspaceState
    @State private var timelineCueCharacterID: UUID?
    @State private var timelineExpressionDraft = ""
    @State private var timelineActionDraft = ""
    @State private var timelinePoseDraft: CharacterPackagePose?
    @State private var timelineViewAngleDraft: AngleView?
    @State private var timelineFacingDraft: FacingDirection?
    @State private var timelineCameraShotDraft: CameraShot?
    @State private var timelineShotIntentDraft: ShotIntent?
    @State private var timelineBeatLabelDraft = ""
    @State private var timelineBeatNotesDraft = ""
    @State private var sceneTemplateShotDraft: CameraShot?
    @State private var sceneTemplateFocusCharacterID: UUID?
    @State private var sceneTemplateNotesDraft = ""
    @State private var selectedShotPresetID: UUID?
    @State private var shotPresetNameDraft = ""
    @State private var shotPresetNotesDraft = ""

    private struct SyncedVariantPreview: Identifiable {
        var partName: String
        var angle: AngleView
        var variant: DrawingVariant

        var id: UUID { variant.id }
    }

    private enum InspectorTab: String { case assets, properties, llm, batch }
    @AppStorage("animate.inspector.selectedTab.v2") private var selectedTab = InspectorTab.assets.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("Assets", tab: .assets, icon: "shippingbox.fill")
                tabButton("Properties", tab: .properties, icon: "slider.horizontal.3")
                tabButton("LLM", tab: .llm, icon: "bubble.left.and.text.bubble.right")
                if currentPage == .characters {
                    tabButton("Batch", tab: .batch, icon: "tray.full")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if selectedTab == InspectorTab.batch.rawValue, currentPage == .characters {
                batchQueueContent
            } else if selectedTab == InspectorTab.assets.rawValue {
                assetsContent
            } else if selectedTab == InspectorTab.llm.rawValue {
                AnimateLLMInspectorView(store: store)
            } else {
                propertiesContent
            }
        }
    }

    private func tabButton(_ title: String, tab: InspectorTab, icon: String) -> some View {
        Button {
            selectedTab = tab.rawValue
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .fontWeight(selectedTab == tab.rawValue ? .semibold : .regular)
                .foregroundStyle(selectedTab == tab.rawValue ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    selectedTab == tab.rawValue
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }

    private var assetsContent: some View {
        Group {
            switch currentPage {
            case .script, .animate:
                AnimatePageView(
                    store: store,
                    workspaceState: animateWorkspaceState,
                    presentation: .assets
                )
            case .characters, .places, .props, .timeline:
                propertiesContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var propertiesContent: some View {
        Group {
            switch currentPage {
            case .script, .animate:
                AnimatePageView(
                    store: store,
                    workspaceState: animateWorkspaceState,
                    presentation: AnimatePageView.Presentation.inspector
                )
            case .characters:
                inspectorScrollContainer { characterInspector }
            case .places:
                inspectorScrollContainer { placeInspector }
            case .props:
                inspectorScrollContainer { propsInspector }
            case .timeline:
                inspectorScrollContainer { timelineInspector }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            syncSceneTemplateDrafts()
            syncTimelineCueDrafts()
            syncShotPresetDrafts()
        }
        .onChange(of: store.currentFrame) { _, _ in
            syncTimelineCueDrafts()
        }
        .onChange(of: store.selectedCharacterID) { _, _ in
            syncTimelineCueDrafts()
        }
        .onChange(of: store.selectedSceneID) { _, _ in
            syncSceneTemplateDrafts()
            syncTimelineCueDrafts()
            syncShotPresetDrafts()
        }
    }

    private func inspectorScrollContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding()
        }
    }

    // MARK: - Script Inspector

    @ViewBuilder
    private var scriptInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Script", systemImage: "text.viewfinder")
                .font(.headline)

            LabeledContent("Frame Rate") {
                Text("\(store.fps) fps")
            }

            if !store.sceneTracks.isEmpty {
                LabeledContent("Tracks") {
                    Text("\(store.sceneTracks.count)")
                }
            }

            LabeledContent("Total Frames") {
                Text("\(store.totalFrames)")
            }
        }
    }

    // MARK: - Place Inspector

    @ViewBuilder
    private var placeInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Draw Things", systemImage: "sparkles")
                .font(.headline)

            if let place = store.selectedPlace {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Selected Location") {
                        Text(place.name)
                    }
                    LabeledContent("Scenes Using It") {
                        Text("\(store.sceneReferences(for: place.id).count)")
                    }
                    if let approved = place.resolvedApprovedImagePath {
                        LabeledContent("Approved Image") {
                            Text(URL(fileURLWithPath: approved).lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Text("Select a script location in the middle pane to generate imagery for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                labeledTextField("Host", text: drawThingsBinding(\.apiHost))
                labeledIntegerField("Port", value: drawThingsBinding(\.apiPort))

                HStack(spacing: 8) {
                    labeledIntegerField("Width", value: drawThingsBinding(\.imageWidth))
                    labeledIntegerField("Height", value: drawThingsBinding(\.imageHeight))
                }

                HStack(spacing: 8) {
                    labeledIntegerField("Steps", value: drawThingsBinding(\.steps))
                    labeledDoubleField("CFG", value: drawThingsBinding(\.cfgScale))
                }

                labeledOptionalIntegerField("Seed", value: drawThingsBinding(\.seed))
                labeledTextField("Prompt Prefix", text: drawThingsBinding(\.promptPrefix), axis: .vertical)
                labeledTextField("Prompt Suffix", text: drawThingsBinding(\.promptSuffix), axis: .vertical)
                labeledTextField("Negative Prompt", text: drawThingsBinding(\.negativePrompt), axis: .vertical)
            }
        }
    }

    // MARK: - Props Inspector

    @ViewBuilder
    private var propsInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Props", systemImage: "shippingbox")
                .font(.headline)
            Text("Select a prop to inspect its model files, materials, and scene usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Character Inspector

    @ViewBuilder
    private var characterInspector: some View {
        if let character = store.selectedCharacter {
            VStack(alignment: .leading, spacing: 12) {
                characterRigSection(character)

                Divider()

                characterPackageInspectorSection(character)

                Divider()

                canvasRenderInspectorSection(character)

                Divider()

                characterActionsInspectorSection(character)

                if !character.parts.isEmpty {
                    Divider()

                    angleCoverageInspectorSection(character)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Characters", systemImage: "person.2")
                    .font(.headline)

                Text("Select a character to view properties.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func characterRigSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rig", systemImage: "figure.arms.open")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Edit Rig") {
                    store.showRigEditor = true
                }
                .buttonStyle(.bordered)

                Button("Save Rig") {
                    store.saveCharacterRig(character.id)
                }
                .buttonStyle(.bordered)
            }

            if character.parts.isEmpty {
                Button("Create Default Rig") {
                    store.createDefaultRig(for: character.id)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func canvasRenderInspectorSection(_ character: AnimationCharacter) -> some View {
        let rigVariantCount = character.parts.reduce(into: 0) { total, part in
            for drawingSet in part.drawingSets.values {
                total += drawingSet.variants.count
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            Label("Canvas Render", systemImage: "play.rectangle.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Render Mode", selection: Binding(
                get: { character.resolvedRenderMode },
                set: { store.setCharacterRenderMode($0, for: character.id) }
            )) {
                ForEach(CharacterCanvasRenderMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Preferred Angle", selection: Binding(
                get: { character.preferredViewAngle },
                set: { store.setCharacterPreferredViewAngle($0, for: character.id) }
            )) {
                Text("Automatic").tag(nil as AngleView?)
                ForEach(AngleView.allCases, id: \.self) { angle in
                    Text(angle.rawValue).tag(Optional(angle))
                }
            }

            if character.resolvedRenderMode == .packagePreview {
                Text("Canvas uses the selected active package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if rigVariantCount > 0 {
                Text("Canvas uses \(rigVariantCount) rig variants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No synced rig drawings yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func characterActionsInspectorSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Actions", systemImage: "figure.arms.open")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button("Import Character Package...") {
                    NotificationCenter.default.post(
                        name: Notification.Name("OpenCharacterPackagePicker"),
                        object: character.id
                    )
                }
                .buttonStyle(.bordered)
                .disabled(store.animateURL == nil)
            }
        }
    }

    @ViewBuilder
    private func angleCoverageInspectorSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Angle Coverage", systemImage: "rotate.3d")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let coverageByAngle = angleCoverage(for: character)
            ForEach(AngleView.allCases, id: \.self) { angle in
                HStack {
                    Text(angle.rawValue)
                        .font(.caption)
                    Spacer()
                    let count = coverageByAngle[angle] ?? 0
                    Text("\(count) drawings")
                        .font(.caption)
                        .foregroundStyle(count > 0 ? Color.green : Color.gray)
                }
            }
        }
    }

    @ViewBuilder
    private func characterPackageInspectorSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Active Package", systemImage: "shippingbox")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let activePackage = activePackage(for: character) {
                let errorCount = activePackage.validationReport.issues.filter { $0.severity == .error }.count
                let warningCount = activePackage.validationReport.issues.filter { $0.severity == .warning }.count
                let coverage = CharacterPackageRigSyncService().coverage(for: character, package: activePackage)
                let partAwareLayerCount = activePackage.manifest.assets.filter { $0.partType != nil }.count
                let syncedStats = syncedVariantStats(for: character, packageID: activePackage.id)
                let syncedPreviews = syncedVariantPreviews(for: character, packageID: activePackage.id)

                HStack(spacing: 8) {
                    statusCapsule(
                        title: activePackage.validationReport.isValid ? "Ready" : "Needs Attention",
                        color: activePackage.validationReport.isValid ? .green : .orange
                    )

                    if partAwareLayerCount > 0 {
                        statusCapsule(
                            title: "\(partAwareLayerCount) Part Layers",
                            color: .blue
                        )
                    }
                }

                LabeledContent("Name") {
                    Text(activePackage.manifest.displayName)
                }

                LabeledContent("Canvas Mode") {
                    Text(character.resolvedRenderMode.displayName)
                }

                LabeledContent("Preferred Angle") {
                    Text(character.preferredViewAngle?.rawValue ?? "Automatic")
                }

                if let liveViewAngle = store.evaluatedViewAngle(for: character.id) {
                    LabeledContent("Live View Cue") {
                        Text(liveViewAngle.rawValue)
                    }
                }

                if let liveFacing = store.evaluatedFacingDirection(for: character.id) {
                    LabeledContent("Live Facing Cue") {
                        Text(liveFacing.displayName)
                    }
                }

                if let livePose = store.evaluatedPose(for: character.id) {
                    LabeledContent("Live Pose Cue") {
                        Text(livePose.rawValue)
                    }
                }

                if let liveExpression = store.evaluatedExpression(for: character.id) {
                    LabeledContent("Live Expression Cue") {
                        Text(liveExpression)
                    }
                }

                if let liveAction = store.evaluatedAction(for: character.id) {
                    LabeledContent("Live Action Cue") {
                        Text(liveAction)
                    }
                }

                LabeledContent("Assets") {
                    Text("\(activePackage.manifest.assets.count)")
                }

                LabeledContent("Blueprints") {
                    Text("\(activePackage.manifest.blueprints.count)")
                }

                LabeledContent("Validation") {
                    Text("\(errorCount) errors, \(warningCount) warnings")
                        .foregroundStyle(errorCount > 0 ? Color.orange : Color.secondary)
                }

                if let importedAt = activePackage.importedAt {
                    LabeledContent("Imported") {
                        Text(importedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                LabeledContent("Sync Coverage") {
                    Text("\(coverage.matchedRigParts)/\(coverage.totalPartAssets) package parts matched")
                }

                if syncedStats.total > 0 {
                    LabeledContent("Synced Variants") {
                        Text("\(syncedStats.total)")
                    }

                    LabeledContent("With Placement") {
                        Text("\(syncedStats.withPlacement)")
                    }

                    if syncedStats.withPivot > 0 {
                        LabeledContent("With Pivot Metadata") {
                            Text("\(syncedStats.withPivot)")
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Synced Source Preview")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ForEach(Array(syncedPreviews.prefix(3))) { preview in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(preview.partName) • \(preview.angle.rawValue)")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if let sourcePath = sourcePathLabel(for: preview.variant) {
                                    Text(sourcePath)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                if let placementSummary = placementSummary(for: preview.variant) {
                                    Text(placementSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                } else if hasLegacyPackageVariants(for: character, package: activePackage) {
                    Text("Legacy synced variants found. Sync the active package again to persist source path and placement metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if character.parts.isEmpty {
                    Text("Syncing this package will create a default rig first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !coverage.missingRigPartTypes.isEmpty {
                    Text("Missing rig matches: \(coverage.missingRigPartTypes.map(\.rawValue).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Button("Sync Active Package") {
                        _ = store.syncCharacterPackageToRig(
                            for: character.id,
                            packageID: activePackage.id
                        )
                    }
                    .buttonStyle(.bordered)

                    Button("Reveal Package") {
                        NSWorkspace.shared.activateFileViewerSelecting([activePackage.packageDirectoryURL])
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("No active package selected for this character yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Batch Queue

    private var batchQueueContent: some View {
        inspectorScrollContainer {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    store.batchQueue.isEmpty
                        ? "Batch Queue"
                        : "\(store.batchQueue.count) item\(store.batchQueue.count == 1 ? "" : "s") queued",
                    systemImage: "tray.full"
                )
                .font(.headline)

                if store.batchQueue.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add items to the batch queue from the character reference workflow or the 3D production preview.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(store.batchQueue) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.characterName)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(item.draftTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let outputRootRelativePath = item.outputRootRelativePath {
                                    Text(outputRootRelativePath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                store.removeBatchQueueItem(item.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from queue")
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button("Submit All") {
                            submitBatchQueue()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.geminiAPIKey.isEmpty)

                        Button("Clear Queue") {
                            store.clearBatchQueue()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func submitBatchQueue() {
        guard !store.batchQueue.isEmpty,
              let animateURL = store.animateURL else { return }

        let queueSnapshot = store.batchQueue

        let grouped = Dictionary(grouping: queueSnapshot, by: \.groupingKey)

        Task { @MainActor in
            for (_, items) in grouped {
                guard let firstItem = items.first else { continue }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
                let stamp = formatter.string(from: Date())

                let character = firstItem.characterID.flatMap { id in
                    store.characters.first(where: { $0.id == id })
                }
                let outputRoot: URL
                let batchName: String
                let batchSlug: String

                if let character {
                    let resolvedSlug = firstItem.characterSlug ?? character.assetFolderSlug
                    outputRoot = animateURL
                        .appendingPathComponent("characters")
                        .appendingPathComponent(resolvedSlug)
                        .appendingPathComponent("batch-queue-batches")
                        .appendingPathComponent("\(stamp)-queue")
                    batchName = character.name
                    batchSlug = resolvedSlug
                } else {
                    let relativeRoot = firstItem.outputRootRelativePath?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    outputRoot = animateURL
                        .appendingPathComponent(relativeRoot?.isEmpty == false ? relativeRoot! : "3d/generation-queue-batches")
                        .appendingPathComponent("\(stamp)-queue")
                    batchName = firstItem.characterName
                    batchSlug = sanitizedBatchSlug(from: relativeRoot ?? firstItem.characterName)
                }

                do {
                    let promptRequests = try items.map { item in
                        let slug = item.draftTitle
                            .lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                            .replacingOccurrences(of: "•", with: "")
                            .replacingOccurrences(of: "  ", with: "-")

                        let referencePaths: [String] = try item.draft.includedReferenceItems.map { ref in
                            if let resolvedURL = store.resolvedCharacterAssetURL(for: ref.path) {
                                return resolvedURL.path
                            }
                            let candidate = URL(fileURLWithPath: ref.path)
                            if FileManager.default.fileExists(atPath: candidate.path) {
                                return candidate.path
                            }
                            throw NSError(
                                domain: "BatchQueue",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Reference image could not be resolved: \(ref.path)"]
                            )
                        }

                        return GeminiBatchSubmissionPlan.PromptRequest(
                            id: slug,
                            title: item.draftTitle,
                            prompt: item.draft.prompt,
                            referencePaths: referencePaths
                        )
                    }

                    let firstDraft = items.first!.draft
                    let submissionPlan = GeminiBatchSubmissionPlan(
                        characterName: batchName,
                        characterSlug: batchSlug,
                        displayName: "\(batchSlug)-queue-\(stamp.lowercased())",
                        model: firstDraft.model,
                        aspectRatio: firstDraft.aspectRatio,
                        imageSize: firstDraft.imageSize,
                        outputRoot: outputRoot,
                        prompts: promptRequests
                    )

                    let service = GeminiBatchService()
                    let submission = try await service.submit(plan: submissionPlan, apiKey: store.geminiAPIKey)
                    try service.launchWatchdog(metadataPath: submission.metadataPath, apiKey: store.geminiAPIKey)

                    if let characterID = firstItem.characterID {
                        store.registerInspirationBatchJob(
                            CharacterInspirationBatchJob(
                                title: "Batch Queue (\(items.count) items)",
                                batchName: submission.batchName,
                                metadataPath: submission.metadataPath.path,
                                outputRootPath: submission.outputRoot.path,
                                state: submission.state,
                                promptCount: submission.promptCount,
                                submittedAt: submission.submittedAt
                            ),
                            for: characterID
                        )
                        store.refreshInspirationBatchJobs()
                    } else {
                        store.statusMessage = "Submitted pipeline batch with \(items.count) item\(items.count == 1 ? "" : "s") to \(submission.outputRoot.lastPathComponent)"
                    }
                    // Remove only this group's items from the queue after successful submission
                    for item in items {
                        store.removeBatchQueueItem(item.id)
                    }
                } catch {
                    // Re-queue items on failure so the user doesn't lose them
                    for item in items {
                        if let characterID = item.characterID {
                            store.addToBatchQueue(
                                characterID: characterID,
                                characterName: item.characterName,
                                draftTitle: item.draftTitle,
                                draft: item.draft,
                                characterSlug: item.characterSlug
                            )
                        } else if let outputRootRelativePath = item.outputRootRelativePath {
                            store.addToBatchQueue(
                                pipelineName: item.characterName,
                                draftTitle: item.draftTitle,
                                draft: item.draft,
                                outputRootRelativePath: outputRootRelativePath
                            )
                        }
                    }
                }
            }
        }
    }

    private func sanitizedBatchSlug(from value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "pipeline" : slug
    }

    // MARK: - Animate Inspector

    @ViewBuilder
    private var animateInspector: some View {
        if let scene = store.selectedScene {
            VStack(alignment: .leading, spacing: 12) {
                Label("Scene", systemImage: "music.note")
                    .font(.headline)

                LabeledContent("Name") {
                    Text(scene.name)
                }

                LabeledContent("Characters") {
                    Text("\(scene.characterIDs.count)")
                }

                LabeledContent("Background") {
                    if let bgID = scene.backgroundID,
                       let bg = store.backgrounds.first(where: { $0.id == bgID }) {
                        Text(bg.name)
                    } else {
                        Text("None")
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                sceneAutomationFrameworkSection(scene)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Background", systemImage: "photo.on.rectangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if store.backgrounds.isEmpty {
                        Text("No backgrounds imported")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Picker("Background", selection: sceneBackgroundBinding) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.backgrounds) { bg in
                                Text(bg.name).tag(UUID?.some(bg.id))
                            }
                        }
                        .labelsHidden()
                    }

                    Button("Import Background...") {
                        importBackground()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                LabeledContent("Project Song") {
                    Text(scene.owpSongPath)
                        .font(.caption)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Animate", systemImage: "play.rectangle")
                    .font(.headline)

                Text("Select a scene to view properties.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func sceneAutomationFrameworkSection(_ scene: AnimationScene) -> some View {
        let sceneCharacters = timelineSceneCharacters(scene)
        let profile = store.resolvedAutomationProfile(for: scene)
            ?? SceneAutomationProfile.defaultProfile(for: scene, characters: sceneCharacters)
        let plan = store.selectedSceneAutomationPlan()

        VStack(alignment: .leading, spacing: 12) {
            Label("Engine Framework", systemImage: "sparkles.rectangle.stack")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Configure the in-house / hybrid automation lane now so the project is ready before production shots depend on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Execution Mode", selection: sceneExecutionModeBinding()) {
                ForEach(SceneExecutionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            HStack(spacing: 12) {
                Picker("Acting", selection: sceneActingIntensityBinding()) {
                    ForEach(AutomationIntensity.allCases, id: \.self) { intensity in
                        Text(intensity.displayName).tag(intensity)
                    }
                }

                Picker("Camera", selection: sceneCameraStyleBinding()) {
                    ForEach(CameraAutomationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Picker("Lip Sync", selection: sceneLipSyncModeBinding()) {
                ForEach(LipSyncAssistMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("Allow Generative Video Assist", isOn: sceneAllowGenerativeAssistBinding())

            VStack(alignment: .leading, spacing: 8) {
                Text("Automation Passes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(SceneAutomationPass.allCases) { pass in
                    Toggle(pass.displayName, isOn: sceneAutomationPassBinding(pass))
                        .toggleStyle(.switch)
                        .font(.caption)
                }
            }

            if let plan {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        statusCapsule(
                            title: "Recommended \(plan.recommendedExecutionMode.displayName)",
                            color: .blue
                        )
                        statusCapsule(
                            title: "Effective \(plan.effectiveExecutionMode.displayName)",
                            color: plan.effectiveExecutionMode == .animateKitOnly ? .green : .orange
                        )
                    }

                    ProgressView(value: plan.readinessScore) {
                        Text(plan.summary)
                            .font(.caption)
                    }
                    .progressViewStyle(.linear)

                    ForEach(plan.checklist) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(automationReadinessColor(item.readiness))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(item.metric)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !sceneCharacters.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Character Automation")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(sceneCharacters) { character in
                            characterAutomationRow(
                                character,
                                profile: profile.characterProfiles.first(where: { $0.characterID == character.id }),
                                summary: plan.characterSummaries.first(where: { $0.id == character.id })
                            )
                        }
                    }
                }

                if !plan.recommendedNextSteps.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Next Steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(Array(plan.recommendedNextSteps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func characterAutomationRow(
        _ character: AnimationCharacter,
        profile: SceneCharacterAutomationProfile?,
        summary: SceneAutomationCharacterSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(character.name)
                    .font(.caption.weight(.semibold))

                if let summary {
                    statusCapsule(
                        title: summary.readiness.displayName,
                        color: automationReadinessColor(summary.readiness)
                    )
                }
            }

            if let summary {
                Text(summary.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(
                "Strategy",
                selection: characterAutomationStrategyBinding(
                    characterID: character.id,
                    fallback: profile?.strategy ?? .followSceneMode
                )
            ) {
                ForEach(CharacterAutomationStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.menu)

            if !character.costumeReferenceSets.isEmpty {
                Picker(
                    "Preferred Costume",
                    selection: characterAutomationCostumeBinding(
                        character: character,
                        fallback: profile?.preferredCostumeSetID
                    )
                ) {
                    Text("Auto").tag(nil as UUID?)
                    ForEach(character.costumeReferenceSets) { costume in
                        Text(costume.name).tag(Optional(costume.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Timeline Inspector

    @ViewBuilder
    private var timelineInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Timeline", systemImage: "ruler")
                .font(.headline)

            LabeledContent("FPS") {
                Text("\(store.fps)")
            }

            LabeledContent("Total Frames") {
                Text("\(store.totalFrames)")
            }

            LabeledContent("Current Frame") {
                Text("\(store.currentFrame)")
                    .monospacedDigit()
            }

            if let scene = store.selectedScene {
                let sceneCharacters = timelineSceneCharacters(scene)

                if !sceneCharacters.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cue Authoring", systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Picker("Character", selection: timelineCueCharacterBinding(scene: scene)) {
                            ForEach(sceneCharacters) { character in
                                Text(character.name).tag(Optional(character.id))
                            }
                        }

                        if let character = selectedTimelineCharacter(scene: scene) {
                            Picker("Facing Cue", selection: $timelineFacingDraft) {
                                Text("None").tag(nil as FacingDirection?)
                                ForEach([FacingDirection.left, .right, .camera, .away], id: \.self) { facing in
                                    Text(facing.displayName).tag(Optional(facing))
                                }
                            }

                            HStack(spacing: 8) {
                                Button("Apply Facing") {
                                    store.setFacingCue(timelineFacingDraft, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Clear Facing") {
                                    store.setFacingCue(nil, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Picker("View Cue", selection: $timelineViewAngleDraft) {
                                Text("None").tag(nil as AngleView?)
                                ForEach(AngleView.allCases, id: \.self) { angle in
                                    Text(angle.rawValue).tag(Optional(angle))
                                }
                            }

                            HStack(spacing: 8) {
                                Button("Apply View") {
                                    store.setViewAngleCue(timelineViewAngleDraft, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Clear View") {
                                    store.setViewAngleCue(nil, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Picker("Pose Cue", selection: $timelinePoseDraft) {
                                Text("None").tag(nil as CharacterPackagePose?)
                                ForEach(CharacterPackagePose.allCases, id: \.self) { pose in
                                    Text(pose.rawValue).tag(Optional(pose))
                                }
                            }

                            HStack(spacing: 8) {
                                Button("Apply Pose") {
                                    store.setPoseCue(timelinePoseDraft, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Clear Pose") {
                                    store.setPoseCue(nil, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            TextField("Expression Cue", text: $timelineExpressionDraft)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 8) {
                                Button("Apply Expression") {
                                    store.setExpressionCue(timelineExpressionDraft, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Clear Expression") {
                                    timelineExpressionDraft = ""
                                    store.setExpressionCue(nil, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            TextField("Action Cue", text: $timelineActionDraft)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 8) {
                                Button("Apply Action") {
                                    store.setActionCue(timelineActionDraft, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Clear Action") {
                                    timelineActionDraft = ""
                                    store.setActionCue(nil, for: character.id)
                                    syncTimelineCueDrafts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        Picker("Camera Shot", selection: $timelineCameraShotDraft) {
                            Text("None").tag(nil as CameraShot?)
                            ForEach([
                                CameraShot.extremeWide,
                                .wide,
                                .medium,
                                .mediumClose,
                                .close,
                                .extremeClose
                            ], id: \.self) { shot in
                                Text(shot.displayName).tag(Optional(shot))
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Apply Camera Shot") {
                                store.setCameraShotCue(timelineCameraShotDraft)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Clear Camera Shot") {
                                store.setCameraShotCue(nil)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Picker("Shot Intent", selection: $timelineShotIntentDraft) {
                            Text("None").tag(nil as ShotIntent?)
                            ForEach(ShotIntent.allCases, id: \.self) { intent in
                                Text(intent.displayName).tag(Optional(intent))
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Apply Shot Intent") {
                                store.setCameraShotIntentCue(timelineShotIntentDraft)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Clear Shot Intent") {
                                timelineShotIntentDraft = nil
                                store.setCameraShotIntentCue(nil)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        TextField("Beat Label", text: $timelineBeatLabelDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("Apply Beat Label") {
                                store.setCameraBeatLabelCue(timelineBeatLabelDraft)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Clear Beat Label") {
                                timelineBeatLabelDraft = ""
                                store.setCameraBeatLabelCue(nil)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        TextField("Beat Notes", text: $timelineBeatNotesDraft, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("Apply Beat Notes") {
                                store.setCameraBeatNotesCue(timelineBeatNotesDraft)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Clear Beat Notes") {
                                timelineBeatNotesDraft = ""
                                store.setCameraBeatNotesCue(nil)
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        Label("Scene Template", systemImage: "square.stack.3d.up")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Resolved Shot: \(store.evaluatedEffectiveCameraShot()?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("Live Default Shot: \(store.evaluatedCameraDefaultShot()?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("Live Focus: \(liveCameraFocusName())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("Live Intent: \(store.evaluatedCameraShotIntent()?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let suggestedShot = store.recommendedCameraShotFromIntent() {
                            Text("Intent Suggests: \(suggestedShot.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if let suggestedMovement = store.recommendedCameraMovementFromIntent() {
                            Text("Intent Move Suggests: \(suggestedMovement.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Text("Live Beat: \(store.evaluatedCameraBeatLabel() ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let liveBeatNotes = store.evaluatedCameraBeatNotes() {
                            Text(liveBeatNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }

                        Text("Template settings remain scene-level defaults. Shot presets now place framing cues on the timeline instead of mutating the whole scene.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Default Shot", selection: $sceneTemplateShotDraft) {
                            Text("None").tag(nil as CameraShot?)
                            ForEach([
                                CameraShot.extremeWide,
                                .wide,
                                .medium,
                                .mediumClose,
                                .close,
                                .extremeClose
                            ], id: \.self) { shot in
                                Text(shot.displayName).tag(Optional(shot))
                            }
                        }

                        Picker("Focus Character", selection: $sceneTemplateFocusCharacterID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(sceneCharacters) { character in
                                Text(character.name).tag(Optional(character.id))
                            }
                        }

                        TextField("Template Notes", text: $sceneTemplateNotesDraft, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button("Save Template") {
                                store.updateSelectedSceneDirectionTemplate(
                                    defaultCameraShot: sceneTemplateShotDraft,
                                    focusCharacterID: sceneTemplateFocusCharacterID,
                                    notes: sceneTemplateNotesDraft
                                )
                                syncSceneTemplateDrafts()
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Clear Template") {
                                sceneTemplateShotDraft = nil
                                sceneTemplateFocusCharacterID = nil
                                sceneTemplateNotesDraft = ""
                                store.updateSelectedSceneDirectionTemplate(
                                    defaultCameraShot: nil,
                                    focusCharacterID: nil,
                                    notes: ""
                                )
                                syncSceneTemplateDrafts()
                                syncTimelineCueDrafts()
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        Divider()

                        Label("Shot Presets", systemImage: "rectangle.stack.badge.play")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Picker("Preset", selection: shotPresetSelectionBinding()) {
                            Text("None").tag(nil as UUID?)
                            ForEach(store.shotPresets) { preset in
                                Text(preset.name).tag(Optional(preset.id))
                            }
                        }

                        TextField("Preset Name", text: $shotPresetNameDraft)
                            .textFieldStyle(.roundedBorder)

                        TextField("Preset Notes", text: $shotPresetNotesDraft, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)

                        if let selectedShotPresetID,
                           let preset = store.shotPreset(id: selectedShotPresetID) {
                            LabeledContent("Preset Intent") {
                                Text(preset.shotIntent?.displayName ?? "None")
                            }
                            .font(.caption)
                        }

                        let suggestedPresets = store.suggestedShotPresets(
                            for: store.evaluatedCameraShotIntent(),
                            focusCharacterID: store.evaluatedCameraFocusCharacterID()
                        )
                        if !suggestedPresets.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Intent Suggestions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(suggestedPresets) { preset in
                                    Button(preset.name) {
                                        selectedShotPresetID = preset.id
                                        syncShotPresetDrafts()
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Save New Preset") {
                                store.captureShotPreset(
                                    named: shotPresetNameDraft,
                                    notes: shotPresetNotesDraft,
                                    overwritePresetID: nil
                                )
                                syncShotPresetDrafts(selectByName: shotPresetNameDraft)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Update Selected") {
                                guard let selectedShotPresetID else { return }
                                store.captureShotPreset(
                                    named: shotPresetNameDraft,
                                    notes: shotPresetNotesDraft,
                                    overwritePresetID: selectedShotPresetID
                                )
                                syncShotPresetDrafts(selectByName: shotPresetNameDraft)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(selectedShotPresetID == nil)
                        }

                        HStack(spacing: 8) {
                            Button("Apply Selected") {
                                guard let selectedShotPresetID,
                                      let preset = store.shotPreset(id: selectedShotPresetID) else { return }
                                store.applyShotPreset(preset)
                                syncSceneTemplateDrafts()
                                syncTimelineCueDrafts()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(selectedShotPresetID == nil)

                            Button("Delete Selected") {
                                guard let selectedShotPresetID else { return }
                                store.deleteShotPreset(id: selectedShotPresetID)
                                self.selectedShotPresetID = nil
                                syncShotPresetDrafts()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(selectedShotPresetID == nil)
                        }
                    }
                }
            }

            if !store.sceneTracks.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Tracks", systemImage: "list.bullet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(store.orderedTimelineTracks().enumerated()), id: \.offset) { _, track in
                        let trackName = store.displayName(for: track)
                        HStack {
                            Text(trackName)
                                .font(.caption)
                            Spacer()
                            Text("\(track.keyframes.count) kf")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func timelineSceneCharacters(_ scene: AnimationScene) -> [AnimationCharacter] {
        scene.characterIDs.compactMap { characterID in
            store.characters.first(where: { $0.id == characterID })
        }
    }

    private func selectedTimelineCharacter(scene: AnimationScene) -> AnimationCharacter? {
        let characters = timelineSceneCharacters(scene)

        if let timelineCueCharacterID,
           let character = characters.first(where: { $0.id == timelineCueCharacterID }) {
            return character
        }

        if let selectedCharacterID = store.selectedCharacterID,
           let character = characters.first(where: { $0.id == selectedCharacterID }) {
            return character
        }

        return characters.first
    }

    private func timelineCueCharacterBinding(scene: AnimationScene) -> Binding<UUID?> {
        Binding(
            get: {
                selectedTimelineCharacter(scene: scene)?.id
            },
            set: { newValue in
                timelineCueCharacterID = newValue
                if let newValue {
                    store.selectedCharacterID = newValue
                }
                syncTimelineCueDrafts()
            }
        )
    }

    private func shotPresetSelectionBinding() -> Binding<UUID?> {
        Binding(
            get: { selectedShotPresetID },
            set: { newValue in
                selectedShotPresetID = newValue
                syncShotPresetDrafts()
            }
        )
    }

    private func sceneExecutionModeBinding() -> Binding<SceneExecutionMode> {
        Binding(
            get: { store.resolvedAutomationProfile()?.executionMode ?? .autoRecommend },
            set: { store.setSelectedSceneExecutionMode($0) }
        )
    }

    private func sceneActingIntensityBinding() -> Binding<AutomationIntensity> {
        Binding(
            get: { store.resolvedAutomationProfile()?.actingIntensity ?? .balanced },
            set: { store.setSelectedSceneActingIntensity($0) }
        )
    }

    private func sceneCameraStyleBinding() -> Binding<CameraAutomationStyle> {
        Binding(
            get: { store.resolvedAutomationProfile()?.cameraStyle ?? .motivated2D },
            set: { store.setSelectedSceneCameraAutomationStyle($0) }
        )
    }

    private func sceneLipSyncModeBinding() -> Binding<LipSyncAssistMode> {
        Binding(
            get: { store.resolvedAutomationProfile()?.lipSyncAssistMode ?? .assistedGuide },
            set: { store.setSelectedSceneLipSyncAssistMode($0) }
        )
    }

    private func sceneAllowGenerativeAssistBinding() -> Binding<Bool> {
        Binding(
            get: { store.resolvedAutomationProfile()?.allowGenerativeVideoAssist ?? true },
            set: { store.setSelectedSceneAllowGenerativeVideoAssist($0) }
        )
    }

    private func sceneAutomationPassBinding(
        _ pass: SceneAutomationPass
    ) -> Binding<Bool> {
        Binding(
            get: { store.resolvedAutomationProfile()?.enabledPasses.contains(pass) ?? false },
            set: { store.setSelectedSceneAutomationPass(pass, isEnabled: $0) }
        )
    }

    private func characterAutomationStrategyBinding(
        characterID: UUID,
        fallback: CharacterAutomationStrategy
    ) -> Binding<CharacterAutomationStrategy> {
        Binding(
            get: {
                store.resolvedAutomationProfile()?.characterProfiles.first(where: {
                    $0.characterID == characterID
                })?.strategy ?? fallback
            },
            set: { store.setSelectedSceneCharacterAutomationStrategy($0, for: characterID) }
        )
    }

    private func characterAutomationCostumeBinding(
        character: AnimationCharacter,
        fallback: UUID?
    ) -> Binding<UUID?> {
        Binding(
            get: {
                store.resolvedAutomationProfile()?.characterProfiles.first(where: {
                    $0.characterID == character.id
                })?.preferredCostumeSetID ?? fallback
            },
            set: { store.setSelectedSceneCharacterPreferredCostumeSet($0, for: character.id) }
        )
    }

    private func syncTimelineCueDrafts() {
        guard let scene = store.selectedScene else {
            timelineCueCharacterID = nil
            timelineExpressionDraft = ""
            timelineActionDraft = ""
            timelinePoseDraft = nil
            timelineViewAngleDraft = nil
            timelineFacingDraft = nil
            timelineCameraShotDraft = nil
            timelineShotIntentDraft = nil
            timelineBeatLabelDraft = ""
            timelineBeatNotesDraft = ""
            return
        }

        timelineCameraShotDraft = store.evaluatedCameraShot()
        timelineShotIntentDraft = store.evaluatedCameraShotIntent()
        timelineBeatLabelDraft = store.evaluatedCameraBeatLabel() ?? ""
        timelineBeatNotesDraft = store.evaluatedCameraBeatNotes() ?? ""

        let characters = timelineSceneCharacters(scene)
        guard !characters.isEmpty else {
            timelineCueCharacterID = nil
            timelineExpressionDraft = ""
            timelineActionDraft = ""
            timelinePoseDraft = nil
            timelineViewAngleDraft = nil
            timelineFacingDraft = nil
            return
        }

        let resolvedCharacter = selectedTimelineCharacter(scene: scene) ?? characters[0]
        timelineCueCharacterID = resolvedCharacter.id
        timelineExpressionDraft = store.evaluatedExpression(for: resolvedCharacter.id) ?? ""
        timelineActionDraft = store.evaluatedAction(for: resolvedCharacter.id) ?? ""
        timelinePoseDraft = store.evaluatedPose(for: resolvedCharacter.id)
        timelineViewAngleDraft = store.evaluatedViewAngle(for: resolvedCharacter.id)
        timelineFacingDraft = store.evaluatedFacingDirection(for: resolvedCharacter.id)
    }

    private func syncSceneTemplateDrafts() {
        let template = store.selectedScene?.directionTemplate
        sceneTemplateShotDraft = template?.defaultCameraShot
        sceneTemplateFocusCharacterID = template?.focusCharacterID
        sceneTemplateNotesDraft = template?.notes ?? ""
    }

    private func liveCameraFocusName() -> String {
        guard let focusCharacterID = store.evaluatedCameraFocusCharacterID() else {
            return "None"
        }

        return store.characters.first(where: { $0.id == focusCharacterID })?.name ?? "None"
    }

    private func syncShotPresetDrafts(selectByName preferredName: String? = nil) {
        if let preferredName {
            let normalizedName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = store.shotPresets.first(where: {
                $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
            }) {
                selectedShotPresetID = match.id
            }
        }

        if let selectedShotPresetID,
           let preset = store.shotPreset(id: selectedShotPresetID) {
            shotPresetNameDraft = preset.name
            shotPresetNotesDraft = preset.notes
            return
        }

        if let firstPreset = store.shotPresets.first {
            selectedShotPresetID = firstPreset.id
            shotPresetNameDraft = firstPreset.name
            shotPresetNotesDraft = firstPreset.notes
        } else {
            selectedShotPresetID = nil
            shotPresetNameDraft = ""
            shotPresetNotesDraft = ""
        }
    }

    private var sceneBackgroundBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedScene?.backgroundID },
            set: { newValue in
                if let sceneID = store.selectedSceneID,
                   let idx = store.scenes.firstIndex(where: { $0.id == sceneID }) {
                    store.scenes[idx].backgroundID = newValue
                    store.save()
                }
            }
        )
    }

    private func drawThingsBinding<Value>(
        _ keyPath: WritableKeyPath<DrawThingsPlaceConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.drawThingsPlaceConfig[keyPath: keyPath] },
            set: { newValue in
                var updated = store.drawThingsPlaceConfig
                updated[keyPath: keyPath] = newValue
                store.drawThingsPlaceConfig = updated
            }
        )
    }

    @ViewBuilder
    private func labeledTextField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func labeledIntegerField(
        _ title: String,
        value: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func labeledOptionalIntegerField(
        _ title: String,
        value: Binding<Int?>
    ) -> some View {
        let stringBinding = Binding<String>(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                value.wrappedValue = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func labeledDoubleField(
        _ title: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(1...2)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func importBackground() {
        let panel = NSOpenPanel()
        panel.title = "Import Background Image"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                store.importBackground(from: url)
            }
        }
    }

    private func angleCoverage(for character: AnimationCharacter) -> [AngleView: Int] {
        var result: [AngleView: Int] = [:]
        for angle in AngleView.allCases {
            var count = 0
            for part in character.parts {
                if let set = part.drawingSets[angle] {
                    count += set.variants.count
                }
            }
            result[angle] = count
        }
        return result
    }

    private func activePackage(for character: AnimationCharacter) -> InstalledCharacterPackage? {
        guard let animateURL = store.animateURL else { return nil }
        return CharacterPackageLibrary().activePackage(
            for: character.owpSlug,
            in: animateURL,
            preferredActivePackageID: store.activePackageID(for: character.owpSlug)
        )
    }

    private func syncedVariantPreviews(
        for character: AnimationCharacter,
        packageID: UUID
    ) -> [SyncedVariantPreview] {
        character.parts
            .flatMap { part in
                part.drawingSets.values.flatMap { drawingSet in
                    drawingSet.variants.compactMap { variant in
                        guard variant.sourcePackageID == packageID else { return nil }
                        return SyncedVariantPreview(
                            partName: part.name,
                            angle: drawingSet.angle,
                            variant: variant
                        )
                    }
                }
            }
            .sorted {
                if $0.partName != $1.partName {
                    return $0.partName.localizedCaseInsensitiveCompare($1.partName) == .orderedAscending
                }
                return $0.angle.rawValue < $1.angle.rawValue
            }
    }

    private func hasLegacyPackageVariants(
        for character: AnimationCharacter,
        package: InstalledCharacterPackage
    ) -> Bool {
        character.parts.contains { part in
            part.drawingSets.values.contains { drawingSet in
                drawingSet.variants.contains { variant in
                    variant.sourcePackageID == nil &&
                    variant.name.hasPrefix("\(package.manifest.displayName) •")
                }
            }
        }
    }

    private func sourcePathLabel(for variant: DrawingVariant) -> String? {
        if let sourceRelativePath = variant.sourceRelativePath, !sourceRelativePath.isEmpty {
            return sourceRelativePath
        }

        return variant.sourceURL?.lastPathComponent
    }

    private func placementSummary(for variant: DrawingVariant) -> String? {
        guard let placement = variant.placement else { return nil }

        var parts: [String] = [placement.resolvedMode == .fullCanvasAligned ? "Full Canvas" : "Framed"]

        if let zOrderOverride = placement.zOrderOverride {
            parts.append("z \(zOrderOverride)")
        }

        if let pivot = placement.normalizedPivot {
            parts.append(String(format: "pivot %.2f, %.2f", pivot.x, pivot.y))
        }

        return parts.joined(separator: " • ")
    }

    private func automationReadinessColor(
        _ readiness: SceneAutomationReadiness
    ) -> Color {
        switch readiness {
        case .missing:
            .red
        case .partial:
            .orange
        case .ready:
            .green
        }
    }

    private func syncedVariantStats(
        for character: AnimationCharacter,
        packageID: UUID
    ) -> (total: Int, withPlacement: Int, withPivot: Int) {
        var total = 0
        var withPlacement = 0
        var withPivot = 0

        for part in character.parts {
            for drawingSet in part.drawingSets.values {
                for variant in drawingSet.variants where variant.sourcePackageID == packageID {
                    total += 1
                    if variant.placement != nil {
                        withPlacement += 1
                    }
                    if variant.placement?.normalizedPivot != nil {
                        withPivot += 1
                    }
                }
            }
        }

        return (total, withPlacement, withPivot)
    }

    private func statusCapsule(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

}
