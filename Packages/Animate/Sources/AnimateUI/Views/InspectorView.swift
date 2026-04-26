import AppKit
import ProjectKit
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
    @State private var characterLibraryState = AllProjectImagesState()
    @State private var sceneLibraryState = AllProjectImagesState()
    @State private var placeLibraryState = AllProjectImagesState()

    private struct SyncedVariantPreview: Identifiable {
        var partName: String
        var angle: AngleView
        var variant: DrawingVariant

        var id: UUID { variant.id }
    }

    private enum InspectorTab: String, Identifiable {
        case details, library, assets, properties, gemini

        var id: String { rawValue }
    }
    @AppStorage("animate.inspector.selectedTab.v3") private var selectedTab = InspectorTab.details.rawValue

    var body: some View {
        VStack(spacing: 0) {
            SharedInspectorTabBar(selection: selectedTabBinding, items: tabItems)
            Divider()
            tabBody
        }
    }

    private var effectiveTab: InspectorTab {
        if selectedTab == InspectorTab.properties.rawValue {
            return .details
        }
        guard let parsed = InspectorTab(rawValue: selectedTab),
              tabItems.contains(where: { $0.value == parsed }) else {
            return .details
        }
        return parsed
    }

    @ViewBuilder
    private var tabBody: some View {
        switch effectiveTab {
        case .library:
            libraryContent
        case .details:
            detailsContent
        case .assets:
            assetsContent
        case .gemini:
            geminiContent
        case .properties:
            detailsContent
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch currentPage {
        case .characters:
            inspectorScrollContainer {
                CharacterImageLibraryInspectorSection(store: store, state: characterLibraryState)
            }
        case .scenes:
            inspectorScrollContainer {
                SceneImageLibraryInspectorSection(store: store, state: sceneLibraryState)
            }
        case .places:
            inspectorScrollContainer {
                PlaceImageLibraryInspectorSection(store: store, state: placeLibraryState)
            }
        case .props, .script, .animate, .timeline:
            EmptyView()
        }
    }

    @ViewBuilder
    private var geminiContent: some View {
        if currentPage == .places {
            inspectorScrollContainer { PlaceGeminiBatchInspectorSection(store: store) }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailsContent: some View {
        detailsContentInner
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailsContentInner: some View {
        switch currentPage {
        case .places:
            placesDetails
        case .characters:
            charactersDetails
        case .props:
            propsDetails
        case .scenes:
            scenesDetails
        case .script, .animate:
            AnimatePageView(
                store: store,
                workspaceState: animateWorkspaceState,
                presentation: .assets
            )
        case .timeline:
            inspectorScrollContainer { timelineInspector }
        }
    }

    private var placesDetails: some View {
        let placeSel = PlaceImageSelection(store: store)
        return inspectorScrollContainer {
            UnifiedDetailsInspectorSection(selection: placeSel) {
                PlaceDetailsExtraActionsSection(store: store)
            }
            if let path = placeSel.imageURL?.path {
                InspectorImageIntelligenceSummary(store: store, resolvedPath: path)
            }
        }
    }

    private var charactersDetails: some View {
        let sel = CharacterImageSelection(store: store)
        return inspectorScrollContainer {
            UnifiedDetailsInspectorSection(selection: sel)
            if let path = sel.imageURL?.path {
                InspectorImageIntelligenceSummary(store: store, resolvedPath: path)
            }
        }
    }

    private var propsDetails: some View {
        let sel = PropImageSelection(store: store)
        return inspectorScrollContainer {
            UnifiedDetailsInspectorSection(selection: sel)
            if let path = sel.imageURL?.path {
                InspectorImageIntelligenceSummary(store: store, resolvedPath: path)
            }
        }
    }

    private var scenesDetails: some View {
        let sel = currentSceneShotSelection
        return inspectorScrollContainer {
            UnifiedDetailsInspectorSection(selection: sel)
            if let path = sel.imageURL?.path {
                InspectorImageIntelligenceSummary(store: store, resolvedPath: path)
            }
        }
    }

    private var currentSceneShotSelection: SceneShotImageSelection {
        SceneShotImageSelection(
            path: store.imaginePreviewImagePath,
            store: store,
            scene: store.selectedScene,
            shotIndex: store.imagineSelectedShotIndex,
            moment: store.imagineSelectedMoment,
            onSetRating: { rating in
                guard let path = store.imaginePreviewImagePath else { return }
                InspectorView.applyRating(rating, path: path)
            },
            onToggleRejected: {
                guard let path = store.imaginePreviewImagePath else { return }
                InspectorView.toggleRejected(path: path)
            },
            onSetNotes: { notes in
                guard let path = store.imaginePreviewImagePath else { return }
                InspectorView.applyNotes(notes, path: path)
            }
        )
    }

    private static func applyRating(_ rating: Int?, path: String) {
        var meta = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        meta.rating = rating
        meta.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(meta, forImagePath: path)
    }

    private static func toggleRejected(path: String) {
        var meta = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        meta.isRejected.toggle()
        meta.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(meta, forImagePath: path)
    }

    private static func applyNotes(_ notes: String, path: String) {
        var meta = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        meta.notes = notes
        meta.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(meta, forImagePath: path)
    }

    private var selectedTabBinding: Binding<InspectorTab> {
        Binding(
            get: {
                let parsed = InspectorTab(rawValue: selectedTab) ?? .details
                return tabItems.contains(where: { $0.value == parsed }) ? parsed : .details
            },
            set: { selectedTab = $0.rawValue }
        )
    }

    private var tabItems: [SharedInspectorTabItem<InspectorTab>] {
        var items: [SharedInspectorTabItem<InspectorTab>] = [
            SharedInspectorTabItem(value: .details, title: "Details", systemImage: "info.circle")
        ]
        switch currentPage {
        case .characters:
            items.append(SharedInspectorTabItem(value: .library, title: "Library", systemImage: "photo.stack"))
        case .scenes:
            items.append(SharedInspectorTabItem(value: .library, title: "Library", systemImage: "photo.stack"))
        case .places:
            items.append(SharedInspectorTabItem(value: .library, title: "Library", systemImage: "photo.stack"))
            items.append(SharedInspectorTabItem(value: .assets, title: "Assets", systemImage: "photo.stack"))
            items.append(SharedInspectorTabItem(value: .gemini, title: "Gemini", systemImage: "sparkles"))
        case .props, .script, .animate, .timeline:
            items.append(SharedInspectorTabItem(value: .assets, title: "Assets", systemImage: "shippingbox.fill"))
        }
        return items
    }

    @ViewBuilder
    private var assetsContent: some View {
        assetsContentInner
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var assetsContentInner: some View {
        switch currentPage {
        case .script, .animate:
            AnimatePageView(
                store: store,
                workspaceState: animateWorkspaceState,
                presentation: .assets
            )
        case .places:
            inspectorScrollContainer { PlaceAssetsInspectorSection(store: store) }
        case .characters:
            inspectorScrollContainer { characterInspector }
        case .props:
            inspectorScrollContainer { propsInspector }
        case .timeline:
            inspectorScrollContainer { timelineInspector }
        case .scenes:
            EmptyView()
        }
    }

    @ViewBuilder
    private var propertiesContent: some View {
        propertiesContentInner
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

    @ViewBuilder
    private var propertiesContentInner: some View {
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
        case .scenes:
            EmptyView()
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
        PlaceGeminiInspectorSection(store: store)
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
        VStack(alignment: .leading, spacing: 8) {
            Label("Characters", systemImage: "person.2")
                .font(.headline)

            if let character = store.selectedCharacter {
                Text(character.name)
                    .font(.subheadline.weight(.semibold))
                Text("Use the Characters page for the current reference, costume, and start/end-frame animation workflow. Legacy rig/package/canvas-render actions are no longer exposed here.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Text("Select a character to inspect image details.")
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
        TextField(title, value: value, format: IntegerFormatStyle<Int>().grouping(.never))
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

@available(macOS 26.0, *)
private struct PlaceAssetsInspectorSection: View {
    @Bindable var store: AnimateStore
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = PlaceWorkflowMode.photorealistic.rawValue

    private var workflowMode: PlaceWorkflowMode {
        get { PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic }
        nonmutating set { workflowModeRawValue = newValue.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Place Assets", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Picker("Workflow", selection: Binding(
                get: { workflowMode },
                set: { workflowMode = $0 }
            )) {
                ForEach(PlaceWorkflowMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let place = store.selectedPlace {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Selected Place") { Text(place.name) }
                    LabeledContent("\(workflowMode.shortLabel) Images") { Text("\(place.imagePaths(for: workflowMode).count)") }
                    LabeledContent("Approved") {
                        Text(place.approvedImagePath(for: workflowMode).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                            .lineLimit(1)
                    }
                    LabeledContent("Local Refs") { Text("\(place.referenceImages.count)") }
                    LabeledContent("Angle Images") { Text("\(place.angleImages.count)") }
                    LabeledContent("Landmark Refs") { Text("\(store.placesWorkflowLibrary.landmarkReferences.count)") }
                }

                assetPreviewCard(
                    title: "\(workflowMode.displayName) Approved",
                    path: place.approvedImagePath(for: workflowMode)
                )

                assetPreviewCard(
                    title: "Master Map",
                    path: store.placesWorkflowLibrary.masterMapImagePath
                )

                HStack(spacing: 8) {
                    Button {
                        store.addImagesToPlaceFromPicker(placeID: place.id, workflow: workflowMode)
                    } label: {
                        Label("Import \(workflowMode.shortLabel)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.addPlaceReferenceImagesFromPicker(placeID: place.id)
                    } label: {
                        Label("Add Refs", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    store.addAngleImagesToPlaceFromPicker(placeID: place.id)
                } label: {
                    Label("Add Angle Images", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Select a place to inspect its approved image, references, and import actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                assetPreviewCard(title: "Master Map", path: store.placesWorkflowLibrary.masterMapImagePath)
            }
        }
    }

    @ViewBuilder
    private func assetPreviewCard(title: String, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let path,
               let url = store.resolvedCharacterAssetURL(for: path) {
                AsyncResolvedImageView(path: url.path, maxPixelSize: 960, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 110)
                    .overlay {
                        Text("No asset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PlaceGeminiInspectorSection: View {
    @Bindable var store: AnimateStore
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = PlaceWorkflowMode.photorealistic.rawValue

    private var workflowMode: PlaceWorkflowMode {
        get { PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic }
        nonmutating set { workflowModeRawValue = newValue.rawValue }
    }

    private var config: PlaceWorkflowRenderConfig {
        store.workflowConfig(for: workflowMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Gemini Places Workflow", systemImage: "sparkles")
                .font(.headline)

            Picker("Workflow", selection: Binding(
                get: { workflowMode },
                set: { workflowMode = $0 }
            )) {
                ForEach(PlaceWorkflowMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let place = store.selectedPlace {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Selected Place") { Text(place.name) }
                    LabeledContent("Scenes Using It") { Text("\(store.sceneReferences(for: place.id).count)") }
                    LabeledContent("\(workflowMode.shortLabel) Images") { Text("\(place.imagePaths(for: workflowMode).count)") }
                    LabeledContent("Approved") {
                        Text(place.approvedImagePath(for: workflowMode).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                            .lineLimit(1)
                    }
                    if let mapPath = store.placesWorkflowLibrary.masterMapImagePath {
                        LabeledContent("Master Map") {
                            Text(URL(fileURLWithPath: mapPath).lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                    LabeledContent("Landmark Refs") { Text("\(store.placesWorkflowLibrary.landmarkReferences.count)") }
                }
            } else {
                Text("Select a place in the middle pane to configure Gemini generation for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Group {
                labeledModelPicker
                labeledChoicePicker(
                    "Aspect Ratio",
                    selection: configBinding(\.aspectRatio),
                    options: ["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"]
                )
                labeledChoicePicker(
                    "Image Size",
                    selection: configBinding(\.imageSize),
                    options: ["1K", "2K", "4K"]
                )
                labeledTextField("Lens / Camera Guidance", text: configBinding(\.lensDescription), axis: .vertical)
                labeledTextField("Prompt Prefix", text: configBinding(\.promptPrefix), axis: .vertical)
                labeledTextField("Prompt Suffix", text: configBinding(\.promptSuffix), axis: .vertical)
            }

            Text("The Places page now previews Gemini prompts before submit. Immediate generations run directly; batch generations launch the Gemini watchdog-backed batch workflow.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var labeledModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Model", selection: $store.selectedGeminiModel) {
                ForEach(GeminiModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Places follows the master Gemini default model.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func configBinding(_ keyPath: WritableKeyPath<PlaceWorkflowRenderConfig, String>) -> Binding<String> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                var updated = config
                updated[keyPath: keyPath] = newValue
                store.updatePlaceWorkflowConfig(updated, for: workflowMode)
            }
        )
    }

    private func labeledTextField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis)
                .textFieldStyle(.roundedBorder)
                .lineLimit(axis == .vertical ? 3...6 : 1...1)
        }
    }

    private func labeledChoicePicker(
        _ title: String,
        selection: Binding<String>,
        options: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                // Preserve any custom/legacy value that isn't in the hard-coded
                // option list so existing configs survive the UI change.
                if !options.contains(selection.wrappedValue) && !selection.wrappedValue.isEmpty {
                    Text("\(selection.wrappedValue) (custom)").tag(selection.wrappedValue)
                }
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

@available(macOS 26.0, *)
struct PlaceGeneratedImageDetailsInspectorSection: View {
    @Bindable var store: AnimateStore
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = PlaceWorkflowMode.photorealistic.rawValue
    @State private var isSubmittingImmediate = false
    @State private var inlineErrorMessage: String?

    private var workflowMode: PlaceWorkflowMode {
        get { PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic }
        nonmutating set { workflowModeRawValue = newValue.rawValue }
    }

    private var record: GeneratedBackgroundLibraryRecord? {
        store.selectedGeneratedBackgroundRecord
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Details", systemImage: "info.circle")
                .font(.headline)

            if let record {
                previewCard(for: record)
                ratingSection(for: record)
                rejectionNotesEditor(for: record)
                Divider()
                notesEditor(for: record)

                if let queueItem = store.pendingGeneratedBackgroundEditQueueItem(for: record.id) {
                    queueStateCard(queueItem)
                }

                metadataSection(for: record)
                versionHistorySection(for: record)
                editHistorySection(for: record)
            } else if let place = store.selectedPlace {
                Text("Select an image in All Generated Background Images to inspect it here. Current place: \(place.name).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a generated background image to see its preview, notes, rating, metadata, and Gemini edit history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func previewCard(for record: GeneratedBackgroundLibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(URL(fileURLWithPath: record.activePath).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if record.isRejected {
                    Text("Rejected")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.14), in: Capsule())
                        .foregroundStyle(.red)
                }
            }

            if let url = store.resolvedCharacterAssetURL(for: record.activePath) {
                AsyncResolvedImageView(path: url.path, maxPixelSize: 1280, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 180, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 180)
                    .overlay {
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            if !record.summary.isEmpty {
                Text(record.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func ratingSection(for record: GeneratedBackgroundLibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rating")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { rating in
                    Button {
                        store.setGeneratedBackgroundRating(record.rating == rating ? nil : rating, for: record.id)
                    } label: {
                        Image(systemName: (record.rating ?? 0) >= rating ? "star.fill" : "star")
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 18)

                Button(record.isRejected ? "Unreject" : "Reject") {
                    store.toggleGeneratedBackgroundRejected(record.id)
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(record.workflow.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func notesEditor(for record: GeneratedBackgroundLibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Notes")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: Binding(
                get: { store.selectedGeneratedBackgroundRecord?.draftEditNotes ?? "" },
                set: { store.updateGeneratedBackgroundEditNotes($0, for: record.id) }
            ))
            .font(.system(.body, design: .default))
            .frame(minHeight: 120)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            HStack(spacing: 8) {
                Button {
                    queueGeneratedBackgroundEdit(record)
                } label: {
                    Label("Add to Batch", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canSubmitGeminiBatchJobs)

                Button {
                    runImmediateEdit(record)
                } label: {
                    if isSubmittingImmediate {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Edit Now", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmittingImmediate || record.draftEditNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                if let queueItem = store.pendingGeneratedBackgroundEditQueueItem(for: record.id) {
                    Text(queueItem.state.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(queueItem.state == .failed ? .orange : .secondary)
                }
            }

            if let inlineErrorMessage, !inlineErrorMessage.isEmpty {
                Text(inlineErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func rejectionNotesEditor(for record: GeneratedBackgroundLibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Rejection Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if record.isRejected {
                    Text("Rejected")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.14), in: Capsule())
                        .foregroundStyle(.red)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(record.isRejected ? 0.09 : 0.05))

                if (store.selectedGeneratedBackgroundRecord?.rejectionNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Why are we rejecting this image?")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { store.selectedGeneratedBackgroundRecord?.rejectionNotes ?? "" },
                    set: { store.updateGeneratedBackgroundRejectionNotes($0, for: record.id) }
                ))
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.clear)
            }
            .frame(minHeight: 110)
        }
    }

    @ViewBuilder
    private func queueStateCard(_ item: PlaceImageEditQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued Gemini Edit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.instructions)
                .font(.caption)
            if let error = item.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metadataSection(for record: GeneratedBackgroundLibraryRecord) -> some View {
        let metadata = store.generationMetadata(for: record.activePath)
        let resolution = store.imageResolutionDescription(for: record.activePath)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.caption)
                .foregroundStyle(.secondary)

            metadataRow("Keywords", value: record.keywords.isEmpty ? "None" : record.keywords.joined(separator: ", "))
            if let metadata {
                metadataRow("Model", value: metadata.model)
                metadataRow("Aspect", value: metadata.aspectRatio)
                metadataRow("Size", value: metadata.imageSize)
            }
            if let resolution, !resolution.isEmpty {
                metadataRow("Resolution", value: resolution)
            }
            metadataRow("Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let prompt = record.sourcePrompt, !prompt.isEmpty {
                metadataRow("Prompt", value: prompt)
            }
            if record.duplicatePaths.count > 0 {
                metadataRow("Duplicates", value: "\(record.duplicatePaths.count) hidden duplicates")
            }
            metadataRow("Used for future refs", value: record.isRejected ? "No" : "Yes (prefer \(record.rating ?? 0)-star priority)")
        }
    }

    @ViewBuilder
    private func versionHistorySection(for record: GeneratedBackgroundLibraryRecord) -> some View {
        if !record.priorVersions.isEmpty {
            DisclosureGroup("Older Versions (\(record.priorVersions.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.priorVersions) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: version.path).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                Text(version.supersededAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") {
                                reveal(version.path)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func editHistorySection(for record: GeneratedBackgroundLibraryRecord) -> some View {
        if !record.editHistory.isEmpty {
            DisclosureGroup("Edit History (\(record.editHistory.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(record.editHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.weight(.semibold))
                            Text(entry.instructions)
                                .font(.caption)
                            if let prompt = entry.prompt, !prompt.isEmpty {
                                Text(prompt)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func queueGeneratedBackgroundEdit(_ record: GeneratedBackgroundLibraryRecord) {
        store.queueGeneratedBackgroundEdit(recordID: record.id, workflow: workflowMode)
        inlineErrorMessage = nil
    }

    private func runImmediateEdit(_ record: GeneratedBackgroundLibraryRecord) {
        inlineErrorMessage = nil
        isSubmittingImmediate = true
        Task { @MainActor in
            defer { isSubmittingImmediate = false }
            do {
                try await store.submitGeneratedBackgroundEditImmediately(recordID: record.id, workflow: workflowMode)
            } catch {
                inlineErrorMessage = error.localizedDescription
            }
        }
    }

    private func reveal(_ path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path)
            ?? (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@available(macOS 26.0, *)
private struct CharacterImageLibraryInspectorSection: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    private var selectedCharacter: AnimationCharacter? {
        store.selectedCharacter
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedCharacter == nil {
                ContentUnavailableView(
                    "No Character Selected",
                    systemImage: "person.crop.square",
                    description: Text("Select a character to view their image library.")
                )
                .padding()
            } else {
                AllProjectImagesPageView(
                    store: store,
                    state: state,
                    layout: .canvasSidebar
                )
                .frame(minHeight: 520)
            }
        }
        .task(id: librarySelectionSignature) {
            configureLibraryFilter()
        }
    }

    private var librarySelectionSignature: String {
        [
            store.owpURL?.path ?? "",
            selectedCharacter?.id.uuidString ?? "",
            selectedCharacter?.name ?? ""
        ].joined(separator: "|")
    }

    private func configureLibraryFilter() {
        guard let selectedCharacter else { return }
        state.selectedSource = .characters
        state.selectedGroupLabel = selectedCharacter.name.isEmpty ? "Character" : selectedCharacter.name
        state.thumbnailSize = 92
        state.flagFilter = .all
    }
}

@available(macOS 26.0, *)
private struct SceneImageLibraryInspectorSection: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedScene == nil {
                ContentUnavailableView(
                    "No Scene Selected",
                    systemImage: "film.stack",
                    description: Text("Select a scene to browse its image library.")
                )
                .padding()
            } else {
                AllProjectImagesPageView(
                    store: store,
                    state: state,
                    layout: .canvasSidebar
                )
                .frame(minHeight: 520)
            }
        }
        .task(id: librarySignature) {
            configureFilter()
        }
    }

    private var librarySignature: String {
        [
            store.owpURL?.path ?? "",
            store.selectedScene?.id.uuidString ?? "",
            store.selectedScene?.name ?? ""
        ].joined(separator: "|")
    }

    private func configureFilter() {
        guard let scene = store.selectedScene else { return }
        state.selectedSource = .sceneShots
        state.selectedGroupLabel = scene.name.isEmpty ? "Scene" : scene.name
        state.thumbnailSize = 92
        state.flagFilter = .all
    }
}

@available(macOS 26.0, *)
private struct PlaceImageLibraryInspectorSection: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedPlace == nil {
                ContentUnavailableView(
                    "No Place Selected",
                    systemImage: "map",
                    description: Text("Select a place to browse its image library.")
                )
                .padding()
            } else {
                AllProjectImagesPageView(
                    store: store,
                    state: state,
                    layout: .canvasSidebar
                )
                .frame(minHeight: 520)
            }
        }
        .task(id: librarySignature) {
            configureFilter()
        }
    }

    private var librarySignature: String {
        [
            store.owpURL?.path ?? "",
            store.selectedPlace?.id.uuidString ?? "",
            store.selectedPlace?.name ?? ""
        ].joined(separator: "|")
    }

    private func configureFilter() {
        guard let place = store.selectedPlace else { return }
        state.selectedSource = .places
        state.selectedGroupLabel = place.name.isEmpty ? "Place" : place.name
        state.thumbnailSize = 92
        state.flagFilter = .all
    }
}

@available(macOS 26.0, *)
struct PlaceGeminiBatchInspectorSection: View {
    @Bindable var store: AnimateStore
    var showsHeading: Bool = true
    @State private var submittingWorkflow: PlaceWorkflowMode?
    @State private var inlineErrorMessage: String?

    private var groupedQueue: [PlaceWorkflowMode: [PlaceImageEditQueueItem]] {
        Dictionary(grouping: store.placesWorkflowLibrary.pendingEditQueue) { $0.workflow }
    }

    private var jobs: [PlaceImageEditBatchJob] {
        store.placesWorkflowLibrary.editBatchJobs.sorted { $0.submittedAt > $1.submittedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeading {
                Label("Gemini Edit Queue", systemImage: "sparkles")
                    .font(.headline)
            }

            HStack(spacing: 8) {
                ForEach(PlaceWorkflowMode.allCases, id: \.self) { mode in
                    let count = groupedQueue[mode, default: []].filter { $0.state == .queued || $0.state == .failed }.count
                    Button {
                        submitBatch(for: mode)
                    } label: {
                        if submittingWorkflow == mode {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 80)
                        } else {
                            Label(
                                count > 0 ? "Submit \(mode.shortLabel) (\(count))" : "Submit \(mode.shortLabel)",
                                systemImage: "tray.and.arrow.up"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0 || submittingWorkflow != nil)
                }

                Spacer()

                Button("Refresh") {
                    store.refreshPlaceEditBatchJobs()
                }
                .buttonStyle(.bordered)
            }

            if let inlineErrorMessage, !inlineErrorMessage.isEmpty {
                Text(inlineErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if store.placesWorkflowLibrary.pendingEditQueue.isEmpty {
                Text("No queued image edits yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Queued Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(store.placesWorkflowLibrary.pendingEditQueue.sorted { $0.queuedAt > $1.queuedAt }) { item in
                        queueRow(item)
                    }
                }
            }

            if !jobs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Batch Jobs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(jobs) { job in
                        jobRow(job)
                    }
                }
            }
        }
        .onAppear {
            store.refreshPlaceEditBatchJobs()
        }
    }

    @ViewBuilder
    private func queueRow(_ item: PlaceImageEditQueueItem) -> some View {
        let record = store.placesWorkflowLibrary.generatedImageRecords.first { $0.id == item.imageRecordID }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.map { URL(fileURLWithPath: $0.activePath).lastPathComponent } ?? "Missing Image")
                        .font(.caption.weight(.semibold))
                    Text("\(item.workflow.displayName) • \(item.state.rawValue.capitalized)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    store.removeGeneratedBackgroundEditQueueItem(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            Text(item.instructions)
                .font(.caption)
                .lineLimit(4)

            if let error = item.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func jobRow(_ job: PlaceImageEditBatchJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.caption.weight(.semibold))
                    Text(job.state)
                        .font(.caption2)
                        .foregroundStyle(job.isTerminal ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue))
                }
                Spacer()
                if job.isTerminal {
                    Button("Dismiss") {
                        store.dismissPlaceEditBatchJob(job.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("\(job.promptCount) images • submitted \(job.submittedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = job.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func submitBatch(for workflow: PlaceWorkflowMode) {
        inlineErrorMessage = nil
        submittingWorkflow = workflow
        Task { @MainActor in
            defer { submittingWorkflow = nil }
            do {
                _ = try await store.submitQueuedGeneratedBackgroundEditBatch(workflow: workflow)
            } catch {
                inlineErrorMessage = error.localizedDescription
            }
        }
    }
}
