import AppKit
import ProjectKit
import SwiftUI

@available(macOS 26.0, *)
struct VariantPromptPreview: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var prompt: String
    var model: String
    var aspectRatio: String
    var imageSize: String
}

@available(macOS 26.0, *)
private struct CharacterMasterImageItem: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var resolvedPath: String
    var label: String
    var systemImage: String
}

@available(macOS 26.0, *)
struct CharacterReferenceWorkflowSheet: View {
    @Bindable var store: AnimateStore
    let characterID: UUID
    let onDismiss: () -> Void
    var isInline: Bool = false

    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var pendingPlan: PendingGenerationPlan?
    @State private var promptPreview: VariantPromptPreview?
    @State private var isGenerating = false
    @State private var generatingActions: Set<WorkflowAction> = []
    @State private var generationStatus: String?
    @State private var generationError: String?

    // Local text state — prevents cursor-jump from Binding(get:set:) on @Observable store
    @State private var localMasterPrompt: String = ""
    @State private var localHeadPrompt: String = ""
    @State private var hasAppearedPrompts = false
    @State private var masterPromptSaveTask: Task<Void, Never>?
    @State private var headPromptSaveTask: Task<Void, Never>?
    @State private var masterPromptDropTargeted = false
    @State private var headSheetPromptReferencePaths: [String] = []
    @State private var headSheetDropTargeted = false
    @State private var masterSourceItems: [CharacterMasterImageItem] = []
    @State private var masterSourceItemsCharacterID: UUID?

    enum WorkflowAction: Hashable {
        case masterSheet
        case headSheet
        case headPose(UUID)
        case costumeSheet(UUID)
        case costumePose(costumeID: UUID, slotID: UUID)
        case accessory(costumeID: UUID, accessoryID: UUID)
    }

    private struct PendingGenerationPlan: Identifiable, Hashable {
        var id: UUID = UUID()
        var title: String
        var confirmTitle: String
        var actions: [WorkflowAction]
        var persistPromptEditsToWorkflowDefaults: Bool = true
    }

    private var character: AnimationCharacter? {
        store.characters.first(where: { $0.id == characterID })
    }

