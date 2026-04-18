import AppKit
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
        .task {
            store.seedCharacterReferenceWorkflowIfNeeded(for: characterID)
            if let char = store.characters.first(where: { $0.id == characterID }) {
                localMasterPrompt = char.masterReferenceSheetPrompt
                localHeadPrompt = char.headTurnaroundSheetPrompt
            }
            hasAppearedPrompts = true
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
                costumesSection(character)
            }
        }
        .task {
            store.seedCharacterReferenceWorkflowIfNeeded(for: characterID)
            if let char = store.characters.first(where: { $0.id == characterID }) {
                localMasterPrompt = char.masterReferenceSheetPrompt
                localHeadPrompt = char.headTurnaroundSheetPrompt
            }
            hasAppearedPrompts = true
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
                .disabled(store.geminiAPIKey.isEmpty)

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
                .disabled(store.geminiAPIKey.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Master Sheet Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $localMasterPrompt)
                    .onChange(of: localMasterPrompt) { _, newValue in
                        guard hasAppearedPrompts else { return }
                        store.updateMasterReferenceSheetPrompt(newValue, for: characterID)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Master Sheet Source Images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.importInspirationImages(for: characterID)
                    } label: {
                        Label("Add Inspiration Images", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("These are the default images sent for master-sheet generation. The preflight pane can still add or remove more.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if character.inspirationImagePaths.isEmpty && character.inspirationReferenceImagePath == nil {
                    Text("No inspiration images available yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(masterSheetSourceCandidates(for: character), id: \.self) { path in
                                masterSheetSourceCard(character: character, path: path)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

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
                .disabled(store.geminiAPIKey.isEmpty)

                Button {
                    prepareHeadBatchPlan()
                } label: {
                    Label("Generate Missing", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.geminiAPIKey.isEmpty)

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
                        store.updateHeadTurnaroundSheetPrompt(newValue, for: characterID)
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)], spacing: 12) {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.background.opacity(0.8), in: Capsule())
            }

            approvedVariantThumbnail(
                approvedVariant,
                isGenerating: isGenerating,
                statusText: generationStatus ?? "Generating…",
                onEdit: onEditApproved,
                onShowPrompt: onShowPromptApproved,
                onAdjustCrop: onAdjustCrop
            )
            .onTapGesture(count: 2, perform: onQuickLookApproved)
            .onTapGesture(count: 1) {
                if let path = approvedVariant?.imagePath {
                    store.imaginePreviewImagePath = path
                }
            }

            HStack(spacing: 6) {
                Text("\(variants.count) variant\(variants.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if approvedVariant != nil {
                    Button(action: onShowPromptApproved) {
                        Image(systemName: "eye.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("View Prompt")
                    Button(action: onEditApproved) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Edit")
                }
                Button(action: onImport) {
                    Image(systemName: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Upload")
                Button(action: onGenerate) {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

            if variants.isEmpty {
                Text("No approved image yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(variants) { variant in
                            MiniVariantChip(
                                store: store,
                                variant: variant,
                                isApproved: approvedVariant?.id == variant.id,
                                onQuickLook: { onQuickLookVariant(variant.id) },
                                onCopy: { copyImage(at: variant.imagePath) },
                                onEdit: { onEditVariant(variant.id) },
                                onShowPrompt: { onShowPromptVariant(variant.id) },
                                onApprove: { onApprove(variant.id) },
                                onDelete: { onDelete(variant.id) },
                                onAdjustCrop: { onAdjustCropVariant(variant.id) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary.opacity(0.35))
        }
    }

    @ViewBuilder
    private func approvedVariantThumbnail(
        _ variant: CharacterLookDevelopmentVariant?,
        isGenerating: Bool,
        statusText: String,
        onEdit: @escaping () -> Void,
        onShowPrompt: @escaping () -> Void,
        onAdjustCrop: @escaping () -> Void
    ) -> some View {
        if let variant {
            AsyncStoreThumbnailImage.rounded(
                store: store,
                path: variant.imagePath,
                maxSize: 360,
                width: nil,
                height: 150,
                cornerRadius: 14
            )
            // Single-tap surfaces this chosen pose image in Inspector Details.
            // Double-tap opens Quick Look. SwiftUI disambiguates by count.
            .onTapGesture(count: 2) {
                openQuickLook(for: [variant.imagePath], startingAt: 0)
            }
            .onTapGesture(count: 1) {
                store.imaginePreviewImagePath = variant.imagePath
            }
            .contextMenu {
                Button("View Prompt", systemImage: "eye.circle") {
                    onShowPrompt()
                }
                Button("Edit", systemImage: "slider.horizontal.3") {
                    onEdit()
                }
                Button("Show in Finder", systemImage: "folder") {
                    showInFinder(at: variant.imagePath)
                }
                Button("Copy Image", systemImage: "doc.on.doc") {
                    copyImage(at: variant.imagePath)
                }
                Divider()
                Button("Adjust Crop", systemImage: "crop") {
                    onAdjustCrop()
                }
                Button("Quick Look", systemImage: "eye") {
                    openQuickLook(for: [variant.imagePath], startingAt: 0)
                }
            }
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
                referenceItems: referenceDrafts(from: store.headSheetReferencePaths(for: character.id, limit: 8))
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
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "Head • \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-turnaround",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: referenceDrafts(from: store.headReferencePaths(for: character.id, limit: 8))
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
        let allPaths = store.fullBodySheetReferencePaths(for: character.id, costumeID: costume.id, limit: 8)
        let masterPath = store.normalizedMasterSheetPath(for: character.id)
        let prechecked: Set<String> = masterPath.map { [$0] } ?? []
        preflightDrafts = [
            GeminiGenerationDraft(
                title: "\(costume.name) Sheet",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/sheet",
                prompt: costume.sheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.sectionSheetImageSize,
                referenceItems: referenceDrafts(from: allPaths, onlyPrecheck: prechecked)
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

                    let request = GeminiImageService.GenerationRequest(
                        prompt: pair.1.prompt,
                        referenceImages: buildReferenceImages(from: pair.1.referenceItems),
                        model: pair.1.model,
                        aspectRatio: pair.1.aspectRatio,
                        imageSize: pair.1.imageSize
                    )

                    store.logGeminiAPICall(endpoint: "image-generation", source: "CharacterReferenceWorkflowSheet.run()")
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)

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

                let outputRoot = animateURL
                    .appendingPathComponent("characters")
                    .appendingPathComponent(character.assetFolderSlug)
                    .appendingPathComponent("reference-workflow-batches")
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

    private func masterSheetSourceCandidates(for character: AnimationCharacter) -> [String] {
        store.preferredInspirationReferencePaths(for: character)
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
                let url = store.resolvedCharacterAssetURL(for: reference.path) ?? URL(fileURLWithPath: reference.path)
                return GeminiImageService.referenceImage(from: url)
            }
    }

    @ViewBuilder
    private func masterSheetSourceCard(character: AnimationCharacter, path: String) -> some View {
        let isIncluded = character.masterReferenceSourceImagePaths.contains(path) || character.curatedInspirationImagePaths.contains(path)

        VStack(alignment: .leading, spacing: 8) {
            AsyncStoreThumbnailImage.rounded(
                store: store,
                path: path,
                maxSize: 132,
                width: 132,
                height: 132,
                cornerRadius: 12,
                placeholderOpacity: 0.2
            )
            .onTapGesture(count: 2) {
                openQuickLook(for: [path], startingAt: 0)
            }
            .onTapGesture(count: 1) {
                // Surface this source image in the Inspector Details pane.
                store.imaginePreviewImagePath = path
            }
            .contextMenu {
                Button("Show in Finder", systemImage: "folder") {
                    showInFinder(at: path)
                }
                Button("Copy Image", systemImage: "doc.on.doc") {
                    copyImage(at: path)
                }
                Button("Quick Look", systemImage: "eye") {
                    openQuickLook(for: [path], startingAt: 0)
                }
            }

            Toggle(isOn: Binding(
                get: { isIncluded },
                set: { store.setMasterReferenceSourceInclusion($0, path: path, for: characterID) }
            )) {
                Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
            }
            .toggleStyle(.checkbox)
            .frame(width: 132, alignment: .leading)
        }
        .padding(10)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isIncluded ? Color.accentColor : Color.secondary, lineWidth: isIncluded ? 2 : 1)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
                .onTapGesture(count: 2, perform: onQuickLook)
                .onTapGesture(count: 1) {
                    // Surface this variant in the Inspector Details pane so
                    // single-click selection mirrors the rest of the app.
                    store.imaginePreviewImagePath = variant.imagePath
                }
                .contextMenu {
                    Button("View Prompt", systemImage: "eye.circle") {
                        onShowPrompt()
                    }
                    Button("Edit", systemImage: "slider.horizontal.3") {
                        onEdit()
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = store.resolvedCharacterAssetURL(for: variant.imagePath) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Copy Image", systemImage: "doc.on.doc") {
                        onCopy()
                    }
                    Button("Quick Look", systemImage: "eye") {
                        onQuickLook()
                    }
                }

            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    onShowPrompt()
                } label: {
                    Image(systemName: "eye.circle")
                }
                .buttonStyle(.borderless)
                .help("View Prompt")
            }

            Text("\(variant.imageSize) • \(variant.aspectRatio)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Button(isApproved ? approvedLabel : approveLabel) {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isApproved)

                Button("Edit") {
                    onEdit()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .frame(width: 220)
        .padding(12)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isApproved ? Color.green : Color.secondary, lineWidth: isApproved ? 2 : 1)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        AsyncStoreThumbnailImage.rounded(
            store: store,
            path: variant.imagePath,
            maxSize: 196,
            width: 196,
            height: 196,
            cornerRadius: 14
        )
    }
}

@available(macOS 26.0, *)
struct MiniVariantChip: View {
    @Bindable var store: AnimateStore
    let variant: CharacterLookDevelopmentVariant
    let isApproved: Bool
    let onQuickLook: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onShowPrompt: () -> Void
    let onApprove: () -> Void
    let onDelete: () -> Void
    let onAdjustCrop: () -> Void

    var body: some View {
        // Pass 4 (Gary): the thumbnail portion routes through
        // UnifiedImageTile so decode/cache/radius match every other grid.
        // The approve/edit/prompt/delete button row stays below — these
        // are chip-specific verbs not present on generic image tiles. The
        // green approval ring stays to communicate the distinct "chosen
        // final pose" state (semantically different from normal selection).
        let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
        VStack(spacing: 4) {
            UnifiedImageTile(
                path: variant.imagePath,
                resolvedPath: resolvedURL?.path,
                thumbnailSize: 72,
                actions: UnifiedImageActions(
                    onShowPrompt: onShowPrompt,
                    onShowInFinder: {
                        if let url = store.resolvedCharacterAssetURL(for: variant.imagePath) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    },
                    onCopy: onCopy,
                    onQuickLook: onQuickLook,
                    onEditWithGemini: onEdit
                ),
                onTap: {
                    // Surface this variant in the Inspector Details pane.
                    store.imaginePreviewImagePath = variant.imagePath
                },
                onDoubleTap: onQuickLook,
                bottomTrailingOverlay: isApproved
                    ? AnyView(
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .background(Circle().fill(.black.opacity(0.5)).padding(-2))
                            .padding(4)
                    )
                    : nil
            )
            .overlay {
                if isApproved {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.5), lineWidth: 2)
                }
            }

            HStack(spacing: 3) {
                Button(action: onApprove) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isApproved)
                .help(isApproved ? "Approved" : "Use")

                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Edit")

                Button(action: onShowPrompt) {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("View Prompt")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Delete")
            }
        }
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
