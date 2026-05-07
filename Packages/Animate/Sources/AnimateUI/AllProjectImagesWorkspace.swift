import AppKit
import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
enum ImageLibrarySemanticRole: String, CaseIterable, Codable, Sendable, Hashable {
    case place
    case character

    var displayName: String {
        switch self {
        case .place: return "Place"
        case .character: return "Character"
        }
    }
}


@available(macOS 26.0, *)
enum ImageSemanticRoleInference {
    nonisolated static func role(from metadata: ImageVisualMetadataRecord?) -> ImageLibrarySemanticRole? {
        guard let metadata else { return nil }
        let text = [
            metadata.summary,
            metadata.shortCaption,
            metadata.longCaption,
            metadata.assetRolesJSON,
            metadata.entitiesJSON,
            metadata.sceneJSON,
            metadata.retrievalJSON,
            metadata.rawModelJSON
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let characterTerms = [
            "character", "person", "people", "human", "man", "woman", "boy", "girl",
            "portrait", "face", "head", "body", "turnaround", "model sheet", "character sheet",
            "costume", "clothing", "uniform", "soldier", "figure"
        ]
        let placeTerms = [
            "place", "map", "terrain", "topography", "town", "village", "city", "landscape",
            "river", "bridge", "road", "street", "building", "architecture", "mountain", "valley", "ravine"
        ]
        let characterScore = characterTerms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        let placeScore = placeTerms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        if characterScore >= placeScore + 2 { return .character }
        if placeScore >= characterScore + 2 { return .place }
        return nil
    }
}

@available(macOS 26.0, *)
struct ImageLibraryReviewMetadata: Equatable, Sendable {
    var rating: Int?
    var isRejected: Bool
    var isLiked: Bool
    var notes: String
    var updatedAt: Date?
    var characterTags: [String]
    var visualStyle: ImageLibraryVisualStyle?
    var semanticRole: ImageLibrarySemanticRole?

    init(
        rating: Int?,
        isRejected: Bool,
        isLiked: Bool = false,
        notes: String,
        updatedAt: Date?,
        characterTags: [String] = [],
        visualStyle: ImageLibraryVisualStyle? = nil,
        semanticRole: ImageLibrarySemanticRole? = nil
    ) {
        self.rating = rating
        self.isRejected = isRejected
        self.isLiked = isLiked
        self.notes = notes
        self.updatedAt = updatedAt
        self.characterTags = characterTags
        self.visualStyle = visualStyle
        self.semanticRole = semanticRole
    }

    var isEmpty: Bool {
        rating == nil
            && !isRejected
            && !isLiked
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && characterTags.isEmpty
            && visualStyle == nil
            && semanticRole == nil
    }
}

@available(macOS 26.0, *)
enum ImageLibraryVisualStyle: String, CaseIterable, Codable, Sendable {
    case realistic
    case animated