    var body: some View {
        if isInline {
            inlineBody
        } else {
            sheetBody
        }
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let character {
                        overviewSection(character)
                        masterReferenceSheetSection(character)
                        headTurnaroundSection(character)
                        costumesSection(character)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 900, idealWidth: 1400, minHeight: 700)
        .task(id: characterID) {
            store.seedCharacterReferenceWorkflowIfNeeded(for: characterID)
            if let char = store.characters.first(where: { $0.id == characterID }) {
                localMasterPrompt = char.masterReferenceSheetPrompt
                localHeadPrompt = char.headTurnaroundSheetPrompt
            }
            hasAppearedPrompts = true
        }
        .onDisappear {
            flushPromptSaveTasks()
        }
        .sheet(item: $pendingPlan) { plan in
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $preflightDrafts,
                title: plan.title,
                confirmTitle: plan.confirmTitle,
                onConfirm: { drafts, mode in
                    pendingPlan = nil
                    switch mode {
                    case .standard:
                        run(plan: plan, drafts: drafts)
                    case .batch:
                        if let character {
                            for draft in drafts {
                                store.addToGeminiQueue(
                                    characterID: character.id,
                                    characterName: character.name,
                                    draftTitle: draft.title,
                                    draft: draft
                                )
                            }
                        }
                    }
                },
                onCancel: {
                    pendingPlan = nil
                }
            )
        }
        .sheet(item: $promptPreview) { preview in
            VariantPromptPreviewSheet(preview: preview)
        }
        .alert("Character Reference Workflow", isPresented: Binding(
            get: { generationError != nil },
            set: { newValue in
                if !newValue {
                    generationError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(generationError ?? "Unknown error")
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            inlineHeader

            if let character {
                overviewSection(character)
                masterReferenceSheetSection(character)
                headTurnaroundSection(character)
            }
        }
        .task(id: characterID) {
            store.seedCharacterReferenceWorkflowIfNeeded(for: characterID)
            if let char = store.characters.first(where: { $0.id == characterID }) {
                localMasterPrompt = char.masterReferenceSheetPrompt
                localHeadPrompt = char.headTurnaroundSheetPrompt
            }
            hasAppearedPrompts = true
        }
        .onDisappear {
            flushPromptSaveTasks()
        }
        .sheet(item: $pendingPlan) { plan in
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $preflightDrafts,
                title: plan.title,
                confirmTitle: plan.confirmTitle,
                onConfirm: { drafts, mode in
                    pendingPlan = nil
                    switch mode {
                    case .standard:
                        run(plan: plan, drafts: drafts)
                    case .batch:
                        if let character {
                            for draft in drafts {
                                store.addToGeminiQueue(
                                    characterID: character.id,
                                    characterName: character.name,
                                    draftTitle: draft.title,
                                    draft: draft
                                )
                            }
                        }
                    }
                },
                onCancel: {
                    pendingPlan = nil
                }
            )
        }
        .sheet(item: $promptPreview) { preview in
            VariantPromptPreviewSheet(preview: preview)
        }
        .alert("Character Reference Workflow", isPresented: Binding(
            get: { generationError != nil },
            set: { newValue in
                if !newValue {
                    generationError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(generationError ?? "Unknown error")
        }
    }

    private var inlineHeader: some View {
        HStack(alignment: .center) {
            if let character {
                Text(character.name + " • inspiration → master sheet → head grid → full-body costumes → accessories")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(generationStatus ?? "Generating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let generationStatus,
                          !generationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(generationStatus, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Reset Workflow") {
                store.resetCharacterReferenceWorkflow(for: characterID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func scheduleMasterPromptSave(_ value: String) {
        masterPromptSaveTask?.cancel()
        let targetCharacterID = characterID
        masterPromptSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, targetCharacterID == characterID else { return }
            store.updateMasterReferenceSheetPrompt(value, for: targetCharacterID)
            masterPromptSaveTask = nil
        }
    }

    private func scheduleHeadPromptSave(_ value: String) {
        headPromptSaveTask?.cancel()
        let targetCharacterID = characterID
        headPromptSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, targetCharacterID == characterID else { return }
            store.updateHeadTurnaroundSheetPrompt(value, for: targetCharacterID)
            headPromptSaveTask = nil
        }
    }

    private func flushPromptSaveTasks() {
        masterPromptSaveTask?.cancel()
        headPromptSaveTask?.cancel()
        masterPromptSaveTask = nil
        headPromptSaveTask = nil
        if hasAppearedPrompts {
            store.updateMasterReferenceSheetPrompt(localMasterPrompt, for: characterID)
            store.updateHeadTurnaroundSheetPrompt(localHeadPrompt, for: characterID)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Character Reference Workflow")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let character {
                    Text(character.name + " • inspiration → master sheet → head grid → full-body costumes → accessories")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(generationStatus ?? "Generating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let generationStatus,
                          !generationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(generationStatus, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Reset Workflow") {
                store.resetCharacterReferenceWorkflow(for: characterID)
            }
            .buttonStyle(.bordered)

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func overviewSection(_ character: AnimationCharacter) -> some View {
        let approvedHeadCount = character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.count
        let approvedFullBodyCount = character.costumeReferenceSets.flatMap(\.fullBodySlots).filter { $0.approvedVariant != nil }.count
        let approvedAccessoryCount = character.costumeReferenceSets.flatMap(\.accessorySlots).filter { $0.approvedVariant != nil }.count

        return VStack(alignment: .leading, spacing: 12) {
            Text("Use the realistic inspiration images to generate several beautiful master sheets first. Approve the best master sheet, then use it as the ingredient for specific head poses, full-body costume poses, and accessories.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                workflowPill(title: "Inspiration Images", value: "\(character.inspirationImagePaths.count)", systemImage: "photo.stack")
                workflowPill(title: "Master Sheets", value: "\(character.masterReferenceSheetVariants.count)", systemImage: "rectangle.3.group")
                workflowPill(title: "Head Poses", value: "\(approvedHeadCount)/\(character.headTurnaroundSlots.count)", systemImage: "person.crop.square")
                workflowPill(title: "Costume Poses", value: "\(approvedFullBodyCount)", systemImage: "figure.stand")
                workflowPill(title: "Accessories", value: "\(approvedAccessoryCount)", systemImage: "briefcase")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func workflowPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.72), in: Capsule())
    }

    private func masterReferenceSheetSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Master Reference Sheet", systemImage: "rectangle.3.group")
                        .font(.headline)
                    Text("Generate several master sheets from the original inspiration images, approve the best one, then use that sheet as the main reference for every later NB2 request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    prepareMasterSheetPlan(count: 1)
                } label: {
                    Label("Generate 1", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canGenerateGeminiImagesImmediately)

                Button {
                    importExistingMasterSheet()
                } label: {
                    Label("Attach Existing Sheet", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    prepareMasterSheetPlan(count: 3)
                } label: {
                    Label("Generate 3", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canGenerateGeminiImagesImmediately)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Master Sheet Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $localMasterPrompt)
                    .onChange(of: localMasterPrompt) { _, newValue in
                        guard hasAppearedPrompts else { return }
                        scheduleMasterPromptSave(newValue)
                    }
                .font(.callout)
                .frame(minHeight: 120)
                .padding(8)
                .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.quaternary.opacity(0.4))
                }
            }

            masterPromptReferenceDropZone(character)

            if character.masterReferenceSheetVariants.isEmpty {
                if generatingActions.contains(.masterSheet) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            loadingReferenceVariantCard(title: "Generating Master Sheet", subtitle: generationStatus ?? "Waiting for Nano Banana 2…")
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    workflowEmptyState(icon: "rectangle.3.group", message: "No master sheets yet. Generate a few variants, pick the best face/costume look, then use it to drive the grids below.")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(character.masterReferenceSheetVariants.enumerated()), id: \.element.id) { index, variant in
                            ReferenceVariantCard(
                                store: store,
                                variant: variant,
                                title: "Master Sheet \(index + 1)",
                                isApproved: character.approvedMasterReferenceSheetVariantID == variant.id,
                                onQuickLook: {
                                    openQuickLook(
                                        for: character.masterReferenceSheetVariants.map(\.imagePath),
                                        startingAt: index
                                    )
                                },
                                onCopy: {
                                    copyImage(at: variant.imagePath)
                                },
                                onEdit: {
                                    prepareMasterSheetEditPlan(variant)
                                },
                                onShowPrompt: {
                                    showPromptPreview(title: "Master Sheet \(index + 1)", variant: variant)
                                },
                                onApprove: {
                                    store.setApprovedMasterReferenceSheetVariant(variant.id, for: characterID)
                                },
                                onDelete: {
                                    store.removeMasterReferenceSheetVariant(variant.id, for: characterID)
                                },
                                approveLabel: "Choose",
                                approvedLabel: "Chosen"
                            )
                        }
                        if generatingActions.contains(.masterSheet) {
                            loadingReferenceVariantCard(title: "Generating Master Sheet", subtitle: generationStatus ?? "Waiting for Nano Banana 2…")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func headTurnaroundSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Head Turnaround Grid", systemImage: "person.crop.square")
                        .font(.headline)
                    Text("Generate or attach one square 2x3 head turnaround sheet first. The system crops the six head poses from the chosen sheet automatically, and you can still regenerate any individual missing pose afterward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    importHeadTurnaroundSheet()
                } label: {
                    Label("Attach Sheet", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    prepareHeadSheetPlan()
                } label: {
                    Label("Generate Sheet", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canGenerateGeminiImagesImmediately)

                Button {
                    prepareHeadBatchPlan()
                } label: {
                    Label("Generate Missing", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSubmitGeminiBatchJobs)

                if character.approvedHeadTurnaroundSheetVariant != nil {
                    Button {
                        do {
                            try store.cropApprovedHeadTurnaroundSheet(for: characterID)
                        } catch {
                            generationError = "Crop failed: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Re-crop from Sheet", systemImage: "crop")
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Head Sheet Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $localHeadPrompt)
                    .onChange(of: localHeadPrompt) { _, newValue in
                        guard hasAppearedPrompts else { return }
                        scheduleHeadPromptSave(newValue)
                    }
                .font(.callout)
                .frame(minHeight: 88)
                .padding(8)
                .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.quaternary.opacity(0.4))
                }
            }

            headSheetReferenceDropZone(character)

            if character.headTurnaroundSheetVariants.isEmpty {
                workflowEmptyState(icon: "square.grid.2x2", message: "No head turnaround sheets yet. Generate or attach one, then choose the best sheet and the six cropped head poses will populate below.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(character.headTurnaroundSheetVariants.enumerated()), id: \.element.id) { index, variant in
                            ReferenceVariantCard(
                                store: store,
                                variant: variant,
                                title: "Head Sheet \(index + 1)",
                                isApproved: character.approvedHeadTurnaroundSheetVariantID == variant.id,
                                onQuickLook: {
                                    openQuickLook(for: character.headTurnaroundSheetVariants.map(\.imagePath), startingAt: index)
                                },
                                onCopy: {
                                    copyImage(at: variant.imagePath)
                                },
                                onEdit: {
                                    prepareHeadSheetEditPlan(variant)
                                },
                                onShowPrompt: {
                                    showPromptPreview(title: "Head Sheet \(index + 1)", variant: variant)
                                },
                                onApprove: {
                                    store.setApprovedHeadTurnaroundSheetVariant(variant.id, for: characterID)
                                },
                                onDelete: {
                                    store.removeHeadTurnaroundSheetVariant(variant.id, for: characterID)
                                },
                                approveLabel: "Choose",
                                approvedLabel: "Chosen"
                            )
                        }
                        if generatingActions.contains(.headSheet) {
                            loadingReferenceVariantCard(title: "Generating Head Sheet", subtitle: generationStatus ?? "Waiting for Nano Banana 2…")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], spacing: 14) {
                ForEach(character.headTurnaroundSlots) { slot in
                    poseSlotCard(
                        title: slot.title,
                        badge: slot.pose.gridLabel,
                        notes: slot.notes,
                        approvedVariant: slot.approvedVariant,
                        variants: slot.variants,
                        isGenerating: generatingActions.contains(.headPose(slot.id)),
                        onGenerate: { prepareHeadSlotPlan(slot) },
                        onImport: { importHeadTurnaroundVariant(slot) },
                        onEditApproved: {
                            guard let approvedVariant = slot.approvedVariant else { return }
                            prepareHeadSlotEditPlan(slot, variant: approvedVariant)
                        },
                        onShowPromptApproved: {
                            guard let approvedVariant = slot.approvedVariant else { return }
                            showPromptPreview(title: slot.title, variant: approvedVariant)
                        },
                        onQuickLookApproved: {
                            openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: slot.approvedVariant?.id))
                        },
                        onEditVariant: { variantID in
                            guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                            prepareHeadSlotEditPlan(slot, variant: variant)
                        },
                        onShowPromptVariant: { variantID in
                            guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                            showPromptPreview(title: "\(slot.title) Variant", variant: variant)
                        },
                        onQuickLookVariant: { variantID in
                            openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: variantID))
                        },
                        onApprove: { variantID in
                            store.setApprovedHeadTurnaroundVariant(variantID, slotID: slot.id, for: characterID)
                        },
                        onDelete: { variantID in
                            store.removeHeadTurnaroundVariant(variantID, slotID: slot.id, for: characterID)
                        },
                        onAdjustCrop: {
                            guard let approvedVariant = slot.approvedVariant else { return }
                            store.openVariantCropTool(
                                characterID: characterID,
                                slotKey: slot.key,
                                variantID: approvedVariant.id,
                                sourceSheetPath: approvedVariant.sourceSheetPath ?? character.approvedHeadTurnaroundSheetVariant?.imagePath,
                                initialCropRect: approvedVariant.sourceCropRect
                            )
                        },
                        onAdjustCropVariant: { variantID in
                            guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                            store.openVariantCropTool(
                                characterID: characterID,
                                slotKey: slot.key,
                                variantID: variantID,
                                sourceSheetPath: variant.sourceSheetPath ?? character.approvedHeadTurnaroundSheetVariant?.imagePath,
                                initialCropRect: variant.sourceCropRect
                            )
                        }
                    )
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func costumesSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Costume Pose Sets", systemImage: "figure.stand")
                    .font(.headline)
                Spacer()
                Button {
                    store.addCostumeReferenceSet(for: characterID)
                } label: {
                    Label("Add Costume", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            ForEach(character.costumeReferenceSets) { costume in
                CostumeSectionView(store: store, characterID: characterID, costume: costume)
            }
        }
    }


    func poseSlotCard(
        title: String,
        badge: String,
        notes: String,
        approvedVariant: CharacterLookDevelopmentVariant?,
        variants: [CharacterLookDevelopmentVariant],
        isGenerating: Bool,
        onGenerate: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onEditApproved: @escaping () -> Void,
        onShowPromptApproved: @escaping () -> Void,
        onQuickLookApproved: @escaping () -> Void,
        onEditVariant: @escaping (UUID) -> Void,
        onShowPromptVariant: @escaping (UUID) -> Void,
        onQuickLookVariant: @escaping (UUID) -> Void,
        onApprove: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onAdjustCrop: @escaping () -> Void = {},
        onAdjustCropVariant: @escaping (UUID) -> Void = { _ in }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if variants.isEmpty {
                emptyPoseTile(title: title, isGenerating: isGenerating)
            } else {
                CharacterPoseVariantCarouselTile(
                    store: store,
                    title: title,
                    variants: variants,
                    approvedVariantID: approvedVariant?.id,
                    isGenerating: isGenerating,
                    statusText: generationStatus ?? "Generating…",
                    onQuickLook: onQuickLookVariant,
                    onCopy: { variant in copyImage(at: variant.imagePath) },
                    onEdit: onEditVariant,
                    onShowPrompt: onShowPromptVariant,
                    onApprove: onApprove,
                    onDelete: onDelete,
                    onAdjustCrop: onAdjustCropVariant,
                    onShowInFinder: { path in showInFinder(at: path) }
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: 6) {
                Button(action: onImport) {
                    Label("Attach", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: onGenerate) {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if approvedVariant != nil {
                    Button(action: onEditApproved) {
                        Label("Edit", systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(action: onAdjustCrop) {
                        Label("Crop", systemImage: "crop")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .labelStyle(.iconOnly)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func emptyPoseTile(title: String, isGenerating: Bool) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.16))
                .frame(width: 132, height: 132)
                .overlay {
                    if isGenerating {
                        generationOverlay(statusText: generationStatus ?? "Generating…")
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 132)
        }
    }

    private func plainWorkflowVariantTile(
        variant: CharacterLookDevelopmentVariant,
        caption: String? = nil,
        isApproved: Bool,
        onQuickLook: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onShowPrompt: @escaping () -> Void,
        onApprove: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onAdjustCrop: (() -> Void)? = nil
    ) -> some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
        return VStack(spacing: 5) {
            UnifiedImageTile(
                path: variant.imagePath,
                resolvedPath: resolvedURL?.path,
                thumbnailSize: 132,
                isSelected: isApproved,
                actions: UnifiedImageActions(
                    onChooseAsMaster: onApprove,
                    isMaster: isApproved,
                    chooseAsMasterLabel: "Choose as Master",
                    chosenAsMasterLabel: "Chosen",
                    onShowPrompt: onShowPrompt,
                    onShowInFinder: { showInFinder(at: variant.imagePath) },
                    onCopy: onCopy,
                    onQuickLook: onQuickLook,
                    onEditWithGemini: onEdit,
                    onAdjustCrop: onAdjustCrop,
                    onRemoveFromCollection: onDelete,
                    removeFromCollectionLabel: "Delete Variant"
                ),
                onTap: { store.imaginePreviewImagePath = variant.imagePath },
                onDoubleTap: onQuickLook
            )
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 132)
            }
        }
    }

    @ViewBuilder
    private func approvedVariantThumbnail(
        _ variant: CharacterLookDevelopmentVariant?,
        isGenerating: Bool,
        statusText: String,
        onQuickLook: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onShowPrompt: @escaping () -> Void,
        onAdjustCrop: @escaping () -> Void
    ) -> some View {
        if let variant {
            let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
            UnifiedImageTile(
                path: variant.imagePath,
                resolvedPath: resolvedURL?.path,
                thumbnailSize: 150,
                sourceLabel: "Chosen",
                sourceSystemImage: "checkmark.circle.fill",
                isSelected: true,
                actions: UnifiedImageActions(
                    onShowPrompt: onShowPrompt,
                    onShowInFinder: { showInFinder(at: variant.imagePath) },
                    onCopy: { copyImage(at: variant.imagePath) },
                    onQuickLook: onQuickLook,
                    onEditWithGemini: onEdit,
                    onAdjustCrop: onAdjustCrop
                ),
                onTap: {
                    store.imaginePreviewImagePath = variant.imagePath
                },
                onDoubleTap: onQuickLook
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if isGenerating {
                    generationOverlay(statusText: statusText)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.22))
                .frame(height: 150)
                .overlay {
                    if isGenerating {
                        generationOverlay(statusText: statusText)
                    } else {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
        }
    }

    private func generationOverlay(statusText: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.32))
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(statusText)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
            }
        }
    }

    func workflowEmptyState(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
    }

    func loadingReferenceVariantCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.18))
                .frame(width: 196, height: 196)
                .overlay {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(subtitle)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pending")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 220)
        .padding(12)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    func approvedVariantIndex(in variants: [CharacterLookDevelopmentVariant], selected selectedID: UUID?) -> Int {
        guard !variants.isEmpty else { return 0 }
        if let selectedID, let index = variants.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return max(0, variants.count - 1)
    }

    private func prepareMasterSheetPlan(count: Int) {
        guard let character else { return }
        let references = referenceDrafts(from: store.masterReferenceSheetReferencePaths(for: character.id, limit: 8))
        preflightDrafts = (0..<count).map { index in
            GeminiGenerationDraft(
                title: count == 1 ? "Master Reference Sheet" : "Master Reference Sheet \(index + 1)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/master-sheet",
                prompt: character.masterReferenceSheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.defaultMasterSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.defaultMasterSheetImageSize,
                referenceItems: references
            )
        }
        pendingPlan = PendingGenerationPlan(
            title: "Preview Master Sheet Request\(count == 1 ? "" : "s")",
            confirmTitle: "Run \(count) Master Sheet Request\(count == 1 ? "" : "s")",
            actions: Array(repeating: .masterSheet, count: count)
        )
    }

    private func prepareMasterSheetEditPlan(_ variant: CharacterLookDevelopmentVariant) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit Master Reference Sheet",
                destinationDescription: "Saved as a new master-sheet variant for \(character.name)",
                prompt: editPromptScaffold(
                    subject: "the first attached master reference sheet",
                    preservationNotes: "the same character identity, facial features, anime style, panel layout, and overall sheet composition unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.masterReferenceSheetReferencePaths(for: character.id, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Master Sheet Edit",
            confirmTitle: "Run Master Sheet Edit",
            actions: [.masterSheet],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    private func prepareHeadSheetPlan() {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Head Turnaround Sheet",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-sheet",
                prompt: character.headTurnaroundSheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.sectionSheetImageSize,
                referenceItems: referenceDrafts(from: headSheetPromptReferencePaths)
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Head Turnaround Sheet",
            confirmTitle: "Run Head Sheet Request",
            actions: [.headSheet]
        )
    }

    private func prepareHeadBatchPlan() {
        guard let character else { return }
        let references = referenceDrafts(from: store.headReferencePaths(for: character.id, limit: 8))
        let slots = character.headTurnaroundSlots.filter { $0.approvedVariant == nil }
        guard !slots.isEmpty else {
            generationStatus = "All head slots already have approved variants."
            return
        }
        guard !references.isEmpty else {
            generationError = "No reference images found for this character. Approve a master reference sheet (or add inspiration images) before generating head poses — otherwise Gemini has nothing to anchor identity to."
            return
        }
        let targetSlots = slots
        preflightDrafts = targetSlots.map { slot in
            GeminiGenerationDraft(
                title: "Head • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-turnaround",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: references
            )
        }
        pendingPlan = PendingGenerationPlan(
            title: "Preview Head Turnaround Batch",
            confirmTitle: "Run \(targetSlots.count) Head Request\(targetSlots.count == 1 ? "" : "s")",
            actions: targetSlots.map { .headPose($0.id) }
        )
    }

    private func prepareHeadSlotPlan(_ slot: CharacterPoseSlot) {
        guard let character else { return }
        let references = referenceDrafts(from: store.headReferencePaths(for: character.id, limit: 8))
        guard !references.isEmpty else {
            generationError = "No reference images found for this character. Approve a master reference sheet (or add inspiration images) before generating head poses."
            return
        }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Head • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-turnaround",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: references
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Head Pose Request",
            confirmTitle: "Run Head Request",
            actions: [.headPose(slot.id)]
        )
    }

    private func prepareHeadSlotEditPlan(_ slot: CharacterPoseSlot, variant: CharacterLookDevelopmentVariant) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit Head • \(slot.title)",
                destinationDescription: "Saved as a new head-turnaround variant for \(slot.title)",
                prompt: editPromptScaffold(
                    subject: "the first attached head-turnaround image",
                    preservationNotes: "the same character identity, head angle, neutral expression, framing, and overall anime rendering unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.headReferencePaths(for: character.id, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Head Edit",
            confirmTitle: "Run Head Edit",
            actions: [.headPose(slot.id)],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    private func prepareHeadSheetEditPlan(_ variant: CharacterLookDevelopmentVariant) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit Head Turnaround Sheet",
                destinationDescription: "Saved as a new head-sheet variant for \(character.name)",
                prompt: editPromptScaffold(
                    subject: "the first attached head turnaround sheet",
                    preservationNotes: "the same character identity, 2x3 layout, head pose order, neutral expressions, and overall anime rendering unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.headSheetReferencePaths(for: character.id, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Head Sheet Edit",
            confirmTitle: "Run Head Sheet Edit",
            actions: [.headSheet],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    func prepareCostumeBatchPlan(_ costume: CharacterCostumeReferenceSet) {
        guard let character else { return }
        let references = referenceDrafts(from: store.fullBodyReferencePaths(for: character.id, costumeID: costume.id, limit: 8))
        let slots = costume.fullBodySlots.filter { $0.approvedVariant == nil }
        guard !slots.isEmpty else {
            generationStatus = "All costume slots already have approved variants."
            return
        }
        let targetSlots = slots
        preflightDrafts = targetSlots.map { slot in
            GeminiGenerationDraft(
                title: "\(costume.name) • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/fullbody",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: references
            )
        }
        pendingPlan = PendingGenerationPlan(
            title: "Preview Costume Pose Batch",
            confirmTitle: "Run \(targetSlots.count) Full-Body Request\(targetSlots.count == 1 ? "" : "s")",
            actions: targetSlots.map { .costumePose(costumeID: costume.id, slotID: $0.id) }
        )
    }

    func prepareCostumeSheetPlan(_ costume: CharacterCostumeReferenceSet) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "\(costume.name) Sheet",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/sheet",
                prompt: costume.sheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.sectionSheetImageSize,
                referenceItems: []
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview \(costume.name) Sheet",
            confirmTitle: "Run Costume Sheet Request",
            actions: [.costumeSheet(costume.id)]
        )
    }

    func prepareCostumeSlotPlan(costumeID: UUID, slot: CharacterPoseSlot) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Full Body • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/fullbody",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: referenceDrafts(from: store.fullBodyReferencePaths(for: character.id, costumeID: costumeID, limit: 8))
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Full-Body Pose Request",
            confirmTitle: "Run Full-Body Request",
            actions: [.costumePose(costumeID: costumeID, slotID: slot.id)]
        )
    }

    func prepareCostumeSlotEditPlan(
        costumeID: UUID,
        slot: CharacterPoseSlot,
        variant: CharacterLookDevelopmentVariant
    ) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit Full Body • \(slot.title)",
                destinationDescription: "Saved as a new full-body variant for \(slot.title)",
                prompt: editPromptScaffold(
                    subject: "the first attached full-body image",
                    preservationNotes: "the same character identity, body angle, costume silhouette, style, and framing unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.fullBodyReferencePaths(for: character.id, costumeID: costumeID, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Full-Body Edit",
            confirmTitle: "Run Full-Body Edit",
            actions: [.costumePose(costumeID: costumeID, slotID: slot.id)],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    private func prepareCostumeSheetEditPlan(_ costume: CharacterCostumeReferenceSet, variant: CharacterLookDevelopmentVariant) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit \(costume.name) Sheet",
                destinationDescription: "Saved as a new \(costume.name) sheet variant",
                prompt: editPromptScaffold(
                    subject: "the first attached full-body turnaround sheet",
                    preservationNotes: "the same character identity, costume, 2x3 layout, pose order, and overall style unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.fullBodySheetReferencePaths(for: character.id, costumeID: costume.id, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview \(costume.name) Sheet Edit",
            confirmTitle: "Run Costume Sheet Edit",
            actions: [.costumeSheet(costume.id)],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    func prepareAccessoryBatchPlan(_ costume: CharacterCostumeReferenceSet) {
        guard let character else { return }
        let references = referenceDrafts(from: store.accessoryReferencePaths(for: character.id, costumeID: costume.id, limit: 8))
        preflightDrafts = costume.accessorySlots.map { slot in
            GeminiGenerationDraft(
                title: "\(costume.name) • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/accessories",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: references
            )
        }
        pendingPlan = PendingGenerationPlan(
            title: "Preview Accessory Batch",
            confirmTitle: "Run \(costume.accessorySlots.count) Accessory Requests",
            actions: costume.accessorySlots.map { .accessory(costumeID: costume.id, accessoryID: $0.id) }
        )
    }

    func prepareAccessoryPlan(costumeID: UUID, slot: CharacterAccessorySlot) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Accessory • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/accessories",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: referenceDrafts(from: store.accessoryReferencePaths(for: character.id, costumeID: costumeID, limit: 8))
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Accessory Request",
            confirmTitle: "Run Accessory Request",
            actions: [.accessory(costumeID: costumeID, accessoryID: slot.id)]
        )
    }

    func prepareAccessoryEditPlan(
        costumeID: UUID,
        slot: CharacterAccessorySlot,
        variant: CharacterLookDevelopmentVariant
    ) {
        guard let character else { return }
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Edit Accessory • \(slot.title)",
                destinationDescription: "Saved as a new accessory variant for \(slot.title)",
                prompt: editPromptScaffold(
                    subject: "the first attached accessory image",
                    preservationNotes: "the same character identity, accessory design, style, and framing unless explicitly changed"
                ),
                model: GeminiModel(rawValue: variant.model) ?? store.selectedGeminiModel,
                aspectRatio: variant.aspectRatio,
                imageSize: variant.imageSize,
                referenceItems: editReferenceDrafts(
                    primaryLabel: "Image to Edit",
                    primaryPath: variant.imagePath,
                    additionalPaths: store.accessoryReferencePaths(for: character.id, costumeID: costumeID, limit: 8)
                )
            )
        ]
        pendingPlan = PendingGenerationPlan(
            title: "Preview Accessory Edit",
            confirmTitle: "Run Accessory Edit",
            actions: [.accessory(costumeID: costumeID, accessoryID: slot.id)],
            persistPromptEditsToWorkflowDefaults: false
        )
    }

    private func run(plan: PendingGenerationPlan, drafts: [GeminiGenerationDraft]) {
        guard let character else { return }
        store.saveCharacterPromptEdits()  // Save any pending prompt edits before generating
        isGenerating = true
        generationStatus = nil
        generationError = nil
        generatingActions = []

        Task { @MainActor in
            let service = GeminiImageService()
            do {
                for (index, pair) in zip(plan.actions, drafts).enumerated() {
                    let requestNumber = index + 1
                    let total = drafts.count
                    generationStatus = "Generating \(requestNumber) of \(total)…"
                    generatingActions = [pair.0]

                    if plan.persistPromptEditsToWorkflowDefaults {
                        switch pair.0 {
                        case .masterSheet:
                            store.updateMasterReferenceSheetPrompt(pair.1.prompt, for: character.id)
                        case .headSheet:
                            store.updateHeadTurnaroundSheetPrompt(pair.1.prompt, for: character.id)
                        case .headPose(let slotID):
                            store.updateHeadTurnaroundPrompt(pair.1.prompt, slotID: slotID, for: character.id)
                        case .costumeSheet(let costumeID):
                            store.updateCostumeSheetPrompt(pair.1.prompt, costumeID: costumeID, for: character.id)
                        case .costumePose(let costumeID, let slotID):
                            store.updateCostumePosePrompt(pair.1.prompt, costumeID: costumeID, slotID: slotID, for: character.id)
                        case .accessory(let costumeID, let accessoryID):
                            store.updateAccessoryPrompt(pair.1.prompt, costumeID: costumeID, accessoryID: accessoryID, for: character.id)
                        }
                    }

                    let activityID = store.registerGeminiActivity(
                        kind: .immediate,
                        title: pair.1.title,
                        source: "Characters • \(character.name) • Reference Workflow"
                    )

                    let submittedPrompt = pair.1.effectivePrompt
                    let request = GeminiImageService.GenerationRequest(
                        prompt: submittedPrompt,
                        referenceImages: buildReferenceImages(from: pair.1.referenceItems),
                        model: pair.1.model,
                        aspectRatio: pair.1.aspectRatio,
                        imageSize: pair.1.imageSize
                    )

                    store.logGeminiAPICall(endpoint: "image-generation", source: "CharacterReferenceWorkflowSheet.run()")
                    let itemTask = Task<GeminiImageService.GenerationResult, Error> {
                        try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    }
                    store.attachGeminiActivityCancel(activityID) { itemTask.cancel() }

                    let result: GeminiImageService.GenerationResult
                    do {
                        result = try await withTaskCancellationHandler {
                            try await itemTask.value
                        } onCancel: {
                            itemTask.cancel()
                        }
                    } catch is CancellationError {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: "Canceled")
                        throw CancellationError()
                    } catch {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                        throw error
                    }

                    switch pair.0 {
                    case .masterSheet:
                        try store.storeMasterReferenceSheetVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    case .headSheet:
                        try store.storeHeadTurnaroundSheetVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    case .headPose(let slotID):
                        try store.storeHeadTurnaroundVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            slotID: slotID,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    case .costumeSheet(let costumeID):
                        try store.storeCostumeSheetVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            costumeID: costumeID,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    case .costumePose(let costumeID, let slotID):
                        try store.storeCostumePoseVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            costumeID: costumeID,
                            slotID: slotID,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    case .accessory(let costumeID, let accessoryID):
                        try store.storeAccessoryVariant(
                            result.imageData,
                            prompt: pair.1.prompt,
                            model: pair.1.model,
                            costumeID: costumeID,
                            accessoryID: accessoryID,
                            for: character.id,
                            aspectRatio: pair.1.aspectRatio,
                            imageSize: pair.1.imageSize
                        )
                    }

                    store.updateGeminiActivity(activityID, status: .completed)
                }

                generationStatus = "Finished \(drafts.count) request\(drafts.count == 1 ? "" : "s")."
            } catch {
                generationError = error.localizedDescription
                generationStatus = nil
            }

            generatingActions = []
            isGenerating = false
        }
    }

    private static let batchTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    private func submitBatch(plan: PendingGenerationPlan, drafts: [GeminiGenerationDraft]) {
        guard let character,
              let animateURL = store.animateURL else { return }
        if let error = store.geminiBatchGenerationAvailabilityError {
            generationError = error
            return
        }

        isGenerating = true
        generationStatus = "Submitting batch…"
        generationError = nil

        Task { @MainActor in
            defer {
                isGenerating = false
            }

            do {
                let stamp = Self.batchTimestampFormatter.string(from: Date())
                let batchSlug = plan.title
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "  ", with: "-")

                let outputRoot = ProjectPaths(root: animateURL.deletingLastPathComponent())
                    .characterReferenceWorkflowBatches(slug: character.assetFolderSlug)
                    .appendingPathComponent("\(stamp)-\(batchSlug)")

                let promptRequests = try drafts.map { draft in
                    GeminiBatchSubmissionPlan.PromptRequest(
                        id: draft.title
                            .lowercased()
                            .replacingOccurrences(of: "°", with: "deg")
                            .replacingOccurrences(of: " ", with: "-")
                            .replacingOccurrences(of: "•", with: "")
                            .replacingOccurrences(of: "  ", with: "-"),
                        title: draft.title,
                        prompt: draft.prompt,
                        referencePaths: try resolvedBatchReferencePaths(from: draft.includedReferenceItems)
                    )
                }

                let submissionPlan = GeminiBatchSubmissionPlan(
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    displayName: "\(character.name.lowercased().replacingOccurrences(of: " ", with: "-"))-refworkflow-\(stamp.lowercased())",
                    model: drafts.first?.model ?? store.selectedGeminiModel,
                    aspectRatio: drafts.first?.aspectRatio ?? "1:1",
                    imageSize: drafts.first?.imageSize ?? "2K",
                    outputRoot: outputRoot,
                    prompts: promptRequests
                )

                let service = GeminiBatchService()
                let submission = try await service.submit(plan: submissionPlan, apiKey: store.geminiAPIKey)
                try service.launchWatchdog(metadataPath: submission.metadataPath, apiKey: store.geminiAPIKey)

                store.registerInspirationBatchJob(
                    CharacterInspirationBatchJob(
                        title: plan.title,
                        batchName: submission.batchName,
                        metadataPath: submission.metadataPath.path,
                        outputRootPath: submission.outputRoot.path,
                        state: submission.state,
                        promptCount: submission.promptCount,
                        submittedAt: submission.submittedAt
                    ),
                    for: character.id
                )
                store.refreshInspirationBatchJobs()
                generationStatus = "Submitted \(submission.promptCount)-image batch. Watchdog is active."
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func resolvedBatchReferencePaths(
        from references: [GeminiGenerationReferenceDraft]
    ) throws -> [String] {
        let included = references.filter(\.isIncluded)
        return try included.map { reference in
            if let resolvedURL = store.resolvedCharacterAssetURL(for: reference.path) {
                return resolvedURL.path
            }

            let candidate = URL(fileURLWithPath: reference.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }

            throw NSError(
                domain: "CharacterReferenceWorkflowSheet.BatchReferences",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Reference image could not be resolved for batch submission: \(reference.path)"
                ]
            )
        }
    }

    private func referenceDrafts(from paths: [String]) -> [GeminiGenerationReferenceDraft] {
        paths.map { path in
            GeminiGenerationReferenceDraft(
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                path: path,
                isIncluded: true
            )
        }
    }

    private func referenceDrafts(from paths: [String], onlyPrecheck precheckedPaths: Set<String>) -> [GeminiGenerationReferenceDraft] {
        paths.map { path in
            GeminiGenerationReferenceDraft(
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                path: path,
                isIncluded: precheckedPaths.contains(path)
            )
        }
    }

    private func editReferenceDrafts(
        primaryLabel: String,
        primaryPath: String,
        additionalPaths: [String]
    ) -> [GeminiGenerationReferenceDraft] {
        var ordered = [GeminiGenerationReferenceDraft(label: primaryLabel, path: primaryPath, isIncluded: true)]
        var seen = Set([primaryPath])
        for path in additionalPaths where seen.insert(path).inserted {
            ordered.append(
                GeminiGenerationReferenceDraft(
                    label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    path: path,
                    isIncluded: true
                )
            )
        }
        return ordered
    }

    private func editPromptScaffold(subject: String, preservationNotes: String) -> String {
        """
        Edit \(subject).

        Preserve \(preservationNotes).

        Requested edits:
        - Describe the exact changes you want here.

        Keep everything else unchanged.
        """
    }

    func showPromptPreview(title: String, variant: CharacterLookDevelopmentVariant) {
        promptPreview = VariantPromptPreview(
            title: title,
            prompt: variant.prompt,
            model: variant.model,
            aspectRatio: variant.aspectRatio,
            imageSize: variant.imageSize
        )
    }

    private func masterPromptReferenceDropZone(_ character: AnimationCharacter) -> some View {
        let selectedPaths = masterPromptReferencePaths(for: character)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Images Attached To This Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(selectedPaths.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                Spacer()
                if !selectedPaths.isEmpty {
                    Button {
                        store.setMasterReferenceSourceImagePaths([], for: characterID)
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if selectedPaths.isEmpty {
                masterPromptEmptyDropZone
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedPaths, id: \.self) { path in
                            masterPromptReferenceChip(path: path)
                        }
                        masterPromptAddChip
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    masterPromptDropTargeted ? Color.accentColor : Color.secondary.opacity(0.16),
                    style: StrokeStyle(lineWidth: masterPromptDropTargeted ? 2 : 1, dash: masterPromptDropTargeted ? [7, 4] : [])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            addMasterPromptReferenceURLs(urls, for: character)
        } isTargeted: { targeted in
            masterPromptDropTargeted = targeted
        }
    }

    private var masterPromptEmptyDropZone: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .frame(minHeight: 92)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(masterPromptDropTargeted ? Color.accentColor : Color.secondary)
                    Text("Drag images here from the character grid to add them to the prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("The preflight pane will use these attached images as the master-sheet references.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
    }

    private var masterPromptAddChip: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.42), style: StrokeStyle(lineWidth: 1.25, dash: [6, 4]))
            .frame(width: 84, height: 84)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Drop")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
    }

    private func masterPromptReferenceChip(path: String) -> some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: path)

        return UnifiedImageTile(
            path: path,
            resolvedPath: resolvedURL?.path,
            thumbnailSize: 84,
            sourceLabel: "Prompt",
            sourceSystemImage: "paperclip",
            isSelected: true,
            actions: UnifiedImageActions(
                onShowInFinder: { showInFinder(at: path) },
                onCopy: { copyImage(at: path) },
                onQuickLook: { openQuickLook(for: [path], startingAt: 0) },
                onRemoveFromCollection: {
                    store.setMasterReferenceSourceInclusion(false, path: path, for: characterID)
                },
                removeFromCollectionLabel: "Remove From Prompt"
            ),
            onTap: {
                store.imaginePreviewImagePath = path
            },
            onDoubleTap: {
                openQuickLook(for: [path], startingAt: 0)
            },
            topTrailingOverlay: AnyView(
                Button {
                    store.setMasterReferenceSourceInclusion(false, path: path, for: characterID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white, Color.black.opacity(0.62))
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .padding(5)
            )
        )
    }

    private func headSheetReferenceDropZone(_ character: AnimationCharacter) -> some View {
        promptReferenceDropZone(
            title: "Head Turnaround Sheet References",
            subtitle: "Drag images here to use as the only references for Generate Sheet.",
            paths: headSheetPromptReferencePaths,
            isTargeted: headSheetDropTargeted,
            onClear: { headSheetPromptReferencePaths = [] },
            onRemove: { path in headSheetPromptReferencePaths.removeAll { $0 == path } }
        )
        .dropDestination(for: URL.self) { urls, _ in
            let matches = matchedCharacterImagePaths(for: urls, character: character)
            let fallbackPaths = urls.compactMap { url -> String? in
                let path = url.standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return path
            }
            let incoming = matches.isEmpty ? fallbackPaths : matches
            guard !incoming.isEmpty else {
                store.statusMessage = "Drop images from the character Library tab or existing image files."
                return false
            }

            var merged = headSheetPromptReferencePaths.filter { resolvedReferenceURL(for: $0) != nil }
            var seen = Set(merged)
            for path in incoming where resolvedReferenceURL(for: path) != nil && seen.insert(path).inserted {
                merged.append(path)
            }
            headSheetPromptReferencePaths = merged
            store.statusMessage = "Attached \(incoming.count) head sheet reference image\(incoming.count == 1 ? "" : "s")."
            return true
        } isTargeted: { targeted in
            headSheetDropTargeted = targeted
        }
    }

    private func promptReferenceDropZone(
        title: String,
        subtitle: String,
        paths: [String],
        isTargeted: Bool,
        onClear: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(paths.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                Spacer()
                if !paths.isEmpty {
                    Button(action: onClear) {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if paths.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .frame(minHeight: 76)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 16)
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(paths, id: \.self) { path in
                            let resolvedURL = resolvedReferenceURL(for: path)
                            UnifiedImageTile(
                                path: path,
                                resolvedPath: resolvedURL?.path,
                                thumbnailSize: 84,
                                isSelected: true,
                                actions: UnifiedImageActions(
                                    onShowInFinder: { showInFinder(at: path) },
                                    onCopy: { copyImage(at: path) },
                                    onQuickLook: { openQuickLook(for: [path], startingAt: 0) },
                                    onRemoveFromCollection: { onRemove(path) },
                                    removeFromCollectionLabel: "Remove From Prompt"
                                ),
                                onTap: { store.imaginePreviewImagePath = path },
                                onDoubleTap: { openQuickLook(for: [path], startingAt: 0) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.16),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [7, 4] : [])
                )
        }
    }

    private func masterPromptReferencePaths(for character: AnimationCharacter) -> [String] {
        uniqueExistingCharacterPaths(character.masterReferenceSourceImagePaths, excludingRejectedFor: character)
    }

    private func buildMasterSourceItems(for character: AnimationCharacter) -> [CharacterMasterImageItem] {
        var items: [CharacterMasterImageItem] = []
        items.reserveCapacity(64)
        var seenPaths: Set<String> = []
        var seenResolvedPaths: Set<String> = []

        func append(_ path: String?, label: String, systemImage: String) {
            guard let path,
                  let resolvedPath = store.resolvedCharacterAssetURL(for: path)?.path else {
                return
            }
            let canonicalResolvedPath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
            guard seenPaths.insert(path).inserted,
                  seenResolvedPaths.insert(canonicalResolvedPath).inserted else {
                return
            }
            items.append(
                CharacterMasterImageItem(
                    path: path,
                    resolvedPath: canonicalResolvedPath,
                    label: label,
                    systemImage: systemImage
                )
            )
        }

        func appendMany(_ paths: [String], label: String, systemImage: String) {
            paths.forEach { append($0, label: label, systemImage: systemImage) }
        }

        append(character.profileImagePath, label: "Profile", systemImage: "person.crop.square")
        append(character.inspirationReferenceImagePath, label: "Inspiration", systemImage: "sparkles")
        appendMany(character.curatedInspirationImagePaths, label: "Curated", systemImage: "star.fill")
        appendMany(character.inspirationImagePaths, label: "Inspiration", systemImage: "sparkles")
        appendMany(character.referenceImagePaths, label: "Reference", systemImage: "photo")
        appendMany(character.animatedImagePaths, label: "Animated", systemImage: "figure.walk.motion")
        appendMany(character.masterReferenceSheetVariants.map(\.imagePath), label: "Master", systemImage: "rectangle.3.group")
        append(character.approvedMasterReferenceSheetVariant?.imagePath, label: "Master", systemImage: "rectangle.3.group")
        appendMany(character.headTurnaroundSheetVariants.map(\.imagePath), label: "Head", systemImage: "face.smiling")
        append(character.approvedHeadTurnaroundSheetVariant?.imagePath, label: "Head", systemImage: "face.smiling")
        appendMany(character.headTurnaroundSlots.flatMap { $0.variants.map(\.imagePath) }, label: "Pose", systemImage: "figure.stand")
        appendMany(character.lookDevelopmentSlots.flatMap { $0.variants.map(\.imagePath) }, label: "Look", systemImage: "paintpalette")

        for costume in character.costumeReferenceSets {
            appendMany(costume.costumeReferenceImagePaths, label: "Costume", systemImage: "tshirt")
            appendMany(costume.generatedVariationImagePaths, label: "Costume", systemImage: "tshirt")
            appendMany(costume.sheetVariants.map(\.imagePath), label: "Costume", systemImage: "tshirt")
            append(costume.approvedSheetVariant?.imagePath, label: "Costume", systemImage: "tshirt")
            appendMany(costume.fullBodySlots.flatMap { $0.variants.map(\.imagePath) }, label: "Costume", systemImage: "tshirt")
            appendMany(costume.accessorySlots.flatMap { $0.variants.map(\.imagePath) }, label: "Costume", systemImage: "tshirt")
        }

        return items
    }

    private func masterSourceIsRejected(
        _ path: String,
        character: AnimationCharacter,
        includeStoreFallback: Bool = false
    ) -> Bool {
        if character.inspirationRejectedPaths.contains(path) {
            return true
        }
        return includeStoreFallback ? store.imageLibraryIsRejected(for: path) : false
    }

    private func uniqueExistingCharacterPaths(
        _ paths: [String],
        excludingRejectedFor character: AnimationCharacter? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        ordered.reserveCapacity(paths.count)
        for path in paths {
            guard store.resolvedCharacterAssetURL(for: path) != nil,
                  seen.insert(path).inserted else {
                continue
            }
            if let character,
               masterSourceIsRejected(path, character: character, includeStoreFallback: true) {
                continue
            }
            ordered.append(path)
        }
        return ordered
    }

    private func addMasterPromptReferenceURLs(_ urls: [URL], for character: AnimationCharacter) -> Bool {
        let matches = matchedCharacterImagePaths(for: urls, character: character)
        guard !matches.isEmpty else {
            store.statusMessage = "Drop images from this character grid to attach them to the prompt."
            return false
        }

        addMasterPromptReferencePaths(matches, for: character)
        return true
    }

    private func addMasterPromptReferencePaths(_ paths: [String], for character: AnimationCharacter) {
        let allowedPaths = paths.filter { !masterSourceIsRejected($0, character: character, includeStoreFallback: true) }
        guard !allowedPaths.isEmpty else {
            store.statusMessage = "Rejected images can only be reviewed from All Images."
            return
        }

        var merged = masterPromptReferencePaths(for: character)
        var seen = Set(merged)
        for path in allowedPaths where seen.insert(path).inserted {
            merged.append(path)
        }
        store.setMasterReferenceSourceImagePaths(merged, for: characterID)
        store.statusMessage = "Attached \(allowedPaths.count) image\(allowedPaths.count == 1 ? "" : "s") to the master prompt."
    }

    private func matchedCharacterImagePaths(for urls: [URL], character: AnimationCharacter) -> [String] {
        var pathByResolvedPath: [String: String] = [:]
        let items = buildMasterSourceItems(for: character)
            .filter { !masterSourceIsRejected($0.path, character: character, includeStoreFallback: true) }
        for item in items {
            pathByResolvedPath[URL(fileURLWithPath: item.resolvedPath).standardizedFileURL.path] = item.path
        }

        var matches: [String] = []
        var seenMatches: Set<String> = []
        for url in urls {
            let resolvedPath = url.standardizedFileURL.path
            guard let path = pathByResolvedPath[resolvedPath],
                  seenMatches.insert(path).inserted else {
                continue
            }
            matches.append(path)
        }
        return matches
    }

    private func importExistingMasterSheet() {
        let panel = NSOpenPanel()
        panel.title = "Attach Existing Master Reference Sheet"
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.importMasterReferenceSheetVariant(from: url, for: characterID)
            generationStatus = "Attached existing master sheet."
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func importHeadTurnaroundVariant(_ slot: CharacterPoseSlot) {
        guard let url = chooseWorkflowVariantImage(title: "Upload \(slot.title) Head Variant") else { return }
        do {
            try store.importHeadTurnaroundVariant(from: url, slotID: slot.id, for: characterID)
            generationStatus = "Uploaded \(slot.title)."
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func importHeadTurnaroundSheet() {
        guard let url = chooseWorkflowVariantImage(title: "Attach Head Turnaround Sheet") else { return }
        do {
            try store.importHeadTurnaroundSheetVariant(from: url, for: characterID)
            generationStatus = "Attached head sheet."
        } catch {
            generationError = error.localizedDescription
        }
    }

    func importCostumePoseVariant(costumeID: UUID, slot: CharacterPoseSlot) {
        guard let url = chooseWorkflowVariantImage(title: "Upload \(slot.title) Full-Body Variant") else { return }
        do {
            try store.importCostumePoseVariant(from: url, costumeID: costumeID, slotID: slot.id, for: characterID)
            generationStatus = "Uploaded \(slot.title)."
        } catch {
            generationError = error.localizedDescription
        }
    }

    func importCostumeSheet(costumeID: UUID, costumeName: String) {
        guard let url = chooseWorkflowVariantImage(title: "Attach \(costumeName) Sheet") else { return }
        do {
            try store.importCostumeSheetVariant(from: url, costumeID: costumeID, for: characterID)
            generationStatus = "Attached \(costumeName) sheet."
        } catch {
            generationError = error.localizedDescription
        }
    }

    func importAccessoryVariant(costumeID: UUID, slot: CharacterAccessorySlot) {
        guard let url = chooseWorkflowVariantImage(title: "Upload \(slot.title) Accessory Variant") else { return }
        do {
            try store.importAccessoryVariant(from: url, costumeID: costumeID, accessoryID: slot.id, for: characterID)
            generationStatus = "Uploaded \(slot.title)."
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func chooseWorkflowVariantImage(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func buildReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references
            .filter(\.isIncluded)
            .compactMap { reference in
                guard let url = resolvedReferenceURL(for: reference.path) else { return nil }
                return GeminiImageService.referenceImage(from: url)
            }
    }

    private func resolvedReferenceURL(for path: String) -> URL? {
        if let url = store.resolvedCharacterAssetURL(for: path) {
            return url
        }
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func openQuickLook(
        for paths: [String],
        startingAt index: Int
    ) {
        let resolvedItems = paths.enumerated().compactMap { offset, path -> (Int, URL)? in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return (offset, url)
        }

        guard !resolvedItems.isEmpty else { return }

        let quickLookIndex = resolvedItems.firstIndex(where: { $0.0 == index }) ?? 0
        QuickLookPreviewController.shared.present(
            urls: resolvedItems.map(\.1),
            startAt: quickLookIndex
        )
    }

    func copyImage(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path),
              ImageClipboardService.copyImage(at: url) else {
            store.statusMessage = "Could not copy image"
            return
        }
        store.statusMessage = "Copied image"
    }

    private func showInFinder(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path) else {
            store.statusMessage = "Could not locate image"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@available(macOS 26.0, *)
struct ReferenceVariantCard: View {
    @Bindable var store: AnimateStore
    let variant: CharacterLookDevelopmentVariant
    let title: String
    let isApproved: Bool
    let onQuickLook: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onShowPrompt: () -> Void
    let onApprove: () -> Void
    let onDelete: () -> Void
    let approveLabel: String
    let approvedLabel: String

    var body: some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
        UnifiedImageTile(
            path: variant.imagePath,
            resolvedPath: resolvedURL?.path,
            thumbnailSize: 164,
            isSelected: isApproved,
            actions: UnifiedImageActions(
                onChooseAsMaster: onApprove,
                isMaster: isApproved,
                chooseAsMasterLabel: approveLabel == "Choose" ? "Choose as Master" : approveLabel,
                chosenAsMasterLabel: approvedLabel,
                onShowPrompt: onShowPrompt,
                onShowInFinder: {
                    if let url = store.resolvedCharacterAssetURL(for: variant.imagePath) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                },
                onCopy: onCopy,
                onQuickLook: onQuickLook,
                onEditWithGemini: onEdit,
                onRemoveFromCollection: onDelete,
                removeFromCollectionLabel: "Delete Variant"
            ),
            onTap: {
                store.imaginePreviewImagePath = variant.imagePath
            },
            onDoubleTap: onQuickLook
        )
    }
}



@available(macOS 26.0, *)
struct VariantPromptPreviewSheet: View {
    let preview: VariantPromptPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.headline)
                    Text("\(preview.imageSize) • \(preview.aspectRatio) • \(preview.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            ScrollView {
                Text(preview.prompt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
                    .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 420)
    }
}
