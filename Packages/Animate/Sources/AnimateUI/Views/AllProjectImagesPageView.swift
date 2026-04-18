import SwiftUI
import AppKit

// MARK: - Shared types (used by workspace + page + sidebar + inspector)

@available(macOS 26.0, *)
enum AllProjectImagesSource: String, CaseIterable, Identifiable, Hashable {
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
struct ProjectImageRecord: Identifiable, Hashable {
    let id: String
    let path: String
    let resolvedPath: String
    let source: AllProjectImagesSource
    let originLabel: String
    let createdAt: Date?
    let sizeBytes: Int64?
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        }
    }
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

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            gridSection
        }
        .task(id: state.recordsSignature(store: store)) {
            state.rebuildIfNeeded(store: store)
        }
        .task(id: prefetchKey) {
            let paths = state.filteredRecords.prefix(120).map(\.resolvedPath)
            let pixel = Int(state.thumbnailSize * 2)
            ImagineThumbnailCache.shared.prefetch(paths: paths, maxPixelSize: pixel)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("Search paths or names…", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("Sort", selection: $state.sortMode) {
                ForEach(AllProjectImagesSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $state.thumbnailSize, in: 80...260)
                    .frame(width: 110)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridSection: some View {
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
                }
            ),
            onTap: { state.selectedRecordID = record.id }
        )
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
        "\(state.recordsSignature(store: store))|\(state.selectedSource?.rawValue ?? "all")|\(Int(state.thumbnailSize))"
    }
}
