import SwiftUI
import AppKit
import ProjectKit

// MARK: - Shared types (used by workspace + page + sidebar + inspector)

@available(macOS 26.0, *)
enum AllProjectImagesSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case places
    case canvas
    case characters
    case sceneShots
    case map3dCaptures

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .places: "Places"
        case .canvas: "Canvas"
        case .characters: "Characters"
        case .sceneShots: "Scene Shots"
        case .map3dCaptures: "Map 3D Captures"
        }
    }

    var systemImage: String {
        switch self {
        case .places: "map"
        case .canvas: "paintpalette"
        case .characters: "person.2"
        case .sceneShots: "film.stack"
        case .map3dCaptures: "camera.macro"
        }
    }
}

@available(macOS 26.0, *)
struct ProjectImageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let resolvedPath: String
    let source: AllProjectImagesSource
    let originLabel: String
    let createdAt: Date?
    let sizeBytes: Int64?
    let rating: Int?
    let isRejected: Bool
    let notes: String
    let supportsLibraryCuration: Bool
}

@available(macOS 26.0, *)
enum AllProjectImagesInspectorTab: String, CaseIterable, Identifiable, Hashable {
    case details
    case generate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .details: "Details"
        case .generate: "Edit with Gemini"
        }
    }
}

@available(macOS 26.0, *)
enum AllProjectImagesSortMode: String, CaseIterable, Identifiable, Hashable {
    case newest
    case oldest
    case name
    case rating

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        case .rating: "Highest Rated"
        }
    }
}

@available(macOS 26.0, *)
enum AllProjectImagesFlagFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case unflagged
    case rejected

    var id: String { rawValue }
}

@available(macOS 26.0, *)
enum AllProjectImagesDisplayMode: String, CaseIterable, Identifiable, Hashable {
    case grid
    case filmstrip

    var id: String { rawValue }
}

// MARK: - Center Pane (search / sort / size slider + grid)

