import AppKit
import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ImageLibraryReviewMetadata: Equatable, Sendable {
    var rating: Int?
    var isRejected: Bool
    var notes: String
    var updatedAt: Date?

    var isEmpty: Bool {
        rating == nil
            && !isRejected
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@available(macOS 26.0, *)
enum ImageLibraryMetadataSidecarService {
    static func load(forImagePath imagePath: String) -> ImageLibraryReviewMetadata? {
        let sidecarURL = sidecarURL(forImagePath: imagePath)
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              let data = try? Data(contentsOf: sidecarURL),
              let xml = String(data: data, encoding: .utf8) else {
            return nil
        }

        let rating = extractTagValue("Rating", from: xml).flatMap(Int.init)
        let isRejected = extractTagValue("IsRejected", from: xml)
            .map { ["true", "1", "yes"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? false
        let notes = extractTagValue("Notes", from: xml).map(unescapeXML) ?? ""
        let updatedAt = extractTagValue("UpdatedAt", from: xml).flatMap { iso8601Formatter().date(from: $0) }

        let metadata = ImageLibraryReviewMetadata(
            rating: rating.map { min(max($0, 1), 5) },
            isRejected: isRejected,
            notes: notes,
            updatedAt: updatedAt
        )
        return metadata.isEmpty ? nil : metadata
    }

    static func save(_ metadata: ImageLibraryReviewMetadata, forImagePath imagePath: String) {
        let sidecarURL = sidecarURL(forImagePath: imagePath)
        if metadata.isEmpty {
            try? FileManager.default.removeItem(at: sidecarURL)
            return
        }

        let xml = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:amira="https://amira.writer/ns/image-library/1.0/">
              \(metadata.rating.map { "<xmp:Rating>\($0)</xmp:Rating>" } ?? "")
              <amira:IsRejected>\(metadata.isRejected ? "true" : "false")</amira:IsRejected>
              <amira:Notes>\(escapeXML(metadata.notes))</amira:Notes>
              <amira:UpdatedAt>\(iso8601Formatter().string(from: metadata.updatedAt ?? Date()))</amira:UpdatedAt>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        try? xml.data(using: .utf8)?.write(to: sidecarURL, options: .atomic)
    }

    static func sidecarURL(forImagePath imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("xmp")
    }

    private static func extractTagValue(_ tagName: String, from xml: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_\\-]+:)?\(tagName)>(.*?)</(?:[A-Za-z0-9_\\-]+:)?\(tagName)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[valueRange])
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func iso8601Formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

// MARK: - Shared State (observable across the 3 panes)

/// Single source of truth for the All Project Images workspace.
/// Owned by the workspace content view and shared into the sidebar, page,
/// and inspector so every pane stays in sync without binding boilerplate.
@available(macOS 26.0, *)
@Observable @MainActor
final class AllProjectImagesState {
    private struct CachedFileMetadata: Equatable, Sendable {
        let createdAt: Date?
        let sizeBytes: Int64?
    }

    private struct RecordSeed: Sendable {
        let id: String
        let path: String
        let resolvedPath: String
        let source: AllProjectImagesSource
        let originLabel: String
        let rating: Int?
        let isRejected: Bool
        let notes: String
        let supportsLibraryCuration: Bool
    }

    private struct FilterCacheKey: Equatable {
        let buildSignature: Int
        let selectedSource: AllProjectImagesSource?
        let searchText: String
        let sortMode: AllProjectImagesSortMode
        let flagFilter: AllProjectImagesFlagFilter
        let minimumRating: Int?
    }

    // Filter / selection
    var selectedSource: AllProjectImagesSource? = nil
    var selectedRecordID: String? = nil
    var sortMode: AllProjectImagesSortMode = .newest
    var thumbnailSize: CGFloat = 140
    var searchText: String = ""
    var inspectorTab: AllProjectImagesInspectorTab = .details
    var flagFilter: AllProjectImagesFlagFilter = .all
    var minimumRating: Int? = nil

    // Edit-with-Gemini state
    var editAdjustments: String = ""
    var editModel: GeminiModel = .flash
    var editAspectRatio: String = "1:1"
    var editImageSize: String = "1K"
    var editPendingDrafts: [GeminiGenerationDraft] = []
    var editPendingPreflight: GeminiGenerationDraft? = nil
    var editErrorMessage: String? = nil

    // Memoized record set (rebuilt only when the path signature changes).
    var cachedAllRecords: [ProjectImageRecord] = []
    var lastBuildSignature: Int = -1
    private var pendingBuildSignature: Int = -1
    @ObservationIgnored private var recordsByID: [String: ProjectImageRecord] = [:]
    @ObservationIgnored private var countsBySource: [AllProjectImagesSource: Int] = [:]
    private var fileMetadataCache: [String: CachedFileMetadata] = [:]
    @ObservationIgnored private var filteredCacheKey: FilterCacheKey?
    @ObservationIgnored private var filteredCacheRecords: [ProjectImageRecord] = []
    @ObservationIgnored private var filteredRecordsByID: [String: ProjectImageRecord] = [:]
    @ObservationIgnored private var rebuildRequestID: Int = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    // MARK: - Aggregation

    /// Lightweight hash of every path collection's `.count`. Used as `.task(id:)`
    /// so we only rebuild `cachedAllRecords` — which does per-record FileManager
    /// syscalls — when the set of paths actually changed. Typing in the search
    /// field does NOT change this, so no rebuild, no beachball.
    func recordsSignature(store: AnimateStore) -> Int {
        var h = 1469598103934665603 & Int.max
        func mix(_ v: Int) { h = (h ^ v) &* 1099511628211 }
        for p in store.backgrounds {
            mix(p.imagePaths.count)
            mix(p.animatedImagePaths.count &<< 3)
        }
        mix(store.canvasGenerations.count &<< 7)
        mix(store.placesWorkflowLibrary.generatedImageRecords.count &<< 11)
        for c in store.characters {
            mix(c.inspirationImagePaths.count)
            mix(c.referenceImagePaths.count &<< 2)
            mix(c.animatedImagePaths.count &<< 4)
        }
        for (_, galleries) in store.imagineSceneGalleries {
            for g in galleries {
                mix(g.beginningImagePaths.count)
                mix(g.middleImagePaths.count &<< 2)
                mix(g.endImagePaths.count &<< 4)
            }
        }
        return h
    }

    func requestRebuildIfNeeded(store: AnimateStore) {
        let sig = recordsSignature(store: store)
        if sig == lastBuildSignature || sig == pendingBuildSignature { return }

        pendingBuildSignature = sig
        let seeds = buildRecordSeeds(store: store)
        rebuildTask?.cancel()
        rebuildRequestID &+= 1
        let requestID = rebuildRequestID

        rebuildTask = Task { [weak self] in
            let rebuiltRecords = await Task.detached(priority: .utility) {
                Self.buildRecords(from: seeds)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      requestID == self.rebuildRequestID else { return }
                self.applyRebuiltRecords(rebuiltRecords, signature: sig)
                self.pendingBuildSignature = -1
                self.rebuildTask = nil
            }
        }
    }

    private func applyRebuiltRecords(_ rebuiltRecords: [ProjectImageRecord], signature: Int) {
        cachedAllRecords = rebuiltRecords
        recordsByID = Dictionary(uniqueKeysWithValues: rebuiltRecords.map { ($0.id, $0) })
        countsBySource = Dictionary(grouping: rebuiltRecords, by: \.source).mapValues(\.count)
        lastBuildSignature = signature
        filteredCacheKey = nil
        filteredCacheRecords = []
        filteredRecordsByID = [:]
        fileMetadataCache.merge(
            Dictionary(uniqueKeysWithValues: rebuiltRecords.map {
                ($0.resolvedPath, CachedFileMetadata(createdAt: $0.createdAt, sizeBytes: $0.sizeBytes))
            }),
            uniquingKeysWith: { _, new in new }
        )
        if let selectedRecordID, recordsByID[selectedRecordID] == nil {
            self.selectedRecordID = nil
        }
    }

    func updateReviewMetadata(for recordID: String, rating: Int?, isRejected: Bool, notes: String) {
        guard let index = cachedAllRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let updated = ProjectImageRecord(
            id: cachedAllRecords[index].id,
            path: cachedAllRecords[index].path,
            resolvedPath: cachedAllRecords[index].resolvedPath,
            source: cachedAllRecords[index].source,
            originLabel: cachedAllRecords[index].originLabel,
            createdAt: cachedAllRecords[index].createdAt,
            sizeBytes: cachedAllRecords[index].sizeBytes,
            rating: rating,
            isRejected: isRejected,
            notes: notes,
            supportsLibraryCuration: cachedAllRecords[index].supportsLibraryCuration
        )
        cachedAllRecords[index] = updated
        recordsByID[updated.id] = updated
        filteredCacheKey = nil
        filteredCacheRecords = []
        filteredRecordsByID = [:]
    }

    private func buildRecordSeeds(store: AnimateStore) -> [RecordSeed] {
        var records: [RecordSeed] = []
        var dedupeIndexByKey: [String: Int] = [:]

        func appendRecord(
            _ record: RecordSeed,
            dedupeByResolvedPath: Bool = false,
            preferNewRecord: Bool = false
        ) {
            guard dedupeByResolvedPath else {
                records.append(record)
                return
            }

            let dedupeKey = "\(record.source.rawValue)|\(record.resolvedPath)"
            if let existingIndex = dedupeIndexByKey[dedupeKey] {
                if preferNewRecord {
                    records[existingIndex] = record
                }
                return
            }

            dedupeIndexByKey[dedupeKey] = records.count
            records.append(record)
        }

        for place in store.backgrounds {
            for path in place.imagePaths {
                appendRecord(makeSeed(
                    id: "place-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: place.name.isEmpty ? "Place" : place.name,
                    rating: {
                        let value = store.placeImageRating(path: path, placeID: place.id)
                        return value > 0 ? value : nil
                    }(),
                    store: store
                ), dedupeByResolvedPath: true)
            }
            for path in place.animatedImagePaths {
                appendRecord(makeSeed(
                    id: "place-anim-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: "\(place.name) (animated)",
                    rating: {
                        let value = store.placeImageRating(path: path, placeID: place.id)
                        return value > 0 ? value : nil
                    }(),
                    store: store
                ), dedupeByResolvedPath: true)
            }
        }

        for record in store.placesWorkflowLibrary.generatedImageRecords {
            let activePath = record.activePath
            guard !activePath.isEmpty else { continue }
            let isMap3D = record.keywords.contains("map3d-capture")
            let origin: String
            if isMap3D {
                origin = "3D Map Capture"
            } else if let placeID = record.linkedPlaceID,
                      let place = store.backgrounds.first(where: { $0.id == placeID }) {
                origin = place.name
            } else {
                origin = "Unattached"
            }
            appendRecord(makeSeed(
                id: "placelib-\(record.id.uuidString)",
                path: activePath,
                source: isMap3D ? .map3dCaptures : .places,
                originLabel: origin,
                rating: record.rating,
                isRejected: record.isRejected,
                notes: record.draftEditNotes,
                store: store
            ), dedupeByResolvedPath: true, preferNewRecord: !isMap3D)
        }

        for gen in store.canvasGenerations {
            records.append(makeSeed(
                id: "canvas-\(gen.id.uuidString)",
                path: gen.imagePath,
                source: .canvas,
                originLabel: gen.prompt.isEmpty ? "Canvas generation" : String(gen.prompt.prefix(50)),
                store: store
            ))
        }

        for character in store.characters {
            let originBase = character.name.isEmpty ? "Character" : character.name
            for path in character.inspirationImagePaths {
                records.append(makeSeed(
                    id: "char-insp-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (inspiration)",
                    rating: character.inspirationRatings?[path],
                    isRejected: character.inspirationRejectedPaths.contains(path),
                    notes: character.inspirationNotes?[path] ?? "",
                    store: store
                ))
            }
            for path in character.referenceImagePaths {
                records.append(makeSeed(
                    id: "char-ref-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (reference)",
                    store: store
                ))
            }
            for path in character.animatedImagePaths {
                records.append(makeSeed(
                    id: "char-anim-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (animated)",
                    store: store
                ))
            }
        }

        for (_, galleries) in store.imagineSceneGalleries {
            for gallery in galleries {
                for (moment, paths) in [
                    (ImagineShotMoment.beginning, gallery.beginningImagePaths),
                    (ImagineShotMoment.middle, gallery.middleImagePaths),
                    (ImagineShotMoment.end, gallery.endImagePaths)
                ] {
                    for path in paths {
                        records.append(makeSeed(
                            id: "shot-\(gallery.id.uuidString)-\(moment.rawValue)-\(path)",
                            path: path,
                            source: .sceneShots,
                            originLabel: "Shot (\(moment.rawValue))",
                            store: store
                        ))
                    }
                }
            }
        }

        return records
    }

    private func makeSeed(
        id: String,
        path: String,
        source: AllProjectImagesSource,
        originLabel: String,
        rating: Int? = nil,
        isRejected: Bool = false,
        notes: String = "",
        supportsLibraryCuration: Bool = true,
        store: AnimateStore
    ) -> RecordSeed {
        let resolved = store.resolvedCharacterAssetURL(for: path)?.path ?? path
        return RecordSeed(
            id: id,
            path: path,
            resolvedPath: resolved,
            source: source,
            originLabel: originLabel,
            rating: rating,
            isRejected: isRejected,
            notes: notes,
            supportsLibraryCuration: supportsLibraryCuration
        )
    }

    nonisolated private static func buildRecords(from seeds: [RecordSeed]) -> [ProjectImageRecord] {
        var metadataCache: [String: CachedFileMetadata] = [:]
        let fileManager = FileManager.default

        return seeds.map { seed in
            let metadata: CachedFileMetadata
            if let cached = metadataCache[seed.resolvedPath] {
                metadata = cached
            } else {
                let attrs = try? fileManager.attributesOfItem(atPath: seed.resolvedPath)
                metadata = CachedFileMetadata(
                    createdAt: (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date),
                    sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value
                )
                metadataCache[seed.resolvedPath] = metadata
            }

            let hasSeedMetadata = seed.rating != nil
                || seed.isRejected
                || !seed.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sidecarMetadata = (seed.source == .places || !hasSeedMetadata)
                ? ImageLibraryMetadataSidecarService.load(forImagePath: seed.resolvedPath)
                : nil
            let mergedNotes = seed.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (sidecarMetadata?.notes ?? "")
                : seed.notes

            return ProjectImageRecord(
                id: seed.id,
                path: seed.path,
                resolvedPath: seed.resolvedPath,
                source: seed.source,
                originLabel: seed.originLabel,
                createdAt: metadata.createdAt,
                sizeBytes: metadata.sizeBytes,
                rating: seed.rating ?? sidecarMetadata?.rating,
                isRejected: seed.isRejected || (sidecarMetadata?.isRejected ?? false),
                notes: mergedNotes,
                supportsLibraryCuration: seed.supportsLibraryCuration
            )
        }
    }

    // MARK: - Filter + Sort

    var filteredRecords: [ProjectImageRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = FilterCacheKey(
            buildSignature: lastBuildSignature,
            selectedSource: selectedSource,
            searchText: query,
            sortMode: sortMode,
            flagFilter: flagFilter,
            minimumRating: minimumRating
        )
        if filteredCacheKey != cacheKey {
            var records = cachedAllRecords
            if let source = selectedSource {
                records = records.filter { $0.source == source }
            }
            switch flagFilter {
            case .all:
                break
            case .unflagged:
                records = records.filter { !$0.isRejected }
            case .rejected:
                records = records.filter(\.isRejected)
            }
            if let minimumRating {
                records = records.filter { ($0.rating ?? 0) >= minimumRating }
            }
            if !query.isEmpty {
                records = records.filter {
                    $0.path.lowercased().contains(query)
                        || $0.originLabel.lowercased().contains(query)
                        || $0.notes.lowercased().contains(query)
                }
            }
            switch sortMode {
            case .newest:
                records.sort { (lhs, rhs) in
                    (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
                }
            case .oldest:
                records.sort { (lhs, rhs) in
                    (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture)
                }
            case .name:
                records.sort { (lhs, rhs) in
                    (lhs.path as NSString).lastPathComponent
                        .localizedCompare((rhs.path as NSString).lastPathComponent) == .orderedAscending
                }
            case .rating:
                records.sort { lhs, rhs in
                    if (lhs.rating ?? 0) != (rhs.rating ?? 0) {
                        return (lhs.rating ?? 0) > (rhs.rating ?? 0)
                    }
                    return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
                }
            }
            filteredCacheKey = cacheKey
            filteredCacheRecords = records
            filteredRecordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        }
        return filteredCacheRecords
    }

    var selectedRecord: ProjectImageRecord? {
        guard let id = selectedRecordID else { return nil }
        _ = filteredRecords
        return filteredRecordsByID[id] ?? recordsByID[id]
    }

    func count(for source: AllProjectImagesSource) -> Int {
        countsBySource[source] ?? 0
    }

    func ensureFilmstripSelection() {
        let records = filteredRecords
        guard !records.isEmpty else {
            selectedRecordID = nil
            return
        }
        guard let selectedRecordID,
              filteredRecordsByID[selectedRecordID] != nil else {
            self.selectedRecordID = records.first?.id
            return
        }
    }

    func selectAdjacentRecord(in records: [ProjectImageRecord], delta: Int) {
        guard !records.isEmpty else { return }
        guard let selectedRecordID,
              let currentIndex = records.firstIndex(where: { $0.id == selectedRecordID }) else {
            self.selectedRecordID = records.first?.id
            return
        }
        let clampedIndex = min(max(currentIndex + delta, 0), records.count - 1)
        self.selectedRecordID = records[clampedIndex].id
    }

    func prefetchPaths(limit: Int = 120) -> [String] {
        Array(filteredRecords.prefix(limit).map(\.resolvedPath))
    }

    func prefetchSignature(thumbnailSize: CGFloat, limit: Int = 120) -> String {
        let ids = filteredRecords.prefix(limit).map(\.id).joined(separator: "|")
        return "\(ids)#\(Int(thumbnailSize.rounded()))"
    }
}

// MARK: - Public Workspace (consumed by OperaShellView)

@available(macOS 26.0, *)
public struct AllProjectImagesWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            AllProjectImagesWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening All Images" : "Refreshing All Images",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

// MARK: - Three-Pane Content

@available(macOS 26.0, *)
private struct AllProjectImagesWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var state = AllProjectImagesState()

    @AppStorage("novotro.allImages.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.allImages.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.allImages.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.allImages.inspector.width") private var inspectorWidth: Double = 340

    var body: some View {
        // Shadow `state` with @Bindable so `$state.editPendingPreflight`
        // produces a Binding that SwiftUI actually subscribes to when the
        // property changes. Without this, `@State` on an `@Observable`
        // reference type + `$state.property` goes through dynamic member
        // lookup in a way that silently fails to trigger `.sheet(item:)`
        // — that's why right-clicking "Edit with Gemini…" did nothing
        // visible even though the closure was firing and mutating state.
        @Bindable var state = state
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "photo.on.rectangle.angled",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
                    .sheet(item: $state.editPendingPreflight) { _ in
                        GeminiGenerationPreflightSheet(
                            store: store,
                            drafts: $state.editPendingDrafts,
                            title: "Edit with Gemini",
                            confirmTitle: "Generate",
                            onConfirm: { finalDrafts, _ in
                                let sourceRecord = state.selectedRecord
                                state.editPendingPreflight = nil
                                runEditGeneration(finalDrafts, sourceRecord: sourceRecord)
                            },
                            onCancel: {
                                state.editPendingPreflight = nil
                                state.editPendingDrafts = []
                            }
                        )
                    }
                    .alert(
                        "Generation Error",
                        isPresented: Binding(
                            get: { state.editErrorMessage != nil },
                            set: { if !$0 { state.editErrorMessage = nil } }
                        ),
                        actions: { Button("OK") { state.editErrorMessage = nil } },
                        message: { Text(state.editErrorMessage ?? "") }
                    )
            }
        }
        .onAppear {
            store.refreshGeneratedBackgroundLibraryIfNeededInBackground()
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            // MARK: Left Sidebar
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ALL IMAGES",
                        title: "Sources",
                        subtitle: state.cachedAllRecords.isEmpty
                            ? "No images yet"
                            : "\(state.cachedAllRecords.count) total"
                    ) {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = false
                            }
                        }
                    }
                } content: {
                    AllProjectImagesSidebarView(store: store, state: state)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            // MARK: Center Pane (header + grid)
            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    if !sidebarVisible {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = true
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ALL IMAGES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(centerPaneTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(centerPaneSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    if !inspectorVisible {
                        OperaChromeActionButton(systemImage: "sidebar.right") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = true
                            }
                        }
                    }
                }
            } content: {
                AllProjectImagesPageView(store: store, state: state)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Right Inspector
            if inspectorVisible {
                // Raise the split handle on top of everything so the
                // inspector's ScrollView + the picture view below it can't
                // shadow the 10px-wide gesture zone (that's how this handle
                // went invisible once a record was selected — the ScrollView
                // drawn inside the inspector pane registered hover/hit
                // regions a few pixels into the handle's strip).
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )
                .zIndex(2)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "All Images"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    AllProjectImagesInspectorView(store: store, state: state)
                }
                .frame(width: max(inspectorWidth, 280))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
        // Preflight + alerts live on `body` (not here), with an explicit
        // @Bindable shadow of `state`, so `$state.editPendingPreflight`
        // actually triggers the sheet. See comment in `body`.
    }

    private var centerPaneTitle: String {
        state.selectedSource?.displayName ?? "All Images"
    }

    private var centerPaneSubtitle: String {
        let shown = state.filteredRecords.count
        let total = state.cachedAllRecords.count
        if total == 0 { return "No images indexed" }
        if shown == total { return "\(total) image\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total)"
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        // Anchor off the larger of the persisted value or the clamp floor
        // before subtracting the delta. Without this, a previously saved
        // width below 280 would stay stuck at 280 visually but drift under
        // the hood, making drags feel unresponsive until you pulled enough
        // pixels to overcome the accumulated offset.
        let anchor = max(inspectorWidth, 280.0)
        inspectorWidth = min(max(anchor - Double(delta), 280.0), 600.0)
    }

    // MARK: - Generate pipeline (lives at workspace root so both the grid's
    // context-menu "Generate with Gemini" and the inspector's "Edit with
    // Gemini" surface flow through the same sheet + activity tracker).

    private func runEditGeneration(
        _ drafts: [GeminiGenerationDraft],
        sourceRecord: ProjectImageRecord?
    ) {
        guard store.isGeminiAllowed() else {
            state.editErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }
        Task { @MainActor in
            let service = GeminiImageService()
            var finishedCount = 0
            for draft in drafts {
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: draft.title,
                    source: "All Images • Edit with Gemini"
                )
                let refs: [GeminiImageService.ReferenceImage] = draft.referenceItems
                    .filter(\.isIncluded)
                    .compactMap { ref in
                        let url = store.resolvedCharacterAssetURL(for: ref.path)
                            ?? (ref.path.hasPrefix("/") ? URL(fileURLWithPath: ref.path) : nil)
                        guard let url else { return nil }
                        return GeminiImageService.referenceImage(from: url)
                    }
                let request = GeminiImageService.GenerationRequest(
                    prompt: draft.effectivePrompt,
                    referenceImages: refs,
                    model: draft.model,
                    aspectRatio: draft.aspectRatio,
                    imageSize: draft.imageSize
                )
                store.logGeminiAPICall(
                    endpoint: "image-generation",
                    source: "AllProjectImagesWorkspace.runEditGeneration()"
                )
                do {
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    let storedPath = try store.storeUnattachedGeneratedImage(
                        imageData: result.imageData,
                        prompt: draft.effectivePrompt,
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
                    )
                    store.updateGeminiActivity(
                        activityID,
                        status: .completed,
                        outputFilename: URL(fileURLWithPath: storedPath).lastPathComponent
                    )
                    finishedCount += 1
                } catch {
                    store.updateGeminiActivity(
                        activityID,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    state.editErrorMessage = error.localizedDescription
                    break
                }
            }
            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) edited image\(finishedCount == 1 ? "" : "s")"
                state.editAdjustments = ""
            }
            _ = sourceRecord // reserved for future routing (filing back to origin place)
            state.editPendingDrafts = []
        }
    }
}

