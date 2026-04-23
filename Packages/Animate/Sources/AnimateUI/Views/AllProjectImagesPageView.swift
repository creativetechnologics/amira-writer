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
private extension View {
    @ViewBuilder
    func applyOptionalFrame(width: CGFloat?) -> some View {
        if let width {
            frame(width: width)
        } else {
            frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Copy a full-res image to the pasteboard without blocking the main thread.
/// Immediately seats a cached thumbnail on the pasteboard so the clipboard
/// feels responsive, then replaces it with the real decoded image once the
/// disk read + decode finish on a background actor.
@available(macOS 26.0, *)
@MainActor
func copyImageToPasteboardAsync(path: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    // Fast-path: if we already have any-size thumbnail decoded, seat it now so
    // Cmd-V feels instant. The full-res decode will overwrite below.
    if let thumb = ImagineThumbnailCache.shared.bestCached(for: path) {
        pasteboard.writeObjects([thumb])
    } else {
        pasteboard.setString(path, forType: .string)
    }
    Task.detached(priority: .userInitiated) {
        guard let fullData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        await MainActor.run {
            guard let full = NSImage(data: fullData) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([full])
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
    let groupLabel: String
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
    case imageIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .details: "Details"
        case .generate: "Edit with Gemini"
        case .imageIntelligence: "Image Intelligence"
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

@available(macOS 26.0, *)
struct AllProjectImagesPageLayout: Sendable {
    var forcedDisplayMode: AllProjectImagesDisplayMode? = nil
    var showsDisplayModeControl: Bool = true
    var compactControls: Bool = false
    var thumbnailMin: CGFloat = 80
    var thumbnailMax: CGFloat = 260
    var gridSpacing: CGFloat = 10
    var gridPadding: CGFloat = 12

    static let standard = AllProjectImagesPageLayout()

    static let canvasSidebar = AllProjectImagesPageLayout(
        forcedDisplayMode: .grid,
        showsDisplayModeControl: false,
        compactControls: true,
        thumbnailMin: 68,
        thumbnailMax: 150,
        gridSpacing: 10,
        gridPadding: 14
    )
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
    let layout: AllProjectImagesPageLayout
    @AppStorage("novotro.allImages.displayMode") private var displayModeRaw = AllProjectImagesDisplayMode.grid.rawValue
    @FocusState private var filmstripKeyboardFocused: Bool
    @State private var isImportDropTarget = false
    @State private var gridColumnCount: Int = 1

    init(
        store: AnimateStore,
        state: AllProjectImagesState,
        layout: AllProjectImagesPageLayout = .standard
    ) {
        _store = Bindable(store)
        _state = Bindable(state)
        self.layout = layout
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            contentSection
        }
        .task(id: layoutSignature) {
            state.thumbnailSize = min(max(state.thumbnailSize, layout.thumbnailMin), layout.thumbnailMax)
        }
        .task(id: store.owpURL?.path) {
            store.recoverMissingPersistedCharactersIfNeeded()
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importDroppedImagesToUnattachedLibrary(urls: urls)
        } isTargeted: { isTargeted in
            isImportDropTarget = isTargeted
        }
        .overlay {
            if isImportDropTarget {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    .padding(8)
            }
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
        .onChange(of: state.selectedSource) { _, _ in
            if let selectedGroupLabel = state.selectedGroupLabel,
               !state.availableGroupLabels.contains(selectedGroupLabel) {
                state.selectedGroupLabel = nil
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        Group {
            if layout.compactControls {
                compactFilterBar
            } else {
                standardFilterBar
            }
        }
    }

    private var standardFilterBar: some View {
        HStack(spacing: 12) {
            if layout.showsDisplayModeControl {
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
            }

            Picker("Sort", selection: $state.sortMode) {
                ForEach(AllProjectImagesSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .fixedSize(horizontal: true, vertical: false)

            sourceFilterPicker(width: 132)

            groupFilterPicker(width: 156)

            flagFilterCapsule()

            ratingFilterCapsule()

            TextField("Filter by filename, source, path, or note", text: $state.searchText)
                .textFieldStyle(.roundedBorder)

            Spacer()

            thumbnailSizeControl

            if hasActiveFilters {
                Button("Clear") {
                    clearFilters()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var compactFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Filter images", text: $state.searchText)
                    .textFieldStyle(.roundedBorder)

                if hasActiveFilters {
                    Button("Clear") {
                        clearFilters()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 8) {
                compactControlBlock(title: "Sort") {
                    Picker("Sort", selection: $state.sortMode) {
                        ForEach(AllProjectImagesSortMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 74)
                }

                compactControlBlock(title: "Page") {
                    sourceFilterPicker(width: 82)
                        .labelsHidden()
                }

                Spacer(minLength: 0)

                compactControlBlock(title: "Rating") {
                    ratingFilterCapsule(compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 8) {
                compactControlBlock(title: groupPickerTitle) {
                    groupFilterPicker(width: 118)
                        .labelsHidden()
                }

                compactControlBlock(title: "Flags") {
                    flagFilterCapsule(compact: true)
                }

                Spacer(minLength: 0)

                compactControlBlock(title: "Thumbs") {
                    thumbnailSizeControl
                        .controlSize(.small)
                        .frame(width: 68, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func flagFilterCapsule(compact: Bool = false) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            libraryFilterButton(
                systemImage: "square.grid.2x2",
                isSelected: state.flagFilter == .all
                ,
                size: compact ? 18 : 24
            ) {
                state.flagFilter = .all
            }
            .help("Show all images")

            libraryFilterButton(
                systemImage: "flag.slash",
                isSelected: state.flagFilter == .unflagged
                ,
                size: compact ? 18 : 24
            ) {
                state.flagFilter = .unflagged
            }
            .help("Show only unflagged images")

            libraryFilterButton(
                systemImage: "xmark.circle.fill",
                isSelected: state.flagFilter == .rejected
                ,
                size: compact ? 18 : 24
            ) {
                state.flagFilter = .rejected
            }
            .help("Show only rejected images")
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(.quaternary.opacity(0.12), in: Capsule())
    }

    private func ratingFilterCapsule(compact: Bool = false) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(1...5, id: \.self) { rating in
                libraryFilterButton(
                    systemImage: state.minimumRating != nil && rating <= (state.minimumRating ?? 0) ? "star.fill" : "star",
                    tint: .yellow,
                    isSelected: state.minimumRating == rating,
                    size: compact ? 18 : 24
                ) {
                    state.minimumRating = state.minimumRating == rating ? nil : rating
                }
                .help("Show \(rating)-star and higher images")
            }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(.quaternary.opacity(0.12), in: Capsule())
    }

    private var thumbnailSizeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: layout.compactControls ? 8 : 9))
                .foregroundStyle(.secondary)
            Slider(value: $state.thumbnailSize, in: layout.thumbnailMin...layout.thumbnailMax)
                .frame(width: layout.compactControls ? 70 : 110)
        }
    }

    private var hasActiveFilters: Bool {
        !state.searchText.isEmpty
            || state.flagFilter != .all
            || state.minimumRating != nil
            || state.selectedSource != nil
            || state.selectedGroupLabel != nil
    }

    private func clearFilters() {
        state.searchText = ""
        state.flagFilter = .all
        state.minimumRating = nil
        state.selectedSource = nil
        state.selectedGroupLabel = nil
    }

    @ViewBuilder
    private func sourceFilterPicker(width: CGFloat?) -> some View {
        Picker("Page", selection: $state.selectedSource) {
            Text("All Pages").tag(nil as AllProjectImagesSource?)
            ForEach(AllProjectImagesSource.allCases) { source in
                Text(source.displayName).tag(Optional(source))
            }
        }
        .pickerStyle(.menu)
        .applyOptionalFrame(width: width)
    }

    @ViewBuilder
    private func groupFilterPicker(width: CGFloat?) -> some View {
        Picker(groupPickerTitle, selection: $state.selectedGroupLabel) {
            Text("All \(groupPickerTitlePlural)").tag(nil as String?)
            ForEach(state.availableGroupLabels, id: \.self) { label in
                Text(label).tag(Optional(label))
            }
        }
        .pickerStyle(.menu)
        .disabled(state.availableGroupLabels.isEmpty)
        .applyOptionalFrame(width: width)
    }

    private var groupPickerTitle: String {
        switch state.selectedSource {
        case .places: return "Place"
        case .characters: return "Character"
        case .canvas: return "Canvas"
        case .sceneShots: return "Shot"
        case .map3dCaptures: return "Capture"
        case nil: return "Group"
        }
    }

    private var groupPickerTitlePlural: String {
        switch state.selectedSource {
        case .places: return "Places"
        case .characters: return "Characters"
        case .canvas: return "Canvas Items"
        case .sceneShots: return "Shots"
        case .map3dCaptures: return "Captures"
        case nil: return "Groups"
        }
    }

    private func libraryFilterButton(
        systemImage: String,
        tint: Color = .secondary,
        isSelected: Bool,
        size: CGFloat = 24,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size <= 18 ? 10 : 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : tint)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(isSelected ? Color.secondary.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func compactControlBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
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
                    columns: [GridItem(.adaptive(minimum: state.thumbnailSize), spacing: layout.gridSpacing)],
                    spacing: layout.gridSpacing
                ) {
                    ForEach(records) { record in
                        thumbnailCell(for: record)
                    }
                }
                .trackGridColumnCount($gridColumnCount, tileMinWidth: state.thumbnailSize, spacing: layout.gridSpacing)
                .padding(layout.gridPadding)
            }
            .focusable()
            .focused($filmstripKeyboardFocused)
            .focusEffectDisabled()
            .onTapGesture {
                filmstripKeyboardFocused = true
            }
            .onKeyPress(.space) {
                toggleGridQuickLook()
            }
            .onKeyPress(.leftArrow) { navigateGrid(.left) }
            .onKeyPress(.rightArrow) { navigateGrid(.right) }
            .onKeyPress(.upArrow) { navigateGrid(.up) }
            .onKeyPress(.downArrow) { navigateGrid(.down) }
            .onKeyPress(.init("1")) { applyGridRating(1) }
            .onKeyPress(.init("2")) { applyGridRating(2) }
            .onKeyPress(.init("3")) { applyGridRating(3) }
            .onKeyPress(.init("4")) { applyGridRating(4) }
            .onKeyPress(.init("5")) { applyGridRating(5) }
            .onKeyPress(.init(".")) { applyGridRating(5) }
            .onKeyPress(.init("0")) { applyGridRating(nil) }
            .onKeyPress(.init("x")) { toggleGridRejected() }
            .onKeyPress(.init("X")) { toggleGridRejected() }
            .onKeyPress(phases: .down) { press in
                handleGridRatingKeyPress(press)
            }
            .onKeyPress(.escape) {
                if QuickLookPreviewController.shared.isVisible {
                    QuickLookPreviewController.shared.dismiss()
                    return .handled
                }
                if state.selectedRecordID != nil {
                    state.selectedRecordID = nil
                    return .handled
                }
                return .ignored
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
                                        copyImageToPasteboardAsync(path: record.resolvedPath)
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
                            .draggable(URL(fileURLWithPath: record.resolvedPath))
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
                .onKeyPress(.space) {
                    toggleGridQuickLook()
                }
                .onKeyPress(.init("1")) { applyGridRating(1) }
                .onKeyPress(.init("2")) { applyGridRating(2) }
                .onKeyPress(.init("3")) { applyGridRating(3) }
                .onKeyPress(.init("4")) { applyGridRating(4) }
                .onKeyPress(.init("5")) { applyGridRating(5) }
                .onKeyPress(.init(".")) { applyGridRating(5) }
                .onKeyPress(.init("0")) { applyGridRating(nil) }
                .onKeyPress(.init("x")) { toggleGridRejected() }
                .onKeyPress(.init("X")) { toggleGridRejected() }
                .onKeyPress(phases: .down) { press in
                    handleGridRatingKeyPress(press)
                }
                .onKeyPress(.escape) {
                    if QuickLookPreviewController.shared.isVisible {
                        QuickLookPreviewController.shared.dismiss()
                        return .handled
                    }
                    if state.selectedRecordID != nil {
                        state.selectedRecordID = nil
                        return .handled
                    }
                    return .ignored
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
                    copyImageToPasteboardAsync(path: record.resolvedPath)
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
            onTap: {
                filmstripKeyboardFocused = true
                state.selectedRecordID = record.id
                if QuickLookPreviewController.shared.isVisible,
                   let index = state.filteredRecords.firstIndex(where: { $0.id == record.id }) {
                    QuickLookPreviewController.shared.navigateTo(index: index)
                }
            }
        )
        .draggable(URL(fileURLWithPath: record.resolvedPath))
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
        get { layout.forcedDisplayMode ?? (AllProjectImagesDisplayMode(rawValue: displayModeRaw) ?? .grid) }
        nonmutating set { displayModeRaw = newValue.rawValue }
    }

    private var layoutSignature: String {
        "\(layout.compactControls)#\(layout.thumbnailMin)#\(layout.thumbnailMax)#\(layout.forcedDisplayMode?.rawValue ?? "none")"
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

    private func navigateGrid(_ direction: UnifiedGridNavigation.Direction) -> KeyPress.Result {
        let records = state.filteredRecords
        guard !records.isEmpty else { return .ignored }
        guard let selectedRecordID = state.selectedRecordID,
              let currentIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            state.selectedRecordID = records.first?.id
            filmstripKeyboardFocused = true
            return .handled
        }
        guard let newIndex = UnifiedGridNavigation.nextIndex(
            currentIndex: currentIndex,
            totalCount: records.count,
            columnCount: gridColumnCount,
            direction: direction
        ) else { return .ignored }
        state.selectedRecordID = records[newIndex].id
        if QuickLookPreviewController.shared.isVisible {
            QuickLookPreviewController.shared.navigateTo(index: newIndex)
        }
        return .handled
    }

    private func applyGridRating(_ rating: Int?) -> KeyPress.Result {
        guard let record = state.selectedRecord else { return .ignored }
        updateRating(rating, for: record)
        return .handled
    }

    private func toggleGridRejected() -> KeyPress.Result {
        guard let record = state.selectedRecord else { return .ignored }
        toggleRejected(for: record)
        return .handled
    }

    private func handleGridRatingKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case "1":
            return applyGridRating(1)
        case "2":
            return applyGridRating(2)
        case "3":
            return applyGridRating(3)
        case "4":
            return applyGridRating(4)
        case "5", ".":
            return applyGridRating(5)
        case "0":
            return applyGridRating(nil)
        case "x", "X":
            return toggleGridRejected()
        default:
            return .ignored
        }
    }

    private func toggleGridQuickLook() -> KeyPress.Result {
        let records = state.filteredRecords
        guard !records.isEmpty else {
            if QuickLookPreviewController.shared.isVisible {
                QuickLookPreviewController.shared.dismiss()
                return .handled
            }
            return .ignored
        }
        guard let selectedRecordID = state.selectedRecordID,
              let recordIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            state.selectedRecordID = records.first?.id
            return .handled
        }
        let resolvedItems = records.enumerated().compactMap { index, record -> (Int, URL)? in
            let url = store.resolvedCharacterAssetURL(for: record.path) ?? URL(fileURLWithPath: record.resolvedPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (index, url)
        }
        guard !resolvedItems.isEmpty else { return .ignored }
        let quickLookIndex = resolvedItems.firstIndex(where: { $0.0 == recordIndex }) ?? 0
        QuickLookPreviewController.shared.toggle(
            urls: resolvedItems.map(\.1),
            startAt: quickLookIndex
        )
        filmstripKeyboardFocused = true
        return .handled
    }
}
