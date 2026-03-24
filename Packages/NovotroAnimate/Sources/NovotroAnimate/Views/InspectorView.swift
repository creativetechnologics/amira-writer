import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct InspectorView: View {
    @Bindable var store: AnimateStore
    var currentPage: AnimatePage
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch currentPage {
                case .script:
                    scriptInspector
                case .characters:
                    characterInspector
                case .animate:
                    animateInspector
                case .timeline:
                    timelineInspector
                }
            }
            .padding()
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

    // MARK: - Script Inspector

    @ViewBuilder
    private var scriptInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Script", systemImage: "text.viewfinder")
                .font(.headline)

            LabeledContent("BPM") {
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

                                if let sourcePath = sourcePathLabel(for: preview.variant) {
                                    Text(sourcePath)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                if let placementSummary = placementSummary(for: preview.variant) {
                                    Text(placementSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } else if hasLegacyPackageVariants(for: character, package: activePackage) {
                    Text("Legacy synced variants found. Sync the active package again to persist source path and placement metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                // Background picker
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

                        Text("Live Default Shot: \(store.evaluatedCameraDefaultShot()?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Live Focus: \(liveCameraFocusName())")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Live Intent: \(store.evaluatedCameraShotIntent()?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let suggestedShot = store.recommendedCameraShotFromIntent() {
                            Text("Intent Suggests: \(suggestedShot.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let suggestedMovement = store.recommendedCameraMovementFromIntent() {
                            Text("Intent Move Suggests: \(suggestedMovement.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Live Beat: \(store.evaluatedCameraBeatLabel() ?? "None")")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let liveBeatNotes = store.evaluatedCameraBeatNotes() {
                            Text(liveBeatNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Template settings remain scene-level defaults. Shot presets now place framing cues on the timeline instead of mutating the whole scene.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

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
                }
            }
        )
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
