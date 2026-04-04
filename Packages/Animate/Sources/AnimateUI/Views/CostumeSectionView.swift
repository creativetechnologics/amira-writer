import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CostumeSectionView: View {
    @Bindable var store: AnimateStore
    let characterID: UUID
    let costume: CharacterCostumeReferenceSet

    // Local text state — avoids cursor-jump from Binding(get:set:) on @Observable store
    @State private var localName: String = ""
    @State private var localNotes: String = ""
    @State private var localSheetPrompt: String = ""
    @State private var hasAppeared = false

    // Generation state
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var pendingPlan: PendingGenerationPlan?
    @State private var promptPreview: VariantPromptPreview?
    @State private var isGenerating = false
    @State private var generatingActions: Set<WorkflowAction> = []
    @State private var generationStatus: String?
    @State private var generationError: String?

    private enum WorkflowAction: Hashable {
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
        costumeContent
            .onAppear {
                guard !hasAppeared else { return }
                localName = costume.name
                localNotes = costume.notes
                localSheetPrompt = costume.sheetPrompt
                hasAppeared = true
            }
            .onChange(of: costume.id) { _, _ in
                localName = costume.name
                localNotes = costume.notes
                localSheetPrompt = costume.sheetPrompt
            }
            .onChange(of: localName) { _, newValue in
                guard hasAppeared else { return }
                store.updateCostumeReferenceSetName(newValue, costumeID: costume.id, for: characterID)
            }
            .onChange(of: localNotes) { _, newValue in
                guard hasAppeared else { return }
                store.updateCostumeReferenceSetNotes(newValue, costumeID: costume.id, for: characterID)
            }
            .onChange(of: localSheetPrompt) { _, newValue in
                guard hasAppeared else { return }
                store.updateCostumeSheetPrompt(newValue, costumeID: costume.id, for: characterID)
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
                set: { if !$0 { generationError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(generationError ?? "Unknown error")
            }
    }

    // MARK: - View Body

    @ViewBuilder
    private var costumeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            costumeHeader
            sheetPromptSection
            sheetVariantsSection
            fullBodySlotsGrid
            accessoriesSection
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var costumeHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Costume Name", text: $localName)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)

                TextEditor(text: $localNotes)
                    .font(.callout)
                    .frame(minHeight: 86)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    importCostumeSheet(costumeID: costume.id, costumeName: costume.name)
                } label: {
                    Label("Attach Sheet", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    prepareCostumeSheetPlan(costume)
                } label: {
                    Label("Generate Sheet", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .disabled(store.geminiAPIKey.isEmpty)

                Button {
                    prepareCostumeBatchPlan(costume)
                } label: {
                    Label("Generate Missing", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.geminiAPIKey.isEmpty)

                if costume.approvedSheetVariant != nil {
                    Button {
                        do {
                            try store.cropApprovedCostumeSheet(for: characterID, costumeID: costume.id)
                        } catch {
                            generationError = "Crop failed: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Re-crop from Sheet", systemImage: "crop")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    store.removeCostumeReferenceSet(costume.id, for: characterID)
                } label: {
                    Label("Delete Costume", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled((character?.costumeReferenceSets.count ?? 0) <= 1)
            }
        }
    }

    @ViewBuilder
    private var sheetPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(costume.name) Sheet Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $localSheetPrompt)
                .font(.callout)
                .frame(minHeight: 88)
                .padding(8)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.quaternary.opacity(0.4))
                }
        }
    }

    @ViewBuilder
    private var sheetVariantsSection: some View {
        if costume.sheetVariants.isEmpty {
            workflowEmptyState(icon: "square.grid.2x2", message: "No \(costume.name) sheets yet. Generate or attach one to auto-crop the six full-body poses below.")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(costume.sheetVariants.enumerated()), id: \.element.id) { index, variant in
                        ReferenceVariantCard(
                            store: store,
                            variant: variant,
                            title: "\(costume.name) Sheet \(index + 1)",
                            isApproved: costume.approvedSheetVariantID == variant.id,
                            onQuickLook: {
                                openQuickLook(for: costume.sheetVariants.map(\.imagePath), startingAt: index)
                            },
                            onCopy: {
                                copyImage(at: variant.imagePath)
                            },
                            onEdit: {
                                prepareCostumeSheetEditPlan(costume, variant: variant)
                            },
                            onShowPrompt: {
                                showPromptPreview(title: "\(costume.name) Sheet \(index + 1)", variant: variant)
                            },
                            onApprove: {
                                store.setApprovedCostumeSheetVariant(variant.id, costumeID: costume.id, for: characterID)
                            },
                            onDelete: {
                                store.removeCostumeSheetVariant(variant.id, costumeID: costume.id, for: characterID)
                            },
                            approveLabel: "Choose",
                            approvedLabel: "Chosen"
                        )
                    }
                    if generatingActions.contains(.costumeSheet(costume.id)) {
                        loadingReferenceVariantCard(title: "Generating \(costume.name) Sheet", subtitle: generationStatus ?? "Waiting…")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var fullBodySlotsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)], spacing: 12) {
            ForEach(costume.fullBodySlots) { slot in
                fullBodySlotCard(slot)
            }
        }
    }

    @ViewBuilder
    private func fullBodySlotCard(_ slot: CharacterPoseSlot) -> some View {
        poseSlotCard(
            title: slot.title,
            badge: slot.pose.gridLabel,
            notes: slot.notes,
            approvedVariant: slot.approvedVariant,
            variants: slot.variants,
            isGenerating: generatingActions.contains(.costumePose(costumeID: costume.id, slotID: slot.id)),
            onGenerate: { prepareCostumeSlotPlan(costumeID: costume.id, slot: slot) },
            onImport: { importCostumePoseVariant(costumeID: costume.id, slot: slot) },
            onEditApproved: {
                guard let approvedVariant = slot.approvedVariant else { return }
                prepareCostumeSlotEditPlan(costumeID: costume.id, slot: slot, variant: approvedVariant)
            },
            onShowPromptApproved: {
                guard let approvedVariant = slot.approvedVariant else { return }
                showPromptPreview(title: "\(costume.name) • \(slot.title)", variant: approvedVariant)
            },
            onQuickLookApproved: {
                openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: slot.approvedVariant?.id))
            },
            onEditVariant: { variantID in
                guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                prepareCostumeSlotEditPlan(costumeID: costume.id, slot: slot, variant: variant)
            },
            onShowPromptVariant: { variantID in
                guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                showPromptPreview(title: "\(costume.name) • \(slot.title) Variant", variant: variant)
            },
            onQuickLookVariant: { variantID in
                openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: variantID))
            },
            onApprove: { variantID in
                store.setApprovedCostumePoseVariant(variantID, costumeID: costume.id, slotID: slot.id, for: characterID)
            },
            onDelete: { variantID in
                store.removeCostumePoseVariant(variantID, costumeID: costume.id, slotID: slot.id, for: characterID)
            },
            onAdjustCrop: {
                guard let approvedVariant = slot.approvedVariant else { return }
                store.openVariantCropTool(
                    characterID: characterID,
                    slotKey: slot.key,
                    variantID: approvedVariant.id,
                    sourceSheetPath: approvedVariant.sourceSheetPath ?? costume.approvedSheetVariant?.imagePath,
                    initialCropRect: approvedVariant.sourceCropRect
                )
            },
            onAdjustCropVariant: { variantID in
                guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                store.openVariantCropTool(
                    characterID: characterID,
                    slotKey: slot.key,
                    variantID: variantID,
                    sourceSheetPath: variant.sourceSheetPath ?? costume.approvedSheetVariant?.imagePath,
                    initialCropRect: variant.sourceCropRect
                )
            }
        )
    }

    @ViewBuilder
    private var accessoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Accessories", systemImage: "briefcase")
                    .font(.subheadline)
                Spacer()
                Button {
                    prepareAccessoryBatchPlan(costume)
                } label: {
                    Label("Generate All Accessories", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .disabled(store.geminiAPIKey.isEmpty)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)], spacing: 14) {
                ForEach(costume.accessorySlots) { slot in
                    accessorySlotCard(slot)
                }
            }
        }
    }

    @ViewBuilder
    private func accessorySlotCard(_ slot: CharacterAccessorySlot) -> some View {
        poseSlotCard(
            title: slot.title,
            badge: "Accessory",
            notes: slot.notes,
            approvedVariant: slot.approvedVariant,
            variants: slot.variants,
            isGenerating: generatingActions.contains(.accessory(costumeID: costume.id, accessoryID: slot.id)),
            onGenerate: { prepareAccessoryPlan(costumeID: costume.id, slot: slot) },
            onImport: { importAccessoryVariant(costumeID: costume.id, slot: slot) },
            onEditApproved: {
                guard let approvedVariant = slot.approvedVariant else { return }
                prepareAccessoryEditPlan(costumeID: costume.id, slot: slot, variant: approvedVariant)
            },
            onShowPromptApproved: {
                guard let approvedVariant = slot.approvedVariant else { return }
                showPromptPreview(title: "\(slot.title)", variant: approvedVariant)
            },
            onQuickLookApproved: {
                openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: slot.approvedVariant?.id))
            },
            onEditVariant: { variantID in
                guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                prepareAccessoryEditPlan(costumeID: costume.id, slot: slot, variant: variant)
            },
            onShowPromptVariant: { variantID in
                guard let variant = slot.variants.first(where: { $0.id == variantID }) else { return }
                showPromptPreview(title: "\(slot.title) Variant", variant: variant)
            },
            onQuickLookVariant: { variantID in
                openQuickLook(for: slot.variants.map(\.imagePath), startingAt: approvedVariantIndex(in: slot.variants, selected: variantID))
            },
            onApprove: { variantID in
                store.setApprovedAccessoryVariant(variantID, costumeID: costume.id, accessoryID: slot.id, for: characterID)
            },
            onDelete: { variantID in
                store.removeAccessoryVariant(variantID, costumeID: costume.id, accessoryID: slot.id, for: characterID)
            }
        )
    }

    // MARK: - Pose Slot Card

    @ViewBuilder
    private func poseSlotCardHeader(title: String, badge: String, notes: String) -> some View {
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
    }

    @ViewBuilder
    private func poseSlotCardActionBar(
        variantCount: Int,
        hasApproved: Bool,
        onGenerate: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onEditApproved: @escaping () -> Void,
        onShowPromptApproved: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text("\(variantCount) variant\(variantCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if hasApproved {
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
    }

    private func poseSlotCard(
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
            poseSlotCardHeader(title: title, badge: badge, notes: notes)

            approvedVariantThumbnail(
                approvedVariant,
                isGenerating: isGenerating,
                statusText: generationStatus ?? "Generating…",
                onEdit: onEditApproved,
                onShowPrompt: onShowPromptApproved,
                onAdjustCrop: onAdjustCrop
            )
            .onTapGesture(count: 2, perform: onQuickLookApproved)

            poseSlotCardActionBar(
                variantCount: variants.count,
                hasApproved: approvedVariant != nil,
                onGenerate: onGenerate,
                onImport: onImport,
                onEditApproved: onEditApproved,
                onShowPromptApproved: onShowPromptApproved
            )

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

    // MARK: - UI Helpers

    private func workflowEmptyState(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
    }

    private func loadingReferenceVariantCard(title: String, subtitle: String) -> some View {
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

    private func approvedVariantIndex(in variants: [CharacterLookDevelopmentVariant], selected selectedID: UUID?) -> Int {
        guard !variants.isEmpty else { return 0 }
        if let selectedID, let index = variants.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return max(0, variants.count - 1)
    }

    private func approvedVariantThumbnail(
        _ variant: CharacterLookDevelopmentVariant?,
        isGenerating: Bool,
        statusText: String,
        onEdit: @escaping () -> Void,
        onShowPrompt: @escaping () -> Void,
        onAdjustCrop: @escaping () -> Void
    ) -> some View {
        Group {
            if let variant, let image = store.thumbnailImage(for: variant.imagePath, maxSize: 360) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contextMenu {
                        Button("View Prompt", systemImage: "eye.circle") { onShowPrompt() }
                        Button("Edit", systemImage: "slider.horizontal.3") { onEdit() }
                        Button("Show in Finder", systemImage: "folder") { showInFinder(at: variant.imagePath) }
                        Button("Copy Image", systemImage: "doc.on.doc") { copyImage(at: variant.imagePath) }
                        Divider()
                        Button("Adjust Crop", systemImage: "crop") { onAdjustCrop() }
                        Button("Quick Look", systemImage: "eye") { openQuickLook(for: [variant.imagePath], startingAt: 0) }
                    }
                    .overlay {
                        if isGenerating { generationOverlay(statusText: statusText) }
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

    // MARK: - Generation Methods

    private func prepareCostumeBatchPlan(_ costume: CharacterCostumeReferenceSet) {
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

    private func prepareCostumeSheetPlan(_ costume: CharacterCostumeReferenceSet) {
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

    private func prepareCostumeSlotPlan(costumeID: UUID, slot: CharacterPoseSlot) {
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

    private func prepareCostumeSlotEditPlan(
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

    private func prepareAccessoryBatchPlan(_ costume: CharacterCostumeReferenceSet) {
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

    private func prepareAccessoryPlan(costumeID: UUID, slot: CharacterAccessorySlot) {
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

    private func prepareAccessoryEditPlan(
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

    // MARK: - Run Generation

    private func run(plan: PendingGenerationPlan, drafts: [GeminiGenerationDraft]) {
        guard let character else { return }
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

                    store.logGeminiAPICall(endpoint: "image-generation", source: "CostumeSectionView.run()")
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)

                    switch pair.0 {
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

    // MARK: - Import Methods

    private func importCostumePoseVariant(costumeID: UUID, slot: CharacterPoseSlot) {
        guard let url = chooseWorkflowVariantImage(title: "Upload \(slot.title) Full-Body Variant") else { return }
        do {
            try store.importCostumePoseVariant(from: url, costumeID: costumeID, slotID: slot.id, for: characterID)
            generationStatus = "Uploaded \(slot.title)."
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func importCostumeSheet(costumeID: UUID, costumeName: String) {
        guard let url = chooseWorkflowVariantImage(title: "Attach \(costumeName) Sheet") else { return }
        do {
            try store.importCostumeSheetVariant(from: url, costumeID: costumeID, for: characterID)
            generationStatus = "Attached \(costumeName) sheet."
        } catch {
            generationError = error.localizedDescription
        }
    }

    private func importAccessoryVariant(costumeID: UUID, slot: CharacterAccessorySlot) {
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

    // MARK: - Reference Drafts

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

    private func buildReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references
            .filter(\.isIncluded)
            .compactMap { reference in
                let url = store.resolvedCharacterAssetURL(for: reference.path) ?? URL(fileURLWithPath: reference.path)
                return GeminiImageService.referenceImage(from: url)
            }
    }

    private func showPromptPreview(title: String, variant: CharacterLookDevelopmentVariant) {
        promptPreview = VariantPromptPreview(
            title: title,
            prompt: variant.prompt,
            model: variant.model,
            aspectRatio: variant.aspectRatio,
            imageSize: variant.imageSize
        )
    }

    // MARK: - Image Utilities

    private func openQuickLook(for paths: [String], startingAt index: Int) {
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

    private func copyImage(at path: String) {
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
