import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct CharactersPageView: View {
    @Bindable var store: AnimateStore
    @State private var promptPreview: ImagePromptPreview?
    @State private var previewImageIndex: Int?
    @State private var previewImagePaths: [String] = []
    @State private var inspirationSelectedPaths: Set<String> = []
    @State private var inspirationLastClicked: String?
    @State private var thumbnailBaseSize: CGFloat = 120
    @State private var showReferenceImages: Bool = false
    @State private var showExpressionBatchSheet: Bool = false
    @AppStorage("charactersPage.showCharacterNotesPane") private var showCharacterNotesPane: Bool = true
    @AppStorage("charactersPage.showLookDevelopmentPane") private var showLookDevelopmentPane: Bool = true
    @AppStorage("charactersPage.showReferenceWorkflowPane") private var showReferenceWorkflowPane: Bool = true
    // 3D Sidecars pane archived
    @AppStorage("charactersPage.showActionImagesPane") private var showActionImagesPane: Bool = false
    @AppStorage("charactersPage.showExpressionLibraryPane") private var showExpressionLibraryPane: Bool = false
    @State private var characterSearchText: String = ""
    @State private var filteredCharacters: [AnimationCharacter] = []
    var showSidebar: Bool = true

    // MARK: - Cached State Helpers

    private func updateFilteredCharacters() {
        if characterSearchText.isEmpty {
            filteredCharacters = store.characters
        } else {
            filteredCharacters = store.characters.filter {
                $0.name.localizedCaseInsensitiveContains(characterSearchText)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    characterList
                        .frame(width: min(geo.size.width * 0.3, 280))

                    Divider()
                }

                characterDetail
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if let index = previewImageIndex {
                ImagePreviewOverlay(
                    store: store,
                    paths: previewImagePaths,
                    currentIndex: Binding(
                        get: { index },
                        set: { newIndex in
                            previewImageIndex = newIndex
                            if previewImagePaths.indices.contains(newIndex) {
                                let path = previewImagePaths[newIndex]
                                inspirationSelectedPaths = [path]
                                inspirationLastClicked = path
                            }
                        }
                    ),
                    onDismiss: { previewImageIndex = nil }
                )
            }
        }
        .sheet(isPresented: $showReferenceImages) {
            if let character = store.selectedCharacter {
                ReferenceImagesSheet(
                    character: character,
                    store: store,
                    onDismiss: { showReferenceImages = false }
                )
            }
        }
        .onChange(of: store.selectedCharacterID) { _, _ in
            store.saveCharacterPromptEdits()  // Save edits before switching character
            inspirationSelectedPaths = []
            inspirationLastClicked = nil
            previewImageIndex = nil
        }
        .onChange(of: characterSearchText) { _, _ in
            updateFilteredCharacters()
        }
        .onChange(of: store.characters.count) { _, _ in
            updateFilteredCharacters()
        }
        .onAppear {
            updateFilteredCharacters()
        }
        .onChange(of: showReferenceWorkflowPane) { _, expanded in
            if expanded, let character = store.selectedCharacter {
                store.seedCharacterReferenceWorkflowIfNeeded(for: character.id)
            }
        }
        .sheet(item: $promptPreview) { preview in
            StoredImagePromptPreviewSheet(preview: preview)
        }
        .sheet(isPresented: $store.showImageCropper) {
            if let imagePath = store.pendingCropImagePath,
               let characterID = store.pendingCropCharacterID {
                ImageCropperView(
                    imagePath: imagePath,
                    onCrop: { cropRect in
                        store.cropAndSetProfileImage(cropRect: cropRect, for: characterID)
                    },
                    onCancel: {
                        store.cancelImageCrop()
                    }
                )
            }
        }
        .sheet(isPresented: $store.showVariantCropper) {
            if let characterID = store.pendingVariantCropCharacterID,
               let slotKey = store.pendingVariantCropSlotKey,
               let variantID = store.pendingVariantCropVariantID {
                let effectiveSourcePath: String? = {
                    if let sp = store.pendingVariantCropSourceSheetPath { return sp }
                    // Fallback: use variant's own imagePath
                    let chars = store.characters
                    if let char = chars.first(where: { $0.id == characterID }) {
                        if let slot = char.headTurnaroundSlots.first(where: { $0.key == slotKey }),
                           let variant = slot.variants.first(where: { $0.id == variantID }) {
                            return variant.imagePath
                        }
                        for costume in char.costumeReferenceSets {
                            if let slot = costume.fullBodySlots.first(where: { $0.key == slotKey }),
                               let variant = slot.variants.first(where: { $0.id == variantID }) {
                                return variant.imagePath
                            }
                        }
                    }
                    return nil
                }()
                if let imagePath = effectiveSourcePath {
                    CharacterVariantCropSheet(
                        store: store,
                        sourceImagePath: imagePath,
                        initialCropRect: store.pendingVariantCropInitialRect?.cgRect,
                        aspectRatioHint: nil,
                        onCrop: { cropRect in
                            try? store.applyCropToVariant(
                                cropRect: cropRect,
                                characterID: characterID,
                                slotKey: slotKey,
                                variantID: variantID,
                                sourceSheetPath: imagePath
                            )
                            store.cancelVariantCrop()
                        },
                        onCancel: {
                            store.cancelVariantCrop()
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $store.showImageEraser) {
            if let imagePath = store.pendingEraserImagePath {
                ImageEraserView(
                    store: store,
                    imagePath: imagePath,
                    onDone: {
                        store.closeEraseTool()
                    },
                    onCancel: {
                        store.closeEraseTool()
                    }
                )
            }
        }
        .sheet(isPresented: $showExpressionBatchSheet) {
            if let character = store.selectedCharacter {
                ExpressionBatchSheet(store: store, character: character)
            }
        }
    }

    // MARK: - Character List

    @ViewBuilder
    private var characterList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Characters")
                    .font(.headline)
                Spacer()
                Button {
                    store.addCharacter()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add Character")
            }
            .padding()

            Divider()

            HStack(spacing: 4) {
                TextField("Search characters…", text: $characterSearchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                if !characterSearchText.isEmpty {
                    Button {
                        characterSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if store.characters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No characters — open a project")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedCharacterID) {
                    ForEach(filteredCharacters) { character in
                        characterRow(character)
                            .tag(character.id)
                            .draggable(character.id.uuidString)
                            .moveDisabled(!characterSearchText.isEmpty)
                            .contextMenu {
                                Button("Edit Rig") {
                                    store.selectedCharacterID = character.id
                                    store.showRigEditor = true
                                }
                                if !store.geminiAPIKey.isEmpty {
                                    Button("Generate Assets...") {
                                        store.selectedCharacterID = character.id
                                        store.showGenerationSheet = true
                                    }
                                }
                                Button("Save Rig") {
                                    store.saveCharacterRig(character.id)
                                }
                            }
                    }
                    .onMove { from, to in
                        // Only allow reorder when search is inactive so indices
                        // into filteredCharacters match store.characters.
                        guard characterSearchText.isEmpty else { return }
                        store.moveCharacter(from: from, to: to)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(OperaChromeTheme.panelBackground)
                .dropDestination(for: String.self) { items, location in
                    guard let uuidString = items.first,
                          let characterID = UUID(uuidString: uuidString) else {
                        return false
                    }
                    store.moveCharacterToEnd(characterID: characterID)
                    return true
                }
            }
        }
    }

    @ViewBuilder
    private func characterRow(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(character.name)
                    if let colorHex = owpChar?.colorHex {
                        Circle()
                            .fill(ColorHex.color(from: colorHex) ?? .gray)
                            .frame(width: 8, height: 8)
                    }
                }
                if !character.parts.isEmpty {
                    Text("\(character.parts.count) parts")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            characterThumbnail(character, owpChar: owpChar)
        }
    }

    @ViewBuilder
    private func characterThumbnail(_ character: AnimationCharacter, owpChar: OPWCharacter?) -> some View {
        AsyncSidebarThumbnail(
            store: store,
            character: character,
            owpChar: owpChar
        )
    }

    // MARK: - Character Detail

    @ViewBuilder
    private var characterDetail: some View {
        if let character = store.selectedCharacter {
            VStack(spacing: 0) {
                CharacterQueueControlsBar(store: store)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        characterHeader(character)

                    collapsiblePane(
                        title: "Character Notes",
                        icon: "text.alignleft",
                        counterText: textInfoSummary(for: character),
                        isExpanded: $showCharacterNotesPane
                    ) {
                        textInfoSection(character)
                    }

                    collapsiblePane(
                        title: "Look Development",
                        icon: "paintpalette",
                        counterText: nil,
                        isExpanded: $showLookDevelopmentPane
                    ) {
                        lookDevelopmentSection(character)
                    }

                    collapsiblePane(
                        title: "Character Reference Workflow",
                        icon: "square.grid.3x3.topleft.filled",
                        counterText: character.approvedMasterReferenceSheetVariant == nil
                            ? "No approved master sheet"
                            : "Master sheet approved",
                        isExpanded: $showReferenceWorkflowPane
                    ) {
                        if showReferenceWorkflowPane {
                            CharacterReferenceWorkflowSheet(
                                store: store,
                                characterID: character.id,
                                onDismiss: { showReferenceWorkflowPane = false },
                                isInline: true
                            )
                        }
                    }

                    // Character Packages archived 2026-04-05 — Vidu pipeline replaces SceneKit

                    collapsiblePane(
                        title: "Action Images",
                        icon: "figure.walk.motion",
                        isExpanded: $showActionImagesPane
                    ) {
                        if showActionImagesPane {
                            ActionImagesPane(store: store, character: character)
                        }
                    }

                    collapsiblePane(
                        title: "Expression Library",
                        icon: "face.smiling",
                        counterText: "\(EmotionLibrary.presets.count) presets",
                        isExpanded: $showExpressionLibraryPane,
                        trailing: {
                            Button {
                                showExpressionBatchSheet = true
                            } label: {
                                Label("Batch Generate", systemImage: "tray.full")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.geminiAPIKey.isEmpty || !store.geminiMasterSwitch)
                        }
                    ) {
                        if showExpressionLibraryPane {
                            ExpressionLibraryView()
                        }
                    }

                    // Motion Generation archived 2026-04-05

                    // 3D Sidecars and 3D Asset Library archived — 3D pipeline removed

                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a character to view details")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Character Header

    @ViewBuilder
    private func characterHeader(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)

        HStack(spacing: 16) {
            profileImageView(character: character, owpChar: owpChar)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(character.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let colorHex = owpChar?.colorHex {
                        Circle()
                            .fill(ColorHex.color(from: colorHex) ?? .gray)
                            .frame(width: 12, height: 12)
                    }
                }

                if !character.description.isEmpty {
                    Text(character.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            inspirationReferenceView(character: character)
        }
    }

    @ViewBuilder
    private func inspirationReferenceView(character: AnimationCharacter) -> some View {
        Button {
            showReferenceImages = true
        } label: {
            HStack(spacing: 8) {
                Text("Reference Images")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                AsyncReferenceThumbView(
                    store: store,
                    character: character,
                    onShowInFinder: { path in showInFinder(at: path) },
                    onSetAsProfilePic: { path in store.prepareProfilePicCrop(from: path, for: character.id) }
                )
            }
        }
        .buttonStyle(.plain)
        .help("Click to manage reference images")
    }

    @ViewBuilder
    private func profileImageView(character: AnimationCharacter, owpChar: OPWCharacter?) -> some View {
        AsyncProfileImageView(
            store: store,
            character: character,
            onShowInFinder: { path in showInFinder(at: path) },
            onSetAsProfilePic: { path in store.prepareProfilePicCrop(from: path, for: character.id) }
        )
    }

    private var placeholderProfileImage: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .offset(x: 4, y: 4)
            }
    }

    // MARK: - Text Info Section

    @ViewBuilder
    private func textInfoSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Character Type", systemImage: "person.crop.rectangle")
                        .font(.headline)

                    Picker(
                        "Character Type",
                        selection: Binding(
                            get: { character.defaultWardrobeType },
                            set: { store.updateCharacterDefaultWardrobeType($0, for: character.id) }
                        )
                    ) {
                        ForEach(CharacterWardrobeType.allCases) { wardrobe in
                            Text(wardrobe.displayName).tag(wardrobe)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Gender", systemImage: "figure.stand")
                        .font(.headline)

                    Picker(
                        "Gender",
                        selection: Binding(
                            get: { character.genderType },
                            set: { store.updateCharacterGenderType($0, for: character.id) }
                        )
                    ) {
                        ForEach(CharacterGenderType.allCases) { gender in
                            Text(gender.displayName).tag(gender)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Age", systemImage: "number")
                        .font(.headline)

                    TextField(
                        "Age",
                        text: Binding(
                            get: { character.age.map(String.init) ?? "" },
                            set: { newValue in
                                let digits = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if digits.isEmpty {
                                    store.updateCharacterAge(nil, for: character.id)
                                } else {
                                    store.updateCharacterAge(Int(digits), for: character.id)
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                }
            }

            Text("Inspiration-image generation uses Character Type, Gender, and Age when writing prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            DebouncedTextEditorRow(
                title: "Backstory",
                icon: "book.fill",
                storeValue: character.backstory,
                placeholder: "Enter character backstory, history, and origin...",
                onChange: { store.updateCharacterBackstory($0, for: character.id) }
            )

            DebouncedTextEditorRow(
                title: "Personality",
                icon: "brain.fill",
                storeValue: character.personality,
                placeholder: "Describe personality traits, mannerisms, and behaviors...",
                onChange: { store.updateCharacterPersonality($0, for: character.id) }
            )

            DebouncedTextEditorRow(
                title: "Notes",
                icon: "note.text",
                storeValue: character.notes,
                placeholder: "General notes about the character...",
                onChange: { store.updateCharacterNotes($0, for: character.id) }
            )
        }
    }

    @available(macOS 26.0, *)
    private struct DebouncedTextEditorRow: View {
        let title: String
        let icon: String
        let storeValue: String
        let placeholder: String
        let onChange: (String) -> Void

        @State private var localText: String = ""
        @State private var hasAppeared = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $localText)
                        .font(.body)
                        .frame(minHeight: 100, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                        .onChange(of: localText) { _, newValue in
                            guard hasAppeared else { return }
                            onChange(newValue)
                        }

                    if localText.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear {
                localText = storeValue
                hasAppeared = true
            }
            .onChange(of: storeValue) { _, newValue in
                if !hasAppeared || localText != newValue {
                    localText = newValue
                }
            }
        }
    }

    private func inspirationBatchJobRow(_ job: CharacterInspirationBatchJob, characterID: UUID) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.isTerminal ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(job.isTerminal ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(job.state.replacingOccurrences(of: "JOB_STATE_", with: "")) • \(job.autoImportedImagePaths.count)/\(max(job.promptCount, job.downloadedImagePaths.count)) imported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lastErrorMessage = job.lastErrorMessage,
                   !lastErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(lastErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            if job.isTerminal {
                Button {
                    store.removeInspirationBatchJob(job.id, for: characterID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Look Development Section

    @ViewBuilder
    private func lookDevelopmentSection(_ character: AnimationCharacter) -> some View {
        let approvedHeadCount = character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.count
        let approvedMaster = character.approvedMasterReferenceSheetVariant
        let costumeCount = max(character.costumeReferenceSets.count, CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: character.name).count)
        let approvedFullBodyCount = character.costumeReferenceSets.flatMap(\.fullBodySlots).filter { $0.approvedVariant != nil }.count
        let approvedAccessoryCount = character.costumeReferenceSets.flatMap(\.accessorySlots).filter { $0.approvedVariant != nil }.count

        VStack(alignment: .leading, spacing: 12) {
            Text("Start with inspiration photos, generate several master sheets, approve the best one, then generate the six-pose head grid, each costume’s six-pose full-body grid, and accessories. Every NB2 request now previews prompt, reference images, size, and estimated cost before sending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                lookDevelopmentSummaryPill(title: "Master Sheets", value: character.masterReferenceSheetVariants.count, icon: "rectangle.3.group")
                lookDevelopmentSummaryPill(title: "Head Poses", value: approvedHeadCount, icon: "person.crop.square")
                lookDevelopmentSummaryPill(title: "Costumes", value: costumeCount, icon: "figure.stand")
                lookDevelopmentSummaryPill(title: "Full Body", value: approvedFullBodyCount, icon: "figure.walk")
                lookDevelopmentSummaryPill(title: "Accessories", value: approvedAccessoryCount, icon: "briefcase")
            }

            if approvedMaster == nil {
                emptyStateMessage(
                    icon: "square.grid.3x3.topleft.filled",
                    message: "No approved master sheet yet. Generate several sheet variants first, pick the best one, then use it to drive head, full-body, and accessory requests."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let approvedMaster {
                            approvedMasterPreview(variant: approvedMaster, title: "Approved Master", characterID: character.id)
                        }
                        ForEach(Array(character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.prefix(5))) { slot in
                            approvedPosePreview(title: slot.title, variant: slot.approvedVariant, characterID: character.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func lookDevelopmentSummaryPill(title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text("\(title) \(value)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.24), in: Capsule())
    }

    @ViewBuilder
    private func approvedMasterPreview(variant: CharacterLookDevelopmentVariant, title: String, characterID: UUID) -> some View {
        AsyncApprovedVariantView(
            store: store,
            variant: variant,
            title: title,
            width: 156, height: 92,
            onQuickLook: { openQuickLook(for: [variant.imagePath], startingAt: 0) },
            onShowInFinder: { showInFinder(at: variant.imagePath) },
            onCopy: { copyImage(at: variant.imagePath) },
            onSetAsProfilePic: { store.prepareProfilePicCrop(from: variant.imagePath, for: characterID) }
        )
    }

    @ViewBuilder
    private func approvedPosePreview(title: String, variant: CharacterLookDevelopmentVariant?, characterID: UUID) -> some View {
        if let variant {
            AsyncApprovedVariantView(
                store: store,
                variant: variant,
                title: title,
                width: 92, height: 92,
                onQuickLook: { openQuickLook(for: [variant.imagePath], startingAt: 0) },
                onShowInFinder: { showInFinder(at: variant.imagePath) },
                onCopy: { copyImage(at: variant.imagePath) },
                onSetAsProfilePic: { store.prepareProfilePicCrop(from: variant.imagePath, for: characterID) }
            )
        }
    }

    private func textInfoSummary(for character: AnimationCharacter) -> String {
        let filledFields = [
            character.backstory,
            character.personality,
            character.notes
        ]
        .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .filter { $0 }
        .count

        return "\(filledFields)/3 filled"
    }

    private func collapsiblePane<Content: View, Trailing: View>(
        title: String,
        icon: String,
        counterText: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if let counterText {
                    Text(counterText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                trailing()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05))
        )
    }

    private func collapsiblePane<Content: View>(
        title: String,
        icon: String,
        counterText: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        collapsiblePane(
            title: title,
            icon: icon,
            counterText: counterText,
            isExpanded: isExpanded,
            trailing: { EmptyView() },
            content: content
        )
    }

    // MARK: - Image Gallery Components

    @ViewBuilder
    private func emptyStateMessage(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func importImageURLs(
        _ urls: [URL],
        using handler: ([URL]) -> Void
    ) -> Bool {
        let allowedExtensions = Set(["png", "jpg", "jpeg", "tif", "tiff", "webp"])
        let validURLs = urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
        guard !validURLs.isEmpty else { return false }
        handler(validURLs)
        return true
    }

    private func showPromptPreview(for path: String) {
        guard let metadata = store.generationMetadata(for: path) else {
            store.statusMessage = "No prompt metadata saved for this image"
            return
        }

        promptPreview = ImagePromptPreview(
            title: URL(fileURLWithPath: path).lastPathComponent,
            prompt: metadata.prompt,
            model: metadata.model,
            aspectRatio: metadata.aspectRatio,
            imageSize: metadata.imageSize
        )
    }

    // MARK: - Profile Pic from Context Menu


    private func openQuickLook(
        for paths: [String],
        startingAt index: Int
    ) {
        let resolvedItems = paths.enumerated().compactMap { offset, path -> (Int, URL)? in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return (offset, url)
        }

        guard !resolvedItems.isEmpty else {
            previewImageIndex = index
            previewImagePaths = paths
            return
        }

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

    // MARK: - Archived: Inspiration Images (moved to ImagineCharactersPageView)
    // The following sections were moved to the Imagine page on 2026-04-05:
    // - Inspiration Images collapsible pane
    // - Animated Images collapsible pane
    // - Profile Image Picker sheet
    // - inspirationGenerationMenuItems, prepareInspirationGenerationPlan,
    //   runInspirationGeneration, submitInspirationBatch, and related helpers
}

// MARK: - Async Image Helper Views

/// Sidebar 28×28 character thumbnail — loads asynchronously to avoid sync NSImage in body.
@available(macOS 26.0, *)
private struct AsyncSidebarThumbnail: View {
    let store: AnimateStore
    let character: AnimationCharacter
    let owpChar: OPWCharacter?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else if let owpChar,
                      let imageDir = store.owpCharacterImageDirectory(for: owpChar),
                      let firstImage = owpChar.images.first {
                let imageURL = imageDir.appendingPathComponent(firstImage.filename)
                AsyncImage(url: imageURL) { img in
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                } placeholder: {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            } else {
                Image(systemName: "person.fill")
                    .frame(width: 28, height: 28)
            }
        }
        .contextMenu {
            Button("Set as Profile Pic") {
                if let path = character.profileImagePath,
                   let character = store.selectedCharacter {
                    store.prepareProfilePicCrop(from: path, for: character.id)
                }
            }
            Button("Show in Finder", systemImage: "folder") {
                if let path = character.profileImagePath,
                   let url = store.resolvedCharacterAssetURL(for: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .task(id: character.profileImagePath ?? "") {
            guard let path = character.profileImagePath,
                  let url = store.resolvedCharacterAssetURL(for: path) else {
                image = nil
                return
            }
            image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
    }

}

/// Header profile image (64×64) — loads asynchronously.
@available(macOS 26.0, *)
private struct AsyncProfileImageView: View {
    let store: AnimateStore
    let character: AnimationCharacter
    let onShowInFinder: (String) -> Void
    let onSetAsProfilePic: (String) -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                    .contextMenu {
                        if let profilePath = character.profileImagePath {
                            Button("Set as Profile Pic") {
                                onSetAsProfilePic(profilePath)
                            }
                            Button("Show in Finder", systemImage: "folder") {
                                onShowInFinder(profilePath)
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                    }
            }
        }
        .task(id: character.profileImagePath ?? "") {
            guard let path = character.profileImagePath else { image = nil; return }
            let loaded = await store.thumbnailImageAsync(for: path, maxSize: 128)
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// Reference thumbnail in the character header — loads asynchronously.
@available(macOS 26.0, *)
private struct AsyncReferenceThumbView: View {
    let store: AnimateStore
    let character: AnimationCharacter
    let onShowInFinder: (String) -> Void
    let onSetAsProfilePic: (String) -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "photo.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                    .contextMenu {
                        if let refPath = character.inspirationReferenceImagePath {
                            Button("Set as Profile Pic") {
                                onSetAsProfilePic(refPath)
                            }
                            Button("Show in Finder", systemImage: "folder") {
                                onShowInFinder(refPath)
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "photo.fill")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .offset(x: 4, y: 4)
                    }
            }
        }
        .task(id: character.inspirationReferenceImagePath ?? "") {
            guard let path = character.inspirationReferenceImagePath,
                  let url = store.resolvedCharacterAssetURL(for: path) else {
                image = nil; return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// Look development approved variant preview — loads asynchronously.
@available(macOS 26.0, *)
private struct AsyncApprovedVariantView: View {
    let store: AnimateStore
    let variant: CharacterLookDevelopmentVariant
    let title: String
    let width: CGFloat
    let height: CGFloat
    let onQuickLook: () -> Void
    let onShowInFinder: () -> Void
    let onCopy: () -> Void
    let onSetAsProfilePic: () -> Void

    @State private var image: NSImage?

    var body: some View {
        if image != nil || true {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.22))
                        .frame(width: width, height: height)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .transition(.opacity.animation(.easeIn(duration: 0.15)))
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: width, height: height)
                .onTapGesture(count: 2) { onQuickLook() }
                .contextMenu {
                    Button("Set as Profile Pic") { onSetAsProfilePic() }
                    Button("Show in Finder", systemImage: "folder") { onShowInFinder() }
                    Button("Copy Image", systemImage: "doc.on.doc") { onCopy() }
                }

                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: .leading)
                    .lineLimit(2)
            }
            .task(id: variant.imagePath) {
                guard let url = store.resolvedCharacterAssetURL(for: variant.imagePath) else { return }
                let loaded = await Task.detached(priority: .userInitiated) {
                    NSImage(contentsOf: url)
                }.value
                if !Task.isCancelled { image = loaded }
            }
        }
    }
}

/// Generic async thumbnail used by gallery sheets.
@available(macOS 26.0, *)
private struct AsyncSheetThumbnail: View {
    let store: AnimateStore
    let path: String
    let size: CGFloat
    let aspectMultiplier: CGFloat
    let minHeight: CGFloat

    @State private var image: NSImage?

    private var boxHeight: CGFloat { max(minHeight, size * aspectMultiplier) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.22))
                .frame(width: size, height: boxHeight)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: boxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: boxHeight)
        .task(id: "\(path)#\(Int(size))") {
            if let cached = store.thumbnailImage(for: path, maxSize: size) {
                image = cached
                return
            }
            let loaded = await store.thumbnailImageAsync(for: path, maxSize: size)
            if !Task.isCancelled { image = loaded }
        }
    }
}

// MARK: - Image Gallery Section

@available(macOS 26.0, *)
struct ImageGallerySection: View {
    let store: AnimateStore
    let title: String
    let icon: String
    let paths: [String]
    @Binding var thumbnailBaseSize: CGFloat
    let onImport: () -> Void
    let onRemove: (Int) -> Void
    let onRemoveMultiple: ((IndexSet) -> Void)?
    let onPreview: (Int, [String]) -> Void
    let onCopy: (String) -> Void
    let onShowInFinder: (String) -> Void
    let onSetAsProfilePic: ((String) -> Void)?
    let onShowPrompt: ((String) -> Void)?
    let onToggleCurated: ((String) -> Void)?
    var curatedPaths: Set<String>
    var showsHeader: Bool
    @Binding var selectedPaths: Set<String>
    @Binding var lastClickedPath: String?
    let onDropURLs: (([URL]) -> Bool)?
    let onFocusPathChange: ((String?) -> Void)?
    @FocusState private var galleryKeyboardFocused: Bool

    private let minThumbnailSize: CGFloat = 80
    private let maxThumbnailSize: CGFloat = 300

    init(
        store: AnimateStore,
        title: String,
        icon: String,
        paths: [String],
        thumbnailBaseSize: Binding<CGFloat>,
        onImport: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
        onRemoveMultiple: ((IndexSet) -> Void)? = nil,
        onPreview: @escaping (Int, [String]) -> Void,
        onCopy: @escaping (String) -> Void,
        onShowInFinder: @escaping (String) -> Void,
        onSetAsProfilePic: ((String) -> Void)? = nil,
        onShowPrompt: ((String) -> Void)? = nil,
        onToggleCurated: ((String) -> Void)? = nil,
        curatedPaths: Set<String> = [],
        showsHeader: Bool = true,
        selectedPaths: Binding<Set<String>>,
        lastClickedPath: Binding<String?>,
        onDropURLs: (([URL]) -> Bool)? = nil,
        onFocusPathChange: ((String?) -> Void)? = nil
    ) {
        self.store = store
        self.title = title
        self.icon = icon
        self.paths = paths
        self._thumbnailBaseSize = thumbnailBaseSize
        self.onImport = onImport
        self.onRemove = onRemove
        self.onRemoveMultiple = onRemoveMultiple
        self.onPreview = onPreview
        self.onCopy = onCopy
        self.onShowInFinder = onShowInFinder
        self.onSetAsProfilePic = onSetAsProfilePic
        self.onShowPrompt = onShowPrompt
        self.onToggleCurated = onToggleCurated
        self.curatedPaths = curatedPaths
        self.showsHeader = showsHeader
        self._selectedPaths = selectedPaths
        self._lastClickedPath = lastClickedPath
        self.onDropURLs = onDropURLs
        self.onFocusPathChange = onFocusPathChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                headerRow
            }

            if paths.isEmpty {
                emptyStateView
            } else {
                galleryGrid
                    .focusable()
                    .focused($galleryKeyboardFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) {
                        guard let focusPath = lastClickedPath,
                              let index = paths.firstIndex(of: focusPath) else {
                            if QuickLookPreviewController.shared.isVisible {
                                QuickLookPreviewController.shared.dismiss()
                                return .handled
                            }
                            return .ignored
                        }
                        let urls = paths.compactMap { store.resolvedCharacterAssetURL(for: $0) }
                        let qlIndex = min(index, max(urls.count - 1, 0))
                        QuickLookPreviewController.shared.toggle(urls: urls, startAt: qlIndex)
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        guard let focusPath = lastClickedPath,
                              let currentIndex = paths.firstIndex(of: focusPath),
                              currentIndex > 0 else {
                            return .ignored
                        }
                        let newIndex = currentIndex - 1
                        let newPath = paths[newIndex]
                        selectedPaths = [newPath]
                        lastClickedPath = newPath
                        onFocusPathChange?(newPath)
                        if QuickLookPreviewController.shared.isVisible {
                            QuickLookPreviewController.shared.navigateTo(index: newIndex)
                        }
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard let focusPath = lastClickedPath,
                              let currentIndex = paths.firstIndex(of: focusPath),
                              currentIndex < paths.count - 1 else {
                            return .ignored
                        }
                        let newIndex = currentIndex + 1
                        let newPath = paths[newIndex]
                        selectedPaths = [newPath]
                        lastClickedPath = newPath
                        onFocusPathChange?(newPath)
                        if QuickLookPreviewController.shared.isVisible {
                            QuickLookPreviewController.shared.navigateTo(index: newIndex)
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if QuickLookPreviewController.shared.isVisible {
                            QuickLookPreviewController.shared.dismiss()
                            return .handled
                        }
                        if !selectedPaths.isEmpty {
                            selectedPaths.removeAll()
                            lastClickedPath = nil
                            onFocusPathChange?(nil)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "p")) { _ in
                        guard let focusPath = lastClickedPath,
                              let onToggleCurated else {
                            return .ignored
                        }
                        onToggleCurated(focusPath)
                        return .handled
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let onDropURLs else { return false }
            return onDropURLs(urls)
        }
    }

    private var headerRow: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            if !selectedPaths.isEmpty {
                Button("Deselect All") {
                    selectedPaths.removeAll()
                    lastClickedPath = nil
                    onFocusPathChange?(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if selectedPaths.count > 1, let onRemoveMultiple {
                Button("Delete \(selectedPaths.count) Selected", systemImage: "trash", role: .destructive) {
                    let indices = IndexSet(selectedPaths.compactMap { path in paths.firstIndex(of: path) })
                    onRemoveMultiple(indices)
                    selectedPaths.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("\(paths.count) images")
                .font(.caption)
                .foregroundStyle(.tertiary)

            zoomControls

            Button(action: onImport) {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                thumbnailBaseSize = max(minThumbnailSize, thumbnailBaseSize - 20)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize <= minThumbnailSize)
            .help("Zoom Out")

            Slider(value: $thumbnailBaseSize, in: minThumbnailSize...maxThumbnailSize, step: 20)
                .frame(width: 80)

            Button {
                thumbnailBaseSize = min(maxThumbnailSize, thumbnailBaseSize + 20)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize >= maxThumbnailSize)
            .help("Zoom In")
        }
    }

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text("No images yet. Click Import or drag images in from Finder.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func handleClick(path: String, event: GalleryClickEvent) {
        galleryKeyboardFocused = true
        switch event.modifiers {
        case .command:
            if selectedPaths.contains(path) {
                selectedPaths.remove(path)
            } else {
                selectedPaths.insert(path)
            }
        case .shift:
            if let anchor = lastClickedPath, let anchorIndex = paths.firstIndex(of: anchor),
               let clickIndex = paths.firstIndex(of: path) {
                let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
                for i in range {
                    selectedPaths.insert(paths[i])
                }
            } else {
                selectedPaths = [path]
            }
        default:
            selectedPaths = [path]
        }
        lastClickedPath = path
        onFocusPathChange?(path)
        if QuickLookPreviewController.shared.isVisible,
           let clickIndex = paths.firstIndex(of: path) {
            QuickLookPreviewController.shared.navigateTo(index: clickIndex)
        }
    }

    private var galleryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)],
            spacing: 12
        ) {
            ForEach(paths, id: \.self) { path in
                let index = paths.firstIndex(of: path) ?? 0
                ImageGalleryThumbnail(
                    store: store,
                    path: path,
                    tileWidth: thumbnailBaseSize,
                    isSelected: selectedPaths.contains(path),
                    isCurated: curatedPaths.contains(path),
                    selectedCount: selectedPaths.count,
                    onClick: { event in handleClick(path: path, event: event) },
                    onRemove: {
                        if selectedPaths.count > 1, selectedPaths.contains(path), let onRemoveMultiple {
                            let indices = IndexSet(selectedPaths.compactMap { p in paths.firstIndex(of: p) })
                            onRemoveMultiple(indices)
                            selectedPaths.removeAll()
                        } else {
                            onRemove(index)
                            selectedPaths.remove(path)
                        }
                    },
                    onPreview: { onPreview(index, paths) },
                    onCopy: { onCopy(path) },
                    onShowInFinder: { onShowInFinder(path) },
                    onSetAsProfilePic: onSetAsProfilePic == nil ? nil : { onSetAsProfilePic?(path) },
                    onShowPrompt: onShowPrompt == nil ? nil : { onShowPrompt?(path) },
                    onToggleCurated: onToggleCurated == nil ? nil : { onToggleCurated?(path) }
                )
            }
        }
    }
}

struct GalleryClickEvent {
    enum Modifiers { case none, command, shift }
    let modifiers: Modifiers
}

private struct FileDragModifier: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

// MARK: - Image Gallery Thumbnail

@available(macOS 26.0, *)
struct ImageGalleryThumbnail: View {
    let store: AnimateStore
    let path: String
    let tileWidth: CGFloat
    let isSelected: Bool
    let isCurated: Bool
    let selectedCount: Int
    let onClick: (GalleryClickEvent) -> Void
    let onRemove: () -> Void
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onShowInFinder: () -> Void
    let onSetAsProfilePic: (() -> Void)?
    let onShowPrompt: (() -> Void)?
    let onToggleCurated: (() -> Void)?

    private var imageBoxHeight: CGFloat {
        max(88, tileWidth * 0.68)
    }

    var body: some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: path)
        let displayName = resolvedURL?.lastPathComponent ?? URL(fileURLWithPath: path).lastPathComponent
        let hasPromptMetadata = onShowPrompt != nil && store.generationMetadata(for: path) != nil

        VStack(spacing: 4) {
            thumbnailImage
                .contextMenu {
                    if let onToggleCurated {
                        Button(isCurated ? "Remove from Curated" : "Add to Curated References",
                               systemImage: isCurated ? "star.slash" : "star.fill") {
                            onToggleCurated()
                        }
                        Divider()
                    }
                    if hasPromptMetadata {
                        Button("View Prompt", systemImage: "eye.circle") {
                            onShowPrompt?()
                        }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        onShowInFinder()
                    }
                    if let onSetAsProfilePic {
                        Button("Set as Profile Pic") {
                            onSetAsProfilePic()
                        }
                    }
                    Button("Copy Image", systemImage: "doc.on.doc") {
                        onCopy()
                    }
                    Button("Quick Look", systemImage: "eye") {
                        onPreview()
                    }
                    Divider()
                    if selectedCount > 1, isSelected {
                        Button("Remove \(selectedCount) Selected", systemImage: "trash", role: .destructive) {
                            onRemove()
                        }
                    } else {
                        Button("Remove Image", systemImage: "trash", role: .destructive) {
                            onRemove()
                        }
                    }
                }

            HStack(alignment: .center, spacing: 4) {
                if isCurated {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }
                Text(displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.tertiary)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasPromptMetadata {
                    Button {
                        onShowPrompt?()
                    } label: {
                        Image(systemName: "eye.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View Prompt")
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isCurated ? Color.yellow.opacity(0.5) : (isSelected ? Color.accentColor : Color.white.opacity(0.06)),
                    lineWidth: isSelected || isCurated ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) {
            onClick(GalleryClickEvent(modifiers: .none))
            onPreview()
        }
        .onTapGesture(count: 1) {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                onClick(GalleryClickEvent(modifiers: .command))
            } else if flags.contains(.shift) {
                onClick(GalleryClickEvent(modifiers: .shift))
            } else {
                onClick(GalleryClickEvent(modifiers: .none))
            }
        }
        .modifier(FileDragModifier(url: store.resolvedCharacterAssetURL(for: path)))
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        AsyncThumbnailView(store: store, path: path, tileWidth: tileWidth, imageBoxHeight: imageBoxHeight, isSelected: isSelected)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if isCurated {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(6)
            }
        }
    }
}

// MARK: - Async Thumbnail

@available(macOS 26.0, *)
private struct AsyncThumbnailView: View {
    let store: AnimateStore
    let path: String
    let tileWidth: CGFloat
    let imageBoxHeight: CGFloat
    let isSelected: Bool

    @State private var loadedImage: NSImage?
    @State private var loadTaskID: UUID?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(.quaternary.opacity(0.22))
                )
                .frame(width: tileWidth, height: imageBoxHeight)

            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: tileWidth, height: imageBoxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: tileWidth, height: imageBoxHeight)
            }
        }
        .frame(width: tileWidth, height: imageBoxHeight)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(path)#\(Int(tileWidth))") {
            // Check synchronous cache first (instant for already-loaded thumbnails)
            if let cached = store.thumbnailImage(for: path, maxSize: tileWidth) {
                loadedImage = cached
                return
            }
            // Load async off the main thread
            let image = await store.thumbnailImageAsync(for: path, maxSize: tileWidth)
            if !Task.isCancelled {
                loadedImage = image
            }
        }
    }
}

// MARK: - Image Preview Overlay

@available(macOS 26.0, *)
struct ImagePreviewOverlay: View {
    let store: AnimateStore
    let paths: [String]
    @Binding var currentIndex: Int
    let onDismiss: () -> Void

    @State private var previewImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                headerBar

                Spacer()

                imageDisplay

                Spacer()

                navigationBar
            }
        }
        .keyboardShortcut(.escape, modifiers: [])
        .onAppear {
            loadCurrentImage()
        }
        .onChange(of: currentIndex) { _, _ in
            loadCurrentImage()
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            navigatePrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateNext()
            return .handled
        }
    }

    private var headerBar: some View {
        HStack {
            Text("\(currentIndex + 1) of \(paths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let path = paths[safe: currentIndex] {
                let displayName = store.resolvedCharacterAssetURL(for: path)?.lastPathComponent
                    ?? URL(fileURLWithPath: path).lastPathComponent
                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary, .primary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var imageDisplay: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(1.5)
        } else if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Failed to load image")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 24) {
            Button {
                navigatePrevious()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(currentIndex > 0 ? .white : .gray, .primary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex <= 0)

            Spacer()

            Button {
                navigateNext()
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(currentIndex < paths.count - 1 ? .white : .gray, .primary)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= paths.count - 1)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func navigatePrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func navigateNext() {
        guard currentIndex < paths.count - 1 else { return }
        currentIndex += 1
    }

    private func loadCurrentImage() {
        guard let path = paths[safe: currentIndex] else { return }
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let image = store.resolvedCharacterAssetURL(for: path).flatMap(NSImage.init(contentsOf:))
            DispatchQueue.main.async {
                self.previewImage = image
                self.isLoading = false
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ProfileImagePickerSection: Identifiable {
    let id = UUID()
    let title: String
    let paths: [String]
}

@available(macOS 26.0, *)
private struct ProfileImagePickerSheet: View {
    let character: AnimationCharacter
    let store: AnimateStore
    let onChooseImagePath: (String) -> Void
    let onChooseFromDisk: () -> Void
    let onDismiss: () -> Void

    @State private var thumbnailSize: CGFloat = 108

    private var sections: [ProfileImagePickerSection] {
        var sections: [ProfileImagePickerSection] = []
        var seen = Set<String>()

        func appendSection(_ title: String, paths rawPaths: [String]) {
            let paths = rawPaths.filter {
                guard store.resolvedCharacterAssetURL(for: $0) != nil else { return false }
                return seen.insert($0).inserted
            }
            guard !paths.isEmpty else { return }
            sections.append(ProfileImagePickerSection(title: title, paths: paths))
        }

        appendSection("Current Profile", paths: [character.profileImagePath].compactMap { $0 })
        appendSection("Inspiration Images", paths: character.inspirationImagePaths)
        appendSection("Reference Images", paths: [character.inspirationReferenceImagePath].compactMap { $0 } + character.referenceImagePaths)
        appendSection("Animated Images", paths: character.animatedImagePaths)
        appendSection("Master Sheet Variants", paths: character.masterReferenceSheetVariants.map(\.imagePath))
        appendSection("Head Turnaround Sheets", paths: character.headTurnaroundSheetVariants.map(\.imagePath))
        appendSection("Head Turnaround Poses", paths: character.headTurnaroundSlots.flatMap { $0.variants.map(\.imagePath) })
        appendSection("Look Development", paths: character.lookDevelopmentSlots.flatMap { $0.variants.map(\.imagePath) })

        for costume in character.costumeReferenceSets {
            appendSection("\(costume.name) • Sheet Variants", paths: costume.sheetVariants.map(\.imagePath))
            appendSection("\(costume.name) • Full-Body Poses", paths: costume.fullBodySlots.flatMap { $0.variants.map(\.imagePath) })
            appendSection("\(costume.name) • Accessories", paths: costume.accessorySlots.flatMap { $0.variants.map(\.imagePath) })
        }

        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Profile Image")
                        .font(.headline)
                    Text("Use any existing image for this character, or choose a file from disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Choose from Disk…") {
                    onChooseFromDisk()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if sections.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.square")
                                .font(.system(size: 42))
                                .foregroundStyle(.tertiary)
                            Text("No character images available yet.")
                                .font(.headline)
                            Text("Choose a file from disk to set the profile image.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Choose from Disk…") {
                                onChooseFromDisk()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    } else {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title)
                                    .font(.headline)

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize), spacing: 12)],
                                    spacing: 12
                                ) {
                                    ForEach(section.paths, id: \.self) { path in
                                        if let url = store.resolvedCharacterAssetURL(for: path) {
                                            Button {
                                                onChooseImagePath(path)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(.quaternary.opacity(0.22))
                                                            .frame(width: thumbnailSize, height: thumbnailSize)

                                                        if let image = store.thumbnailImage(for: path, maxSize: thumbnailSize) {
                                                            Image(nsImage: image)
                                                                .resizable()
                                                                .aspectRatio(contentMode: .fit)
                                                                .frame(width: thumbnailSize, height: thumbnailSize)
                                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                        } else {
                                                            Image(systemName: "photo")
                                                                .foregroundStyle(.tertiary)
                                                        }
                                                    }

                                                    Text(url.lastPathComponent)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                        .truncationMode(.middle)
                                                        .frame(width: thumbnailSize, alignment: .leading)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button("Set as Profile Pic") {
                                                    if let character = store.selectedCharacter {
                                                        store.prepareProfilePicCrop(from: path, for: character.id)
                                                    }
                                                }
                                                Button("Show in Finder", systemImage: "folder") {
                                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                                }
                                                Button("Quick Look", systemImage: "eye") {
                                                    QuickLookPreviewController.shared.present(urls: [url], startAt: 0)
                                                }
                                            }
                                            .onTapGesture(count: 2) {
                                                QuickLookPreviewController.shared.present(urls: [url], startAt: 0)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 820, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

}

// MARK: - Image Cropper View

@available(macOS 26.0, *)
struct ImageCropperView: View {
    let imagePath: String
    let onCrop: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var cropRect: CGRect = .zero
    @State private var hasInitializedCrop = false
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            imageCanvas
            controlBar
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack {
            Text("Crop Profile Image")
                .font(.headline)
            Spacer()
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var imageCanvas: some View {
        GeometryReader { geo in
            ZStack {
                if let image = NSImage(contentsOfFile: imagePath) {
                    imageCropView(image: image, geo: geo)
                        .onAppear {
                            initializeCropIfNeeded(for: image)
                        }
                } else {
                    Text("Failed to load image")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }

    @ViewBuilder
    private func imageCropView(image: NSImage, geo: GeometryProxy) -> some View {
        let imageAspectRatio = image.size.width / image.size.height
        let displaySize = calculateDisplaySize(aspectRatio: imageAspectRatio, containerSize: geo.size)
        let offset = CGPoint(
            x: (geo.size.width - displaySize.width) / 2,
            y: (geo.size.height - displaySize.height) / 2
        )
        let displayCropRect = CGRect(
            x: offset.x + displaySize.width * cropRect.minX,
            y: offset.y + displaySize.height * cropRect.minY,
            width: displaySize.width * cropRect.width,
            height: displaySize.height * cropRect.height
        )

        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: displaySize.width, height: displaySize.height)

            Rectangle()
                .strokeBorder(Color.blue, lineWidth: 2)
                .frame(width: displayCropRect.width, height: displayCropRect.height)
                .contentShape(Rectangle())
                .position(x: displayCropRect.midX, y: displayCropRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startOrigin = dragStartOrigin ?? cropRect.origin
                            if dragStartOrigin == nil {
                                dragStartOrigin = cropRect.origin
                            }
                            let newX = max(0, min(1 - cropRect.width, startOrigin.x + value.translation.width / displaySize.width))
                            let newY = max(0, min(1 - cropRect.height, startOrigin.y + value.translation.height / displaySize.height))
                            cropRect.origin = CGPoint(x: newX, y: newY)
                        }
                        .onEnded { _ in
                            dragStartOrigin = nil
                        }
                )
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    private func calculateDisplaySize(aspectRatio: CGFloat, containerSize: CGSize) -> CGSize {
        let maxWidth = containerSize.width * 0.9
        let maxHeight = containerSize.height * 0.9

        if aspectRatio > 1 {
            let width = min(maxWidth, maxHeight * aspectRatio)
            return CGSize(width: width, height: width / aspectRatio)
        } else {
            let height = min(maxHeight, maxWidth / aspectRatio)
            return CGSize(width: height * aspectRatio, height: height)
        }
    }

    private var controlBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Drag the square to position the crop area")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("1:1 Square") {
                    if let image = NSImage(contentsOfFile: imagePath) {
                        makeSquareCrop(for: image)
                    }
                }
                .buttonStyle(.bordered)

                Button("Crop & Save") {
                    onCrop(cropRect)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func initializeCropIfNeeded(for image: NSImage) {
        guard !hasInitializedCrop else { return }
        hasInitializedCrop = true
        let aspectRatio = image.size.width / image.size.height
        let squarePixelFraction: CGFloat = 0.7
        let width = squarePixelFraction * min(1, 1 / aspectRatio)
        let height = squarePixelFraction * min(1, aspectRatio)
        cropRect = CGRect(
            x: (1 - width) / 2,
            y: (1 - height) / 2,
            width: width,
            height: height
        )
    }

    private func makeSquareCrop(for image: NSImage) {
        let imageAspectRatio = image.size.width / image.size.height

        if imageAspectRatio > 1 {
            let w = 1.0 / imageAspectRatio
            cropRect = CGRect(x: (1.0 - w) / 2, y: 0, width: w, height: 1.0)
        } else {
            let h = imageAspectRatio
            cropRect = CGRect(x: 0, y: (1.0 - h) / 2, width: 1.0, height: h)
        }
    }
}

// MARK: - Inspiration Gallery Sheet

@available(macOS 26.0, *)
struct InspirationGallerySheet: View {
    let character: AnimationCharacter
    let store: AnimateStore
    let onDismiss: () -> Void

    @State private var thumbnailBaseSize: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if character.inspirationImagePaths.isEmpty {
                        emptyState
                    } else {
                        galleryGrid
                    }
                }
                .padding()
            }
        }
        .frame(width: 700, height: 600)
    }

    private var headerBar: some View {
        HStack {
            Label("Inspiration Images", systemImage: "photo.stack")
                .font(.headline)

            Text("for \(character.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No inspiration images yet")
                .font(.headline)
            Text("Import images to build your character's inspiration gallery.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Import Images") {
                store.importInspirationImages(for: character.id)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var galleryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)], spacing: 12) {
            ForEach(character.inspirationImagePaths, id: \.self) { path in
                let index = character.inspirationImagePaths.firstIndex(of: path) ?? 0
                galleryThumbnail(path: path, index: index)
            }
        }
    }

    @ViewBuilder
    private func galleryThumbnail(path: String, index: Int) -> some View {
        VStack(spacing: 4) {
            thumbnailImage(for: path)
                .contextMenu {
                    Button("Set as Profile Pic") {
                        if let character = store.selectedCharacter {
                            store.prepareProfilePicCrop(from: path, for: character.id)
                        }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = store.resolvedCharacterAssetURL(for: path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        store.removeInspirationImage(at: index, for: character.id)
                    }
                }
                .onTapGesture(count: 2) {
                    openQuickLook(for: character.inspirationImagePaths, startingAt: index)
                }

            Text(store.resolvedCharacterAssetURL(for: path)?.lastPathComponent ?? URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for path: String) -> some View {
        AsyncSheetThumbnail(store: store, path: path, size: thumbnailBaseSize, aspectMultiplier: 0.68, minHeight: 96)
    }

    private func openQuickLook(for paths: [String], startingAt index: Int) {
        let urls = paths.compactMap { path in
            store.resolvedCharacterAssetURL(for: path)
        }
        guard !urls.isEmpty else { return }
        QuickLookPreviewController.shared.present(urls: urls, startAt: min(index, urls.count - 1))
    }

}

// MARK: - Reference Images Sheet

struct ReferenceImagesSheet: View {
    let character: AnimationCharacter
    let store: AnimateStore
    let onDismiss: () -> Void

    @State private var thumbnailBaseSize: CGFloat = 120
    @State private var mainRefImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    mainReferenceImageSection
                    Divider()
                    referenceImageGallerySection
                }
                .padding()
            }
        }
        .frame(width: 600, height: 650)
        .task(id: character.inspirationReferenceImagePath ?? "") {
            guard let path = character.inspirationReferenceImagePath,
                  let url = store.resolvedCharacterAssetURL(for: path) else {
                mainRefImage = nil; return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            if !Task.isCancelled { mainRefImage = loaded }
        }
    }

    private var headerBar: some View {
        HStack {
            Label("Reference Images", systemImage: "photo.on.rectangle")
                .font(.headline)

            Text("for \(character.name)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var mainReferenceImageSection: some View {
        let refURL = store.resolvedCharacterAssetURL(for: character.inspirationReferenceImagePath)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Main Reference Image")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if let refURL, let image = mainRefImage {
                VStack(spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .onTapGesture(count: 2) {
                            openQuickLook(for: [character.inspirationReferenceImagePath].compactMap { $0 }, startingAt: 0)
                        }
                        .contextMenu {
                            if let refPath = character.inspirationReferenceImagePath {
                                Button("Set as Profile Pic") {
                                    if let character = store.selectedCharacter {
                                        store.prepareProfilePicCrop(from: refPath, for: character.id)
                                    }
                                }
                                Button("Show in Finder", systemImage: "folder") {
                                    if let url = store.resolvedCharacterAssetURL(for: refPath) {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }

                    HStack {
                        Text(refURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Replace") {
                            store.setInspirationReferenceImageFromPicker(for: character.id)
                        }
                        .buttonStyle(.bordered)

                        Button("Remove", role: .destructive) {
                            store.setInspirationReferenceImage(nil, for: character.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if refURL != nil {
                // URL exists but image still loading — show placeholder
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.3))
                    .frame(height: 200)
                    .overlay { ProgressView() }
            } else {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary.opacity(0.3))
                        .frame(height: 160)
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.tertiary)
                                Text("No main reference image set")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    Button("Choose Reference Image") {
                        store.setInspirationReferenceImageFromPicker(for: character.id)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("Shown in the character header. Use for the primary visual reference.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let firstURL = urls.first else { return false }
            store.setInspirationReferenceImage(from: firstURL, for: character.id)
            return true
        }
    }

    private var referenceImageGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reference Image Gallery")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(character.referenceImagePaths.count) images")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                zoomControls

                Button(action: {
                    store.importReferenceImages(for: character.id)
                }) {
                    Label("Import", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if character.referenceImagePaths.isEmpty {
                emptyGalleryState
            } else {
                galleryGrid
            }

            Text("Additional reference images for personal use and Gemini prompts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let valid = urls.filter { ["png", "jpg", "jpeg", "tif", "tiff", "webp"].contains($0.pathExtension.lowercased()) }
            guard !valid.isEmpty else { return false }
            store.importReferenceImages(from: valid, for: character.id)
            return true
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                thumbnailBaseSize = max(80, thumbnailBaseSize - 20)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize <= 80)

            Slider(value: $thumbnailBaseSize, in: 80...200, step: 20)
                .frame(width: 60)

            Button {
                thumbnailBaseSize = min(200, thumbnailBaseSize + 20)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize >= 200)
        }
    }

    private var emptyGalleryState: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .foregroundStyle(.tertiary)
            Text("No reference images yet. Click Import to add images.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var galleryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)],
            spacing: 12
        ) {
            ForEach(character.referenceImagePaths, id: \.self) { path in
                let index = character.referenceImagePaths.firstIndex(of: path) ?? 0
                referenceGalleryThumbnail(path: path, index: index)
            }
        }
    }

    @ViewBuilder
    private func referenceGalleryThumbnail(path: String, index: Int) -> some View {
        VStack(spacing: 4) {
            thumbnailImage(for: path)
                .contextMenu {
                    Button("Set as Profile Pic") {
                        if let character = store.selectedCharacter {
                            store.prepareProfilePicCrop(from: path, for: character.id)
                        }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        if let url = store.resolvedCharacterAssetURL(for: path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        store.removeReferenceImage(at: index, for: character.id)
                    }
                }
                .onTapGesture(count: 2) {
                    openQuickLook(for: character.referenceImagePaths, startingAt: index)
                }

            Text(store.resolvedCharacterAssetURL(for: path)?.lastPathComponent ?? URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for path: String) -> some View {
        AsyncSheetThumbnail(store: store, path: path, size: thumbnailBaseSize, aspectMultiplier: 0.68, minHeight: 88)
    }

    private func openQuickLook(for paths: [String], startingAt index: Int) {
        let urls = paths.compactMap { path in
            store.resolvedCharacterAssetURL(for: path)
        }
        guard !urls.isEmpty else { return }
        QuickLookPreviewController.shared.present(urls: urls, startAt: min(index, urls.count - 1))
    }

}

@available(macOS 26.0, *)
typealias CharacterInspirationWardrobe = CharacterWardrobeType

@available(macOS 26.0, *)
struct CharacterInspirationPromptSpec: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let category: String
    let poseInstruction: String
}

@available(macOS 26.0, *)
enum CharacterInspirationGenerationMode: String, Hashable, Sendable {
    case immediate
    case batch
}

@available(macOS 26.0, *)
enum CharacterInspirationPromptCatalog {
    static let defaultAspectRatio = "1:1"
    static let defaultImageSize = "2K"

    static let allSpecs: [CharacterInspirationPromptSpec] = [
        .init(id: "front_view_neutral", title: "Front Neutral", category: "front_view", poseInstruction: "front facing portrait of the reference character, neutral expression, looking directly at camera, relaxed face, natural upright head position"),
        .init(id: "front_view_soft_smile_head_tilt", title: "Front Soft Smile", category: "front_view", poseInstruction: "front facing portrait of the reference character, soft natural smile, head slightly tilted to the right, looking directly at camera, relaxed face"),
        .init(id: "front_view_serious_chin_lowered", title: "Front Serious", category: "front_view", poseInstruction: "front facing portrait of the reference character, serious neutral expression, chin slightly lowered, eyes looking directly at camera, relaxed face"),
        .init(id: "close_up_neutral", title: "Close-Up Neutral", category: "close_up", poseInstruction: "close up portrait of the reference character, neutral expression, looking directly at camera, upright head position, face fills frame"),
        .init(id: "close_up_laughing_head_tilt", title: "Close-Up Laughing", category: "close_up", poseInstruction: "close up portrait of the reference character, genuine laughing expression, head slightly tilted to the left, eyes looking at camera, face fills frame"),
        .init(id: "close_up_serious_head_turn", title: "Close-Up Serious", category: "close_up", poseInstruction: "close up portrait of the reference character, serious expression, head turned slightly a few degrees to the right while eyes still looking at camera, face fills frame"),
        .init(id: "full_body_front_straight_posture", title: "Full Body Front Straight", category: "full_body_front", poseInstruction: "full body portrait of the reference character, neutral expression, standing upright, facing camera directly, arms relaxed naturally"),
        .init(id: "full_body_front_weight_shift", title: "Full Body Front Weight Shift", category: "full_body_front", poseInstruction: "full body portrait of the reference character, neutral expression, standing facing camera, slight natural weight shift to one leg, relaxed posture"),
        .init(id: "full_body_front_head_tilt", title: "Full Body Front Head Tilt", category: "full_body_front", poseInstruction: "full body portrait of the reference character, neutral expression, standing facing camera, head slightly tilted, relaxed posture"),
        .init(id: "full_body_left_upright", title: "Full Body Left Upright", category: "full_body_left", poseInstruction: "full body portrait of the reference character, facing left side, neutral expression, upright posture, arms relaxed naturally"),
        .init(id: "full_body_left_weight_shift", title: "Full Body Left Weight Shift", category: "full_body_left", poseInstruction: "full body portrait of the reference character, facing left side, neutral expression, slight natural weight shift to one leg, relaxed posture, arms relaxed naturally"),
        .init(id: "full_body_right_upright", title: "Full Body Right Upright", category: "full_body_right", poseInstruction: "full body portrait of the reference character, facing right side, neutral expression, upright posture, arms relaxed naturally"),
        .init(id: "full_body_right_weight_shift", title: "Full Body Right Weight Shift", category: "full_body_right", poseInstruction: "full body portrait of the reference character, facing right side, neutral expression, slight natural weight shift to one leg, relaxed posture, arms relaxed naturally"),
        .init(id: "full_body_back_upright", title: "Full Body Back Upright", category: "full_body_back", poseInstruction: "full body portrait of the reference character, facing away from camera, back view, upright posture, arms relaxed naturally"),
        .init(id: "full_body_back_head_turn", title: "Full Body Back Head Turn", category: "full_body_back", poseInstruction: "full body portrait of the reference character, facing away from camera, back view, head slightly turned to the side, relaxed posture, arms relaxed naturally"),
        .init(id: "fortyfive_left_upright", title: "45° Left Upright", category: "fortyfive_left", poseInstruction: "45 degree angle portrait of the reference character facing left, neutral expression, upright head position, eyes looking forward"),
        .init(id: "fortyfive_left_head_tilt", title: "45° Left Head Tilt", category: "fortyfive_left", poseInstruction: "45 degree angle portrait of the reference character facing left, neutral expression, head slightly tilted downward, eyes looking forward"),
        .init(id: "fortyfive_left_chin_raise", title: "45° Left Chin Raise", category: "fortyfive_left", poseInstruction: "45 degree angle portrait of the reference character facing left, neutral expression, chin slightly raised, eyes looking forward"),
        .init(id: "fortyfive_right_upright", title: "45° Right Upright", category: "fortyfive_right", poseInstruction: "45 degree angle portrait of the reference character facing right, neutral expression, upright head position, eyes looking forward"),
        .init(id: "fortyfive_right_head_tilt", title: "45° Right Head Tilt", category: "fortyfive_right", poseInstruction: "45 degree angle portrait of the reference character facing right, neutral expression, head slightly tilted downward, eyes looking forward"),
        .init(id: "fortyfive_right_chin_raise", title: "45° Right Chin Raise", category: "fortyfive_right", poseInstruction: "45 degree angle portrait of the reference character facing right, neutral expression, chin slightly raised, eyes looking forward"),
        .init(id: "profile_left_upright", title: "Profile Left Upright", category: "profile_left", poseInstruction: "strict side profile portrait of the reference character facing left, neutral expression, upright head position, eyes looking forward"),
        .init(id: "profile_left_chin_raise", title: "Profile Left Chin Raise", category: "profile_left", poseInstruction: "strict side profile portrait of the reference character facing left, neutral expression, chin slightly raised, eyes looking forward"),
        .init(id: "profile_left_chin_lower", title: "Profile Left Chin Lower", category: "profile_left", poseInstruction: "strict side profile portrait of the reference character facing left, neutral expression, chin slightly lowered, eyes looking forward"),
        .init(id: "profile_right_upright", title: "Profile Right Upright", category: "profile_right", poseInstruction: "strict side profile portrait of the reference character facing right, neutral expression, upright head position, eyes looking forward"),
        .init(id: "profile_right_chin_raise", title: "Profile Right Chin Raise", category: "profile_right", poseInstruction: "strict side profile portrait of the reference character facing right, neutral expression, chin slightly raised, eyes looking forward"),
        .init(id: "profile_right_chin_lower", title: "Profile Right Chin Lower", category: "profile_right", poseInstruction: "strict side profile portrait of the reference character facing right, neutral expression, chin slightly lowered, eyes looking forward"),
    ]

    static func prompt(
        for spec: CharacterInspirationPromptSpec,
        character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe
    ) -> String {
        let subject = subjectDescriptor(for: character)
        let shortSubject = shortSubjectDescriptor(for: character)
        return """
        TASK: Generate a brand-new photorealistic cinematic documentary frame. This is a NEW image — do NOT reproduce, edit, or copy any reference image. The reference images are provided ONLY for facial identity lock.

        IDENTITY LOCK (from reference images): Retain the facial identity of \(subject) — same face shape, eyes, nose, mouth, hairline, skin tone, and apparent age as shown in the reference images. Do NOT use the references for composition, background, framing, lighting, crop, pose, clothing details, or any other visual element. The references are identity-only.

        NEW COMPOSITION (this is required — ignore any composition cues from references): \(spec.poseInstruction). The pose, camera angle, framing, background, lighting, and crop must all come from this instruction, NOT from any reference image.

        WARDROBE: \(wardrobePrompt(for: character, wardrobe: wardrobe))

        SETTING: Place \(shortSubject) on \(CharacterPromptWorldContext.cityClinicEnvironment). The scene must feel native to \(CharacterPromptWorldContext.settingSummary). Keep the frame inside the city-and-clinic setting — no bridge, no European stone village look. \(shortSubject.capitalized) should feel grounded, emotionally believable, and visually consistent with the world.

        RENDERING: natural filmic color, authentic fabric texture, realistic skin pores, sharp face detail, shallow depth of field, documentary cinematography.

        NEGATIVE: no readable nametag, no gibberish text, no fake patches, no shiny vest, no oversized body armor, no stone bridge, no European stone village look, no text, no watermark, no copying of the reference image composition or background.
        """
    }

    private static func wardrobePrompt(
        for character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe
    ) -> String {
        let subject = shortSubjectDescriptor(for: character)
        switch wardrobe {
        case .soldier:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.militaryClothing), with weathered utility layers, sleeves rolled, subtle local scarf or village-fabric detail, grounded and believable, and no tactical-hero styling."
        case .civilian:
            return "\(subject.capitalized) is wearing \(CharacterPromptWorldContext.civilianClothing), with practical everyday layers, believable local fabrics, and a modest lived-in silhouette."
        }
    }

    private static func subjectDescriptor(for character: AnimationCharacter) -> String {
        if let age = character.age, age > 0 {
            return "this \(age)-year-old \(character.genderType.promptNoun)"
        }
        return shortSubjectDescriptor(for: character)
    }

    private static func shortSubjectDescriptor(for character: AnimationCharacter) -> String {
        "this \(character.genderType.promptNoun)"
    }
}

@available(macOS 26.0, *)
struct PendingInspirationGenerationPlan: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var confirmTitle: String
    var mode: CharacterInspirationGenerationMode
    var wardrobe: CharacterInspirationWardrobe
}

@available(macOS 26.0, *)
private struct ImagePromptPreview: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var prompt: String
    var model: String
    var aspectRatio: String
    var imageSize: String
}

@available(macOS 26.0, *)
private struct StoredImagePromptPreviewSheet: View {
    let preview: ImagePromptPreview
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

                Button("Done") {
                    dismiss()
                }
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

// MARK: - Array Safe Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