    var displayName: String {
        switch self {
        case .realistic: return "Realistic"
        case .animated: return "Animated"
        }
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
        let isLiked = extractTagValue("IsLiked", from: xml)
            .map { ["true", "1", "yes"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? false
        let notes = extractTagValue("Notes", from: xml).map(unescapeXML) ?? ""
        let updatedAt = extractTagValue("UpdatedAt", from: xml).flatMap { iso8601Formatter().date(from: $0) }
        let characterTags = extractTagValues("Character", from: xml)
            .map(unescapeXML)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let visualStyle = extractTagValue("VisualStyle", from: xml)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(ImageLibraryVisualStyle.init(rawValue:))
        let semanticRole = extractTagValue("SemanticRole", from: xml)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(ImageLibrarySemanticRole.init(rawValue:))

        let metadata = ImageLibraryReviewMetadata(
            rating: rating.map { min(max($0, 1), 5) },
            isRejected: isRejected,
            isLiked: isRejected ? false : isLiked,
            notes: notes,
            updatedAt: updatedAt,
            characterTags: Array(Set(characterTags)).sorted(),
            visualStyle: visualStyle,
            semanticRole: semanticRole
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
              <amira:IsLiked>\((metadata.isLiked && !metadata.isRejected) ? "true" : "false")</amira:IsLiked>
              <amira:Notes>\(escapeXML(metadata.notes))</amira:Notes>
              \(metadata.visualStyle.map { "<amira:VisualStyle>\($0.rawValue)</amira:VisualStyle>" } ?? "")
              \(metadata.semanticRole.map { "<amira:SemanticRole>\($0.rawValue)</amira:SemanticRole>" } ?? "")
              \(metadata.characterTags.map { "<amira:Character>\(escapeXML($0))</amira:Character>" }.joined(separator: "\n              "))
              <amira:UpdatedAt>\(iso8601Formatter().string(from: metadata.updatedAt ?? Date()))</amira:UpdatedAt>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        try? xml.data(using: .utf8)?.write(to: sidecarURL, options: .atomic)
    }

    static func saveAsync(_ metadata: ImageLibraryReviewMetadata, forImagePath imagePath: String) {
        Task.detached(priority: .utility) {
            await ImageLibraryMetadataSidecarWriteQueue.shared.save(metadata, forImagePath: imagePath)
        }
    }

    static func sidecarURL(forImagePath imagePath: String) -> URL {
        URL(fileURLWithPath: imagePath).deletingPathExtension().appendingPathExtension("xmp")
    }

    // Pre-compiled regex patterns keyed by tag name — avoids recompiling on every call.
    private static let tagRegexes: [String: NSRegularExpression] = {
        let tags = ["Rating", "IsRejected", "IsLiked", "Notes", "UpdatedAt", "Character", "VisualStyle", "SemanticRole"]
        var dict: [String: NSRegularExpression] = [:]
        for tag in tags {
            let pattern = "<(?:[A-Za-z0-9_\\-]+:)?\(tag)>(.*?)</(?:[A-Za-z0-9_\\-]+:)?\(tag)>"
            dict[tag] = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        }
        return dict
    }()

    private static func extractTagValues(_ tag: String, from xml: String) -> [String] {
        guard let regex = tagRegexes[tag] else { return [] }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }
    }

    private static func extractTagValue(_ tagName: String, from xml: String) -> String? {
        guard let regex = tagRegexes[tagName] else { return nil }
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

    nonisolated(unsafe) private static let sharedISO8601Formatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static func iso8601Formatter() -> ISO8601DateFormatter {
        sharedISO8601Formatter
    }
}

@available(macOS 26.0, *)
private actor ImageLibraryMetadataSidecarWriteQueue {
    static let shared = ImageLibraryMetadataSidecarWriteQueue()

    func save(_ metadata: ImageLibraryReviewMetadata, forImagePath imagePath: String) {
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: imagePath)
    }
}

// MARK: - Shared State (observable across the 3 panes)

/// Dedicated observable container for the Gemini "Edit Image" binding surface.
/// Split out from `AllProjectImagesState` (Phase 4.1 of the perf plan) so that
/// typing in the adjustments TextEditor — or toggling aspect-ratio / model —
/// can't invalidate observers that only care about records, filter, or
/// selection state.
@available(macOS 26.0, *)
@Observable @MainActor
final class AllProjectImagesEditState {
    private static let aspectRatioKey = "amira.editGemini.aspectRatio.v1"
    private static let imageSizeKey = "amira.editGemini.imageSize.v1"

    var adjustments: String = ""
    var model: GeminiModel = .flash
    var aspectRatio: String = UserDefaults.standard.string(forKey: aspectRatioKey) ?? "1:1" {
        didSet { UserDefaults.standard.set(aspectRatio, forKey: Self.aspectRatioKey) }
    }
    var imageSize: String = UserDefaults.standard.string(forKey: imageSizeKey) ?? "1K" {
        didSet { UserDefaults.standard.set(imageSize, forKey: Self.imageSizeKey) }
    }
    var pendingDrafts: [GeminiGenerationDraft] = []
    var pendingPreflight: GeminiGenerationDraft? = nil
    var errorMessage: String? = nil
}

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

    private struct RecordBuildContext: Equatable, Sendable {
        let projectURL: URL?
        let animateURL: URL?
    }

    private struct RecordSeed: Equatable, Sendable {
        let id: String
        let path: String
        let source: AllProjectImagesSource
        let semanticRole: ImageLibrarySemanticRole?
        let originLabel: String
        let groupLabel: String
        let sceneID: UUID?
        let shotID: UUID?
        let rating: Int?
        let isRejected: Bool
        let isLiked: Bool
        let notes: String
        let supportsLibraryCuration: Bool
    }

    private struct FilterCacheKey: Hashable {
        let buildSignature: Int
        let selectedSource: AllProjectImagesSource?
        let selectedGroupLabel: String?
        let selectedSceneID: UUID?
        let selectedShotID: UUID?
        let searchText: String
        let sortMode: AllProjectImagesSortMode
        let flagFilter: AllProjectImagesFlagFilter
        let minimumRating: Int?
    }

    private struct PrefetchSignatureCacheKey: Hashable {
        let filterCacheKey: FilterCacheKey?
        let contentRevision: Int
        let roundedThumbnailSize: Int
        let limit: Int
    }

    // Filter / selection
    var selectedSource: AllProjectImagesSource? = nil {
        didSet {
            if oldValue != selectedSource {
                selectedGroupLabel = nil
                if selectedSource != .sceneShots {
                    selectedSceneID = nil
                    selectedShotID = nil
                }
            }
        }
    }
    var selectedGroupLabel: String? = nil
    var selectedSceneID: UUID? = nil {
        didSet {
            if selectedSceneID != oldValue {
                selectedShotID = nil
            }
        }
    }
    var selectedShotID: UUID? = nil
    var selectedRecordID: String? = nil {
        didSet {
            if selectedRecordID != oldValue {
                PerfSignposts.event(.inspectorSelection, "id=\(selectedRecordID ?? "nil")")
            }
            if let selectedRecordID, !selectedRecordIDs.contains(selectedRecordID) {
                selectedRecordIDs.insert(selectedRecordID)
                lastSelectedRecordID = selectedRecordID
            }
        }
    }
    var selectedRecordIDs: Set<String> = []
    var lastSelectedRecordID: String? = nil
    var sortMode: AllProjectImagesSortMode = .newest
    var thumbnailSize: CGFloat = 140
    var searchText: String = ""
    var inspectorTab: AllProjectImagesInspectorTab = .details
    var flagFilter: AllProjectImagesFlagFilter = .all
    var minimumRating: Int? = nil

    // Edit-with-Gemini state — extracted into its own @Observable holder so
    // keystrokes in the adjustments editor don't trip observers that only care
    // about records / filter / selection.
    // Declared `var` so SwiftUI dynamic-member bindings like `$state.edit.adjustments`
    // resolve (bindings need a writable path even though the instance itself is stable).
    var edit = AllProjectImagesEditState()

    // Memoized record set (rebuilt only when the path signature changes).
    var cachedAllRecords: [ProjectImageRecord] = []
    var lastBuildSignature: Int = -1
    var isRebuilding: Bool = false
    private var pendingBuildSignature: Int = -1
    @ObservationIgnored private var seedsByID: [String: RecordSeed] = [:]
    @ObservationIgnored private var recordsByID: [String: ProjectImageRecord] = [:]
    @ObservationIgnored private var countsBySource: [AllProjectImagesSource: Int] = [:]
    @ObservationIgnored private var countsBySourceAndGroupLabel: [AllProjectImagesSource: [String: Int]] = [:]
    @ObservationIgnored private var groupLabelsBySource: [AllProjectImagesSource: [String]] = [:]
    @ObservationIgnored private var allGroupLabels: [String] = []
    @ObservationIgnored private var countsBySceneID: [UUID: Int] = [:]
    @ObservationIgnored private var countsByShotID: [UUID: Int] = [:]
    @ObservationIgnored private var fileMetadataCache: [String: CachedFileMetadata] = [:]
    @ObservationIgnored private var filteredCacheKey: FilterCacheKey?
    @ObservationIgnored private var filteredCacheRecords: [ProjectImageRecord] = []
    @ObservationIgnored private var filteredRecordsByID: [String: ProjectImageRecord] = [:]
    @ObservationIgnored private var contentRevision: Int = 0
    @ObservationIgnored private var prefetchSignatureCache: [PrefetchSignatureCacheKey: String] = [:]
    @ObservationIgnored private var rebuildRequestID: Int = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastProjectPath: String?
    @ObservationIgnored private var characterRecoveryProjectPath: String?
    @ObservationIgnored private var characterRecoveryTask: Task<Void, Never>?

    // MARK: - Aggregation

    /// Lightweight hash of every path collection's `.count`. Used as `.task(id:)`
    /// so we only rebuild `cachedAllRecords` — which does per-record FileManager
    /// syscalls — when the set of paths actually changed. Typing in the search
    /// field does NOT change this, so no rebuild, no beachball.
    func recordsSignature(store: AnimateStore) -> Int {
        var h = 1469598103934665603 & Int.max
        func mix(_ v: Int) { h = (h ^ v) &* 1099511628211 }
        func mixString(_ value: String) {
            for scalar in value.unicodeScalars {
                mix(Int(scalar.value))
            }
        }
        for p in store.backgrounds {
            mixString(p.name)
            mix(p.imagePaths.count)
            mix(p.animatedImagePaths.count &<< 3)
        }
        for profile in store.placesWorkflowLibrary.landmarkProfiles {
            mixString(profile.title)
            mix(profile.primaryImagePath == nil ? 0 : 1)
            mix((profile.exteriorImagePath == nil ? 0 : 1) &<< 1)
            mix((profile.interiorImagePath == nil ? 0 : 1) &<< 2)
            mix(profile.galleryImagePaths.count &<< 3)
        }
        mix(store.canvasGenerations.count &<< 7)
        mix(store.placesWorkflowLibrary.generatedImageRecords.count &<< 11)
        for c in store.characters {
            mixString(c.name)
            mix(c.profileImagePath == nil ? 0 : 1)
            mix(c.inspirationImagePaths.count)
            mix((c.inspirationReferenceImagePath == nil ? 0 : 1) &<< 1)
            mix(c.referenceImagePaths.count &<< 2)
            mix(c.animatedImagePaths.count &<< 4)
            mix(c.masterReferenceSourceImagePaths.count &<< 6)
            mix(c.masterReferenceSheetVariants.count &<< 8)
            mix(c.headTurnaroundSheetVariants.count &<< 10)
            mix(c.lookDevelopmentSlots.reduce(0) { $0 + $1.variants.count } &<< 12)
            mix(c.headTurnaroundSlots.reduce(0) { $0 + $1.variants.count } &<< 14)
            mix(c.costumeReferenceSets.count &<< 16)
            mix(c.costumeReferenceSets.reduce(0) { $0 + $1.sheetVariants.count } &<< 18)
            mix(c.costumeReferenceSets.reduce(0) { $0 + $1.fullBodySlots.reduce(0) { $0 + $1.variants.count } } &<< 20)
            mix(c.costumeReferenceSets.reduce(0) { $0 + $1.accessorySlots.reduce(0) { $0 + $1.variants.count } } &<< 22)
            mix(c.costumeReferenceSets.reduce(0) { $0 + $1.costumeReferenceImagePaths.count } &<< 24)
            mix(c.costumeReferenceSets.reduce(0) { $0 + $1.generatedVariationImagePaths.count } &<< 26)
        }
        for item in store.imageLibraryOrganizeItems {
            mixString(item.category.rawValue)
            mixString(item.id.uuidString)
            mixString(item.title)
            mix(item.imagePaths.count &<< 4)
            mix(Int(item.updatedAt.timeIntervalSinceReferenceDate.rounded(.towardZero)) &<< 6)
        }
        for scene in store.scenes {
            mixString(scene.name)
            mix(scene.shots.count &<< 5)
            for shot in scene.shots {
                mixString(shot.name)
            }
            for g in store.imagineSceneGalleries[scene.id] ?? [] {
                mix(g.beginningImagePaths.count)
                mix(g.middleImagePaths.count &<< 2)
                mix(g.endImagePaths.count &<< 4)
            }
        }
        mix(store.allImagesContentRevision &<< 28)
        return h
    }

    /// Cheap body-safe trigger for the All Images rebuild task.
    /// This intentionally avoids walking every image path / name on each
    /// render; the expensive full signature check still happens inside
    /// `requestRebuildIfNeeded(store:)`.
    func recordsRefreshKey(store: AnimateStore) -> Int {
        var h = 1469598103934665603 & Int.max
        func mix(_ v: Int) { h = (h ^ v) &* 1099511628211 }
        func mixString(_ value: String?) {
            guard let value else { return }
            for scalar in value.unicodeScalars {
                mix(Int(scalar.value))
            }
        }

        mixString(store.owpURL?.standardizedFileURL.path)
        mix(store.allImagesContentRevision)
        return h
    }

    func requestRebuildIfNeeded(store: AnimateStore) {
        rebuildTask?.cancel()
        rebuildRequestID &+= 1
        let requestID = rebuildRequestID
        if cachedAllRecords.isEmpty {
            isRebuilding = true
        }

        rebuildTask = Task { [weak self, weak store] in
            await Task.yield()
            guard let self, let store else {
                return
            }
            if self.cachedAllRecords.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
            } else {
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard requestID == self.rebuildRequestID else {
                return
            }
            let sig = self.recordsSignature(store: store)
            let projectPath = store.owpURL?.standardizedFileURL.path
            let isSameProject = projectPath == self.lastProjectPath
            if isSameProject && (sig == self.lastBuildSignature || sig == self.pendingBuildSignature) {
                self.isRebuilding = false
                self.pendingBuildSignature = -1
                self.rebuildTask = nil
                return
            }

            let rebuildSignpost = PerfSignposts.begin(
                .allImagesRebuild,
                "sig=\(sig) sameProject=\(isSameProject)"
            )
            self.pendingBuildSignature = sig
            let seeds = self.buildRecordSeeds(store: store)
            let previousSeedsByID = isSameProject ? self.seedsByID : [:]
            let previousRecordsByID = isSameProject ? self.recordsByID : [:]
            let metadataCache = isSameProject ? self.fileMetadataCache : [:]
            let buildContext = RecordBuildContext(
                projectURL: store.fileOWPURL,
                animateURL: store.animateURL
            )
            let rebuiltSeedsByID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0) })
            let rebuiltRecords = await Task.detached(priority: .utility) {
                Self.buildRecordsIncrementally(
                    from: seeds,
                    context: buildContext,
                    previousSeedsByID: previousSeedsByID,
                    previousRecordsByID: previousRecordsByID,
                    metadataCache: metadataCache
                )
            }.value
            guard !Task.isCancelled else {
                self.isRebuilding = false
                PerfSignposts.end(.allImagesRebuild, token: rebuildSignpost)
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      requestID == self.rebuildRequestID else {
                    PerfSignposts.end(.allImagesRebuild, token: rebuildSignpost)
                    return
                }
                self.applyRebuiltRecords(
                    rebuiltRecords,
                    seedsByID: rebuiltSeedsByID,
                    signature: sig,
                    projectPath: projectPath,
                    store: store
                )
                self.pendingBuildSignature = -1
                self.rebuildTask = nil
                self.isRebuilding = false
                PerfSignposts.end(.allImagesRebuild, token: rebuildSignpost)
            }
        }
    }

    func requestCharacterRecoveryIfNeeded(store: AnimateStore) {
        guard let projectPath = store.owpURL?.standardizedFileURL.path else { return }
        guard characterRecoveryProjectPath != projectPath else { return }
        characterRecoveryProjectPath = projectPath
        characterRecoveryTask?.cancel()
        characterRecoveryTask = Task { [weak store] in
            await store?.recoverMissingPersistedCharactersIfNeededAsync()
        }
    }

    private func applyRebuiltRecords(
        _ rebuiltRecords: [ProjectImageRecord],
        seedsByID rebuiltSeedsByID: [String: RecordSeed],
        signature: Int,
        projectPath: String?,
        store: AnimateStore
    ) {
        cachedAllRecords = rebuiltRecords
        seedsByID = rebuiltSeedsByID
        recordsByID = rebuiltRecords.reduce(into: [:]) { partialResult, record in
            partialResult[record.id] = record
        }
        rebuildAggregationCaches(from: rebuiltRecords)
        lastBuildSignature = signature
        lastProjectPath = projectPath
        contentRevision &+= 1
        filteredCacheKey = nil
        filteredCacheRecords = []
        filteredRecordsByID = [:]
        prefetchSignatureCache.removeAll(keepingCapacity: true)
        let rebuiltMetadata = rebuiltRecords.reduce(into: [String: CachedFileMetadata]()) { partialResult, record in
            guard !record.resolvedPath.isEmpty else { return }
            partialResult[record.resolvedPath] = CachedFileMetadata(
                createdAt: record.createdAt,
                sizeBytes: record.sizeBytes
            )
        }
        fileMetadataCache.merge(
            rebuiltMetadata,
            uniquingKeysWith: { _, new in new }
        )
        if let selectedGroupLabel,
           !availableGroupLabels.contains(selectedGroupLabel) {
            self.selectedGroupLabel = nil
        }
        selectedRecordIDs = selectedRecordIDs.filter { recordsByID[$0] != nil }
        if let lastSelectedRecordID, recordsByID[lastSelectedRecordID] == nil {
            self.lastSelectedRecordID = nil
        }
        if let selectedRecordID, recordsByID[selectedRecordID] == nil {
            self.selectedRecordID = selectedRecordIDs.first
        }
        repairSemanticallyMisfiledMapCapturesIfNeeded(store: store)
    }

    private func repairSemanticallyMisfiledMapCapturesIfNeeded(store: AnimateStore) {
        let candidates = cachedAllRecords.filter { record in
            guard record.source == .map3dCaptures else { return false }
            guard ImageLibraryMetadataSidecarService.load(forImagePath: record.resolvedPath)?.semanticRole == nil else { return false }
            return true
        }
        guard !candidates.isEmpty else { return }

        Task { [weak self, weak store] in
            guard let self, let store else { return }
            var repaired = 0
            for record in candidates {
                guard !Task.isCancelled else { return }
                let analysis = await store.imageIntelligenceRecordAndMetadata(for: record.resolvedPath).metadata
                guard ImageSemanticRoleInference.role(from: analysis) == .character else { continue }
                var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: record.resolvedPath)
                    ?? ImageLibraryReviewMetadata(rating: record.rating, isRejected: record.isRejected, isLiked: record.isLiked, notes: record.notes, updatedAt: record.createdAt)
                metadata.semanticRole = .character
                metadata.updatedAt = Date()
                ImageLibraryMetadataSidecarService.save(metadata, forImagePath: record.resolvedPath)
                repaired += 1
            }
            if repaired > 0 {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.contentRevision &+= 1
                    self.lastBuildSignature = -1
                    self.filteredCacheKey = nil
                    self.filteredCacheRecords = []
                    self.filteredRecordsByID = [:]
                    self.prefetchSignatureCache.removeAll(keepingCapacity: true)
                    self.requestRebuildIfNeeded(store: store)
                }
            }
        }
    }

    func updateReviewMetadata(
        for recordID: String,
        rating: Int?,
        isRejected: Bool,
        isLiked: Bool? = nil,
        notes: String,
        semanticRole: ImageLibrarySemanticRole? = nil
    ) {
        guard let index = cachedAllRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let existing = cachedAllRecords[index]
        let resolvedSemanticRole = semanticRole ?? existing.semanticRole
        let resolvedIsLiked = isLiked ?? existing.isLiked
        let updated = ProjectImageRecord(
            id: cachedAllRecords[index].id,
            path: cachedAllRecords[index].path,
            resolvedPath: cachedAllRecords[index].resolvedPath,
            source: cachedAllRecords[index].source,
            semanticRole: resolvedSemanticRole,
            originLabel: cachedAllRecords[index].originLabel,
            groupLabel: cachedAllRecords[index].groupLabel,
            sceneID: cachedAllRecords[index].sceneID,
            shotID: cachedAllRecords[index].shotID,
            searchHaystack: Self.searchHaystack(
                path: cachedAllRecords[index].path,
                resolvedPath: cachedAllRecords[index].resolvedPath,
                source: cachedAllRecords[index].source,
                originLabel: cachedAllRecords[index].originLabel,
                groupLabel: cachedAllRecords[index].groupLabel,
                notes: notes
            ),
            createdAt: cachedAllRecords[index].createdAt,
            sizeBytes: cachedAllRecords[index].sizeBytes,
            rating: rating,
            isRejected: isRejected,
            isLiked: isRejected ? false : resolvedIsLiked,
            notes: notes,
            supportsLibraryCuration: cachedAllRecords[index].supportsLibraryCuration
        )
        cachedAllRecords[index] = updated
        recordsByID[updated.id] = updated
        if existing.source != updated.source || existing.groupLabel != updated.groupLabel {
            rebuildAggregationCaches(from: cachedAllRecords)
        }
        contentRevision &+= 1
        filteredCacheKey = nil
        filteredCacheRecords = []
        filteredRecordsByID = [:]
        prefetchSignatureCache.removeAll(keepingCapacity: true)
    }

    func updateSemanticRoleMetadata(
        for recordID: String,
        semanticRole: ImageLibrarySemanticRole?
    ) {
        guard let index = cachedAllRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let existing = cachedAllRecords[index]
        let updatedSource = Self.sourceAfterRecategorization(
            recordID: existing.id,
            originalSource: existing.source,
            semanticRole: semanticRole
        )
        let updated = ProjectImageRecord(
            id: existing.id,
            path: existing.path,
            resolvedPath: existing.resolvedPath,
            source: updatedSource,
            semanticRole: semanticRole,
            originLabel: existing.originLabel,
            groupLabel: existing.groupLabel,
            sceneID: existing.sceneID,
            shotID: existing.shotID,
            searchHaystack: Self.searchHaystack(
                path: existing.path,
                resolvedPath: existing.resolvedPath,
                source: updatedSource,
                originLabel: existing.originLabel,
                groupLabel: existing.groupLabel,
                notes: existing.notes
            ),
            createdAt: existing.createdAt,
            sizeBytes: existing.sizeBytes,
            rating: existing.rating,
            isRejected: existing.isRejected,
            isLiked: existing.isLiked,
            notes: existing.notes,
            supportsLibraryCuration: existing.supportsLibraryCuration
        )
        cachedAllRecords[index] = updated
        recordsByID[updated.id] = updated
        if existing.source != updated.source || existing.groupLabel != updated.groupLabel {
            rebuildAggregationCaches(from: cachedAllRecords)
        }
        contentRevision &+= 1
        filteredCacheKey = nil
        filteredCacheRecords = []
        filteredRecordsByID = [:]
        prefetchSignatureCache.removeAll(keepingCapacity: true)
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

            let dedupeKey = "\(record.source.rawValue)|\(record.path.trimmingCharacters(in: .whitespacesAndNewlines))"
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
                    groupLabel: place.name.isEmpty ? "Place" : place.name,
                    store: store
                ), dedupeByResolvedPath: true)
            }
            for path in place.animatedImagePaths {
                appendRecord(makeSeed(
                    id: "place-anim-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: "\(place.name) (animated)",
                    groupLabel: place.name.isEmpty ? "Place" : place.name,
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
                groupLabel: origin,
                rating: record.rating,
                isRejected: record.isRejected,
                notes: record.draftEditNotes,
                store: store
            ), dedupeByResolvedPath: true, preferNewRecord: !isMap3D)
        }

        for profile in store.placesWorkflowLibrary.landmarkProfiles {
            let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? profile.kind.displayName
                : profile.title
            var seenLandmarkPaths = Set<String>()

            func appendLandmarkSeed(rawPath: String?, role: String) {
                guard let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmedPath.isEmpty,
                      seenLandmarkPaths.insert(trimmedPath).inserted else { return }
                appendRecord(makeSeed(
                    id: "landmark-\(profile.id.uuidString)-\(role)-\(trimmedPath)",
                    path: trimmedPath,
                    source: .landmarks,
                    originLabel: "\(title) (\(role))",
                    groupLabel: title,
                    store: store
                ), dedupeByResolvedPath: true)
            }

            appendLandmarkSeed(rawPath: profile.primaryImagePath, role: "main")
            appendLandmarkSeed(rawPath: profile.exteriorImagePath, role: "exterior")
            appendLandmarkSeed(rawPath: profile.interiorImagePath, role: "interior")
            for path in profile.galleryImagePaths {
                appendLandmarkSeed(rawPath: path, role: "gallery")
            }
        }

        for gen in store.canvasGenerations {
            records.append(makeSeed(
                id: "canvas-\(gen.id.uuidString)",
                path: gen.imagePath,
                source: .canvas,
                originLabel: gen.prompt.isEmpty ? "Canvas generation" : String(gen.prompt.prefix(50)),
                groupLabel: "Canvas",
                store: store
            ))
        }

        for character in store.characters {
            let originBase = character.name.isEmpty ? "Character" : character.name

            func appendCharacterSeed(
                prefix: String,
                rawPath: String?,
                originSuffix: String,
                rating: Int? = nil,
                isRejected: Bool = false,
                notes: String = ""
            ) {
                guard let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmedPath.isEmpty else { return }
                appendRecord(makeSeed(
                    id: "\(prefix)-\(character.id.uuidString)-\(trimmedPath)",
                    path: trimmedPath,
                    source: .characters,
                    originLabel: "\(originBase) (\(originSuffix))",
                    groupLabel: originBase,
                    rating: rating,
                    isRejected: isRejected,
                    notes: notes,
                    store: store
                ), dedupeByResolvedPath: true)
            }

            appendCharacterSeed(prefix: "char-profile", rawPath: character.profileImagePath, originSuffix: "profile")
            appendCharacterSeed(prefix: "char-insp-ref", rawPath: character.inspirationReferenceImagePath, originSuffix: "reference anchor")

            for path in character.inspirationImagePaths {
                appendCharacterSeed(
                    prefix: "char-insp",
                    rawPath: path,
                    originSuffix: "inspiration",
                    rating: character.inspirationRatings?[path],
                    isRejected: character.inspirationRejectedPaths.contains(path),
                    notes: character.inspirationNotes?[path] ?? ""
                )
            }

            for path in character.referenceImagePaths {
                appendCharacterSeed(prefix: "char-ref", rawPath: path, originSuffix: "reference")
            }

            for path in character.animatedImagePaths {
                appendCharacterSeed(prefix: "char-anim", rawPath: path, originSuffix: "animated")
            }

            for path in character.masterReferenceSourceImagePaths {
                appendCharacterSeed(prefix: "char-master-source", rawPath: path, originSuffix: "master sheet source")
            }

            for variant in character.masterReferenceSheetVariants {
                appendCharacterSeed(prefix: "char-master-sheet", rawPath: variant.imagePath, originSuffix: "master sheet")
            }

            for variant in character.headTurnaroundSheetVariants {
                appendCharacterSeed(prefix: "char-head-sheet", rawPath: variant.imagePath, originSuffix: "head turnaround sheet")
            }

            for slot in character.lookDevelopmentSlots {
                for variant in slot.variants {
                    appendCharacterSeed(
                        prefix: "char-lookdev-\(slot.id.uuidString)",
                        rawPath: variant.imagePath,
                        originSuffix: slot.title
                    )
                }
            }

            for slot in character.headTurnaroundSlots {
                for variant in slot.variants {
                    appendCharacterSeed(
                        prefix: "char-headslot-\(slot.id.uuidString)",
                        rawPath: variant.imagePath,
                        originSuffix: slot.title
                    )
                }
            }

            for costume in character.costumeReferenceSets {
                for variant in costume.sheetVariants {
                    appendCharacterSeed(
                        prefix: "char-costume-sheet-\(costume.id.uuidString)",
                        rawPath: variant.imagePath,
                        originSuffix: "\(costume.name) sheet"
                    )
                }

                for slot in costume.fullBodySlots {
                    for variant in slot.variants {
                        appendCharacterSeed(
                            prefix: "char-costume-fullbody-\(costume.id.uuidString)-\(slot.id.uuidString)",
                            rawPath: variant.imagePath,
                            originSuffix: "\(costume.name) \(slot.title)"
                        )
                    }
                }

                for slot in costume.accessorySlots {
                    for variant in slot.variants {
                        appendCharacterSeed(
                            prefix: "char-costume-accessory-\(costume.id.uuidString)-\(slot.id.uuidString)",
                            rawPath: variant.imagePath,
                            originSuffix: "\(costume.name) \(slot.title)"
                        )
                    }
                }

                for path in costume.costumeReferenceImagePaths {
                    appendCharacterSeed(
                        prefix: "char-costume-ref-\(costume.id.uuidString)",
                        rawPath: path,
                        originSuffix: "\(costume.name) reference"
                    )
                }

                for path in costume.generatedVariationImagePaths {
                    appendCharacterSeed(
                        prefix: "char-costume-var-\(costume.id.uuidString)",
                        rawPath: path,
                        originSuffix: "\(costume.name) variation"
                    )
                }
            }
        }

        for item in store.imageLibraryOrganizeItems {
            let origin = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? item.category.singularName
                : item.title
            let source = allImagesSource(for: item.category)
            for path in item.imagePaths {
                appendRecord(makeSeed(
                    id: "organize-\(item.id.uuidString)-\(path)",
                    path: path,
                    source: source,
                    originLabel: origin,
                    groupLabel: origin,
                    store: store
                ), dedupeByResolvedPath: true)
            }
        }

        for scene in store.scenes {
            let sceneTitle = scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? URL(fileURLWithPath: scene.owpSongPath).deletingPathExtension().lastPathComponent
                : scene.name
            let shotsByID = Dictionary(uniqueKeysWithValues: scene.shots.map { ($0.id, $0) })
            for gallery in store.imagineSceneGalleries[scene.id] ?? [] {
                let shot = shotsByID[gallery.shotID]
                let rawShotTitle = shot?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackShotIndex = (scene.shots.firstIndex(where: { $0.id == gallery.shotID }) ?? 0) + 1
                let shotTitle = rawShotTitle.isEmpty ? "Shot \(fallbackShotIndex)" : rawShotTitle
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
                            originLabel: "\(sceneTitle) · \(shotTitle) · \(moment.rawValue)",
                            groupLabel: shotTitle,
                            sceneID: scene.id,
                            shotID: gallery.shotID,
                            store: store
                        ))
                    }
                }
            }
        }

        return records
    }

    private func allImagesSource(for category: ImageLibraryOrganizeCategory) -> AllProjectImagesSource {
        switch category {
        case .costumes: return .costumes
        case .props: return .props
        case .vehicles: return .vehicles
        }
    }

    private func makeSeed(
        id: String,
        path: String,
        source: AllProjectImagesSource,
        originLabel: String,
        groupLabel: String,
        sceneID: UUID? = nil,
        shotID: UUID? = nil,
        rating: Int? = nil,
        isRejected: Bool = false,
        isLiked: Bool = false,
        notes: String = "",
        semanticRole: ImageLibrarySemanticRole? = nil,
        supportsLibraryCuration: Bool = true,
        store: AnimateStore
    ) -> RecordSeed {
        return RecordSeed(
            id: id,
            path: path,
            source: source,
            semanticRole: semanticRole,
            originLabel: originLabel,
            groupLabel: groupLabel,
            sceneID: sceneID,
            shotID: shotID,
            rating: rating,
            isRejected: isRejected,
            isLiked: isLiked,
            notes: notes,
            supportsLibraryCuration: supportsLibraryCuration
        )
    }

    nonisolated private static func buildRecordsIncrementally(
        from seeds: [RecordSeed],
        context: RecordBuildContext,
        previousSeedsByID: [String: RecordSeed],
        previousRecordsByID: [String: ProjectImageRecord],
        metadataCache: [String: CachedFileMetadata]
    ) -> [ProjectImageRecord] {
        var mutableMetadataCache = metadataCache
        var records = seeds.map { seed in
            if previousSeedsByID[seed.id] == seed,
               let existing = previousRecordsByID[seed.id] {
                return existing
            }
            return buildRecord(from: seed, context: context, metadataCache: &mutableMetadataCache)
        }
        var seenResolvedKeys = Set<String>()
        records = records.filter { record in
            seenResolvedKeys.insert("\(record.source.rawValue)|\(record.resolvedPath)").inserted
        }
        records.sort { (lhs, rhs) in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
        return records
    }

    nonisolated private static func buildRecord(
        from seed: RecordSeed,
        context: RecordBuildContext,
        metadataCache: inout [String: CachedFileMetadata]
    ) -> ProjectImageRecord {
        let resolvedPath = resolvedImagePath(for: seed.path, context: context)
        let metadata: CachedFileMetadata
        if let cached = metadataCache[resolvedPath] {
            metadata = cached
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            metadata = CachedFileMetadata(
                createdAt: (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date),
                sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value
            )
            metadataCache[resolvedPath] = metadata
        }

        let sidecarMetadata = ImageLibraryMetadataSidecarService.load(forImagePath: resolvedPath)
        let resolvedSemanticRole = sidecarMetadata?.semanticRole ?? seed.semanticRole ?? inferredSemanticRole(for: seed.source)
        let resolvedSource = sourceAfterRecategorization(
            recordID: seed.id,
            originalSource: seed.source,
            semanticRole: sidecarMetadata?.semanticRole ?? seed.semanticRole
        )
        let mergedNotes = seed.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (sidecarMetadata?.notes ?? "")
            : seed.notes

        return ProjectImageRecord(
            id: seed.id,
            path: seed.path,
            resolvedPath: resolvedPath,
            source: resolvedSource,
            semanticRole: resolvedSemanticRole,
            originLabel: seed.originLabel,
            groupLabel: seed.groupLabel,
            sceneID: seed.sceneID,
            shotID: seed.shotID,
            searchHaystack: searchHaystack(
                path: seed.path,
                resolvedPath: resolvedPath,
                source: seed.source,
                originLabel: seed.originLabel,
                groupLabel: seed.groupLabel,
                notes: mergedNotes
            ),
            createdAt: metadata.createdAt,
            sizeBytes: metadata.sizeBytes,
            rating: seed.rating ?? sidecarMetadata?.rating,
            isRejected: seed.isRejected || (sidecarMetadata?.isRejected ?? false),
            isLiked: (seed.isLiked || (sidecarMetadata?.isLiked ?? false)) && !(seed.isRejected || (sidecarMetadata?.isRejected ?? false)),
            notes: mergedNotes,
            supportsLibraryCuration: seed.supportsLibraryCuration
        )
    }

    nonisolated private static func resolvedImagePath(
        for path: String,
        context: RecordBuildContext
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }

        let fileManager = FileManager.default
        if !trimmed.hasPrefix("/"),
           let projectURL = context.projectURL {
            let projectRelativeURL = projectURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: projectRelativeURL.path) {
                return projectRelativeURL.path
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL = context.animateURL,
           trimmed.hasPrefix("Animate/") {
            let animateRelativeURL = animateURL
                .deletingLastPathComponent()
                .appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL.path
            }
        }

        if !trimmed.hasPrefix("/"),
           let animateURL = context.animateURL,
           (trimmed.hasPrefix("characters/") || trimmed.hasPrefix("backgrounds/")) {
            let animateRelativeURL = animateURL.appendingPathComponent(trimmed)
            if fileManager.fileExists(atPath: animateRelativeURL.path) {
                return animateRelativeURL.path
            }
        }

        if let projectURL = context.projectURL,
           let projectRelativePath = projectRelativeCharacterAssetPath(from: trimmed, projectURL: projectURL) {
            let remappedURL = projectURL.appendingPathComponent(projectRelativePath)
            if fileManager.fileExists(atPath: remappedURL.path) {
                return remappedURL.path
            }
        }

        if trimmed.hasPrefix("/") {
            let candidateURL = URL(fileURLWithPath: trimmed)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL.path
            }
        }

        return trimmed
    }

    nonisolated private static func projectRelativeCharacterAssetPath(
        from path: String,
        projectURL: URL
    ) -> String? {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        if !normalizedPath.hasPrefix("/") {
            if normalizedPath.hasPrefix("Characters/") {
                return normalizedPath
            }
            if normalizedPath.hasPrefix("Animate/") {
                if normalizedPath.hasPrefix("Animate/characters/") {
                    return "Characters/" + normalizedPath.dropFirst("Animate/characters/".count)
                }
                return normalizedPath
            }
            if normalizedPath.hasPrefix("characters/") {
                return "Characters/" + normalizedPath.dropFirst("characters/".count)
            }
            if normalizedPath.hasPrefix("backgrounds/") {
                return "Animate/" + normalizedPath
            }
            return normalizedPath
        }

        let standardizedAbsoluteURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
        if let projectRelativePath = projectRelativePath(for: standardizedAbsoluteURL, projectURL: projectURL) {
            return projectRelativePath
        }

        let standardizedAbsolutePath = standardizedAbsoluteURL.path
        if let animateRange = standardizedAbsolutePath.range(of: "/Animate/") {
            return "Animate/" + standardizedAbsolutePath[animateRange.upperBound...]
        }

        return nil
    }

    nonisolated private static func projectRelativePath(for url: URL, projectURL: URL) -> String? {
        let absolutePath = url.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        guard absolutePath == projectPath || absolutePath.hasPrefix(projectPath + "/") else {
            return nil
        }

        let suffix = absolutePath.dropFirst(projectPath.count)
        let trimmed = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func rebuildAggregationCaches(from records: [ProjectImageRecord]) {
        countsBySource.removeAll(keepingCapacity: true)
        countsBySourceAndGroupLabel.removeAll(keepingCapacity: true)
        groupLabelsBySource.removeAll(keepingCapacity: true)
        allGroupLabels.removeAll(keepingCapacity: true)
        countsBySceneID.removeAll(keepingCapacity: true)
        countsByShotID.removeAll(keepingCapacity: true)

        var groupedLabels: [AllProjectImagesSource: Set<String>] = [:]
        for record in records {
            countsBySource[record.source, default: 0] += 1
            if let sceneID = record.sceneID {
                countsBySceneID[sceneID, default: 0] += 1
            }
            if let shotID = record.shotID {
                countsByShotID[shotID, default: 0] += 1
            }
            let normalizedGroupLabel = record.groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedGroupLabel.isEmpty else { continue }

            countsBySourceAndGroupLabel[record.source, default: [:]][record.groupLabel, default: 0] += 1
            groupedLabels[record.source, default: []].insert(record.groupLabel)
        }

        for (source, labels) in groupedLabels {
            groupLabelsBySource[source] = labels.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }

        let all = groupedLabels.values.reduce(into: Set<String>()) { result, labels in
            result.formUnion(labels)
        }
        allGroupLabels = all.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    nonisolated private static func searchHaystack(
        path: String,
        resolvedPath: String,
        source: AllProjectImagesSource,
        originLabel: String,
        groupLabel: String,
        notes: String
    ) -> String {
        [
            path,
            resolvedPath,
            URL(fileURLWithPath: resolvedPath).lastPathComponent,
            source.displayName,
            originLabel,
            groupLabel,
            notes
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    nonisolated private static func inferredSemanticRole(for source: AllProjectImagesSource) -> ImageLibrarySemanticRole? {
        switch source {
        case .places, .landmarks, .map3dCaptures:
            return .place
        case .characters, .costumes:
            return .character
        case .props, .vehicles, .sceneShots, .canvas:
            return nil
        }
    }

    nonisolated private static func sourceAfterRecategorization(
        recordID: String,
        originalSource: AllProjectImagesSource,
        semanticRole: ImageLibrarySemanticRole?
    ) -> AllProjectImagesSource {
        if let semanticRole {
            switch semanticRole {
            case .place:
                return .places
            case .character:
                return .characters
            }
        }

        if recordID.hasPrefix("canvas-") { return .canvas }
        if recordID.hasPrefix("shot-") { return .sceneShots }
        return originalSource
    }

    // MARK: - Filter + Sort

    var filteredRecords: [ProjectImageRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = FilterCacheKey(
            buildSignature: lastBuildSignature,
            selectedSource: selectedSource,
            selectedGroupLabel: selectedGroupLabel,
            selectedSceneID: selectedSceneID,
            selectedShotID: selectedShotID,
            searchText: query,
            sortMode: sortMode,
            flagFilter: flagFilter,
            minimumRating: minimumRating
        )
        if filteredCacheKey != cacheKey {
            let usesAllNewestRecords = selectedSource == nil
                && (selectedGroupLabel?.isEmpty ?? true)
                && selectedSceneID == nil
                && selectedShotID == nil
                && query.isEmpty
                && sortMode == .newest
                && flagFilter == .all
                && minimumRating == nil
            var records = cachedAllRecords
            if !usesAllNewestRecords {
                if let source = selectedSource {
                    records = records.filter { $0.source == source }
                }
                if let selectedGroupLabel, !selectedGroupLabel.isEmpty {
                    records = records.filter { $0.groupLabel == selectedGroupLabel }
                }
                if selectedSource == .sceneShots {
                    if let selectedSceneID {
                        records = records.filter { $0.sceneID == selectedSceneID }
                    }
                    if let selectedShotID {
                        records = records.filter { $0.shotID == selectedShotID }
                    }
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
                    records = records.filter { $0.searchHaystack.contains(query) }
                }
                switch sortMode {
                case .newest:
                    // `cachedAllRecords` is already sorted newest-first by the
                    // background rebuild. Filters preserve that order, so the
                    // initial All Images view avoids a main-actor sort.
                    break
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
            }
            filteredCacheKey = cacheKey
            filteredCacheRecords = records
            filteredRecordsByID = usesAllNewestRecords
                ? recordsByID
                : Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        }
        return filteredCacheRecords
    }

    var selectedRecord: ProjectImageRecord? {
        guard let id = selectedRecordID else { return nil }
        _ = filteredRecords
        return filteredRecordsByID[id] ?? recordsByID[id]
    }

    func recordsByIDForReview(_ id: String) -> ProjectImageRecord? {
        _ = filteredRecords
        return filteredRecordsByID[id] ?? recordsByID[id] ?? cachedAllRecords.first(where: { $0.id == id })
    }

    func count(for source: AllProjectImagesSource) -> Int {
        countsBySource[source] ?? 0
    }

    func count(for source: AllProjectImagesSource, groupLabel: String) -> Int {
        countsBySourceAndGroupLabel[source]?[groupLabel] ?? 0
    }

    func countForScene(_ sceneID: UUID) -> Int {
        countsBySceneID[sceneID] ?? 0
    }

    func countForShot(_ shotID: UUID) -> Int {
        countsByShotID[shotID] ?? 0
    }

    func groupLabels(for source: AllProjectImagesSource?) -> [String] {
        if let source {
            return groupLabelsBySource[source] ?? []
        }
        return allGroupLabels
    }

    var availableGroupLabels: [String] {
        groupLabels(for: selectedSource)
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
            if let selectedRecordID { selectedRecordIDs = [selectedRecordID] }
            return
        }
        let clampedIndex = min(max(currentIndex + delta, 0), records.count - 1)
        self.selectedRecordID = records[clampedIndex].id
        self.selectedRecordIDs = [records[clampedIndex].id]
        self.lastSelectedRecordID = records[clampedIndex].id
    }

    func selectRecord(_ record: ProjectImageRecord, in records: [ProjectImageRecord], modifiers: GalleryClickEvent.Modifiers) {
        switch modifiers {
        case .command:
            if selectedRecordIDs.contains(record.id) {
                selectedRecordIDs.remove(record.id)
                if selectedRecordID == record.id { selectedRecordID = selectedRecordIDs.first }
            } else {
                selectedRecordIDs.insert(record.id)
                selectedRecordID = record.id
                lastSelectedRecordID = record.id
            }
        case .shift:
            guard let anchorID = lastSelectedRecordID,
                  let anchorIndex = records.firstIndex(where: { $0.id == anchorID }),
                  let targetIndex = records.firstIndex(where: { $0.id == record.id }) else {
                selectedRecordIDs = [record.id]
                selectedRecordID = record.id
                lastSelectedRecordID = record.id
                return
            }
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedRecordIDs = Set(records[range].map(\.id))
            selectedRecordID = record.id
        case .none:
            selectedRecordIDs = [record.id]
            selectedRecordID = record.id
            lastSelectedRecordID = record.id
        }
    }

    func selectedRecordsForAction(fallback record: ProjectImageRecord? = nil) -> [ProjectImageRecord] {
        let selected = selectedRecordIDs.compactMap { recordsByID[$0] }
        guard !selected.isEmpty else {
            return record.map { [$0] } ?? []
        }
        guard let record else {
            return selected
        }
        if selected.count > 1, selectedRecordIDs.contains(record.id) {
            return selected
        }
        return [record]
    }

    func selectedRecordsForDrag(fallback record: ProjectImageRecord? = nil) -> [ProjectImageRecord] {
        selectedRecordsForAction(fallback: record)
    }

    func selectedDragURLs(fallback record: ProjectImageRecord? = nil) -> [URL] {
        selectedRecordsForDrag(fallback: record).map { URL(fileURLWithPath: $0.resolvedPath) }
    }

    func prefetchPaths(limit: Int = 120) -> [String] {
        Array(filteredRecords.prefix(limit).map(\.resolvedPath))
    }

    func prefetchSignature(thumbnailSize: CGFloat, limit: Int = 120) -> String {
        let cacheKey = PrefetchSignatureCacheKey(
            filterCacheKey: filteredCacheKey,
            contentRevision: contentRevision,
            roundedThumbnailSize: Int(thumbnailSize.rounded()),
            limit: limit
        )
        if let cached = prefetchSignatureCache[cacheKey] {
            return cached
        }

        var hasher = Hasher()
        hasher.combine(cacheKey.roundedThumbnailSize)
        hasher.combine(limit)
        for record in filteredRecords.prefix(limit) {
            hasher.combine(record.id)
        }
        let signature = "\(hasher.finalize())"
        prefetchSignatureCache[cacheKey] = signature
        return signature
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
            AllProjectImagesWorkspaceContent(
                store: controller.store,
                state: controller.allProjectImagesState
            )
                .environment(\.unifiedImageFlipHandler) { path in
                    controller.store.flipImageHorizontallyAndAttachLikeOriginal(path: path)
                }
                .environment(\.unifiedImageRecategorizeHandler) { path, category in
                    controller.store.recategorizeImageReviewScope(path: path, semanticRole: category.semanticRole)
                }
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
    @Bindable var state: AllProjectImagesState

    @AppStorage("amira.allImages.sidebarVisible") private var sidebarVisible = true
    @AppStorage("amira.allImages.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("amira.allImages.showInspector") private var inspectorVisible = true
    @AppStorage("amira.allImages.inspector.width") private var inspectorWidth: Double = 340

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "photo.on.rectangle.angled",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
                    .sheet(item: $state.edit.pendingPreflight) { _ in
                        GeminiGenerationPreflightSheet(
                            store: store,
                            drafts: $state.edit.pendingDrafts,
                            title: "Edit with Gemini",
                            confirmTitle: "Generate",
                            onConfirm: { finalDrafts, _ in
                                if let first = finalDrafts.first {
                                    state.edit.aspectRatio = first.aspectRatio
                                    state.edit.imageSize = first.imageSize
                                }
                                let sourceRecord = state.selectedRecord
                                state.edit.pendingPreflight = nil
                                runEditGeneration(finalDrafts, sourceRecord: sourceRecord)
                            },
                            onCancel: {
                                if let first = state.edit.pendingDrafts.first {
                                    state.edit.aspectRatio = first.aspectRatio
                                    state.edit.imageSize = first.imageSize
                                }
                                state.edit.pendingPreflight = nil
                                state.edit.pendingDrafts = []
                            }
                        )
                        // Persist the picker selections live too so a hard
                        // quit (or any close path that bypasses the explicit
                        // callbacks) still saves the last value.
                        .onChange(of: state.edit.pendingDrafts.first?.aspectRatio) { _, newValue in
                            if let newValue { state.edit.aspectRatio = newValue }
                        }
                        .onChange(of: state.edit.pendingDrafts.first?.imageSize) { _, newValue in
                            if let newValue { state.edit.imageSize = newValue }
                        }
                    }
                    .alert(
                        "Generation Error",
                        isPresented: Binding(
                            get: { state.edit.errorMessage != nil },
                            set: { if !$0 { state.edit.errorMessage = nil } }
                        ),
                        actions: { Button("OK") { state.edit.errorMessage = nil } },
                        message: { Text(state.edit.errorMessage ?? "") }
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
        // Preflight + alerts live on `body`.
    }

    private var centerPaneTitle: String {
        state.selectedSource?.displayName ?? "All Images"
    }

    private var centerPaneSubtitle: String {
        let shown = state.filteredRecords.count
        let total = state.cachedAllRecords.count
        if total == 0, state.isRebuilding { return "Indexing images…" }
        if state.isRebuilding { return "Refreshing index · \(shown) of \(total)" }
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

    private func semanticRoleForEditedOutput(sourceRecord: ProjectImageRecord?) async -> ImageLibrarySemanticRole? {
        guard let sourceRecord else { return nil }
        if let explicitRole = ImageLibraryMetadataSidecarService.load(forImagePath: sourceRecord.resolvedPath)?.semanticRole {
            return explicitRole
        }

        let analysis = await store.imageIntelligenceRecordAndMetadata(for: sourceRecord.resolvedPath).metadata
        if let inferred = ImageSemanticRoleInference.role(from: analysis) {
            return inferred
        }

        switch sourceRecord.source {
        case .characters, .costumes:
            return .character
        case .places, .landmarks, .map3dCaptures:
            return .place
        case .props, .vehicles, .sceneShots, .canvas:
            return sourceRecord.semanticRole
        }
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
        if let error = store.geminiImageGenerationAvailabilityError {
            state.edit.errorMessage = error.localizedDescription
            return
        }
        Task { @MainActor in
            let service = GeminiImageService()
            let outputSemanticRole = await semanticRoleForEditedOutput(sourceRecord: sourceRecord)
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
                        imageSize: draft.imageSize,
                        referencePaths: draft.referenceItems.filter(\.isIncluded).map(\.path),
                        semanticRole: outputSemanticRole
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
                    state.edit.errorMessage = error.localizedDescription
                    break
                }
            }
            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) edited image\(finishedCount == 1 ? "" : "s")"
                state.edit.adjustments = ""
            }
            _ = sourceRecord // reserved for future routing (filing back to origin place)
            state.edit.pendingDrafts = []
        }
    }
}

// MARK: - Left Sidebar (source filter)

@available(macOS 26.0, *)
private struct AllProjectImagesSidebarView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState
    @State private var placesExpanded = true
    @State private var landmarksExpanded = true
    @State private var charactersExpanded = true
    @State private var costumesExpanded = true
    @State private var propsExpanded = true
    @State private var vehiclesExpanded = true
    @State private var scenesExpanded = true
    @State private var expandedSceneIDs: Set<UUID> = []
    @State private var addItemCategory: ImageLibraryOrganizeCategory?
    @State private var addItemTitle = ""

    var body: some View {
        let landmarkProfiles = sortedLandmarkProfiles
        let backgrounds = sortedBackgrounds
        let characters = sortedCharacters

        OperaChromeSidebarList {
            sidebarRow(
                title: "All",
                systemImage: "photo.on.rectangle.angled",
                count: state.cachedAllRecords.count,
                isSelected: state.selectedSource == nil
            ) {
                state.selectedSource = nil
            }

            sidebarRow(
                title: "Canvas",
                systemImage: AllProjectImagesSource.canvas.systemImage,
                count: state.count(for: .canvas),
                isSelected: state.selectedSource == .canvas
            ) {
                state.selectedSource = .canvas
            }

            sidebarRow(
                title: "Map 3D Captures",
                systemImage: AllProjectImagesSource.map3dCaptures.systemImage,
                count: state.count(for: .map3dCaptures),
                isSelected: state.selectedSource == .map3dCaptures
            ) {
                state.selectedSource = .map3dCaptures
            }

            sidebarSectionLabel("Organize")

            sidebarDisclosureHeader(
                title: "Places",
                systemImage: AllProjectImagesSource.places.systemImage,
                count: state.count(for: .places),
                isSelected: state.selectedSource == .places && state.selectedGroupLabel == nil,
                isExpanded: placesExpanded,
                indent: 0,
                onSelect: {
                    state.selectedSource = .places
                    state.selectedGroupLabel = nil
                },
                onToggleExpansion: {
                    placesExpanded.toggle()
                }
            )

            if placesExpanded {
                ForEach(backgrounds) { place in
                    let groupLabel = place.name.isEmpty ? "Place" : place.name
                    sidebarRow(
                        title: place.name.isEmpty ? "Untitled Place" : place.name,
                        systemImage: "mappin.and.ellipse",
                        count: state.count(for: .places, groupLabel: groupLabel),
                        isSelected: state.selectedSource == .places && state.selectedGroupLabel == groupLabel,
                        indent: 14
                    ) {
                        state.selectedSource = .places
                        state.selectedGroupLabel = groupLabel
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        store.attachDroppedImagesToPlace(urls: dropURLs(urls), placeID: place.id, workflow: .photorealistic)
                    }
                }
            }

            sidebarDisclosureHeader(
                title: "Landmarks",
                systemImage: AllProjectImagesSource.landmarks.systemImage,
                count: state.count(for: .landmarks),
                isSelected: state.selectedSource == .landmarks && state.selectedGroupLabel == nil,
                isExpanded: landmarksExpanded,
                indent: 0,
                onSelect: {
                    state.selectedSource = .landmarks
                    state.selectedGroupLabel = nil
                },
                onToggleExpansion: {
                    landmarksExpanded.toggle()
                }
            )

            if landmarksExpanded {
                if landmarkProfiles.isEmpty {
                    sidebarEmptyRow("No landmarks yet")
                } else {
                    ForEach(landmarkProfiles) { profile in
                        let groupLabel = landmarkTitle(profile)
                        sidebarRow(
                            title: groupLabel,
                            systemImage: "building.columns",
                            count: state.count(for: .landmarks, groupLabel: groupLabel),
                            isSelected: state.selectedSource == .landmarks && state.selectedGroupLabel == groupLabel,
                            indent: 14
                        ) {
                            state.selectedSource = .landmarks
                            state.selectedGroupLabel = groupLabel
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            let accepted = store.attachDroppedImagesToLandmark(urls: dropURLs(urls), landmarkID: profile.id)
                            if accepted {
                                state.selectedSource = .landmarks
                                state.selectedGroupLabel = groupLabel
                            }
                            return accepted
                        }
                    }
                }
            }

            sidebarDisclosureHeader(
                title: "Characters",
                systemImage: AllProjectImagesSource.characters.systemImage,
                count: state.count(for: .characters),
                isSelected: state.selectedSource == .characters && state.selectedGroupLabel == nil,
                isExpanded: charactersExpanded,
                indent: 0,
                onSelect: {
                    state.selectedSource = .characters
                    state.selectedGroupLabel = nil
                },
                onToggleExpansion: {
                    charactersExpanded.toggle()
                }
            )

            if charactersExpanded {
                ForEach(characters) { character in
                    let groupLabel = character.name.isEmpty ? "Character" : character.name
                    sidebarRow(
                        title: character.name.isEmpty ? "Untitled Character" : character.name,
                        systemImage: "person.crop.square",
                        count: state.count(for: .characters, groupLabel: groupLabel),
                        isSelected: state.selectedSource == .characters && state.selectedGroupLabel == groupLabel,
                        indent: 14
                    ) {
                        state.selectedSource = .characters
                        state.selectedGroupLabel = groupLabel
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        let incoming = dropURLs(urls)
                        for url in incoming { store.addInspirationImage(url.path, for: character.id) }
                        return !incoming.isEmpty
                    }
                }
            }

            organizerCategorySection(
                category: .costumes,
                source: .costumes,
                items: store.imageLibraryOrganizeItems(for: .costumes),
                isExpanded: $costumesExpanded
            )

            organizerCategorySection(
                category: .props,
                source: .props,
                items: store.imageLibraryOrganizeItems(for: .props),
                isExpanded: $propsExpanded
            )

            organizerCategorySection(
                category: .vehicles,
                source: .vehicles,
                items: store.imageLibraryOrganizeItems(for: .vehicles),
                isExpanded: $vehiclesExpanded
            )

            sidebarDisclosureHeader(
                title: "Scenes",
                systemImage: AllProjectImagesSource.sceneShots.systemImage,
                count: state.count(for: .sceneShots),
                isSelected: state.selectedSource == .sceneShots && state.selectedGroupLabel == nil,
                isExpanded: scenesExpanded,
                indent: 0,
                onSelect: {
                    state.selectedSource = .sceneShots
                    state.selectedGroupLabel = nil
                    state.selectedSceneID = nil
                    state.selectedShotID = nil
                },
                onToggleExpansion: {
                    scenesExpanded.toggle()
                }
            )

            if scenesExpanded {
                ForEach(store.scenes) { scene in
                    let isExpanded = expandedSceneIDs.contains(scene.id)
                    sidebarDisclosureHeader(
                        title: sceneTitle(scene),
                        systemImage: "film",
                        count: state.countForScene(scene.id),
                        isSelected: state.selectedSource == .sceneShots
                            && state.selectedSceneID == scene.id
                            && state.selectedShotID == nil,
                        isExpanded: isExpanded,
                        indent: 14,
                        onSelect: {
                            state.selectedSource = .sceneShots
                            state.selectedGroupLabel = nil
                            state.selectedSceneID = scene.id
                            state.selectedShotID = nil
                            expandedSceneIDs.insert(scene.id)
                        },
                        onToggleExpansion: {
                            if expandedSceneIDs.contains(scene.id) {
                                expandedSceneIDs.remove(scene.id)
                            } else {
                                expandedSceneIDs.insert(scene.id)
                            }
                        }
                    )

                    if isExpanded {
                        if scene.shots.isEmpty {
                            sidebarEmptyRow("No shots yet", indent: 28)
                        } else {
                            ForEach(scene.shots) { shot in
                                sidebarRow(
                                    title: shotTitle(shot, in: scene),
                                    systemImage: "rectangle.on.rectangle.angled",
                                    count: state.countForShot(shot.id),
                                    isSelected: state.selectedSource == .sceneShots && state.selectedShotID == shot.id,
                                    indent: 28
                                ) {
                                    state.selectedSource = .sceneShots
                                    state.selectedGroupLabel = nil
                                    state.selectedSceneID = scene.id
                                    state.selectedShotID = shot.id
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert(addItemAlertTitle, isPresented: addItemAlertIsPresented) {
            TextField("Name", text: $addItemTitle)
            Button("Cancel", role: .cancel) {
                addItemTitle = ""
                addItemCategory = nil
            }
            Button("Add") {
                if let addItemCategory {
                    store.addImageLibraryOrganizeItem(category: addItemCategory, title: addItemTitle)
                    state.selectedSource = source(for: addItemCategory)
                    state.selectedGroupLabel = addItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                addItemTitle = ""
                addItemCategory = nil
            }
            .disabled(addItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Add a new item to track under All Images → Organize.")
        }
    }

    private var addItemAlertTitle: String {
        guard let addItemCategory else { return "Add Item" }
        return "Add \(addItemCategory.singularName)"
    }

    private var addItemAlertIsPresented: Binding<Bool> {
        Binding(
            get: { addItemCategory != nil },
            set: { isPresented in
                if !isPresented {
                    addItemCategory = nil
                    addItemTitle = ""
                }
            }
        )
    }

    private var sortedLandmarkProfiles: [PlaceLandmarkProfile] {
        store.placesWorkflowLibrary.landmarkProfiles.sorted { lhs, rhs in
            landmarkTitle(lhs).localizedCaseInsensitiveCompare(landmarkTitle(rhs)) == .orderedAscending
        }
    }

    private var sortedBackgrounds: [BackgroundPlate] {
        store.backgrounds.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var sortedCharacters: [AnimationCharacter] {
        store.characters.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func organizerCategorySection(
        category: ImageLibraryOrganizeCategory,
        source: AllProjectImagesSource,
        items: [ImageLibraryOrganizeItem],
        isExpanded: Binding<Bool>
    ) -> some View {
        sidebarDisclosureHeader(
            title: category.displayName,
            systemImage: category.systemImage,
            count: state.count(for: source),
            isSelected: state.selectedSource == source && state.selectedGroupLabel == nil,
            isExpanded: isExpanded.wrappedValue,
            indent: 0,
            onSelect: {
                state.selectedSource = source
                state.selectedGroupLabel = nil
            },
            onToggleExpansion: {
                isExpanded.wrappedValue.toggle()
            },
            onAdd: {
                addItemTitle = ""
                addItemCategory = category
                isExpanded.wrappedValue = true
            }
        )

        if isExpanded.wrappedValue {
            if items.isEmpty {
                sidebarEmptyRow("No \(category.displayName.lowercased()) yet")
            } else {
                ForEach(items) { item in
                    let groupLabel = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? category.singularName
                        : item.title
                    sidebarRow(
                        title: groupLabel,
                        systemImage: category.systemImage,
                        count: state.count(for: source, groupLabel: groupLabel),
                        isSelected: state.selectedSource == source && state.selectedGroupLabel == groupLabel,
                        indent: 14
                    ) {
                        state.selectedSource = source
                        state.selectedGroupLabel = groupLabel
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        store.attachDroppedImagesToImageLibraryOrganizeItem(
                            urls: dropURLs(urls),
                            itemID: item.id
                        )
                    }
                }
            }
        }
    }

    private func source(for category: ImageLibraryOrganizeCategory) -> AllProjectImagesSource {
        switch category {
        case .costumes: return .costumes
        case .props: return .props
        case .vehicles: return .vehicles
        }
    }

    private func landmarkTitle(_ profile: PlaceLandmarkProfile) -> String {
        let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? profile.kind.displayName : title
    }

    private func sceneTitle(_ scene: AnimationScene) -> String {
        let title = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? URL(fileURLWithPath: scene.owpSongPath).deletingPathExtension().lastPathComponent
            : title
    }

    private func shotTitle(_ shot: AnimationSceneShot, in scene: AnimationScene) -> String {
        let title = shot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let index = scene.shots.firstIndex(where: { $0.id == shot.id }) ?? 0
        return "Shot \(index + 1)"
    }

    private func dropURLs(_ urls: [URL]) -> [URL] {
        ImageMultiSelectionDragContext.resolveDroppedURLs(urls)
    }

    @ViewBuilder
    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(OperaChromeTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .padding(.horizontal, 11)
    }

    @ViewBuilder
    private func sidebarDisclosureHeader(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        isExpanded: Bool,
        indent: CGFloat = 0,
        onSelect: @escaping () -> Void,
        onToggleExpansion: @escaping () -> Void,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        OperaChromeSidebarRow(isSelected: isSelected) {
            HStack(spacing: 8) {
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)

                Button(action: onSelect) {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                            .frame(width: 18)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        Text(title)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Add \(title.dropLast(title.hasSuffix("s") ? 1 : 0))")
                }

                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, indent)
        }
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        indent: CGFloat = 0,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            OperaChromeSidebarRow(isSelected: isSelected) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, indent)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sidebarEmptyRow(_ title: String, indent: CGFloat = 14) -> some View {
        OperaChromeSidebarRow {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .padding(.leading, indent)
        }
    }
}

// MARK: - Right Inspector (Details | Edit with Gemini)

@available(macOS 26.0, *)
private struct AllProjectImagesInspectorView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState
    @State private var dictationSession = ImageReviewDictationSession()

    var body: some View {
        VStack(spacing: 0) {
            SharedInspectorTabBar(selection: $state.inspectorTab, items: [
                SharedInspectorTabItem(value: .details, title: "Details", systemImage: "info.circle"),
                SharedInspectorTabItem(value: .generate, title: "Edit with Gemini", systemImage: "sparkles"),
                SharedInspectorTabItem(value: .imageIntelligence, title: "AI", systemImage: "brain.head.profile")
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
                                    persistAndRefresh(record: record, rating: newRating, isRejected: record.isRejected, isLiked: record.isLiked, notes: record.notes)
                                },
                                onToggleLiked: {
                                    guard let record = state.selectedRecord else { return }
                                    persistAndRefresh(record: record, rating: record.rating, isRejected: false, isLiked: !record.isLiked, notes: record.notes)
                                },
                                onToggleRejected: {
                                    guard let record = state.selectedRecord else { return }
                                    persistAndRefresh(record: record, rating: record.rating, isRejected: !record.isRejected, isLiked: record.isRejected ? record.isLiked : false, notes: record.notes)
                                },
                                onSetNotes: { newNotes in
                                    guard let record = state.selectedRecord else { return }
                                    persistAndRefresh(record: record, rating: record.rating, isRejected: record.isRejected, isLiked: record.isLiked, notes: newNotes)
                                },
                                onReviewCommand: { command in
                                    handleReviewCommand(command)
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                ProjectImageReviewDictationSection(
                                    projectRoot: store.fileOWPURL,
                                    session: dictationSession
                                )
                                ProjectImageFileActionsSection(record: state.selectedRecord)
                            }
                        }

                        if let record = state.selectedRecord {
                            InspectorImageIntelligenceSummary(store: store, resolvedPath: record.resolvedPath)
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
            case .imageIntelligence:
                if let record = state.selectedRecord {
                    imageIntelligenceTab(for: record)
                } else {
                    emptyImageIntelligenceState
                }
            }
        }
    }

    @discardableResult
    private func persistAndRefresh(
        record: ProjectImageRecord,
        rating: Int?,
        isRejected: Bool,
        isLiked: Bool? = nil,
        notes: String
    ) -> ImageLibraryReviewMetadata {
        let updated = persistReviewUpdate(
            store: store,
            record: record,
            rating: rating,
            isRejected: isRejected,
            isLiked: isLiked,
            notes: notes
        )
        state.updateReviewMetadata(
            for: record.id,
            rating: updated.rating,
            isRejected: updated.isRejected,
            isLiked: updated.isLiked,
            notes: updated.notes,
            semanticRole: updated.semanticRole
        )
        return updated
    }

    private func handleReviewCommand(_ command: ImageReviewKeyboardCommand) -> Bool {
        guard let record = state.selectedRecord else { return false }
        Task { @MainActor in
            let transcript = await dictationSession.cycleForReviewCommand(projectRoot: store.fileOWPURL)
            let latestRecord = state.recordsByIDForReview(record.id) ?? record
            let mergedNotes = appendTranscript(transcript, to: latestRecord.notes)
            if mergedNotes != latestRecord.notes {
                persistAndRefresh(
                    record: latestRecord,
                    rating: latestRecord.rating,
                    isRejected: latestRecord.isRejected,
                    isLiked: latestRecord.isLiked,
                    notes: mergedNotes
                )
            }
            applyReviewCommand(command, anchorRecordID: latestRecord.id)
        }
        return true
    }

    private func appendTranscript(_ transcript: String?, to notes: String) -> String {
        guard let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else { return notes }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return transcript }
        return trimmed + "\n" + transcript
    }

    private func applyReviewCommand(_ command: ImageReviewKeyboardCommand, anchorRecordID: String) {
        let record = state.recordsByIDForReview(anchorRecordID) ?? state.selectedRecord
        switch command {
        case .previous:
            state.selectAdjacentRecord(in: state.filteredRecords, delta: -1)
        case .next:
            state.selectAdjacentRecord(in: state.filteredRecords, delta: 1)
        case .reject:
            if let record {
                persistAndRefresh(record: record, rating: record.rating, isRejected: true, isLiked: false, notes: record.notes)
            }
            state.selectAdjacentRecord(in: state.filteredRecords, delta: 1)
        case .fiveStars:
            if let record {
                persistAndRefresh(record: record, rating: 5, isRejected: false, isLiked: true, notes: record.notes)
            }
            state.selectAdjacentRecord(in: state.filteredRecords, delta: 1)
        case .setRating(let rating):
            if let record {
                persistAndRefresh(record: record, rating: rating, isRejected: false, isLiked: record.isLiked, notes: record.notes)
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
                    ResizablePromptEditor(
                        text: $state.edit.adjustments,
                        persistenceID: "allImages.editAdjustments",
                        minHeight: 80,
                        defaultHeight: 100
                    )
                        .font(.system(size: 11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.edit.model) {
                            ForEach(GeminiModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aspect").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.edit.aspectRatio) {
                            ForEach(["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.edit.imageSize) {
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
                .disabled(state.edit.adjustments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var emptyImageIntelligenceState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 30))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text("No image selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textSecondary)
            Text("Select an image to see AI analysis, tags, and search.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Image Intelligence tab

    @ViewBuilder
    private func imageIntelligenceTab(for record: ProjectImageRecord) -> some View {
        InspectorImageIntelligenceTab(store: store, record: record)
    }

    // MARK: Preflight trigger (Edit-with-Gemini tab button)

    private func openPreflight(for record: ProjectImageRecord) {
        let adjustments = state.edit.adjustments.trimmingCharacters(in: .whitespacesAndNewlines)
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
            model: state.edit.model,
            aspectRatio: state.edit.aspectRatio,
            imageSize: state.edit.imageSize,
            referenceItems: [reference],
            editInstructions: adjustments
        )
        state.edit.pendingDrafts = [draft]
        state.edit.pendingPreflight = draft
    }

}

@available(macOS 26.0, *)
private struct ProjectImageReviewDictationSection: View {
    let projectRoot: URL?
    @Bindable var session: ImageReviewDictationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Dictation")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    session.toggle(projectRoot: projectRoot)
                } label: {
                    Label(session.isEnabled ? "Mic On" : "Mic", systemImage: session.isRecording ? "mic.fill" : "mic")
                }
                .buttonStyle(.bordered)
                .tint(session.isEnabled ? .red : nil)

                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(session.isEnabled ? .primary : .secondary)
                    .lineLimit(3)
            }

            Text("Review keys while Notes is focused: [ previous, ] next, / reject, ; five stars. If Parakeet is configured, each key commits the current recording to Notes before moving on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let lastAudioPath = session.lastAudioPath, !lastAudioPath.isEmpty {
                Text(lastAudioPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
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
    isLiked: Bool? = nil,
    notes: String,
    semanticRole: ImageLibrarySemanticRole? = nil
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
        if isRejected {
            store.setImageLibraryRejected(true, for: path)
        }
    case .generic:
        if record.isRejected != isRejected {
            store.setImageLibraryRejected(isRejected, for: record.path)
        }
    }

    let existingMetadata = ImageLibraryMetadataSidecarService.load(forImagePath: record.resolvedPath)
    let resolvedSemanticRole = semanticRole ?? existingMetadata?.semanticRole ?? record.semanticRole
    let resolvedIsLiked = isRejected ? false : (isLiked ?? existingMetadata?.isLiked ?? record.isLiked)
    let metadata = ImageLibraryReviewMetadata(
        rating: rating,
        isRejected: isRejected,
        isLiked: resolvedIsLiked,
        notes: notes,
        updatedAt: Date(),
        characterTags: existingMetadata?.characterTags ?? [],
        visualStyle: existingMetadata?.visualStyle,
        semanticRole: resolvedSemanticRole
    )
    ImageLibraryMetadataSidecarService.saveAsync(metadata, forImagePath: record.resolvedPath)
    ImageReviewFeedbackService.recordFeedback(
        store: store,
        projectRoot: store.fileOWPURL,
        record: record,
        metadata: metadata
    )
    ImagePreferenceProfileService.scheduleRebuild(store: store, projectRoot: store.fileOWPURL)
    return metadata
}

@available(macOS 26.0, *)
private struct AllProjectImageSelection: DetailedImageSelection {
    let store: AnimateStore
    let record: ProjectImageRecord?
    let onSetRating: (Int?) -> Void
    let onToggleLiked: () -> Void
    let onToggleRejected: () -> Void
    let onSetNotes: (String) -> Void
    let onReviewCommand: (ImageReviewKeyboardCommand) -> Bool

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

    var isLiked: Bool {
        record?.isLiked ?? false
    }

    var notes: String {
        record?.notes ?? ""
    }

    var projectRootURL: URL? { store.fileOWPURL }

    var generationReferenceImages: [GenerationReferenceImageItem] {
        guard let record else { return [] }
        return GenerationReferenceImageResolver.referenceItems(
            forImagePath: record.resolvedPath,
            projectRoot: store.fileOWPURL
        )
    }

    var supportsRating: Bool {
        record?.supportsLibraryCuration == true
    }

    var supportsNotes: Bool {
        record?.supportsLibraryCuration == true
    }

    var metadataRows: [(label: String, value: String)] {
        guard let record else { return [] }
        let candidatePaths = candidatePaths(for: record)
        var rows: [(label: String, value: String)] = [
            ("Source", record.source.displayName),
            ("Origin", record.originLabel)
        ]
        if let semanticRole = record.semanticRole {
            rows.append(("Review Scope", semanticRole.displayName))
        }

        if let placeRecord {
            rows.append(("Workflow", placeRecord.workflow.displayName))
            if !placeRecord.keywords.isEmpty {
                rows.append(("Keywords", placeRecord.keywords.joined(separator: ", ")))
            }
        } else if let characterContext {
            rows.append(("Character", characterContext.characterName))
            rows.append(("Image Type", characterContext.kind))
        }

        let jsonMetadata = candidatePaths.lazy.compactMap({ store.generationMetadata(for: $0) }).first
        if let metadata = jsonMetadata {
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
            if let cameraPose = metadata.cameraPose {
                let parts = [
                    "Yaw \(String(format: "%.1f", cameraPose.yawDegrees))°",
                    "Pitch \(String(format: "%.1f", cameraPose.pitchDegrees))°",
                    "Focal \(String(format: "%.0f", cameraPose.focalLengthMM))mm",
                ]
                rows.append(("Camera", parts.joined(separator: " • ")))
            }
            if let status = metadata.mapPlacementStatus {
                rows.append(("Map Placement", status.rawValue))
            }
        }

        // Fallback: read .prompt.txt sidecar if no prompt from .json
        if jsonMetadata?.prompt.isEmpty != false {
            let promptText: String? = candidatePaths.lazy.compactMap { path -> String? in
                let url = URL(fileURLWithPath: path)
                let promptURL = url.deletingPathExtension().appendingPathExtension("prompt.txt")
                return try? String(contentsOf: promptURL, encoding: .utf8)
            }.first
            if let text = promptText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(("Prompt", text))
            }
        }

        if let resolution = candidatePaths.lazy.compactMap({ store.imageResolutionDescription(for: $0) }).first,
           !resolution.isEmpty {
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

    func toggleLiked() {
        onToggleLiked()
    }

    func toggleRejected() {
        onToggleRejected()
    }

    func setNotes(_ newValue: String) {
        onSetNotes(newValue)
    }

    func handleReviewCommand(_ command: ImageReviewKeyboardCommand) -> Bool {
        onReviewCommand(command)
    }
}

// MARK: - Image Intelligence Summary (Details tab)

/// Compact, read-only summary of Image Intelligence analysis data shown
/// inline in the Details inspector tab, below the generation metadata.
@available(macOS 26.0, *)
struct InspectorImageIntelligenceSummary: View {
    @Bindable var store: AnimateStore
    let resolvedPath: String

    @State private var metadata: ImageVisualMetadataRecord?
    @State private var isIndexed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Label("Image Intelligence", systemImage: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isIndexed {
                    Text("Indexed")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                } else {
                    Text("Not Indexed")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if let md = metadata {
                if let summary = md.summary, !summary.isEmpty {
                    intelligenceRow("Summary", summary)
                }
                if let shortCaption = md.shortCaption, !shortCaption.isEmpty {
                    intelligenceRow("Caption", shortCaption)
                }
                if let longCaption = md.longCaption, !longCaption.isEmpty {
                    intelligenceRow("Long Caption", longCaption)
                }
                if let tags = parsedTags(from: md.retrievalJSON) {
                    intelligenceRow("Tags", tags)
                }
                if let scene = md.sceneJSON, !scene.isEmpty {
                    intelligenceRow("Scene", scene)
                }
                if let style = md.styleJSON, !style.isEmpty {
                    intelligenceRow("Style", style)
                }
                if let entities = md.entitiesJSON, !entities.isEmpty {
                    intelligenceRow("Entities", entities)
                }
                if let quality = md.qualityJSON, !quality.isEmpty {
                    intelligenceRow("Quality", quality)
                }
                if let camera = md.cameraJSON, !camera.isEmpty {
                    intelligenceRow("Camera", camera)
                }
                if let roles = md.assetRolesJSON, !roles.isEmpty {
                    intelligenceRow("Asset Roles", roles)
                }
                if let confidence = md.confidenceJSON, !confidence.isEmpty {
                    intelligenceRow("Confidence", confidence)
                }
                if let modelID = md.modelID, !modelID.isEmpty {
                    intelligenceRow("Analysis Model", modelID)
                }
            } else if isIndexed {
                Text("Indexed but no analysis data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not analyzed. Use the AI tab to queue analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: resolvedPath) {
            let result = await store.imageIntelligenceRecordAndMetadata(for: resolvedPath)
            guard !Task.isCancelled else { return }
            isIndexed = result.isIndexed
            metadata = result.metadata
        }
    }

    @ViewBuilder
    private func intelligenceRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parsedTags(from json: String?) -> String? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let array = parsed as? [String], !array.isEmpty {
            return array.joined(separator: ", ")
        }
        if let dict = parsed as? [String: Any] {
            let tags = dict.compactMap { key, value -> String? in
                if let arr = value as? [String], !arr.isEmpty {
                    return "\(key): \(arr.joined(separator: ", "))"
                }
                if let str = value as? String, !str.isEmpty {
                    return "\(key): \(str)"
                }
                return nil
            }
            if !tags.isEmpty { return tags.joined(separator: "\n") }
        }
        return json
    }
}

// MARK: - Inspector Image Intelligence Tab

@available(macOS 26.0, *)
private struct InspectorImageIntelligenceTab: View {
    @Bindable var store: AnimateStore
    let record: ProjectImageRecord

    @State private var lastBackfillReport: String?
    @State private var analysisRecord: ImageAssetRecord?
    @State private var analysisJobs: [ImageAnalysisCoordinator.JobRecord] = []
    @State private var analysisRuns: [ImageAnalysisRunRecord] = []
    @State private var latestMetadata: ImageVisualMetadataRecord?
    @State private var queueSnapshot: [ImageAnalysisCoordinator.JobRecord] = []
    @State private var recentLogs: [ImageAnalysisCoordinator.LogEntry] = []
    @State private var searchResults: [ImageSearchService.SearchResult] = []
    @State private var selectedQuery: String = ""
    @State private var isSearching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                statusSection
                actionsSection
                analysisSection
                returnedDataSection
                jobsSection
                queueSection
                logsSection
                searchSection
            }
            .padding()
        }
        .task(id: record.resolvedPath) {
            await refresh()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(URL(fileURLWithPath: record.resolvedPath).lastPathComponent)
                .font(.headline)
            Text(record.originLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.groupLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.subheadline.bold())
            HStack(spacing: 8) {
                statusPill(label: analysisRecord == nil ? "Not Indexed" : "Indexed", color: analysisRecord == nil ? .orange : .green)
                if !analysisJobs.isEmpty {
                    statusPill(label: "\(analysisJobs.count) job(s)", color: .blue)
                }
            }
            if let report = lastBackfillReport {
                Text(report)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.subheadline.bold())
            HStack(spacing: 6) {
                Button("Reanalyze") {
                    Task { await reanalyze() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Backfill All") {
                    Task { await runBackfill() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Dry Run") {
                    Task { await runDryRun() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                Button("Start Worker") {
                    store.startImageAnalysisWorker()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Stop Worker") {
                    store.stopImageAnalysisWorker()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis")
                .font(.subheadline.bold())
            if let ar = analysisRecord {
                Text("Path: \(ar.resolvedPath)")
                    .font(.caption)
                Text("Missing: \(ar.isMissing ? "Yes" : "No")")
                    .font(.caption)
                if let hash = ar.contentHashSHA256 {
                    Text("SHA-256: \(String(hash.prefix(16)))…")
                        .font(.caption)
                }
            } else {
                Text("Not indexed. Click Reanalyze to queue this image for analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var returnedDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Returned Data")
                .font(.subheadline.bold())
            if let md = latestMetadata {
                if let summary = md.summary, !summary.isEmpty {
                    labeledValue("Summary", summary)
                }
                if let shortCaption = md.shortCaption, !shortCaption.isEmpty {
                    labeledValue("Short Caption", shortCaption)
                }
                if let longCaption = md.longCaption, !longCaption.isEmpty {
                    labeledValue("Long Caption", longCaption)
                }
                if let retrievalJSON = md.retrievalJSON, !retrievalJSON.isEmpty {
                    labeledValue("Retrieval Tags JSON", retrievalJSON)
                }
                if let sceneJSON = md.sceneJSON, !sceneJSON.isEmpty {
                    labeledValue("Scene JSON", sceneJSON)
                }
                if let styleJSON = md.styleJSON, !styleJSON.isEmpty {
                    labeledValue("Style JSON", styleJSON)
                }
                if let confidenceJSON = md.confidenceJSON, !confidenceJSON.isEmpty {
                    labeledValue("Confidence JSON", confidenceJSON)
                }
                DisclosureGroup("Raw Model JSON") {
                    ScrollView(.horizontal) {
                        Text(md.rawModelJSON ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                Text("No returned analysis data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Image: Jobs & Runs")
                .font(.subheadline.bold())
            if analysisJobs.isEmpty && analysisRuns.isEmpty {
                Text("No jobs or runs recorded for this image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(analysisJobs, id: \.id) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Job • \(job.status.rawValue.capitalized)")
                            .font(.caption.bold())
                        Text("Reason: \(job.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastError = job.lastError, !lastError.isEmpty {
                            Text("Error: \(lastError)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                ForEach(analysisRuns, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run • \(run.status)")
                            .font(.caption.bold())
                        if let reason = run.reason {
                            Text("Reason: \(reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage = run.errorMessage, !errorMessage.isEmpty {
                            Text("Run Error: \(errorMessage)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global Queue Snapshot")
                .font(.subheadline.bold())
            if queueSnapshot.isEmpty {
                Text("Queue is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(queueSnapshot.prefix(10), id: \.id) { job in
                    HStack {
                        Text(job.status.rawValue.capitalized)
                            .font(.caption.bold())
                            .frame(width: 72, alignment: .leading)
                        Text(job.reason)
                            .font(.caption)
                        Spacer()
                        Text(job.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Logs")
                .font(.subheadline.bold())
            if recentLogs.isEmpty {
                Text("No logs yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(recentLogs.suffix(15).enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search by Text")
                .font(.subheadline.bold())
            HStack {
                TextField("Tags or caption…", text: $selectedQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Search") {
                    Task { await search() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if isSearching {
                ProgressView()
            } else {
                ForEach(searchResults.prefix(5), id: \.assetID) { result in
                    HStack {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: result.resolvedPath).lastPathComponent)
                                .font(.caption)
                            Text("score \(result.score, specifier: "%.3f")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func statusPill(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func refresh() async {
        analysisRecord = await store.imageIntelligenceRecord(for: record.resolvedPath)
        analysisJobs = await store.imageIntelligenceJobs(for: record.resolvedPath)
        analysisRuns = await store.imageIntelligenceRuns(for: record.resolvedPath)
        latestMetadata = await store.imageIntelligenceLatestMetadata(for: record.resolvedPath)
        queueSnapshot = await store.imageIntelligenceQueueSnapshot(limit: 50)
        recentLogs = await store.imageIntelligenceRecentLogs(limit: 100)
    }

    @MainActor
    private func reanalyze() async {
        store.registerImageAsset(
            path: record.resolvedPath,
            linkKind: .sceneShotImage,
            analysisMode: .immediate
        )
        await refresh()
    }

    @MainActor
    private func runBackfill() async {
        lastBackfillReport = "Backfill running…"
        store.runImageIntelligenceBackfill(dryRun: false) { [self] report in
            Task { @MainActor in
                lastBackfillReport = report.summary
                await refresh()
            }
        }
    }

    @MainActor
    private func runDryRun() async {
        store.runImageIntelligenceBackfill(dryRun: true) { [self] report in
            Task { @MainActor in
                lastBackfillReport = report.summary
            }
        }
    }

    @MainActor
    private func search() async {
        guard let service = store.imageIntelligenceSearchService() else { return }
        isSearching = true
        let query = selectedQuery
        defer { isSearching = false }
        do {
            searchResults = try await service.searchByText(query, limit: 10)
        } catch {
            searchResults = []
        }
    }
}