// MARK: - Left Sidebar (source filter)

@available(macOS 26.0, *)
private struct AllProjectImagesSidebarView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        List {
            Section {
                sidebarRow(
                    title: "All",
                    systemImage: "photo.on.rectangle.angled",
                    count: state.cachedAllRecords.count,
                    isSelected: state.selectedSource == nil
                ) {
                    state.selectedSource = nil
                }
            }

            Section("Sources") {
                ForEach(AllProjectImagesSource.allCases) { source in
                    sidebarRow(
                        title: source.displayName,
                        systemImage: source.systemImage,
                        count: state.count(for: source),
                        isSelected: state.selectedSource == source
                    ) {
                        state.selectedSource = source
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }
}

// MARK: - Right Inspector (Details | Edit with Gemini)

@available(macOS 26.0, *)
private struct AllProjectImagesInspectorView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        VStack(spacing: 0) {
            SharedInspectorTabBar(selection: $state.inspectorTab, items: [
                SharedInspectorTabItem(value: .details, title: "Details", systemImage: "info.circle"),
                SharedInspectorTabItem(value: .generate, title: "Edit with Gemini", systemImage: "sparkles")
            ])

            Divider()

            switch state.inspectorTab {
            case .details:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        UnifiedDetailsInspectorSection(
                            selection: AllProjectImageSelection(
                                store: store,
                                record: state.selectedRecord,
                                onSetRating: { newRating in
                                    guard let record = state.selectedRecord else { return }
                                    let updated = persistReviewUpdate(
                                        store: store,
                                        record: record,
                                        rating: newRating,
                                        isRejected: record.isRejected,
                                        notes: record.notes
                                    )
                                    state.updateReviewMetadata(
                                        for: record.id,
                                        rating: updated.rating,
                                        isRejected: updated.isRejected,
                                        notes: updated.notes
                                    )
                                },
                                onToggleRejected: {
                                    guard let record = state.selectedRecord else { return }
                                    let updated = persistReviewUpdate(
                                        store: store,
                                        record: record,
                                        rating: record.rating,
                                        isRejected: !record.isRejected,
                                        notes: record.notes
                                    )
                                    state.updateReviewMetadata(
                                        for: record.id,
                                        rating: updated.rating,
                                        isRejected: updated.isRejected,
                                        notes: updated.notes
                                    )
                                },
                                onSetNotes: { newNotes in
                                    guard let record = state.selectedRecord else { return }
                                    let updated = persistReviewUpdate(
                                        store: store,
                                        record: record,
                                        rating: record.rating,
                                        isRejected: record.isRejected,
                                        notes: newNotes
                                    )
                                    state.updateReviewMetadata(
                                        for: record.id,
                                        rating: updated.rating,
                                        isRejected: updated.isRejected,
                                        notes: updated.notes
                                    )
                                }
                            )
                        ) {
                            ProjectImageFileActionsSection(record: state.selectedRecord)
                        }
                    }
                    .padding()
                }
            case .generate:
                if let record = state.selectedRecord {
                    generateTab(for: record)
                } else {
                    emptyGenerateState
                }
            }
        }
    }

    // MARK: Generate tab

    @ViewBuilder
    private func generateTab(for record: ProjectImageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CachedThumbnailView(path: record.resolvedPath, size: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Uses this image as the reference; output lands in Places → Unattached where you can re-file it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Adjustments")
                        .font(.system(size: 11, weight: .medium))
                    TextEditor(text: $state.editAdjustments)
                        .font(.system(size: 11))
                        .frame(minHeight: 80, maxHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editModel) {
                            ForEach(GeminiModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aspect").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editAspectRatio) {
                            ForEach(["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editImageSize) {
                            ForEach(["1K", "2K", "4K"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Button {
                    openPreflight(for: record)
                } label: {
                    Label("Open Preflight…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
    }

    private var emptyGenerateState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 30))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text("No image selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textSecondary)
            Text("Select an image to open Gemini edit preflight from this tab.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Preflight trigger (Edit-with-Gemini tab button)

    private func openPreflight(for record: ProjectImageRecord) {
        let adjustments = state.editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adjustments.isEmpty else { return }
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
            editInstructions: adjustments
        )
        state.editPendingDrafts = [draft]
        state.editPendingPreflight = draft
    }

}

@available(macOS 26.0, *)
private struct ProjectImageFileActionsSection: View {
    let record: ProjectImageRecord?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 8) {
                Text("File")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: record.resolvedPath)]
                        )
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.resolvedPath, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

@available(macOS 26.0, *)
@MainActor
enum AllProjectImageReviewPersistenceContext {
    case generatedBackground(recordID: UUID)
    case characterInspiration(characterID: UUID, path: String)
    case place(placeID: UUID, path: String)
    case generic
}

@available(macOS 26.0, *)
@MainActor
func allProjectImageReviewContext(store: AnimateStore, record: ProjectImageRecord) -> AllProjectImageReviewPersistenceContext {
    let candidates = Array(Set([record.path, record.resolvedPath].filter { !$0.isEmpty }))
    if let generated = store.generatedBackgroundRecord(for: record.path) ?? store.generatedBackgroundRecord(for: record.resolvedPath) {
        return .generatedBackground(recordID: generated.id)
    }
    for character in store.characters {
        if let match = character.inspirationImagePaths.first(where: { candidates.contains($0) }) {
            return .characterInspiration(characterID: character.id, path: match)
        }
    }
    for place in store.backgrounds {
        if let match = (place.imagePaths + place.animatedImagePaths).first(where: { candidates.contains($0) }) {
            return .place(placeID: place.id, path: match)
        }
    }
    return .generic
}

@available(macOS 26.0, *)
@discardableResult
@MainActor
func persistReviewUpdate(
    store: AnimateStore,
    record: ProjectImageRecord,
    rating: Int?,
    isRejected: Bool,
    notes: String
) -> ImageLibraryReviewMetadata {
    switch allProjectImageReviewContext(store: store, record: record) {
    case .generatedBackground(let recordID):
        store.setGeneratedBackgroundRating(rating, for: recordID)
        if let generated = store.generatedBackgroundRecord(for: record.path) ?? store.generatedBackgroundRecord(for: record.resolvedPath),
           generated.isRejected != isRejected {
            store.toggleGeneratedBackgroundRejected(recordID)
        }
        store.updateGeneratedBackgroundEditNotes(notes, for: recordID)
    case .characterInspiration(let characterID, let path):
        store.setInspirationRating(rating, path: path, for: characterID)
        if let character = store.characters.first(where: { $0.id == characterID }),
           character.inspirationRejectedPaths.contains(path) != isRejected {
            store.toggleInspirationRejected(path: path, for: characterID)
        }
        store.updateInspirationNotes(notes, path: path, for: characterID)
    case .place(let placeID, let path):
        store.setPlaceImageRating(path: path, rating: rating ?? 0, placeID: placeID)
    case .generic:
        break
    }

    let metadata = ImageLibraryReviewMetadata(
        rating: rating,
        isRejected: isRejected,
        notes: notes,
        updatedAt: Date()
    )
    ImageLibraryMetadataSidecarService.save(metadata, forImagePath: record.resolvedPath)
    return metadata
}

@available(macOS 26.0, *)
private struct AllProjectImageSelection: DetailedImageSelection {
    let store: AnimateStore
    let record: ProjectImageRecord?
    let onSetRating: (Int?) -> Void
    let onToggleRejected: () -> Void
    let onSetNotes: (String) -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func candidatePaths(for record: ProjectImageRecord) -> [String] {
        Array(Set([record.path, record.resolvedPath].filter { !$0.isEmpty }))
    }

    private var placeRecord: GeneratedBackgroundLibraryRecord? {
        guard let record else { return nil }
        return store.generatedBackgroundRecord(for: record.path)
            ?? store.generatedBackgroundRecord(for: record.resolvedPath)
    }

    private var characterContext: (characterID: UUID, characterName: String, kind: String, path: String, supportsCuration: Bool)? {
        guard let record, record.source == .characters else { return nil }
        let candidates = candidatePaths(for: record)
        for character in store.characters {
            if let match = character.inspirationImagePaths.first(where: { candidates.contains($0) }) {
                return (character.id, character.name, "Inspiration", match, true)
            }
            if let match = character.referenceImagePaths.first(where: { candidates.contains($0) }) {
                return (character.id, character.name, "Reference", match, false)
            }
            if let match = character.animatedImagePaths.first(where: { candidates.contains($0) }) {
                return (character.id, character.name, "Animated", match, false)
            }
        }
        return nil
    }

    var imageURL: URL? {
        guard let record else { return nil }
        return URL(fileURLWithPath: record.resolvedPath)
    }

    var title: String {
        guard let record else { return "" }
        return URL(fileURLWithPath: record.resolvedPath).lastPathComponent
    }

    var subtitle: String? {
        guard let record else { return nil }
        return record.originLabel
    }

    var rating: Int? {
        record?.rating
    }

    var isRejected: Bool {
        record?.isRejected ?? false
    }

    var notes: String {
        record?.notes ?? ""
    }

    var supportsRating: Bool {
        record?.supportsLibraryCuration == true
    }

    var supportsNotes: Bool {
        record?.supportsLibraryCuration == true
    }

    var metadataRows: [(label: String, value: String)] {
        guard let record else { return [] }
        var rows: [(label: String, value: String)] = [
            ("Source", record.source.displayName),
            ("Origin", record.originLabel)
        ]

        if let placeRecord {
            rows.append(("Workflow", placeRecord.workflow.displayName))
            if !placeRecord.keywords.isEmpty {
                rows.append(("Keywords", placeRecord.keywords.joined(separator: ", ")))
            }
        } else if let characterContext {
            rows.append(("Character", characterContext.characterName))
            rows.append(("Image Type", characterContext.kind))
        }

        if let metadata = store.generationMetadata(for: record.path) ?? store.generationMetadata(for: record.resolvedPath) {
            if !metadata.model.isEmpty {
                rows.append(("Model", metadata.model))
            }
            let sizing = [metadata.imageSize, metadata.aspectRatio].filter { !$0.isEmpty }.joined(separator: " • ")
            if !sizing.isEmpty {
                rows.append(("Generation", sizing))
            }
            if !metadata.prompt.isEmpty {
                rows.append(("Prompt", metadata.prompt))
            }
        }

        if let resolution = store.imageResolutionDescription(for: record.path), !resolution.isEmpty {
            rows.append(("Resolution", resolution))
        } else if let resolution = store.imageResolutionDescription(for: record.resolvedPath), !resolution.isEmpty {
            rows.append(("Resolution", resolution))
        }

        if let createdAt = record.createdAt {
            rows.append(("Created", createdAt.formatted(date: .abbreviated, time: .shortened)))
        }
        if let sizeBytes = record.sizeBytes {
            rows.append(("Size", Self.byteFormatter.string(fromByteCount: sizeBytes)))
        }
        rows.append(("Path", record.path))
        return rows
    }

    var emptyStateMessage: String {
        "Click a thumbnail to see details or right-click to edit with Gemini."
    }

    func setRating(_ newValue: Int?) {
        onSetRating(newValue)
    }

    func toggleRejected() {
        onToggleRejected()
    }

    func setNotes(_ newValue: String) {
        onSetNotes(newValue)
    }
}