/// Renders the center content of the All Images workspace — the filter bar
/// and the thumbnail grid. The left sidebar and right inspector are owned
/// by `AllProjectImagesWorkspace`; selection / filter / generation state is
/// shared through `AllProjectImagesState`.
@available(macOS 26.0, *)
struct AllProjectImagesPageView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState
    @AppStorage("novotro.allImages.displayMode") private var displayModeRaw = AllProjectImagesDisplayMode.grid.rawValue
    @FocusState private var filmstripKeyboardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            contentSection
        }
        .task(id: state.recordsSignature(store: store)) {
            state.requestRebuildIfNeeded(store: store)
        }
        .task(id: prefetchKey) {
            let pixel = Int(state.thumbnailSize * 2)
            ImagineThumbnailCache.shared.prefetch(
                paths: state.prefetchPaths(),
                maxPixelSize: pixel
            )
        }
        .task(id: filmstripSelectionKey) {
            if displayMode == .filmstrip {
                state.ensureFilmstripSelection()
                filmstripKeyboardFocused = true
            }
        }
        .task(id: filmstripPreviewPrefetchKey) {
            let previewPaths = filmstripPreviewPrefetchPaths
            guard !previewPaths.isEmpty else { return }
            ImagineThumbnailCache.shared.prefetch(
                paths: previewPaths,
                maxPixelSize: 2200
            )
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                libraryFilterButton(
                    systemImage: "square.grid.2x2",
                    isSelected: displayMode == .grid
                ) {
                    displayMode = .grid
                }
                .help("Grid view")

                libraryFilterButton(
                    systemImage: "rectangle.bottomthird.inset.filled",
                    isSelected: displayMode == .filmstrip
                ) {
                    displayMode = .filmstrip
                }
                .help("Filmstrip view")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            Picker("Sort", selection: $state.sortMode) {
                ForEach(AllProjectImagesSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 8) {
                libraryFilterButton(
                    systemImage: "square.grid.2x2",
                    isSelected: state.flagFilter == .all
                ) {
                    state.flagFilter = .all
                }
                .help("Show all images")

                libraryFilterButton(
                    systemImage: "flag.slash",
                    isSelected: state.flagFilter == .unflagged
                ) {
                    state.flagFilter = .unflagged
                }
                .help("Show only unflagged images")

                libraryFilterButton(
                    systemImage: "xmark.circle.fill",
                    isSelected: state.flagFilter == .rejected
                ) {
                    state.flagFilter = .rejected
                }
                .help("Show only rejected images")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { rating in
                    libraryFilterButton(
                        systemImage: state.minimumRating != nil && rating <= (state.minimumRating ?? 0) ? "star.fill" : "star",
                        tint: .yellow,
                        isSelected: state.minimumRating == rating
                    ) {
                        state.minimumRating = state.minimumRating == rating ? nil : rating
                    }
                    .help("Show \(rating)-star and higher images")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            TextField("Filter by filename, source, path, or note", text: $state.searchText)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $state.thumbnailSize, in: 80...260)
                    .frame(width: 110)
            }

            if !state.searchText.isEmpty || state.flagFilter != .all || state.minimumRating != nil {
                Button("Clear") {
                    state.searchText = ""
                    state.flagFilter = .all
                    state.minimumRating = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func libraryFilterButton(
        systemImage: String,
        tint: Color = .secondary,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : tint)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isSelected ? Color.secondary.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        let records = state.filteredRecords
        if records.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No images in this view")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayMode == .filmstrip {
            filmstripSection(records: records)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: state.thumbnailSize), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(records) { record in
                        thumbnailCell(for: record)
                    }
                }
                .padding(12)
            }
        }
    }

    private func filmstripSection(records: [ProjectImageRecord]) -> some View {
        guard let selectedRecord = filmstripSelectedRecord(from: records) else {
            return AnyView(
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No images in this view")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        let filmstripThumbnailSize = min(max(state.thumbnailSize, 84), 180)

        return AnyView(VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((selectedRecord.path as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(selectedRecord.originLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 8) {
                        filmstripPill(selectedRecord.source.displayName, systemImage: selectedRecord.source.systemImage)
                        if let rating = selectedRecord.rating, rating > 0 {
                            filmstripPill("\(rating)★", systemImage: "star.fill", tint: .yellow)
                        }
                        if selectedRecord.isRejected {
                            filmstripPill("Rejected", systemImage: "eye.slash.fill", tint: .red)
                        }
                        if !selectedRecord.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            filmstripPill("Notes", systemImage: "note.text")
                        }
                    }
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.black.opacity(0.18))
                    AsyncResolvedImageView(
                        path: selectedRecord.resolvedPath,
                        maxPixelSize: 2200,
                        contentMode: .fit
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    if selectedRecord.isRejected || selectedRecord.rating != nil || !selectedRecord.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 8) {
                            if selectedRecord.isRejected {
                                filmstripPill("Rejected", systemImage: "eye.slash.fill", tint: .red)
                            }
                            if let rating = selectedRecord.rating, rating > 0 {
                                filmstripPill("\(rating) Stars", systemImage: "star.fill", tint: .yellow)
                            }
                            if !selectedRecord.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                filmstripPill("Has Notes", systemImage: "note.text")
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(records) { record in
                            UnifiedImageTile(
                                path: record.path,
                                resolvedPath: record.resolvedPath,
                                thumbnailSize: filmstripThumbnailSize,
                                sourceLabel: record.source.displayName,
                                sourceSystemImage: record.source.systemImage,
                                isSelected: state.selectedRecordID == record.id,
                                isRejected: record.isRejected,
                                hasNotes: !record.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                rating: record.rating,
                                actions: UnifiedImageActions(
                                    onShowInFinder: {
                                        NSWorkspace.shared.activateFileViewerSelecting(
                                            [URL(fileURLWithPath: record.resolvedPath)]
                                        )
                                    },
                                    onCopy: {
                                        if let image = NSImage(contentsOfFile: record.resolvedPath) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.writeObjects([image])
                                        } else {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(record.resolvedPath, forType: .string)
                                        }
                                    },
                                    onEditWithGemini: {
                                        state.selectedRecordID = record.id
                                        state.inspectorTab = .generate
                                        beginEdit(for: record)
                                    },
                                    onGenerateWithGemini: { count in
                                        beginGenerate(for: record, count: count)
                                    },
                                    onSetRating: { rating in
                                        updateRating(rating, for: record)
                                    },
                                    currentRating: record.rating,
                                    onToggleRejected: {
                                        toggleRejected(for: record)
                                    },
                                    isRejected: record.isRejected
                                ),
                                onTap: {
                                    state.selectedRecordID = record.id
                                    filmstripKeyboardFocused = true
                                }
                            )
                            .id(record.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(height: filmstripThumbnailSize + 34)
                .background(OperaChromeTheme.raisedBackground.opacity(0.35))
                .focusable()
                .focused($filmstripKeyboardFocused)
                .focusEffectDisabled()
                .onTapGesture {
                    filmstripKeyboardFocused = true
                }
                .onKeyPress(.leftArrow) {
                    state.selectAdjacentRecord(in: records, delta: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    state.selectAdjacentRecord(in: records, delta: 1)
                    return .handled
                }
                .onChange(of: state.selectedRecordID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .task(id: state.selectedRecordID) {
                    guard let selectedID = state.selectedRecordID else { return }
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        })
    }

    @ViewBuilder
    private func thumbnailCell(for record: ProjectImageRecord) -> some View {
        let isSelected = state.selectedRecordID == record.id
        UnifiedImageTile(
            path: record.path,
            resolvedPath: record.resolvedPath,
            thumbnailSize: state.thumbnailSize,
            caption: record.originLabel,
            sourceLabel: record.source.displayName,
            sourceSystemImage: record.source.systemImage,
            isSelected: isSelected,
            isRejected: record.isRejected,
            hasNotes: !record.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            rating: record.rating,
            actions: UnifiedImageActions(
                onShowInFinder: {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: record.resolvedPath)]
                    )
                },
                onCopy: {
                    if let image = NSImage(contentsOfFile: record.resolvedPath) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.resolvedPath, forType: .string)
                    }
                },
                onEditWithGemini: {
                    // Open the preflight sheet immediately so the user can
                    // type the adjustment there and hit Generate. Also
                    // select the record + flip the inspector tab so after
                    // the sheet closes they can keep iterating from the
                    // Edit-with-Gemini tab without re-hunting the image.
                    state.selectedRecordID = record.id
                    state.inspectorTab = .generate
                    beginEdit(for: record)
                },
                onGenerateWithGemini: { count in
                    beginGenerate(for: record, count: count)
                },
                onSetRating: { rating in
                    updateRating(rating, for: record)
                },
                currentRating: record.rating,
                onToggleRejected: {
                    toggleRejected(for: record)
                },
                isRejected: record.isRejected
            ),
            onTap: { state.selectedRecordID = record.id }
        )
    }

    private func updateRating(_ rating: Int?, for record: ProjectImageRecord) {
        let updated = persistReviewUpdate(
            store: store,
            record: record,
            rating: rating,
            isRejected: record.isRejected,
            notes: record.notes
        )
        state.updateReviewMetadata(for: record.id, rating: updated.rating, isRejected: updated.isRejected, notes: updated.notes)
    }

    private func toggleRejected(for record: ProjectImageRecord) {
        let updated = persistReviewUpdate(
            store: store,
            record: record,
            rating: record.rating,
            isRejected: !record.isRejected,
            notes: record.notes
        )
        state.updateReviewMetadata(for: record.id, rating: updated.rating, isRejected: updated.isRejected, notes: updated.notes)
    }

    // MARK: - Inline edit (right-click → Edit with Gemini)

    /// Builds a single-draft preflight for "Edit with Gemini…" and pushes it
    /// to `state.editPendingPreflight`. The workspace-root `.sheet(item:)`
    /// presents the preflight regardless of whether the inspector is open,
    /// so this works from anywhere in the grid.
    private func beginEdit(for record: ProjectImageRecord) {
        let reference = GeminiGenerationReferenceDraft(
            label: URL(fileURLWithPath: record.resolvedPath)
                .deletingPathExtension()
                .lastPathComponent,
            path: record.resolvedPath,
            isIncluded: true
        )
        let draft = GeminiGenerationDraft(
            title: "Edit: \(record.originLabel)",
            destinationDescription: "Places → Unattached library",
            prompt: "",
            model: state.editModel,
            aspectRatio: state.editAspectRatio,
            imageSize: state.editImageSize,
            referenceItems: [reference],
            editInstructions: state.editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        state.editPendingDrafts = [draft]
        state.editPendingPreflight = draft
    }

    // MARK: - Inline generate (right-click → Generate with Gemini)

    private func beginGenerate(for record: ProjectImageRecord, count: Int) {
        let filename = URL(fileURLWithPath: record.resolvedPath).lastPathComponent
        let reference = GeminiGenerationReferenceDraft(
            label: "Reference: \(filename)",
            path: record.resolvedPath,
            isIncluded: true
        )
        let drafts = (0..<max(1, count)).map { i in
            GeminiGenerationDraft(
                title: count == 1
                    ? "Generate from \(filename)"
                    : "Batch \(i + 1) from \(filename)",
                destinationDescription: "Places → Unattached library",
                prompt: "",
                model: state.editModel,
                aspectRatio: state.editAspectRatio,
                imageSize: state.editImageSize,
                referenceItems: [reference]
            )
        }
        state.editPendingDrafts = drafts
        state.editPendingPreflight = drafts.first
    }

    // MARK: - Prefetch key

    private var prefetchKey: String {
        state.prefetchSignature(thumbnailSize: state.thumbnailSize)
    }

    private var displayMode: AllProjectImagesDisplayMode {
        get { AllProjectImagesDisplayMode(rawValue: displayModeRaw) ?? .grid }
        nonmutating set { displayModeRaw = newValue.rawValue }
    }

    private var filmstripSelectionKey: String {
        "\(displayMode.rawValue)#\(state.prefetchSignature(thumbnailSize: state.thumbnailSize, limit: 200))"
    }

    private var filmstripPreviewPrefetchKey: String {
        filmstripPreviewPrefetchPaths.joined(separator: "|")
    }

    private var filmstripPreviewPrefetchPaths: [String] {
        let records = state.filteredRecords
        guard displayMode == .filmstrip,
              !records.isEmpty,
              let selectedRecord = filmstripSelectedRecord(from: records),
              let selectedIndex = records.firstIndex(where: { $0.id == selectedRecord.id }) else {
            return []
        }
        let range = max(0, selectedIndex - 1)...min(records.count - 1, selectedIndex + 1)
        return range.map { records[$0].resolvedPath }
    }

    private func filmstripSelectedRecord(from records: [ProjectImageRecord]) -> ProjectImageRecord? {
        if let selectedRecordID = state.selectedRecordID,
           let selectedRecord = records.first(where: { $0.id == selectedRecordID }) {
            return selectedRecord
        }
        return records.first
    }

    private func filmstripPill(_ title: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
