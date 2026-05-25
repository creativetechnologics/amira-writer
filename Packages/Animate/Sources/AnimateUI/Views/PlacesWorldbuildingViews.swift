import AppKit
import ImageIO
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
private func isWorldMapEligibleGeneratedRecord(_ record: GeneratedBackgroundLibraryRecord) -> Bool {
    guard !record.isRejected else { return false }
    let haystack = [
        record.activePath,
        record.summary,
        record.sourcePrompt ?? "",
        record.keywords.joined(separator: " ")
    ]
    .joined(separator: " ")
    .lowercased()

    if haystack.contains("/backgrounds/chosen-references/map/") {
        return false
    }

    let excludedTerms = [
        "topdown",
        "top-down",
        "master map",
        "world map",
        "bird's-eye",
        "birds-eye",
        "satellite view",
        "orthographic"
    ]

    return !excludedTerms.contains(where: haystack.contains)
}

@available(macOS 26.0, *)
struct PlacesWorldMapPoint: Hashable, Sendable {
    var x: CGFloat
    var y: CGFloat

    static let zero = PlacesWorldMapPoint(x: 0.5, y: 0.5)

    var clamped: PlacesWorldMapPoint {
        PlacesWorldMapPoint(x: min(max(x, 0.04), 0.96), y: min(max(y, 0.04), 0.96))
    }
}

@available(macOS 26.0, *)
struct PlacesWorldNodeDraft: Hashable, Sendable {
    var title: String
    var heading: Double
    var pitch: Double
    var roll: Double
    var focalLength: Double
    var expectedLandmarks: [String]

    init(node: PlacesWorldbuildingSnapshot.Node) {
        title = node.title
        heading = node.heading
        pitch = node.pitch
        roll = node.roll
        focalLength = node.focalLength
        expectedLandmarks = node.expectedLandmarks
    }
}

@MainActor
@available(macOS 26.0, *)
struct PlacesWorldbuildingSnapshot {
    struct Node: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var placeID: UUID?
        var placeName: String
        var routeID: String?
        var sequenceIndex: Int
        var position: PlacesWorldMapPoint
        var heading: Double
        var pitch: Double
        var roll: Double
        var focalLength: Double
        var expectedLandmarks: [String]
        var canonImagePath: String?
        var sourceImagePath: String?
        var imageRecordID: UUID?
        var angleImageID: UUID?
        var statusText: String
        var isFlagged: Bool
        var qaFlags: [String]

        var positionLabel: String {
            String(format: "x %.3f • y %.3f", position.x, position.y)
        }

        var poseLabel: String {
            String(format: "H %.0f° • P %.0f° • R %.0f°", heading, pitch, roll)
        }

        var focalLabel: String {
            focalLength > 0 ? String(format: "%.0fmm", focalLength) : "Default lens"
        }

        var canonStatusLabel: String {
            canonImagePath == nil ? "Needs canon" : (isFlagged ? "Canon flagged" : "Canon ready")
        }
    }

    struct Route: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var placeID: UUID?
        var placeName: String
        var nodeIDs: [String]
        var path: [PlacesWorldMapPoint]
        var flaggedCount: Int
        var reviewCount: Int
        var lengthLabel: String
        var generationSummary: String
        var workflow: PlaceWorkflowMode

        var coverageLabel: String {
            "\(nodeIDs.count) node\(nodeIDs.count == 1 ? "" : "s")"
        }
    }

    enum ReviewSeverity: String, CaseIterable, Hashable, Sendable {
        case info
        case warning
        case critical

        var color: Color {
            switch self {
            case .info: .blue
            case .warning: .orange
            case .critical: .red
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .critical: "xmark.octagon.fill"
            }
        }
    }

    struct Review: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var summary: String
        var severity: ReviewSeverity
        var placeID: UUID?
        var placeName: String
        var routeID: String?
        var nodeID: String?
        var recordID: UUID?
        var workflow: PlaceWorkflowMode
        var candidatePath: String?
        var neighborPaths: [String]
        var mismatchTags: [String]
        var statusText: String

        var shortSummary: String {
            summary.isEmpty ? "Needs worldbuilding review." : summary
        }
    }

    struct Capture: Identifiable, Hashable, Sendable {
        var id: String
        var recordID: UUID?
        var imagePath: String
        var placeID: UUID?
        var placeName: String
        var worldNodeID: String?
        var routeID: String?
        var buildingAnchorNodeID: String?
        var position: PlacesWorldMapPoint
        var heading: Double?
        var pitch: Double?
        var focalLength: Double?
        var rating: Int?
        var isRejected: Bool
        var isCanon: Bool
        var qaFlags: [String]
        var title: String
        var hasTrustedMapPosition: Bool
        var placementSource: String
        var placementConfidence: Double
        var mapPlacementStatus: GeneratedBackgroundMapPlacementStatus
        var mapPlacementConfirmedAt: Date?
        var orientationState: GeneratedBackgroundOrientationState
        var sceneKind: PlaceWorldSceneKind
        var shouldMirrorPreview: Bool
        var placementDiagnostics: [String]

        var poseLabel: String {
            let headingLabel = heading.map { String(format: "H %.0f°", $0) } ?? "H —"
            let focalLabel = focalLength.map { String(format: "%.0fmm", $0) } ?? "Lens —"
            return "\(headingLabel) • \(focalLabel)"
        }

        var requiresPlacementReview: Bool {
            if mapPlacementStatus != .confirmed { return true }
            if placeID == nil { return true }
            return worldNodeID == nil && buildingAnchorNodeID == nil
        }

        var isInteriorLinkedToBuilding: Bool {
            sceneKind == .interior && buildingAnchorNodeID != nil
        }
    }

    var masterMapPath: String?
    var nodes: [Node]
    var captures: [Capture]
    var routes: [Route]
    var reviews: [Review]
    var placeNodeCounts: [UUID: Int]
    var placeFlaggedCounts: [UUID: Int]
    var usesFallbackWorldGraph: Bool

    var totalFlaggedReviews: Int { reviews.count }
    var totalFlaggedNodes: Int { nodes.filter(\.isFlagged).count }
    var totalPinnedCaptures: Int { captures.count }
    var unplacedCaptureCount: Int {
        captures.filter { $0.mapPlacementStatus == .unplaced || !$0.hasTrustedMapPosition }.count
    }
    var homelessCaptureCount: Int { captures.filter { $0.placeID == nil }.count }
    var unconfirmedCaptureCount: Int {
        captures.filter(\.requiresPlacementReview).count
    }

    static let empty = PlacesWorldbuildingSnapshot(
        masterMapPath: nil,
        nodes: [],
        captures: [],
        routes: [],
        reviews: [],
        placeNodeCounts: [:],
        placeFlaggedCounts: [:],
        usesFallbackWorldGraph: true
    )

    func node(withID id: String?) -> Node? {
        guard let id else { return nil }
        return nodes.first(where: { $0.id == id })
    }

    func route(withID id: String?) -> Route? {
        guard let id else { return nil }
        return routes.first(where: { $0.id == id })
    }

    func capture(withRecordID recordID: UUID?) -> Capture? {
        guard let recordID else { return nil }
        return captures.first(where: { $0.recordID == recordID })
    }

    func reviews(for routeID: String?) -> [Review] {
        guard let routeID else { return reviews }
        return reviews.filter { $0.routeID == routeID }
    }

    func reviews(for placeID: UUID?) -> [Review] {
        guard let placeID else { return reviews }
        return reviews.filter { $0.placeID == placeID }
    }

    func applying(nodeDrafts: [String: PlacesWorldNodeDraft]) -> Self {
        guard !nodeDrafts.isEmpty else { return self }
        var copy = self
        copy.nodes = nodes.map { node in
            guard let draft = nodeDrafts[node.id] else { return node }
            var updated = node
            updated.title = draft.title
            updated.heading = draft.heading
            updated.pitch = draft.pitch
            updated.roll = draft.roll
            updated.focalLength = draft.focalLength
            updated.expectedLandmarks = draft.expectedLandmarks
            return updated
        }
        return copy
    }

    @MainActor
    static func make(store: AnimateStore, workflowMode: PlaceWorkflowMode) -> Self {
        let fallbackNodes = fallbackNodes(store: store, workflowMode: workflowMode)
        let reflectedNodes = reflectedNodes(store: store, workflowMode: workflowMode)
        let usesFallbackWorldGraph = reflectedNodes.isEmpty
        let nodes = reflectedNodes.isEmpty ? fallbackNodes : reflectedNodes
        let routes = reflectedRoutes(store: store, nodes: nodes, workflowMode: workflowMode).ifEmpty {
            fallbackRoutes(from: nodes, workflowMode: workflowMode)
        }
        let reviews = reflectedReviews(store: store, nodes: nodes, routes: routes, workflowMode: workflowMode).ifEmpty {
            fallbackReviews(store: store, nodes: nodes, routes: routes, workflowMode: workflowMode)
        }
        let captures = generatedCaptures(
            store: store,
            workflowMode: workflowMode,
            nodes: nodes,
            usesFallbackWorldGraph: usesFallbackWorldGraph
        )

        var nodeCounts: [UUID: Int] = [:]
        for node in nodes {
            guard let placeID = node.placeID else { continue }
            nodeCounts[placeID, default: 0] += 1
        }

        var flaggedCounts: [UUID: Int] = [:]
        for review in reviews {
            guard let placeID = review.placeID else { continue }
            flaggedCounts[placeID, default: 0] += 1
        }

        return PlacesWorldbuildingSnapshot(
            masterMapPath: store.effectivePlacesMasterMapPath(),
            nodes: nodes,
            captures: captures,
            routes: routes,
            reviews: reviews,
            placeNodeCounts: nodeCounts,
            placeFlaggedCounts: flaggedCounts,
            usesFallbackWorldGraph: usesFallbackWorldGraph
        )
    }

    @MainActor
    private static func fallbackNodes(store: AnimateStore, workflowMode: PlaceWorkflowMode) -> [Node] {
        let places = store.backgrounds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !places.isEmpty else { return [] }

        let columns = max(1, Int(ceil(sqrt(Double(places.count)))))
        let rows = max(1, Int(ceil(Double(places.count) / Double(columns))))
        var nodes: [Node] = []

        for (placeIndex, place) in places.enumerated() {
            let column = placeIndex % columns
            let row = placeIndex / columns
            let basePoint = PlacesWorldMapPoint(
                x: CGFloat(column + 1) / CGFloat(columns + 1),
                y: CGFloat(row + 1) / CGFloat(rows + 1)
            )
            .clamped
            let routeID = "place-\(place.id.uuidString.lowercased())-route"
            let angleImages = place.angleImages

            if angleImages.isEmpty {
                let canonPath = place.approvedImagePath(for: workflowMode)
                let fallbackPath = place.imagePaths(for: workflowMode).first
                let chosenPath: String? = canonPath ?? fallbackPath
                nodes.append(
                    Node(
                        id: "\(routeID)-0",
                        title: place.name,
                        placeID: place.id,
                        placeName: place.name,
                        routeID: routeID,
                        sequenceIndex: 0,
                        position: basePoint,
                        heading: 0,
                        pitch: 0,
                        roll: 0,
                        focalLength: inferredFocalLength(cameraShot: nil),
                        expectedLandmarks: inferredLandmarks(for: place),
                        canonImagePath: canonPath,
                        sourceImagePath: chosenPath,
                        imageRecordID: chosenPath.flatMap { path in store.generatedBackgroundRecord(for: path)?.id },
                        angleImageID: nil,
                        statusText: chosenPath == nil ? "Awaiting first capture" : "Coverage anchor",
                        isFlagged: canonPath == nil,
                        qaFlags: canonPath == nil ? ["Choose canon"] : []
                    )
                )
                continue
            }

            let spread = min(0.12, CGFloat(max(angleImages.count - 1, 1)) * 0.03)
            for (nodeIndex, angleImage) in angleImages.enumerated() {
                let ratio = angleImages.count == 1 ? 0 : CGFloat(nodeIndex) / CGFloat(max(angleImages.count - 1, 1))
                let offset = (ratio - 0.5) * spread
                let point = PlacesWorldMapPoint(
                    x: basePoint.x + offset,
                    y: basePoint.y + (nodeIndex.isMultiple(of: 2) ? -0.02 : 0.02)
                )
                .clamped
                let chosenPath: String? = place.approvedImagePath(for: workflowMode) ?? angleImage.imagePath
                let qaFlags = inferredNodeFlags(from: angleImage, chosenPath: chosenPath, approvedPath: place.approvedImagePath(for: workflowMode))
                nodes.append(
                    Node(
                        id: angleImage.id.uuidString.lowercased(),
                        title: angleNodeTitle(place: place, angleImage: angleImage, index: nodeIndex),
                        placeID: place.id,
                        placeName: place.name,
                        routeID: routeID,
                        sequenceIndex: nodeIndex,
                        position: point,
                        heading: inferredHeading(angle: angleImage.angle),
                        pitch: 0,
                        roll: 0,
                        focalLength: inferredFocalLength(cameraShot: angleImage.cameraShot),
                        expectedLandmarks: inferredLandmarks(for: place),
                        canonImagePath: place.approvedImagePath(for: workflowMode),
                        sourceImagePath: chosenPath,
                        imageRecordID: chosenPath.flatMap { path in store.generatedBackgroundRecord(for: path)?.id },
                        angleImageID: angleImage.id,
                        statusText: angleImage.notes.isEmpty ? "Coverage image" : angleImage.notes,
                        isFlagged: !qaFlags.isEmpty,
                        qaFlags: qaFlags
                    )
                )
            }
        }

        return nodes
    }

    @MainActor
    private static func fallbackRoutes(from nodes: [Node], workflowMode: PlaceWorkflowMode) -> [Route] {
        Dictionary(grouping: nodes, by: { $0.routeID ?? "unassigned" })
            .map { routeID, groupedNodes in
                let ordered = groupedNodes.sorted { $0.sequenceIndex < $1.sequenceIndex }
                let placeID = ordered.first?.placeID
                let placeName = ordered.first?.placeName ?? "Unknown Place"
                let flaggedCount = ordered.reduce(0) { $0 + ($1.isFlagged ? 1 : 0) }
                return Route(
                    id: routeID,
                    title: placeName,
                    placeID: placeID,
                    placeName: placeName,
                    nodeIDs: ordered.map(\.id),
                    path: ordered.map(\.position),
                    flaggedCount: flaggedCount,
                    reviewCount: flaggedCount,
                    lengthLabel: "\(ordered.count) coverage point\(ordered.count == 1 ? "" : "s")",
                    generationSummary: "Prepare \(min(max(ordered.count, 1), 8)) \(workflowMode.shortLabel.lowercased()) draft\(ordered.count == 1 ? "" : "s") along this route.",
                    workflow: workflowMode
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @MainActor
    private static func fallbackReviews(
        store: AnimateStore,
        nodes: [Node],
        routes: [Route],
        workflowMode: PlaceWorkflowMode
    ) -> [Review] {
        var reviews: [Review] = []
        let routeByPlaceID = Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            route.placeID.map { ($0, route) }
        })
        let nodesByPlaceID = Dictionary(grouping: nodes, by: { $0.placeID })

        for place in store.backgrounds {
            let imagePaths = place.imagePaths(for: workflowMode)
            let approvedPath = place.approvedImagePath(for: workflowMode)
            if approvedPath == nil, imagePaths.count > 1 {
                reviews.append(
                    Review(
                        id: "canon-\(place.id.uuidString.lowercased())-\(workflowMode.rawValue)",
                        title: "Choose canon for \(place.name)",
                        summary: "This route has multiple candidate images but no approved canon yet.",
                        severity: .warning,
                        placeID: place.id,
                        placeName: place.name,
                        routeID: routeByPlaceID[place.id]?.id,
                        nodeID: nodesByPlaceID[place.id]?.first?.id,
                        recordID: imagePaths.first.flatMap { store.generatedBackgroundRecord(for: $0)?.id },
                        workflow: workflowMode,
                        candidatePath: imagePaths.first,
                        neighborPaths: Array(imagePaths.dropFirst().prefix(3)),
                        mismatchTags: ["Canon"],
                        statusText: "Needs approval"
                    )
                )
            }
        }

        return reviews.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return severityRank(lhs.severity) > severityRank(rhs.severity)
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private struct BatchPromptPinMetadata: Sendable {
        var title: String
        var mapPoint: PlacesWorldMapPoint?
        var heading: Double?
        var pitch: Double?
        var roll: Double?
        var focalLength: Double?
    }

    @MainActor
    private static func generatedCaptures(
        store: AnimateStore,
        workflowMode: PlaceWorkflowMode,
        nodes: [Node],
        usesFallbackWorldGraph: Bool
    ) -> [Capture] {
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let placesByID = Dictionary(uniqueKeysWithValues: store.backgrounds.map { ($0.id, $0) })
        let batchMetadataByStem = batchPromptPinMetadataLookup(store: store, workflowMode: workflowMode)

        return store.visibleGeneratedBackgroundLibraryRecords()
            .filter { $0.workflow == workflowMode && isWorldMapEligibleGeneratedRecord($0) }
            .compactMap { record in
                let fileStem = URL(fileURLWithPath: record.activePath).deletingPathExtension().lastPathComponent.lowercased()
                let linkedNode = record.worldNodeID.flatMap { nodeByID[$0.uuidString.lowercased()] }
                let linkedPlace = record.linkedPlaceID.flatMap { placesByID[$0] }
                let buildingAnchorNode = record.buildingAnchorNodeID
                    .flatMap { nodeByID[$0.uuidString.lowercased()] }
                    ?? linkedPlace?.buildingAnchorNodeID.flatMap { nodeByID[$0.uuidString.lowercased()] }
                let batchMetadata = batchMetadataByStem[fileStem]
                let canTrustGraphNodes = !usesFallbackWorldGraph

                let position = record.mapPoint.map { PlacesWorldMapPoint(x: CGFloat($0.x), y: CGFloat($0.y)).clamped }
                    ?? (canTrustGraphNodes ? linkedNode?.position : nil)
                    ?? (canTrustGraphNodes ? buildingAnchorNode?.position : nil)
                    ?? batchMetadata?.mapPoint
                    ?? .zero
                let hasExplicitInteriorAnchor =
                    linkedPlace?.buildingAnchorNodeID != nil
                    || linkedPlace?.linkedExteriorPlaceID != nil
                let hasTrustedMapPosition =
                    (canTrustGraphNodes && linkedNode != nil)
                    || (canTrustGraphNodes && buildingAnchorNode != nil && hasExplicitInteriorAnchor)
                    || (record.mapPlacementStatus == .confirmed && record.mapPoint != nil)

                let heading = record.cameraPose?.yawDegrees
                    ?? (canTrustGraphNodes ? linkedNode?.heading : nil)
                    ?? (canTrustGraphNodes ? buildingAnchorNode?.heading : nil)
                    ?? batchMetadata?.heading
                let focalLength = record.cameraPose?.focalLengthMM
                    ?? (canTrustGraphNodes ? linkedNode?.focalLength : nil)
                    ?? (canTrustGraphNodes ? buildingAnchorNode?.focalLength : nil)
                    ?? batchMetadata?.focalLength
                let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = batchMetadata?.title
                    ?? (summary.isEmpty ? nil : summary)
                    ?? linkedPlace?.name
                    ?? URL(fileURLWithPath: record.activePath).deletingPathExtension().lastPathComponent

                return Capture(
                    id: record.id.uuidString.lowercased(),
                    recordID: record.id,
                    imagePath: record.activePath,
                    placeID: linkedPlace?.id,
                    placeName: linkedPlace?.name ?? "Unassigned",
                    worldNodeID: linkedNode?.id,
                    routeID: linkedNode?.routeID,
                    buildingAnchorNodeID: buildingAnchorNode?.id,
                    position: position,
                    heading: heading,
                    pitch: record.cameraPose?.pitchDegrees
                        ?? linkedNode?.pitch
                        ?? buildingAnchorNode?.pitch
                        ?? batchMetadata?.pitch,
                    focalLength: focalLength,
                    rating: record.rating,
                    isRejected: record.isRejected,
                    isCanon: record.canonStatus == .canon,
                    qaFlags: record.qaFlags.map(\.message),
                    title: title,
                    hasTrustedMapPosition: hasTrustedMapPosition,
                    placementSource: linkedNode != nil
                        ? (canTrustGraphNodes ? "world_node" : "linked_node_untrusted")
                        : (buildingAnchorNode != nil
                            ? (canTrustGraphNodes ? "building_anchor" : "building_anchor_untrusted")
                            : (record.mapPlacementStatus == .confirmed ? "confirmed" : "unplaced")),
                    placementConfidence: hasTrustedMapPosition ? 1.0 : 0.0,
                    mapPlacementStatus: record.mapPlacementStatus,
                    mapPlacementConfirmedAt: record.mapPlacementConfirmedAt,
                    orientationState: record.orientationState,
                    sceneKind: .ambiguous,
                    shouldMirrorPreview: record.orientationState == .mirrored,
                    placementDiagnostics: []
                )
            }
            .sorted { lhs, rhs in
                if lhs.isRejected != rhs.isRejected {
                    return !lhs.isRejected
                }
                if (lhs.rating ?? 0) != (rhs.rating ?? 0) {
                    return (lhs.rating ?? 0) > (rhs.rating ?? 0)
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @MainActor
    private static func batchPromptPinMetadataLookup(
        store: AnimateStore,
        workflowMode: PlaceWorkflowMode
    ) -> [String: BatchPromptPinMetadata] {
        guard let animateURL = store.animateURL else { return [:] }
        let rootURL = ProjectPaths(root: animateURL.deletingLastPathComponent()).animatePlaceBatches
        guard FileManager.default.fileExists(atPath: rootURL.path),
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return [:]
        }

        var lookup: [String: BatchPromptPinMetadata] = [:]

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "batch_submission.json" {
            let workflowFolder = fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased()
            switch workflowMode {
            case .photorealistic where !workflowFolder.contains("photo"):
                continue
            case .animated where !workflowFolder.contains("anim"):
                continue
            default:
                break
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let manifest = (json["prompt_manifest"] as? [[String: Any]]) ?? []
            for entry in manifest {
                let title = trimmedString(entry["title"]) ?? "Generated Capture"
                let prompt = trimmedString(entry["prompt"]) ?? ""
                let identifier = trimmedString(entry["id"])
                    ?? URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent
                let stem = identifier.lowercased()
                lookup[stem] = BatchPromptPinMetadata(
                    title: title,
                    mapPoint: parsedBatchPromptMapPoint(prompt),
                    heading: parsedBatchPromptScalar(prompt, marker: "Camera pose: heading ", terminator: " degrees"),
                    pitch: parsedBatchPromptScalar(prompt, marker: "pitch ", terminator: " degrees"),
                    roll: parsedBatchPromptScalar(prompt, marker: "roll ", terminator: " degrees"),
                    focalLength: parsedBatchPromptScalar(prompt, marker: "focal length ", terminator: "mm")
                )
            }
        }

        return lookup
    }

    private static func parsedBatchPromptMapPoint(_ prompt: String) -> PlacesWorldMapPoint? {
        guard let x = parsedBatchPromptScalar(prompt, marker: "Map anchor: normalized x ", terminator: ","),
              let y = parsedBatchPromptScalar(prompt, marker: "y ", terminator: " on the master map") else {
            return nil
        }
        return PlacesWorldMapPoint(x: CGFloat(x), y: CGFloat(y)).clamped
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parsedBatchPromptScalar(
        _ prompt: String,
        marker: String,
        terminator: String
    ) -> Double? {
        guard let markerRange = prompt.range(of: marker) else { return nil }
        let remainder = prompt[markerRange.upperBound...]
        guard let terminatorRange = remainder.range(of: terminator) else { return nil }
        let value = remainder[..<terminatorRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(value)
    }

    @MainActor
    private static func reflectedNodes(store: AnimateStore, workflowMode: PlaceWorkflowMode) -> [Node] {
        guard let worldGraph = Reflection.child(named: "worldGraph", in: store.placesWorkflowLibrary) else { return [] }
        let rawNodes = Reflection.collection(named: "nodes", in: worldGraph)
        return rawNodes.compactMap { rawNode in
            guard let point = normalizedPoint(from: rawNode) else { return nil }
            let nodeUUID = Reflection.uuid(named: "id", in: rawNode)
            let id = nodeUUID?.uuidString.lowercased()
                ?? Reflection.string(named: "id", in: rawNode)
                ?? UUID().uuidString.lowercased()
            let placeID = Reflection.uuid(named: "placeID", in: rawNode)
            let routeID = Reflection.string(named: "routeID", in: rawNode) ?? Reflection.string(named: "parentRouteID", in: rawNode)
            let placeName = placeID.flatMap { placeID in
                store.backgrounds.first(where: { $0.id == placeID })?.name
            } ?? Reflection.string(named: "placeName", in: rawNode) ?? "Unassigned"
            let poseSource = Reflection.child(named: "cameraPose", in: rawNode) ?? rawNode
            let recordID = Reflection.uuid(named: "linkedGeneratedRecordID", in: rawNode)
                ?? nodeUUID.flatMap { nodeID in
                    store.placesWorkflowLibrary.generatedImageRecords.first(where: {
                        $0.worldNodeID == nodeID && $0.workflow == workflowMode
                    })?.id
                }
            let sourcePath = Reflection.string(named: "sourceImagePath", in: rawNode)
                ?? Reflection.string(named: "imagePath", in: rawNode)
                ?? recordID.flatMap { recordID in
                    store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID })?.activePath
                }
            let canonPath = resolvedCanonPath(rawNode: rawNode, store: store, recordID: recordID, placeID: placeID, workflowMode: workflowMode)
            let flags = Reflection.stringArray(named: "qaFlags", in: rawNode)
                .ifEmpty { Reflection.stringArray(named: "warnings", in: rawNode) }
            return Node(
                id: id,
                title: Reflection.string(named: "title", in: rawNode)
                    ?? Reflection.string(named: "name", in: rawNode)
                    ?? placeName,
                placeID: placeID,
                placeName: placeName,
                routeID: routeID,
                sequenceIndex: Reflection.int(named: "sequenceIndex", in: rawNode) ?? 0,
                position: point,
                heading: Reflection.double(named: "heading", in: poseSource)
                    ?? Reflection.double(named: "yaw", in: poseSource)
                    ?? Reflection.double(named: "yawDegrees", in: poseSource)
                    ?? 0,
                pitch: Reflection.double(named: "pitch", in: poseSource)
                    ?? Reflection.double(named: "pitchDegrees", in: poseSource)
                    ?? 0,
                roll: Reflection.double(named: "roll", in: poseSource)
                    ?? Reflection.double(named: "rollDegrees", in: poseSource)
                    ?? 0,
                focalLength: Reflection.double(named: "focalLength", in: poseSource)
                    ?? Reflection.double(named: "focalLength35mm", in: poseSource)
                    ?? Reflection.double(named: "focalLengthMM", in: poseSource)
                    ?? 35,
                expectedLandmarks: Reflection.stringArray(named: "expectedLandmarks", in: rawNode)
                    .ifEmpty { Reflection.stringArray(named: "expectedLandmarkTitles", in: rawNode) }
                    .ifEmpty { Reflection.stringArray(named: "landmarkExpectations", in: rawNode) },
                canonImagePath: canonPath,
                sourceImagePath: sourcePath,
                imageRecordID: recordID,
                angleImageID: Reflection.uuid(named: "sourceAngleImageID", in: rawNode),
                statusText: Reflection.string(named: "statusText", in: rawNode)
                    ?? Reflection.string(named: "notes", in: rawNode)
                    ?? "World node",
                isFlagged: !flags.isEmpty || (Reflection.bool(named: "needsReview", in: rawNode) ?? false),
                qaFlags: flags
            )
        }
    }

    @MainActor
    private static func reflectedRoutes(store: AnimateStore, nodes: [Node], workflowMode: PlaceWorkflowMode) -> [Route] {
        guard let worldGraph = Reflection.child(named: "worldGraph", in: store.placesWorkflowLibrary) else { return [] }
        let nodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return Reflection.collection(named: "routes", in: worldGraph).compactMap { rawRoute in
            let id = Reflection.string(named: "id", in: rawRoute) ?? UUID().uuidString.lowercased()
            let explicitNodeIDs = Reflection.stringArray(named: "nodeIDs", in: rawRoute)
                .ifEmpty { Reflection.stringArray(named: "sequenceNodeIDs", in: rawRoute) }
            let routeNodes = explicitNodeIDs.isEmpty
                ? nodes
                    .filter { $0.routeID == id }
                    .sorted { $0.sequenceIndex < $1.sequenceIndex }
                : explicitNodeIDs.compactMap { nodeLookup[$0] }
            guard !routeNodes.isEmpty else { return nil }
            let nodeIDs = routeNodes.map(\.id)
            let flaggedCount = Reflection.int(named: "flaggedReviewCount", in: rawRoute)
                ?? Reflection.int(named: "flaggedCount", in: rawRoute)
                ?? store.placesWorkflowLibrary.continuityReviews.filter {
                    $0.routeID?.uuidString.lowercased() == id && !$0.flags.isEmpty
                }.count
            return Route(
                id: id,
                title: Reflection.string(named: "title", in: rawRoute)
                    ?? Reflection.string(named: "name", in: rawRoute)
                    ?? routeNodes.first?.placeName
                    ?? "Route",
                placeID: Reflection.uuid(named: "placeID", in: rawRoute) ?? routeNodes.first?.placeID,
                placeName: routeNodes.first?.placeName ?? "Unassigned",
                nodeIDs: nodeIDs,
                path: routeNodes.map(\.position),
                flaggedCount: flaggedCount,
                reviewCount: Reflection.int(named: "reviewCount", in: rawRoute) ?? flaggedCount,
                lengthLabel: Reflection.string(named: "lengthLabel", in: rawRoute) ?? "\(routeNodes.count) coverage points",
                generationSummary: Reflection.string(named: "generationSummary", in: rawRoute)
                    ?? "Prepare \(min(max(routeNodes.count, 1), 8)) \(workflowMode.shortLabel.lowercased()) draft\(routeNodes.count == 1 ? "" : "s") for this route.",
                workflow: workflowMode
            )
        }
    }

    @MainActor
    private static func reflectedReviews(
        store: AnimateStore,
        nodes: [Node],
        routes: [Route],
        workflowMode: PlaceWorkflowMode
    ) -> [Review] {
        let rawReviews = Reflection.collection(named: "continuityReviews", in: store.placesWorkflowLibrary)
        guard !rawReviews.isEmpty else { return [] }
        let nodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let routeLookup = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        return rawReviews.compactMap { rawReview in
            let rawStatus = Reflection.string(named: "status", in: rawReview)?.lowercased()
            if let rawStatus, rawStatus != PlaceContinuityReviewStatus.pending.rawValue {
                return nil
            }
            let nodeID = Reflection.string(named: "nodeID", in: rawReview)
            let routeID = Reflection.string(named: "routeID", in: rawReview)
            let placeID = Reflection.uuid(named: "placeID", in: rawReview)
                ?? nodeLookup[nodeID ?? ""]?.placeID
                ?? routeLookup[routeID ?? ""]?.placeID
            let placeName = placeID.flatMap { id in
                store.backgrounds.first(where: { $0.id == id })?.name
            } ?? nodeLookup[nodeID ?? ""]?.placeName ?? routeLookup[routeID ?? ""]?.placeName ?? "Unassigned"
            let flagLabels = Reflection.collection(named: "flags", in: rawReview).compactMap { rawFlag in
                Reflection.string(named: "message", in: rawFlag)
                    ?? Reflection.string(named: "code", in: rawFlag)
            }
            let severity = parsedSeverity(
                Reflection.collection(named: "flags", in: rawReview)
                    .compactMap { Reflection.string(named: "severity", in: $0) }
                    .sorted { severityRank(parsedSeverity($0)) > severityRank(parsedSeverity($1)) }
                    .first
                    ?? Reflection.string(named: "severity", in: rawReview)
                    ?? Reflection.string(named: "status", in: rawReview)
            )
            let candidatePath = Reflection.string(named: "candidateImagePath", in: rawReview)
                ?? Reflection.string(named: "imagePath", in: rawReview)
            let tags = Reflection.stringArray(named: "mismatchTags", in: rawReview)
                .ifEmpty { flagLabels }
                .ifEmpty { Reflection.stringArray(named: "qaFlags", in: rawReview) }
            guard !tags.isEmpty || !flagLabels.isEmpty else { return nil }
            return Review(
                id: Reflection.string(named: "id", in: rawReview) ?? UUID().uuidString.lowercased(),
                title: Reflection.string(named: "title", in: rawReview)
                    ?? (flagLabels.first.map { "\($0) • \(placeName)" })
                    ?? "Continuity review",
                summary: Reflection.string(named: "summary", in: rawReview)
                    ?? flagLabels.first
                    ?? Reflection.string(named: "notes", in: rawReview)
                    ?? "Review this worldbuilding mismatch.",
                severity: severity,
                placeID: placeID,
                placeName: placeName,
                routeID: routeID,
                nodeID: nodeID,
                recordID: Reflection.uuid(named: "candidateRecordID", in: rawReview)
                    ?? Reflection.uuid(named: "recordID", in: rawReview)
                    ?? Reflection.uuid(named: "generatedRecordID", in: rawReview),
                workflow: workflowMode,
                candidatePath: candidatePath,
                neighborPaths: Reflection.stringArray(named: "neighborPaths", in: rawReview)
                    .ifEmpty { Reflection.stringArray(named: "comparedImagePaths", in: rawReview) }
                    .ifEmpty { Reflection.stringArray(named: "referencePaths", in: rawReview) },
                mismatchTags: tags,
                statusText: Reflection.string(named: "statusText", in: rawReview)
                    ?? Reflection.string(named: "status", in: rawReview)
                    ?? severity.rawValue.capitalized
            )
        }
    }

    @MainActor
    private static func resolvedCanonPath(
        rawNode: Any,
        store: AnimateStore,
        recordID: UUID?,
        placeID: UUID?,
        workflowMode: PlaceWorkflowMode
    ) -> String? {
        if let directPath = Reflection.string(named: "canonImagePath", in: rawNode) {
            return directPath
        }
        switch workflowMode {
        case .photorealistic:
            if let photorealPath = Reflection.string(named: "approvedPhotorealImagePath", in: rawNode) {
                return photorealPath
            }
        case .animated:
            if let animatedPath = Reflection.string(named: "approvedAnimatedImagePath", in: rawNode) {
                return animatedPath
            }
        }
        if let recordID,
           let record = store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID }) {
            return record.activePath
        }
        if let placeID,
           let place = store.backgrounds.first(where: { $0.id == placeID }) {
            return place.approvedImagePath(for: workflowMode)
        }
        return nil
    }

    @MainActor
    private static func normalizedPoint(from rawNode: Any) -> PlacesWorldMapPoint? {
        if let point = normalizedPoint(in: rawNode) {
            return point
        }
        for label in ["mapPoint", "position", "point", "anchor"] {
            if let child = Reflection.child(named: label, in: rawNode),
               let point = normalizedPoint(in: child) {
                return point
            }
        }
        return nil
    }

    @MainActor
    private static func normalizedPoint(in rawValue: Any) -> PlacesWorldMapPoint? {
        let x = Reflection.double(named: "x", in: rawValue)
            ?? Reflection.double(named: "normalizedX", in: rawValue)
            ?? Reflection.double(named: "u", in: rawValue)
        let y = Reflection.double(named: "y", in: rawValue)
            ?? Reflection.double(named: "normalizedY", in: rawValue)
            ?? Reflection.double(named: "v", in: rawValue)
        guard let x, let y, (0...1).contains(x), (0...1).contains(y) else {
            return nil
        }
        return PlacesWorldMapPoint(x: CGFloat(x), y: CGFloat(y)).clamped
    }

    @MainActor
    private static func angleNodeTitle(place: BackgroundPlate, angleImage: PlaceAngleImage, index: Int) -> String {
        let shot = angleImage.cameraShot?.capitalized ?? "Coverage"
        return "\(place.name) • \(shot) \(index + 1)"
    }

    @MainActor
    private static func inferredLandmarks(for place: BackgroundPlate) -> [String] {
        let localRefs = place.referenceImages.prefix(3).map(\.title)
        guard !localRefs.isEmpty else {
            return place.notes
                .split(separator: ",")
                .prefix(3)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return localRefs
    }

    @MainActor
    private static func inferredNodeFlags(from angleImage: PlaceAngleImage, chosenPath: String?, approvedPath: String?) -> [String] {
        var flags: [String] = []
        if approvedPath == nil {
            flags.append("Choose canon")
        }
        if let notes = angleImage.notes.nilIfBlank,
           notes.localizedCaseInsensitiveContains("mismatch") || notes.localizedCaseInsensitiveContains("review") {
            flags.append("Check continuity")
        }
        if chosenPath == nil {
            flags.append("Missing image")
        }
        return flags
    }

    @MainActor
    private static func inferredHeading(angle: String?) -> Double {
        switch angle?.lowercased() {
        case "left": -90
        case "right": 90
        case "behind": 180
        case "overhead": -5
        case "low": 10
        default: 0
        }
    }

    @MainActor
    private static func inferredFocalLength(cameraShot: String?) -> Double {
        switch cameraShot?.lowercased() {
        case "extreme wide", "wide": 24
        case "medium": 50
        case "medium close": 70
        case "close", "extreme close": 85
        default: 35
        }
    }

    @MainActor
    private static func neighbors(for path: String, within paths: [String]) -> [String] {
        guard let index = paths.firstIndex(of: path) else { return Array(paths.prefix(3)) }
        var candidates: [String] = []
        if index > 0 { candidates.append(paths[index - 1]) }
        if index + 1 < paths.count { candidates.append(paths[index + 1]) }
        if index + 2 < paths.count { candidates.append(paths[index + 2]) }
        return candidates
    }

    @MainActor
    private static func parsedSeverity(_ value: String?) -> ReviewSeverity {
        let lowercased = value?.lowercased() ?? ""
        if lowercased.contains("critical") || lowercased.contains("reject") || lowercased.contains("fail") {
            return .critical
        }
        if lowercased.contains("warn") || lowercased.contains("review") || lowercased.contains("pending") {
            return .warning
        }
        return .info
    }

    @MainActor
    private static func severityRank(_ severity: ReviewSeverity) -> Int {
        switch severity {
        case .critical: 3
        case .warning: 2
        case .info: 1
        }
    }
}

import AppKit
import Combine
import Foundation
import ImageIO
import Vision

@available(macOS 26.0, *)
struct PlaceWorldAutoPlacement: Sendable {
    var mapPoint: WorldMapPoint
    var cameraPose: WorldCameraPose?
    var confidence: Double
    var source: String
    var inferredPlaceID: UUID?
    var inferredPlaceName: String?
    var sceneKind: PlaceWorldSceneKind
    var shouldMirrorPreview: Bool
    var diagnostics: [String]
}

@available(macOS 26.0, *)
struct PlaceWorldAutoPlacementInput: Sendable {
    var recordID: UUID
    var activePath: String
    var workflow: PlaceWorkflowMode
    var summary: String
    var keywords: [String]
    var sourcePrompt: String?
    var linkedPlaceID: UUID?
    var linkedPlaceName: String?
    var linkedPlaceNotes: String?
    var linkedPlacePromptNotes: String?
    var explicitMapPoint: WorldMapPoint?
    var explicitPose: WorldCameraPose?
}

@available(macOS 26.0, *)
enum PlaceWorldSceneKind: String, Sendable {
    case exterior
    case interior
    case mapReference
    case designStudy
    case ambiguous

    var displayName: String {
        switch self {
        case .exterior: "Exterior"
        case .interior: "Interior"
        case .mapReference: "Map"
        case .designStudy: "Design"
        case .ambiguous: "Uncertain"
        }
    }

    var isRenderableOnWorldMap: Bool {
        self != .mapReference && self != .designStudy
    }
}

@available(macOS 26.0, *)
private struct PlaceWorldCanonicalPlaceDescriptor: Sendable {
    var id: UUID
    var name: String
    var locationCategory: String
    var aliases: [String]
    var prototypeID: String?
    var anchorPoint: WorldMapPoint?
    var referenceImagePaths: [String]
}

@available(macOS 26.0, *)
final class PlaceWorldAutoPlacementService {
    private struct BatchPromptPinMetadata: Sendable {
        var mapPoint: WorldMapPoint?
        var heading: Double?
        var pitch: Double?
        var roll: Double?
        var focalLength: Double?
    }

    private struct Prototype {
        var id: String
        var point: WorldMapPoint
        var heading: Double?
        var aliases: [String]
        var preferredSceneKinds: Set<PlaceWorldSceneKind> = [.exterior, .interior, .designStudy, .ambiguous]
    }

    private var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
    private var histogramCache: [String: [Double]] = [:]
    private var resolutionRootURL: URL?

    func inferPlacements(
        inputs: [PlaceWorldAutoPlacementInput],
        places: [BackgroundPlate],
        animateURL: URL?
    ) async -> [UUID: PlaceWorldAutoPlacement] {
        guard !inputs.isEmpty else { return [:] }

        resolutionRootURL = animateURL?.deletingLastPathComponent()
        let batchMetadata = batchPromptPinMetadataLookup(animateURL: animateURL)
        let prototypes = canonicalPrototypes()
        let placeDescriptors = canonicalPlaceDescriptors(from: places, prototypes: prototypes)
        var placements: [UUID: PlaceWorldAutoPlacement] = [:]
        var prototypeAssignments: [UUID: String] = [:]
        var inferredPlaces: [UUID: PlaceWorldCanonicalPlaceDescriptor] = [:]
        var sceneKinds: [UUID: PlaceWorldSceneKind] = [:]

        for input in inputs {
            let sceneKind = sceneKind(for: input)
            sceneKinds[input.recordID] = sceneKind
            if let inferredPlace = matchedPlaceDescriptor(for: input, descriptors: placeDescriptors, sceneKind: sceneKind) {
                inferredPlaces[input.recordID] = inferredPlace
            }

            if let explicitMapPoint = input.explicitMapPoint {
                placements[input.recordID] = PlaceWorldAutoPlacement(
                    mapPoint: explicitMapPoint,
                    cameraPose: input.explicitPose,
                    confidence: 1.0,
                    source: "exact",
                    inferredPlaceID: input.linkedPlaceID ?? inferredPlaces[input.recordID]?.id,
                    inferredPlaceName: input.linkedPlaceName ?? inferredPlaces[input.recordID]?.name,
                    sceneKind: sceneKind,
                    shouldMirrorPreview: false,
                    diagnostics: []
                )
                continue
            }

            let stem = fileStem(for: input.activePath)
            if let batch = batchMetadata[stem], let batchPoint = batch.mapPoint {
                placements[input.recordID] = PlaceWorldAutoPlacement(
                    mapPoint: batchPoint,
                    cameraPose: WorldCameraPose(
                        yawDegrees: batch.heading ?? input.explicitPose?.yawDegrees ?? 0,
                        pitchDegrees: batch.pitch ?? input.explicitPose?.pitchDegrees ?? 0,
                        rollDegrees: batch.roll ?? input.explicitPose?.rollDegrees ?? 0,
                        focalLengthMM: batch.focalLength ?? input.explicitPose?.focalLengthMM ?? 35,
                        horizontalFOVDegrees: input.explicitPose?.horizontalFOVDegrees,
                        verticalFOVDegrees: input.explicitPose?.verticalFOVDegrees
                    ),
                    confidence: 0.98,
                    source: "batch_prompt",
                    inferredPlaceID: input.linkedPlaceID ?? inferredPlaces[input.recordID]?.id,
                    inferredPlaceName: input.linkedPlaceName ?? inferredPlaces[input.recordID]?.name,
                    sceneKind: sceneKind,
                    shouldMirrorPreview: false,
                    diagnostics: []
                )
                continue
            }

            let preferredPrototype = exactStemPrototype(
                for: stem,
                sceneKind: sceneKind,
                prototypes: prototypes,
                inferredPlace: inferredPlaces[input.recordID]
            ) ?? strongAnchorPrototype(
                for: input,
                prototypes: prototypes,
                inferredPlace: inferredPlaces[input.recordID],
                sceneKind: sceneKind
            )

            if let prototype = preferredPrototype {
                placements[input.recordID] = PlaceWorldAutoPlacement(
                    mapPoint: prototype.point,
                    cameraPose: prototype.heading.map {
                        WorldCameraPose(
                            yawDegrees: $0,
                            pitchDegrees: input.explicitPose?.pitchDegrees ?? 0,
                            rollDegrees: input.explicitPose?.rollDegrees ?? 0,
                            focalLengthMM: input.explicitPose?.focalLengthMM ?? 35,
                            horizontalFOVDegrees: input.explicitPose?.horizontalFOVDegrees,
                            verticalFOVDegrees: input.explicitPose?.verticalFOVDegrees
                        )
                    } ?? input.explicitPose,
                    confidence: exactStemPrototype(
                        for: stem,
                        sceneKind: sceneKind,
                        prototypes: prototypes,
                        inferredPlace: inferredPlaces[input.recordID]
                    ) != nil ? 0.95 : 0.90,
                    source: exactStemPrototype(
                        for: stem,
                        sceneKind: sceneKind,
                        prototypes: prototypes,
                        inferredPlace: inferredPlaces[input.recordID]
                    ) != nil ? "stem_profile" : "place_anchor",
                    inferredPlaceID: input.linkedPlaceID ?? inferredPlaces[input.recordID]?.id,
                    inferredPlaceName: input.linkedPlaceName ?? inferredPlaces[input.recordID]?.name,
                    sceneKind: sceneKind,
                    shouldMirrorPreview: false,
                    diagnostics: []
                )
                prototypeAssignments[input.recordID] = prototype.id
            }
        }

        let anchoredInputs = inputs.filter { placements[$0.recordID] != nil }
        let resolvedAnchors = anchoredInputs.compactMap { input -> (PlaceWorldAutoPlacementInput, PlaceWorldAutoPlacement)? in
            guard let placement = placements[input.recordID] else { return nil }
            return (input, placement)
        }

        for input in inputs where placements[input.recordID] == nil {
            let sceneKind = sceneKinds[input.recordID] ?? sceneKind(for: input)
            if let inherited = inheritedPlacement(
                for: input,
                anchors: resolvedAnchors,
                prototypes: prototypes,
                inferredPlace: inferredPlaces[input.recordID],
                sceneClassification: sceneKind
            ) {
                placements[input.recordID] = inherited
                continue
            }

            if let inferredPlace = inferredPlaces[input.recordID],
               let point = inferredPlace.anchorPoint ?? prototype(withID: inferredPlace.prototypeID, prototypes: prototypes)?.point {
                let heading = prototype(withID: inferredPlace.prototypeID, prototypes: prototypes)?.heading
                placements[input.recordID] = PlaceWorldAutoPlacement(
                    mapPoint: point,
                    cameraPose: heading.map {
                        WorldCameraPose(
                            yawDegrees: $0,
                            pitchDegrees: input.explicitPose?.pitchDegrees ?? 0,
                            rollDegrees: input.explicitPose?.rollDegrees ?? 0,
                            focalLengthMM: input.explicitPose?.focalLengthMM ?? 35,
                            horizontalFOVDegrees: input.explicitPose?.horizontalFOVDegrees,
                            verticalFOVDegrees: input.explicitPose?.verticalFOVDegrees
                        )
                    } ?? input.explicitPose,
                    confidence: inferredPlace.anchorPoint == nil ? 0.74 : 0.92,
                    source: inferredPlace.anchorPoint == nil ? "place_match" : "place_anchor_existing",
                    inferredPlaceID: inferredPlace.id,
                    inferredPlaceName: inferredPlace.name,
                    sceneKind: sceneKind,
                    shouldMirrorPreview: false,
                    diagnostics: sceneKind == .interior ? ["Interior anchored to building location"] : []
                )
            }
        }

        let groupedByBucket = Dictionary(grouping: inputs.compactMap { input -> (String, PlaceWorldAutoPlacementInput, PlaceWorldAutoPlacement)? in
            guard let placement = placements[input.recordID] else { return nil }
            let bucket = prototypeAssignments[input.recordID]
                ?? strongAnchorPrototype(
                    for: input,
                    prototypes: prototypes,
                    inferredPlace: inferredPlaces[input.recordID],
                    sceneKind: sceneKinds[input.recordID] ?? self.sceneKind(for: input)
                )?.id
                ?? (input.linkedPlaceID?.uuidString ?? "world")
            return (bucket, input, placement)
        }, by: { $0.0 })

        for (_, group) in groupedByBucket {
            let sorted = group.sorted { lhs, rhs in
                lhs.1.summary.localizedCaseInsensitiveCompare(rhs.1.summary) == .orderedAscending
            }
            for (index, entry) in sorted.enumerated() {
                guard var placement = placements[entry.1.recordID] else { continue }
                let baseRadius = max(0.006, 0.024 * (1.0 - placement.confidence))
                let offset = stableClusterOffset(index: index, key: entry.1.activePath, radius: baseRadius)
                placement.mapPoint = WorldMapPoint(
                    x: min(max(placement.mapPoint.x + offset.x, 0.03), 0.97),
                    y: min(max(placement.mapPoint.y + offset.y, 0.03), 0.97)
                )
                placements[entry.1.recordID] = placement
            }
        }

        for input in inputs {
            guard var placement = placements[input.recordID] else { continue }
            let mirrorScore = mirrorPreferenceScore(
                for: input,
                placement: placement,
                inferredPlace: inferredPlaces[input.recordID],
                prototypes: prototypes
            )
            if mirrorScore > 0.10 {
                placement.shouldMirrorPreview = true
                placement.diagnostics.append("Mirror-suspect composition")
                placement.confidence = max(0.32, placement.confidence - 0.08)
            }
            placements[input.recordID] = placement
        }

        return placements.filter { $0.value.sceneKind.isRenderableOnWorldMap }
    }

    private func inheritedPlacement(
        for input: PlaceWorldAutoPlacementInput,
        anchors: [(PlaceWorldAutoPlacementInput, PlaceWorldAutoPlacement)],
        prototypes: [Prototype],
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        sceneClassification: PlaceWorldSceneKind
    ) -> PlaceWorldAutoPlacement? {
        guard !anchors.isEmpty else { return nil }

        let bestSemanticPrototype = bestPrototype(
            for: input,
            prototypes: prototypes,
            inferredPlace: inferredPlace,
            sceneKind: sceneClassification
        )
        let candidateAnchors = anchors.filter { anchorInput, _ in
            if let placeID = input.linkedPlaceID, placeID == anchorInput.linkedPlaceID {
                return true
            }
            if let inferredPlace, inferredPlace.id == anchorInput.linkedPlaceID {
                return true
            }
            let inputPrototype = bestSemanticPrototype?.id
            let anchorPrototype = strongAnchorPrototype(
                for: anchorInput,
                prototypes: prototypes,
                inferredPlace: inferredPlace,
                sceneKind: self.sceneKind(for: anchorInput)
            )?.id
                ?? bestPrototype(
                    for: anchorInput,
                    prototypes: prototypes,
                    inferredPlace: inferredPlace,
                    sceneKind: self.sceneKind(for: anchorInput)
                )?.id
            if inputPrototype != nil, inputPrototype == anchorPrototype {
                return true
            }
            return lexicalOverlapScore(lhs: metadataText(for: input), rhs: metadataText(for: anchorInput)) > 0.18
        }

        let filteredAnchors = candidateAnchors.isEmpty ? anchors : candidateAnchors
        let inputURL = resolvedURL(for: input.activePath)
        var weighted: [(PlaceWorldAutoPlacement, Double)] = []

        for (anchorInput, anchorPlacement) in filteredAnchors {
            var score = lexicalOverlapScore(lhs: metadataText(for: input), rhs: metadataText(for: anchorInput))
            if input.linkedPlaceID != nil, input.linkedPlaceID == anchorInput.linkedPlaceID {
                score += 0.45
            }
            if let inferredPlace, inferredPlace.id == anchorInput.linkedPlaceID {
                score += 0.35
            }
            if let inputURL,
               let anchorURL = resolvedURL(for: anchorInput.activePath) {
                score += (featureSimilarity(lhs: inputURL, rhs: anchorURL) * 0.35)
                score += (histogramSimilarity(lhs: inputURL, rhs: anchorURL) * 0.15)
            }
            if score > 0.12 {
                weighted.append((anchorPlacement, score))
            }
        }

        let topAnchors = weighted.sorted { $0.1 > $1.1 }.prefix(3)
        guard !topAnchors.isEmpty else { return nil }

        let totalWeight = topAnchors.reduce(0.0) { $0 + $1.1 }
        let x = topAnchors.reduce(0.0) { $0 + ($1.0.mapPoint.x * $1.1) } / totalWeight
        let y = topAnchors.reduce(0.0) { $0 + ($1.0.mapPoint.y * $1.1) } / totalWeight
        let headingValues = topAnchors.compactMap { $0.0.cameraPose?.yawDegrees }
        let focalValues = topAnchors.compactMap { $0.0.cameraPose?.focalLengthMM }

        return PlaceWorldAutoPlacement(
            mapPoint: WorldMapPoint(x: x, y: y),
            cameraPose: WorldCameraPose(
                yawDegrees: circularMean(headingValues) ?? input.explicitPose?.yawDegrees ?? bestSemanticPrototype?.heading ?? 0,
                pitchDegrees: input.explicitPose?.pitchDegrees ?? 0,
                rollDegrees: input.explicitPose?.rollDegrees ?? 0,
                focalLengthMM: focalValues.isEmpty ? (input.explicitPose?.focalLengthMM ?? 35) : (focalValues.reduce(0, +) / Double(focalValues.count)),
                horizontalFOVDegrees: input.explicitPose?.horizontalFOVDegrees,
                verticalFOVDegrees: input.explicitPose?.verticalFOVDegrees
            ),
            confidence: min(0.86, max(0.5, totalWeight / Double(topAnchors.count))),
            source: "visual_inference",
            inferredPlaceID: input.linkedPlaceID ?? inferredPlace?.id,
            inferredPlaceName: input.linkedPlaceName ?? inferredPlace?.name,
            sceneKind: sceneClassification,
            shouldMirrorPreview: false,
            diagnostics: []
        )
    }

    private func strongAnchorPrototype(
        for input: PlaceWorldAutoPlacementInput,
        prototypes: [Prototype],
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        sceneKind: PlaceWorldSceneKind
    ) -> Prototype? {
        let haystack = strongAnchorText(for: input)
        guard !haystack.isEmpty || inferredPlace?.prototypeID != nil else { return nil }
        let allowedIDs = preferredPrototypeIDs(for: input, inferredPlace: inferredPlace, sceneKind: sceneKind)
        return prototypes
            .compactMap { prototype -> (Prototype, Double)? in
                if let allowedIDs, !allowedIDs.contains(prototype.id) {
                    return nil
                }
                if !prototype.preferredSceneKinds.contains(sceneKind) && sceneKind != .ambiguous {
                    return nil
                }
                let score = prototype.aliases.reduce(0.0) { partial, alias in
                    let aliasLower = alias.lowercased()
                    guard haystack.contains(aliasLower) else { return partial }
                    return partial + (aliasLower.contains(" ") ? 1.25 : 0.65)
                }
                let boostedScore = score + ((prototype.id == inferredPlace?.prototypeID) ? 0.9 : 0)
                return boostedScore > 0 ? (prototype, boostedScore) : nil
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    private func canonicalPrototypes() -> [Prototype] {
        [
            Prototype(id: "ridge_overlook", point: .init(x: 0.115, y: 0.315), heading: 110, aliases: ["the ridge", "ridge overlook", "ridge dawn", "mountain valley road", "convoy unload", "valley road", "base gate", "base perimeter"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "west_approach", point: .init(x: 0.18, y: 0.38), heading: 92, aliases: ["west approach", "west road", "south ridge", "high west ridge", "southwest long lens", "glacier context"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "base_tents", point: .init(x: 0.14, y: 0.19), heading: 95, aliases: ["comms tent", "operations tent", "tent row", "briefing room", "barracks", "base tent", "base roof", "base interior"], preferredSceneKinds: [.interior, .exterior, .ambiguous]),
            Prototype(id: "memorial", point: .init(x: 0.235, y: 0.57), heading: 70, aliases: ["grave marker", "yasmin", "memorial", "cemetery", "river road", "riverbank", "ancient waters"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "riverside", point: .init(x: 0.44, y: 0.565), heading: 72, aliases: ["riverside", "river bend", "lower town riverside", "blue hour across river", "river path and town"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "bridge_ridge_approach", point: .init(x: 0.285, y: 0.505), heading: 86, aliases: ["bridge approach ridge", "approach ridge", "approach from the base", "ridge side of bridge", "bridge ahead"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "bridge_midspan", point: .init(x: 0.34, y: 0.5), heading: 90, aliases: ["the bridge", "bridge", "midspan", "onto the bridge", "stone bridge", "single-lane stone bridge"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "bridge_village_approach", point: .init(x: 0.40, y: 0.505), heading: 82, aliases: ["bridge approach village", "approach village", "town-side end of bridge", "bridge behind", "bridge end"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "marketplace", point: .init(x: 0.47, y: 0.505), heading: 77, aliases: ["marketplace", "town center", "market wall", "rubble field", "bombing site", "photo shop", "market entry"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "photo_shop", point: .init(x: 0.515, y: 0.492), heading: 74, aliases: ["photo shop", "film shop", "developing room", "photo lab"], preferredSceneKinds: [.interior, .exterior, .ambiguous]),
            Prototype(id: "village_streets", point: .init(x: 0.585, y: 0.47), heading: 67, aliases: ["village street", "streets", "main road", "back alleys", "alley", "rooftop", "upper street", "village"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "village_edge", point: .init(x: 0.72, y: 0.355), heading: 52, aliases: ["village edge", "upper slope", "terraces", "residential lane", "neighborhood edge"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous]),
            Prototype(id: "gathering_space", point: .init(x: 0.655, y: 0.445), heading: 60, aliases: ["gathering space", "community center", "mosque", "courtyard"], preferredSceneKinds: [.interior, .exterior, .ambiguous]),
            Prototype(id: "amira_home", point: .init(x: 0.715, y: 0.425), heading: 58, aliases: ["amira's home", "quiet moment", "home"], preferredSceneKinds: [.interior, .exterior, .ambiguous]),
            Prototype(id: "clinic", point: .init(x: 0.79, y: 0.39), heading: 50, aliases: ["clinic", "clinic doorway", "clinic edge", "back room", "treatment area"], preferredSceneKinds: [.interior, .exterior, .ambiguous]),
            Prototype(id: "shepherds_huts", point: .init(x: 0.885, y: 0.29), heading: 35, aliases: ["shepherd", "huts", "hillside", "sunrise", "escape destination", "mountain overlook"], preferredSceneKinds: [.exterior, .designStudy, .ambiguous])
        ]
    }

    private func bestPrototype(
        for input: PlaceWorldAutoPlacementInput,
        prototypes: [Prototype],
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        sceneKind: PlaceWorldSceneKind
    ) -> Prototype? {
        let haystack = metadataText(for: input)
        let allowedIDs = preferredPrototypeIDs(for: input, inferredPlace: inferredPlace, sceneKind: sceneKind)
        return prototypes
            .compactMap { prototype -> (Prototype, Double)? in
                if let allowedIDs, !allowedIDs.contains(prototype.id) {
                    return nil
                }
                if !prototype.preferredSceneKinds.contains(sceneKind) && sceneKind != .ambiguous {
                    return nil
                }
                let score = prototype.aliases.reduce(0.0) { partial, alias in
                    let aliasLower = alias.lowercased()
                    guard haystack.contains(aliasLower) else { return partial }
                    return partial + (aliasLower.contains(" ") ? 1.1 : 0.45)
                }
                let boostedScore = score + ((prototype.id == inferredPlace?.prototypeID) ? 0.8 : 0)
                return boostedScore > 0 ? (prototype, boostedScore) : nil
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    private func preferredPrototypeIDs(
        for input: PlaceWorldAutoPlacementInput,
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        sceneKind: PlaceWorldSceneKind
    ) -> Set<String>? {
        let text = metadataText(for: input)
        if let prototypeID = inferredPlace?.prototypeID {
            if sceneKind == .interior {
                return [prototypeID]
            }
        }
        if text.contains("amira") && text.contains("home") { return ["amira_home"] }
        if text.contains("gathering space") || text.contains("community center") || text.contains("mosque") {
            return ["gathering_space"]
        }
        if text.contains("photo shop") || text.contains("film shop") || text.contains("developing room") || text.contains("photo lab") {
            return ["photo_shop"]
        }
        if text.contains("clinic") || text.contains("treatment area") || text.contains("back room") || text.contains("clinic doorway") {
            return ["clinic"]
        }
        if text.contains("shepherd") || text.contains("huts") {
            return ["shepherds_huts"]
        }
        if text.contains("bridge") {
            return ["bridge_ridge_approach", "bridge_midspan", "bridge_village_approach"]
        }
        if text.contains("grave") || text.contains("memorial") || text.contains("cemetery") || text.contains("yasmin") || text.contains("riverbank") {
            return ["memorial"]
        }
        if text.contains("riverside") || text.contains("river bend") || text.contains("across river") {
            return ["riverside", "memorial"]
        }
        if text.contains("market") || text.contains("rubble") {
            return ["marketplace", "photo_shop"]
        }
        if text.contains("base") || text.contains("tent") || text.contains("comms") || text.contains("operations") || text.contains("bunk") {
            return ["base_tents", "ridge_overlook", "west_approach"]
        }
        if text.contains("ridge") || text.contains("overlook") || text.contains("convoy") {
            return ["ridge_overlook", "west_approach"]
        }
        if text.contains("village edge") || text.contains("terrace") || text.contains("upper slope") || text.contains("residential lane") {
            return ["village_edge", "shepherds_huts", "village_streets"]
        }
        if text.contains("village street") || text.contains("village") || text.contains("alley") || text.contains("lane") || text.contains("rooftop") {
            return ["village_streets", "village_edge", "gathering_space", "amira_home", "clinic", "marketplace", "photo_shop"]
        }
        return nil
    }

    private func sceneKind(for input: PlaceWorldAutoPlacementInput) -> PlaceWorldSceneKind {
        let text = metadataText(for: input)
        let mapTerms = [
            "master map",
            "world map",
            "topdown",
            "top-down",
            "bird's-eye",
            "satellite view",
            "orthographic"
        ]
        if mapTerms.contains(where: text.contains) {
            return .mapReference
        }

        let interiorTerms = [
            "interior",
            "room",
            "back room",
            "bunk",
            "briefing",
            "operations tent",
            "comms tent",
            "clinic treatment",
            "treatment area",
            "lamplight",
            "inside",
            "home",
            "quiet moment"
        ]
        if interiorTerms.contains(where: text.contains) {
            return .interior
        }

        let designTerms = [
            "design",
            "study",
            "geometry",
            "profile",
            "documentary",
            "hero wide"
        ]
        if designTerms.contains(where: text.contains) {
            return .designStudy
        }

        return .exterior
    }

    private func canonicalPlaceDescriptors(
        from places: [BackgroundPlate],
        prototypes: [Prototype]
    ) -> [PlaceWorldCanonicalPlaceDescriptor] {
        places.map { place in
            let aliases = placeAliasTokens(for: place)
            let prototypeID = prototypes
                .compactMap { prototype -> (String, Double)? in
                    let score = prototype.aliases.reduce(0.0) { partial, alias in
                        aliases.contains(alias.lowercased()) ? partial + 1 : partial
                    }
                    return score > 0 ? (prototype.id, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .first?
                .0
            let anchorPoint = prototype(withID: prototypeID, prototypes: prototypes)?.point
            return PlaceWorldCanonicalPlaceDescriptor(
                id: place.id,
                name: place.name,
                locationCategory: place.locationCategory,
                aliases: aliases,
                prototypeID: prototypeID,
                anchorPoint: anchorPoint,
                referenceImagePaths: Array(
                    Set(
                        place.imagePaths
                        + place.animatedImagePaths
                        + [place.approvedImagePath, place.animatedApprovedImagePath].compactMap { $0 }
                        + place.referenceImages.map(\.imagePath)
                    )
                )
            )
        }
    }

    private func matchedPlaceDescriptor(
        for input: PlaceWorldAutoPlacementInput,
        descriptors: [PlaceWorldCanonicalPlaceDescriptor],
        sceneKind: PlaceWorldSceneKind
    ) -> PlaceWorldCanonicalPlaceDescriptor? {
        if let linkedPlaceID = input.linkedPlaceID,
           let linked = descriptors.first(where: { $0.id == linkedPlaceID }) {
            return linked
        }

        let text = metadataText(for: input)
        let stem = fileStem(for: input.activePath).replacingOccurrences(of: "-", with: " ")
        let scored = descriptors.compactMap { descriptor -> (PlaceWorldCanonicalPlaceDescriptor, Double)? in
            let overlapScore = descriptor.aliases.reduce(0.0) { partial, alias in
                let aliasLower = alias.lowercased()
                guard !aliasLower.isEmpty, text.contains(aliasLower) || stem.contains(aliasLower) else {
                    return partial
                }
                return partial + (aliasLower.contains(" ") ? 1.2 : 0.45)
            }

            var score = overlapScore
            if !descriptor.locationCategory.isEmpty {
                if sceneKind == .interior, descriptor.locationCategory.caseInsensitiveCompare("Interior") == .orderedSame {
                    score += 0.8
                }
                if sceneKind != .interior, descriptor.locationCategory.caseInsensitiveCompare("Exterior") == .orderedSame {
                    score += 0.35
                }
            }
            if descriptor.name.lowercased().contains("clinic"), text.contains("clinic") {
                score += 1.0
            }
            if descriptor.name.lowercased().contains("bridge"), text.contains("bridge") {
                score += 1.0
            }
            if descriptor.name.lowercased().contains("amira"), text.contains("amira") {
                score += 1.0
            }
            return score > 0 ? (descriptor, score) : nil
        }
        .sorted { $0.1 > $1.1 }

        guard let best = scored.first else { return nil }
        let second = scored.dropFirst().first?.1 ?? 0
        guard best.1 >= 1.2, best.1 >= second + 0.35 else { return nil }
        return best.0
    }

    private func exactStemPrototype(
        for stem: String,
        sceneKind: PlaceWorldSceneKind,
        prototypes: [Prototype],
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?
    ) -> Prototype? {
        let normalizedStem = stem.lowercased()
        let explicitMappings: [(matches: (String) -> Bool, prototypeID: String)] = [
            ({ $0.hasPrefix("town-01") || $0.hasPrefix("town-wide-21") || $0.hasPrefix("town-wide-22") || $0.hasPrefix("town-wide-34") || $0.hasPrefix("town-wide-36") }, "ridge_overlook"),
            ({ $0.hasPrefix("town-02") || $0.hasPrefix("town-wide-23") || $0.hasPrefix("town-wide-26") || $0.hasPrefix("town-wide-27") || $0.hasPrefix("town-wide-40") || $0.contains("west-road") }, "west_approach"),
            ({ $0.hasPrefix("town-03") || $0.hasPrefix("town-wide-30") || $0.hasPrefix("town-wide-35") }, "riverside"),
            ({ $0.hasPrefix("town-04") || $0.hasPrefix("town-05") || $0.hasPrefix("town-06") || $0.hasPrefix("confirm-market") || $0.contains("market-entry") }, "marketplace"),
            ({ $0.hasPrefix("town-07") || $0.hasPrefix("town-08") || $0.hasPrefix("town-09") || $0.hasPrefix("town-10") || $0.hasPrefix("town-wide-38") || $0.contains("alley") }, "village_streets"),
            ({ $0.hasPrefix("town-11") || $0.hasPrefix("town-19") || $0.hasPrefix("town-wide-31") || $0.hasPrefix("town-wide-32") || $0.hasPrefix("town-wide-37") }, "village_edge"),
            ({ $0.hasPrefix("town-12") || $0.contains("gathering-space") || $0.contains("gathering_space") }, "gathering_space"),
            ({ $0.hasPrefix("town-13") || $0.hasPrefix("town-14") || $0.hasPrefix("town-15") || $0.contains("clinic") }, "clinic"),
            ({ $0.hasPrefix("town-16") || $0.hasPrefix("town-17") || $0.hasPrefix("town-wide-39") || $0.contains("bridge-into-town") || $0.contains("town-toward-bridge") }, "bridge_village_approach"),
            ({ $0.hasPrefix("town-18") || $0.hasPrefix("town-wide-24") || $0.hasPrefix("town-wide-25") || $0.contains("grave-marker") || $0.contains("river-road") }, "memorial"),
            ({ $0.contains("bridge-design-01") || $0.contains("bridge-design-04") || $0.contains("bridge-design-10") }, "bridge_midspan"),
            ({ $0.contains("bridge-design-02") || $0.contains("bridge-design-09") || $0.contains("confirm-town-side-bridge-exit") }, "bridge_village_approach"),
            ({ $0.contains("bridge-design-03") || $0.contains("bridge-design-05") || $0.contains("bridge-design-06") || $0.contains("retry-bridge-approach") || $0.contains("route-west-approach") }, "bridge_ridge_approach"),
            ({ $0.contains("bridge-design-07") || $0.contains("bridge-design-08") || $0.contains("bridge-hero") }, "bridge_midspan"),
            ({ $0.contains("amiras_home") || $0.contains("quiet-moment") }, "amira_home"),
            ({ $0.contains("photo-shop") || $0.contains("film-shop") }, "photo_shop"),
            ({ $0.contains("briefing-room") || $0.contains("operations-tent") || $0.contains("comms-tent") || $0.contains("bunk") }, "base_tents"),
            ({ $0.contains("hillside") || $0.contains("shepherd") }, "shepherds_huts")
        ]

        if let match = explicitMappings.first(where: { $0.matches(normalizedStem) }) {
            return prototype(withID: match.prototypeID, prototypes: prototypes)
        }

        if sceneKind == .interior, let prototypeID = inferredPlace?.prototypeID {
            return prototype(withID: prototypeID, prototypes: prototypes)
        }

        return nil
    }

    private func prototype(withID id: String?, prototypes: [Prototype]) -> Prototype? {
        guard let id else { return nil }
        return prototypes.first(where: { $0.id == id })
    }

    private func mirrorPreferenceScore(
        for input: PlaceWorldAutoPlacementInput,
        placement: PlaceWorldAutoPlacement,
        inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        prototypes: [Prototype]
    ) -> Double {
        guard placement.sceneKind != .mapReference,
              let inputURL = resolvedURL(for: input.activePath) else {
            return 0
        }

        let candidateReferencePaths = referenceImagePaths(
            for: inferredPlace,
            prototypes: prototypes,
            input: input
        )
        guard !candidateReferencePaths.isEmpty else { return 0 }

        var bestDelta = 0.0
        for referenceURL in candidateReferencePaths {
            let original = featureSimilarity(lhs: inputURL, rhs: referenceURL) * 0.7
                + histogramSimilarity(lhs: inputURL, rhs: referenceURL) * 0.3
            let mirrored = mirroredFeatureSimilarity(lhs: inputURL, rhs: referenceURL) * 0.7
                + mirroredHistogramSimilarity(lhs: inputURL, rhs: referenceURL) * 0.3
            bestDelta = max(bestDelta, mirrored - original)
        }
        return bestDelta
    }

    private func referenceImagePaths(
        for inferredPlace: PlaceWorldCanonicalPlaceDescriptor?,
        prototypes: [Prototype],
        input: PlaceWorldAutoPlacementInput
    ) -> [URL] {
        var urls: [URL] = []
        if let inferredPlace {
            for path in inferredPlace.referenceImagePaths.prefix(4) {
                if let url = resolvedURL(for: path) {
                    urls.append(url)
                }
            }
        }
        return Array(Set(urls))
    }

    private func placeAliasTokens(for place: BackgroundPlate) -> [String] {
        let sources = [
            place.name,
            place.filename,
            place.notes,
            place.workflowPromptNotes,
            place.referenceImages.map(\.title).joined(separator: " ")
        ]
        let lowered = sources.joined(separator: " ").lowercased()
        let normalized = lowered
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
        let ignored: Set<String> = [
            "day", "night", "morning", "evening", "afternoon", "late", "early", "pre", "dawn",
            "dusk", "twilight", "continuous", "later", "same", "that", "into", "after", "before",
            "weeks", "memory", "flashback", "scene", "the", "and", "from", "with", "room", "view"
        ]
        let tokens = normalized
            .split(separator: " ")
            .map { String($0) }
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !ignored.contains($0) }
        let phrases = [
            place.name.lowercased(),
            place.filename.lowercased().replacingOccurrences(of: "_", with: " "),
            place.workflowPromptNotes.lowercased()
        ]
        .map {
            $0.replacingOccurrences(of: "/", with: " ")
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        return Array(Set(tokens + phrases))
    }

    private func metadataText(for input: PlaceWorldAutoPlacementInput) -> String {
        [
            input.summary,
            input.keywords.joined(separator: " "),
            input.sourcePrompt ?? "",
            input.linkedPlaceName ?? "",
            input.linkedPlaceNotes ?? "",
            input.linkedPlacePromptNotes ?? "",
            pathContext(for: input.activePath),
            fileStem(for: input.activePath).replacingOccurrences(of: "-", with: " ")
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func strongAnchorText(for input: PlaceWorldAutoPlacementInput) -> String {
        [
            input.linkedPlaceName ?? "",
            input.linkedPlaceNotes ?? "",
            input.linkedPlacePromptNotes ?? "",
            pathContext(for: input.activePath),
            fileStem(for: input.activePath).replacingOccurrences(of: "-", with: " ")
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func fileStem(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
    }

    private func pathContext(for path: String) -> String {
        let ignored: Set<String> = [
            "animate", "backgrounds", "places", "photoreal", "photorealistic", "animated",
            "outputs", "pipeline", "tests", "batches", "place-batches"
        ]
        return path
            .lowercased()
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && !ignored.contains($0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func lexicalOverlapScore(lhs: String, rhs: String) -> Double {
        let left = Set(tokens(from: lhs))
        let right = Set(tokens(from: rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func tokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    private func stableClusterOffset(index: Int, key: String, radius: Double) -> (x: Double, y: Double) {
        let hash = abs(key.hashValue)
        let angle = Double((hash + index * 37) % 360) * (.pi / 180)
        let ring = 0.35 + (Double((hash / 97) % 100) / 100.0)
        return (cos(angle) * radius * ring, sin(angle) * radius * ring)
    }

    private func circularMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sinSum = values.reduce(0.0) { $0 + sin($1 * .pi / 180) }
        let cosSum = values.reduce(0.0) { $0 + cos($1 * .pi / 180) }
        guard sinSum != 0 || cosSum != 0 else { return nil }
        let angle = atan2(sinSum, cosSum) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    private func batchPromptPinMetadataLookup(animateURL: URL?) -> [String: BatchPromptPinMetadata] {
        guard let animateURL else { return [:] }
        let rootURL = ProjectPaths(root: animateURL.deletingLastPathComponent()).animatePlaceBatches
        guard FileManager.default.fileExists(atPath: rootURL.path),
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return [:]
        }

        var lookup: [String: BatchPromptPinMetadata] = [:]
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "batch_submission.json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let manifest = (json["prompt_manifest"] as? [[String: Any]]) ?? []
            for entry in manifest {
                let identifier = (entry["id"] as? String)?.lowercased()
                    ?? URL(fileURLWithPath: (entry["title"] as? String) ?? "").deletingPathExtension().lastPathComponent.lowercased()
                let prompt = (entry["prompt"] as? String) ?? ""
                lookup[identifier] = BatchPromptPinMetadata(
                    mapPoint: parsedMapPoint(prompt),
                    heading: parsedScalar(prompt, marker: "Camera pose: heading ", terminator: " degrees"),
                    pitch: parsedScalar(prompt, marker: "pitch ", terminator: " degrees"),
                    roll: parsedScalar(prompt, marker: "roll ", terminator: " degrees"),
                    focalLength: parsedScalar(prompt, marker: "focal length ", terminator: "mm")
                )
            }
        }
        return lookup
    }

    private func parsedMapPoint(_ prompt: String) -> WorldMapPoint? {
        guard let x = parsedScalar(prompt, marker: "Map anchor: normalized x ", terminator: ","),
              let y = parsedScalar(prompt, marker: "y ", terminator: " on the master map") else {
            return nil
        }
        return WorldMapPoint(x: x, y: y)
    }

    private func parsedScalar(_ prompt: String, marker: String, terminator: String) -> Double? {
        guard let markerRange = prompt.range(of: marker) else { return nil }
        let remainder = prompt[markerRange.upperBound...]
        guard let terminatorRange = remainder.range(of: terminator) else { return nil }
        return Double(remainder[..<terminatorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolvedURL(for path: String) -> URL? {
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let resolutionRootURL {
            let projectRelative = resolutionRootURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: projectRelative.path) {
                return projectRelative
            }
        }
        let cwdRelative = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if FileManager.default.fileExists(atPath: cwdRelative.path) {
            return cwdRelative
        }
        return nil
    }

    private func featureSimilarity(lhs: URL, rhs: URL) -> Double {
        guard let lhsFeature = featurePrint(for: lhs),
              let rhsFeature = featurePrint(for: rhs) else { return 0 }
        do {
            var distance: Float = 0
            try lhsFeature.computeDistance(&distance, to: rhsFeature)
            return max(0, min(1, 1 - (Double(distance) / 25.0)))
        } catch {
            return 0
        }
    }

    private func mirroredFeatureSimilarity(lhs: URL, rhs: URL) -> Double {
        guard let lhsFeature = mirroredFeaturePrint(for: lhs),
              let rhsFeature = featurePrint(for: rhs) else { return 0 }
        do {
            var distance: Float = 0
            try lhsFeature.computeDistance(&distance, to: rhsFeature)
            return max(0, min(1, 1 - (Double(distance) / 25.0)))
        } catch {
            return 0
        }
    }

    private func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        if let cached = featurePrintCache[url.path] {
            return cached
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
            let observation = request.results?.first as? VNFeaturePrintObservation
            if let observation {
                featurePrintCache[url.path] = observation
            }
            return observation
        } catch {
            return nil
        }
    }

    private func mirroredFeaturePrint(for url: URL) -> VNFeaturePrintObservation? {
        let cacheKey = "\(url.path)::mirrored"
        if let cached = featurePrintCache[cacheKey] {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let mirrored = mirroredCGImage(cgImage) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: mirrored, options: [:])
        do {
            try handler.perform([request])
            let observation = request.results?.first as? VNFeaturePrintObservation
            if let observation {
                featurePrintCache[cacheKey] = observation
            }
            return observation
        } catch {
            return nil
        }
    }

    private func histogramSimilarity(lhs: URL, rhs: URL) -> Double {
        guard let lhsHistogram = grayscaleHistogram(for: lhs),
              let rhsHistogram = grayscaleHistogram(for: rhs) else { return 0 }
        let dot = zip(lhsHistogram, rhsHistogram).reduce(0.0) { $0 + ($1.0 * $1.1) }
        let lhsMag = sqrt(lhsHistogram.reduce(0.0) { $0 + ($1 * $1) })
        let rhsMag = sqrt(rhsHistogram.reduce(0.0) { $0 + ($1 * $1) })
        guard lhsMag > 0, rhsMag > 0 else { return 0 }
        return max(0, min(1, dot / (lhsMag * rhsMag)))
    }

    private func mirroredHistogramSimilarity(lhs: URL, rhs: URL) -> Double {
        guard let lhsHistogram = grayscaleHistogram(for: lhs, mirrored: true),
              let rhsHistogram = grayscaleHistogram(for: rhs) else { return 0 }
        let dot = zip(lhsHistogram, rhsHistogram).reduce(0.0) { $0 + ($1.0 * $1.1) }
        let lhsMag = sqrt(lhsHistogram.reduce(0.0) { $0 + ($1 * $1) })
        let rhsMag = sqrt(rhsHistogram.reduce(0.0) { $0 + ($1 * $1) })
        guard lhsMag > 0, rhsMag > 0 else { return 0 }
        return max(0, min(1, dot / (lhsMag * rhsMag)))
    }

    private func grayscaleHistogram(for url: URL) -> [Double]? {
        grayscaleHistogram(for: url, mirrored: false)
    }

    private func grayscaleHistogram(for url: URL, mirrored: Bool) -> [Double]? {
        let cacheKey = mirrored ? "\(url.path)::mirrored" : url.path
        if let cached = histogramCache[cacheKey] {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let cgImage = mirrored ? (mirroredCGImage(sourceImage) ?? sourceImage) : sourceImage

        let width = 48
        let height = 48
        let bytesPerRow = width
        var data = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var histogram = [Double](repeating: 0, count: 16)
        for value in data {
            let bucket = min(15, Int(value) / 16)
            histogram[bucket] += 1
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let normalized = histogram.map { $0 / total }
        histogramCache[cacheKey] = normalized
        return normalized
    }

    private func mirroredCGImage(_ cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: CGFloat(width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}

@available(macOS 26.0, *)
@MainActor
final class PlacesWorldAutoPlacementModel: ObservableObject {
    @Published private(set) var placements: [UUID: PlaceWorldAutoPlacement] = [:]
    @Published private(set) var isRefreshing = false

    private let service = PlaceWorldAutoPlacementService()
    private var refreshTask: Task<Void, Never>?

    func refresh(store: AnimateStore, snapshot: PlacesWorldbuildingSnapshot, workflowMode: PlaceWorkflowMode) {
        let placesByID = Dictionary(uniqueKeysWithValues: store.backgrounds.map { ($0.id, $0) })
        let inputs = store.visibleGeneratedBackgroundLibraryRecords()
            .filter { $0.workflow == workflowMode && isWorldMapEligibleGeneratedRecord($0) }
            .map { record in
                let linkedPlace = record.linkedPlaceID.flatMap { placesByID[$0] }
                return PlaceWorldAutoPlacementInput(
                    recordID: record.id,
                    activePath: record.activePath,
                    workflow: record.workflow,
                    summary: record.summary,
                    keywords: record.keywords,
                    sourcePrompt: record.sourcePrompt,
                    linkedPlaceID: record.linkedPlaceID,
                    linkedPlaceName: linkedPlace?.name,
                    linkedPlaceNotes: linkedPlace?.notes,
                    linkedPlacePromptNotes: linkedPlace?.workflowPromptNotes,
                    explicitMapPoint: record.mapPlacementStatus == .confirmed ? record.mapPoint : nil,
                    explicitPose: record.mapPlacementStatus == .confirmed ? record.cameraPose : nil
                )
            }

        refreshTask?.cancel()
        if inputs.isEmpty {
            placements = [:]
            isRefreshing = false
            return
        }
        isRefreshing = true
        let animateURL = store.animateURL
        let backgrounds = store.backgrounds
        refreshTask = Task(priority: .utility) { [service] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let resolved = await service.inferPlacements(inputs: inputs, places: backgrounds, animateURL: animateURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.placements = resolved
                self.isRefreshing = false
            }
        }
    }
}

@available(macOS 26.0, *)
struct PlacesWorldMapBrowserView: View {
    private enum ActiveDragInteraction {
        case pan(origin: CGSize)
        case capture(PlacesWorldbuildingSnapshot.Capture)
        case node(PlacesWorldbuildingSnapshot.Node)
    }

    let store: AnimateStore
    let snapshot: PlacesWorldbuildingSnapshot
    let workflowMode: PlaceWorkflowMode
    let selectedPlace: BackgroundPlate?
    let isLiveResizing: Bool
    let selectedRouteID: String?
    let selectedNodeID: String?
    let selectedCaptureID: UUID?
    let onSelectRoute: (PlacesWorldbuildingSnapshot.Route) -> Void
    let onSelectNode: (PlacesWorldbuildingSnapshot.Node) -> Void
    let onSelectCapture: (PlacesWorldbuildingSnapshot.Capture) -> Void
    let onDropMasterMapCandidate: ([URL]) -> Bool

    @StateObject private var autoPlacementModel = PlacesWorldAutoPlacementModel()
    @State private var cachedMapPath: String?
    @State private var cachedMapImage: NSImage?
    @State private var committedZoomScale: CGFloat = 1
    @State private var zoomScale: CGFloat = 1
    @State private var committedPanOffset: CGSize = .zero
    @State private var panOffset: CGSize = .zero
    @State private var tiltDegrees: Double = 0
    @State private var hoveredMapPoint: PlacesWorldMapPoint?
    @State private var showProvisionalPins = false
    @State private var activeDragInteraction: ActiveDragInteraction?
    @State private var draggedCaptureRecordID: UUID?
    @State private var draggedCaptureMapPoint: PlacesWorldMapPoint?
    @State private var draggedNodeID: String?
    @State private var draggedNodeMapPoint: PlacesWorldMapPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("World Map", systemImage: "globe.americas.fill")
                    .font(.headline)
                Spacer()
                if autoPlacementModel.isRefreshing {
                    Label("Auto-placing…", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                legend
            }

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.background.opacity(0.72))
                mapSurface
                viewportControls
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.quaternary.opacity(0.35))
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 420)
            .dropDestination(for: URL.self) { urls, _ in
                return onDropMasterMapCandidate(urls)
            }
        }
        .onAppear {
            autoPlacementModel.refresh(store: store, snapshot: snapshot, workflowMode: workflowMode)
        }
        .task(id: snapshot.masterMapPath ?? "") {
            await refreshCachedMapImage()
        }
        .onChange(of: workflowMode) { _, _ in
            autoPlacementModel.refresh(store: store, snapshot: snapshot, workflowMode: workflowMode)
        }
        .onChange(of: snapshot.captures.map(\.id).joined(separator: "|")) { _, _ in
            autoPlacementModel.refresh(store: store, snapshot: snapshot, workflowMode: workflowMode)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(color: .accentColor, label: "Images")
            legendItem(color: .mint, label: "Interiors")
            legendItem(color: .blue, label: "Route")
            legendItem(color: .yellow, label: "Selected node")
            legendItem(color: .red, label: "Flagged")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var mapSurface: some View {
        GeometryReader { proxy in
            let imageInfo = mapImageInfo(fitting: proxy.size)
            let baseRect = imageInfo?.rect ?? fallbackRect(in: proxy.size)
            ZStack {
                Group {
                    if isLiveResizing {
                        mapContent(baseRect: baseRect, imageInfo: imageInfo, viewportSize: proxy.size)
                            .compositingGroup()
                    } else {
                        mapContent(baseRect: baseRect, imageInfo: imageInfo, viewportSize: proxy.size)
                            .drawingGroup()
                    }
                }

                PlacesWorldMapScrollWheelMonitorView { event, location in
                    handleScrollWheel(event, at: location, viewportSize: proxy.size)
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hoveredMapPoint = normalizedMapPoint(from: location, in: proxy.size, baseRect: baseRect)
                case .ended:
                    hoveredMapPoint = nil
                }
            }
            .contextMenu {
                if let hoveredMapPoint {
                    if let selectedPlace {
                        Button("Anchor “\(selectedPlace.name)” Here") {
                            anchor(place: selectedPlace, at: hoveredMapPoint)
                        }
                    }

                    if let selectedCapture,
                       let capturePlace = captureAnchorPlace(for: selectedCapture) {
                        Button("Anchor “\(capturePlace.name)” Here from Selected Image") {
                            anchor(place: capturePlace, at: hoveredMapPoint)
                        }
                    }

                    let canonicalPlaces = canonicalAnchorPlaces
                    if !canonicalPlaces.isEmpty {
                        Menu("Anchor Canonical Place Here") {
                            ForEach(canonicalPlaces) { place in
                                Button(place.name) {
                                    anchor(place: place, at: hoveredMapPoint)
                                }
                            }
                        }
                    }
                } else {
                    Text("Move the pointer over the map to anchor a place here.")
                }
            }
        }
    }

    @ViewBuilder
    private func mapContent(
        baseRect: CGRect,
        imageInfo: (image: NSImage, rect: CGRect)?,
        viewportSize: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let imageInfo {
                        Image(nsImage: imageInfo.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: imageInfo.rect.width, height: imageInfo.rect.height)
                            .position(x: imageInfo.rect.midX, y: imageInfo.rect.midY)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.quinary.opacity(0.25))
                            .overlay {
                                VStack(spacing: 10) {
                                    Image(systemName: "map")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                    Text("Import or replace the master map to ground world nodes spatially.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }
                }

                // Route overlays are intentionally hidden in the main World Map.
                // We are map-first now: confirmed image pins and landmark anchors drive
                // world truth, not speculative route/road interpretations.

                ForEach(displayCaptures) { capture in
                    let mappedPoint = point(for: capture.position, in: baseRect)
                    if let heading = capture.heading, (capture.recordID == selectedCaptureID || zoomScale > 1.3) {
                        PlacesWorldViewCone(
                            heading: heading,
                            focalLength: capture.focalLength ?? 35,
                            origin: mappedPoint
                        )
                        .fill(
                            capture.recordID == selectedCaptureID
                                ? Color.accentColor.opacity(0.22)
                                : (capture.isRejected ? Color.red.opacity(0.10) : Color.accentColor.opacity(0.08))
                        )
                    }

                    Button {
                        onSelectCapture(capture)
                    } label: {
                        PlacesWorldCapturePinView(
                            capture: capture,
                            isSelected: capture.recordID == selectedCaptureID
                        )
                    }
                    .buttonStyle(.plain)
                    .position(mappedPoint)
                    .help("\(capture.title)\n\(capture.poseLabel)")
                }

                // Legacy node dots are also hidden in the main World Map. Landmark
                // editing now lives in the dedicated Landmarks workflow instead of
                // rendering generic graph nodes over the painted map.
        }
        .scaleEffect(zoomScale, anchor: .center)
        .offset(panOffset)
        .rotation3DEffect(.degrees(tiltDegrees), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.7)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .local)
                .onChanged { value in
                    handleMapDragChanged(value, viewportSize: viewportSize, baseRect: baseRect)
                }
                .onEnded { value in
                    handleMapDragEnded(value, viewportSize: viewportSize, baseRect: baseRect)
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    zoomScale = min(max(committedZoomScale * value.magnification, 0.65), 6.0)
                }
                .onEnded { value in
                    committedZoomScale = min(max(committedZoomScale * value.magnification, 0.65), 6.0)
                    zoomScale = committedZoomScale
                }
        )
    }

    private var canonicalAnchorPlaces: [BackgroundPlate] {
        let keywords = [
            "amira's home",
            "gathering space",
            "clinic",
            "photo shop",
            "marketplace",
            "rubble field",
            "market wall",
            "bridge",
            "river road",
            "riverbank",
            "memorial",
            "grave",
            "base",
            "ridge",
            "shepherd",
            "hillside"
        ]
        return store.backgrounds
            .filter { place in
                let lower = place.name.lowercased()
                return keywords.contains { lower.contains($0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedCapture: PlacesWorldbuildingSnapshot.Capture? {
        guard let selectedCaptureID else { return nil }
        return displayCaptures.first(where: { $0.recordID == selectedCaptureID })
    }

    private func captureAnchorPlace(for capture: PlacesWorldbuildingSnapshot.Capture) -> BackgroundPlate? {
        if let placeID = capture.placeID {
            return store.backgrounds.first(where: { $0.id == placeID })
        }
        let lowerTitle = capture.title.lowercased()
        return canonicalAnchorPlaces.first(where: { place in
            lowerTitle.contains(place.name.lowercased())
        })
    }

    private func anchor(place: BackgroundPlate, at mapPoint: PlacesWorldMapPoint) {
        store.upsertWorldPlaceAnchor(
            placeID: place.id,
            title: place.name,
            mapPoint: WorldMapPoint(x: Double(mapPoint.x), y: Double(mapPoint.y)),
            role: .landmark
        )
    }

    private func normalizedMapPoint(
        from location: CGPoint,
        in size: CGSize,
        baseRect: CGRect
    ) -> PlacesWorldMapPoint? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let untransformed = CGPoint(
            x: ((location.x - panOffset.width - center.x) / zoomScale) + center.x,
            y: ((location.y - panOffset.height - center.y) / zoomScale) + center.y
        )
        guard baseRect.width > 0, baseRect.height > 0, baseRect.contains(untransformed) else { return nil }
        return PlacesWorldMapPoint(
            x: (untransformed.x - baseRect.minX) / baseRect.width,
            y: (untransformed.y - baseRect.minY) / baseRect.height
        ).clamped
    }

    private var displayCaptures: [PlacesWorldbuildingSnapshot.Capture] {
        snapshot.captures.compactMap { capture in
            let hasCanonicalPlacement =
                capture.mapPlacementStatus == .confirmed
                || (!snapshot.usesFallbackWorldGraph && capture.worldNodeID != nil)
                || (!snapshot.usesFallbackWorldGraph && capture.buildingAnchorNodeID != nil)

            if hasCanonicalPlacement {
                var locked = capture
                if let recordID = capture.recordID,
                   let placement = autoPlacementModel.placements[recordID] {
                    if locked.sceneKind == .ambiguous {
                        locked.sceneKind = placement.sceneKind
                    }
                    locked.placementDiagnostics = Array(Set(locked.placementDiagnostics + placement.diagnostics)).sorted()
                    if locked.orientationState == .unknown {
                        locked.shouldMirrorPreview = placement.shouldMirrorPreview
                    }
                }
                if let recordID = locked.recordID,
                   draggedCaptureRecordID == recordID,
                   let draggedCaptureMapPoint {
                    locked.position = draggedCaptureMapPoint
                }
                return locked
            }

            guard showProvisionalPins else { return nil }

            if let recordID = capture.recordID,
               let placement = autoPlacementModel.placements[recordID],
               placement.confidence >= 0.64 {
                var updated = capture
                updated.position = PlacesWorldMapPoint(x: placement.mapPoint.x, y: placement.mapPoint.y).clamped
                updated.heading = placement.cameraPose?.yawDegrees ?? capture.heading
                updated.pitch = placement.cameraPose?.pitchDegrees ?? capture.pitch
                updated.focalLength = placement.cameraPose?.focalLengthMM ?? capture.focalLength
                updated.hasTrustedMapPosition = false
                updated.placeID = updated.placeID ?? placement.inferredPlaceID
                updated.placeName = (updated.placeName == "Unassigned" ? placement.inferredPlaceName : updated.placeName) ?? updated.placeName
                updated.placementSource = placement.source
                updated.placementConfidence = placement.confidence
                updated.sceneKind = placement.sceneKind
                if updated.orientationState == .unknown {
                    updated.shouldMirrorPreview = placement.shouldMirrorPreview
                } else {
                    updated.shouldMirrorPreview = updated.orientationState == .mirrored
                }
                updated.placementDiagnostics = placement.diagnostics
                if draggedCaptureRecordID == recordID, let draggedCaptureMapPoint {
                    updated.position = draggedCaptureMapPoint
                }
                return updated
            }

            guard capture.hasTrustedMapPosition else { return nil }
            if let recordID = capture.recordID,
               draggedCaptureRecordID == recordID,
               let draggedCaptureMapPoint {
                var updated = capture
                updated.position = draggedCaptureMapPoint
                return updated
            }
            return capture
        }
    }

    @ViewBuilder
    private var viewportControls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            let next = min(zoomScale * 1.15, 6.0)
                            zoomScale = next
                            committedZoomScale = next
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            let next = max(zoomScale / 1.15, 0.65)
                            zoomScale = next
                            committedZoomScale = next
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(.bordered)

                        Button("Reset") {
                            committedZoomScale = 1
                            zoomScale = 1
                            committedPanOffset = .zero
                            panOffset = .zero
                            tiltDegrees = 0
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Toggle(isOn: $showProvisionalPins) {
                            Text("Provisional pins")
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())

                        Image(systemName: "rotate.3d")
                            .foregroundStyle(.secondary)
                        Slider(value: $tiltDegrees, in: 0...62)
                            .frame(width: 140)
                        Text("\(Int(tiltDegrees))°")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())

                    if tiltDegrees > 0.5 {
                        Text("Reset tilt to move pins accurately.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func refreshCachedMapImage() async {
        let path = snapshot.masterMapPath
        guard path != cachedMapPath || cachedMapImage == nil else { return }
        cachedMapPath = path
        guard let path,
              let url = resolvedAssetURL(for: path),
              let image = await loadSharedPreviewImage(at: url.path, maxPixelSize: 2400),
              image.size.width > 0,
              image.size.height > 0 else {
            cachedMapImage = nil
            return
        }
        cachedMapImage = image
    }

    private func mapImageInfo(fitting size: CGSize) -> (image: NSImage, rect: CGRect)? {
        guard let image = cachedMapImage,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        let rect = aspectFitRect(contentSize: image.size, in: fallbackRect(in: size))
        return (image, rect)
    }

    private func point(for point: PlacesWorldMapPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * point.x, y: rect.minY + rect.height * point.y)
    }

    private func persistedPosition(for node: PlacesWorldbuildingSnapshot.Node) -> PlacesWorldMapPoint {
        if draggedNodeID == node.id, let draggedNodeMapPoint {
            return draggedNodeMapPoint
        }
        return node.position
    }

    private func routeMidpoint(_ route: PlacesWorldbuildingSnapshot.Route, in rect: CGRect) -> CGPoint? {
        guard !route.path.isEmpty else { return nil }
        let converted = route.path.map { point(for: $0, in: rect) }
        let sum = converted.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(converted.count), y: sum.y / CGFloat(converted.count))
    }

    private func routeColor(for index: Int, selected: Bool) -> Color {
        let palette: [Color] = [.blue, .purple, .mint, .orange, .teal, .pink]
        let base = palette[index % palette.count]
        return selected ? base.opacity(0.95) : base.opacity(0.65)
    }

    private func nodeFlagColor(_ node: PlacesWorldbuildingSnapshot.Node) -> Color {
        node.isFlagged ? .red : .accentColor
    }

    private func resolvedAssetURL(for path: String) -> URL? {
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func fallbackRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18)
    }

    private func handleScrollWheel(_ event: NSEvent, at location: CGPoint, viewportSize: CGSize) {
        let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard rawDelta != 0 else { return }
        let factor = pow(1.08, rawDelta / 12)
        let nextScale = min(max(zoomScale * factor, 0.65), 6.0)
        setZoom(nextScale, around: location, viewportSize: viewportSize)
    }

    private func setZoom(_ nextScale: CGFloat, around location: CGPoint, viewportSize: CGSize) {
        let currentScale = max(zoomScale, 0.001)
        guard abs(nextScale - currentScale) > 0.0001 else { return }
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let relativeX = location.x - center.x - panOffset.width
        let relativeY = location.y - center.y - panOffset.height
        let scaleRatio = nextScale / currentScale
        let nextPan = CGSize(
            width: location.x - center.x - (relativeX * scaleRatio),
            height: location.y - center.y - (relativeY * scaleRatio)
        )
        zoomScale = nextScale
        committedZoomScale = nextScale
        panOffset = nextPan
        committedPanOffset = nextPan
    }

    private func handleMapDragChanged(
        _ value: DragGesture.Value,
        viewportSize: CGSize,
        baseRect: CGRect
    ) {
        if activeDragInteraction == nil {
            if let target = dragInteraction(at: value.startLocation, viewportSize: viewportSize, baseRect: baseRect) {
                activeDragInteraction = target
                switch target {
                case .capture(let capture):
                    onSelectCapture(capture)
                case .node(let node):
                    onSelectNode(node)
                case .pan:
                    break
                }
            } else {
                activeDragInteraction = .pan(origin: committedPanOffset)
            }
        }

        switch activeDragInteraction {
        case .capture(let capture):
            guard let mapPoint = normalizedMapPoint(from: value.location, in: viewportSize, baseRect: baseRect),
                  let recordID = capture.recordID else { return }
            draggedCaptureRecordID = recordID
            draggedCaptureMapPoint = mapPoint
        case .node(let node):
            guard let mapPoint = normalizedMapPoint(from: value.location, in: viewportSize, baseRect: baseRect) else { return }
            draggedNodeID = node.id
            draggedNodeMapPoint = mapPoint
        case .pan(let origin):
            let nextOffset = CGSize(
                width: origin.width + value.translation.width,
                height: origin.height + value.translation.height
            )
            panOffset = nextOffset
        case nil:
            break
        }
    }

    private func handleMapDragEnded(
        _ value: DragGesture.Value,
        viewportSize: CGSize,
        baseRect: CGRect
    ) {
        defer {
            activeDragInteraction = nil
            draggedCaptureRecordID = nil
            draggedCaptureMapPoint = nil
            draggedNodeID = nil
            draggedNodeMapPoint = nil
        }

        switch activeDragInteraction {
        case .capture(let capture):
            guard let recordID = capture.recordID,
                  let mapPoint = draggedCaptureMapPoint ?? normalizedMapPoint(from: value.location, in: viewportSize, baseRect: baseRect) else { return }
            let persistedWorldNodeID = snapshot.usesFallbackWorldGraph ? nil : uuid(from: capture.worldNodeID)
            let persistedRouteID = snapshot.usesFallbackWorldGraph ? nil : uuid(from: capture.routeID)
            let persistedBuildingAnchorID = snapshot.usesFallbackWorldGraph ? nil : uuid(from: capture.buildingAnchorNodeID)
            store.updateGeneratedBackgroundPlacement(
                recordID,
                mapPoint: WorldMapPoint(x: Double(mapPoint.x), y: Double(mapPoint.y)),
                pose: worldPose(for: capture),
                worldNodeID: persistedWorldNodeID,
                routeID: persistedRouteID,
                placeID: capture.placeID,
                buildingAnchorNodeID: persistedBuildingAnchorID,
                status: .confirmed
            )
        case .node(let node):
            guard let nodeID = uuid(from: node.id),
                  let mapPoint = draggedNodeMapPoint ?? normalizedMapPoint(from: value.location, in: viewportSize, baseRect: baseRect) else { return }
            store.updateWorldNodeMapPoint(
                WorldMapPoint(x: Double(mapPoint.x), y: Double(mapPoint.y)),
                nodeID: nodeID
            )
        case .pan(let origin):
            let nextOffset = CGSize(
                width: origin.width + value.translation.width,
                height: origin.height + value.translation.height
            )
            committedPanOffset = nextOffset
            panOffset = nextOffset
        case nil:
            break
        }
    }

    private func dragInteraction(
        at location: CGPoint,
        viewportSize: CGSize,
        baseRect: CGRect
    ) -> ActiveDragInteraction? {
        guard tiltDegrees <= 0.5 else {
            return .pan(origin: committedPanOffset)
        }
        if let capture = captureNear(location, viewportSize: viewportSize, baseRect: baseRect) {
            return .capture(capture)
        }
        if let node = nodeNear(location, viewportSize: viewportSize, baseRect: baseRect) {
            return .node(node)
        }
        return .pan(origin: committedPanOffset)
    }

    private func captureNear(
        _ location: CGPoint,
        viewportSize: CGSize,
        baseRect: CGRect
    ) -> PlacesWorldbuildingSnapshot.Capture? {
        displayCaptures
            .compactMap { capture -> (PlacesWorldbuildingSnapshot.Capture, CGFloat)? in
                guard capture.recordID != nil else { return nil }
                let screenPoint = viewportPoint(for: capture.position, in: baseRect, viewportSize: viewportSize)
                let distance = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
                guard distance <= 18 else { return nil }
                return (capture, distance)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsSelected = lhs.0.recordID == selectedCaptureID
                let rhsSelected = rhs.0.recordID == selectedCaptureID
                if lhsSelected != rhsSelected { return lhsSelected && !rhsSelected }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .first?
            .0
    }

    private func nodeNear(
        _ location: CGPoint,
        viewportSize: CGSize,
        baseRect: CGRect
    ) -> PlacesWorldbuildingSnapshot.Node? {
        snapshot.nodes
            .compactMap { node -> (PlacesWorldbuildingSnapshot.Node, CGFloat)? in
                guard uuid(from: node.id) != nil else { return nil }
                let screenPoint = viewportPoint(for: persistedPosition(for: node), in: baseRect, viewportSize: viewportSize)
                let distance = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
                guard distance <= 16 else { return nil }
                return (node, distance)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsSelected = lhs.0.id == selectedNodeID
                let rhsSelected = rhs.0.id == selectedNodeID
                if lhsSelected != rhsSelected { return lhsSelected && !rhsSelected }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .first?
            .0
    }

    private func viewportPoint(
        for mapPoint: PlacesWorldMapPoint,
        in rect: CGRect,
        viewportSize: CGSize
    ) -> CGPoint {
        transformedViewportPoint(point(for: mapPoint, in: rect), viewportSize: viewportSize)
    }

    private func transformedViewportPoint(_ point: CGPoint, viewportSize: CGSize) -> CGPoint {
        let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        return CGPoint(
            x: center.x + ((point.x - center.x) * zoomScale) + panOffset.width,
            y: center.y + ((point.y - center.y) * zoomScale) + panOffset.height
        )
    }

    private func worldPose(for capture: PlacesWorldbuildingSnapshot.Capture) -> WorldCameraPose? {
        guard capture.heading != nil || capture.pitch != nil || capture.focalLength != nil else { return nil }
        return WorldCameraPose(
            yawDegrees: capture.heading ?? 0,
            pitchDegrees: capture.pitch ?? 0,
            rollDegrees: 0,
            focalLengthMM: capture.focalLength ?? 35
        )
    }

    private func uuid(from rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        let widthScale = bounds.width / contentSize.width
        let heightScale = bounds.height / contentSize.height
        let scale = min(widthScale, heightScale)
        let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }
}

@available(macOS 26.0, *)
private struct PlacesWorldMapScrollWheelMonitorView: NSViewRepresentable {
    let onScroll: (NSEvent, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ScrollWheelMonitorNSView {
        let view = ScrollWheelMonitorNSView()
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view, onScroll: onScroll)
        return view
    }

    func updateNSView(_ nsView: ScrollWheelMonitorNSView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.attach(to: nsView, onScroll: onScroll)
    }

    static func dismantleNSView(_ nsView: ScrollWheelMonitorNSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private weak var view: ScrollWheelMonitorNSView?
        private var monitor: Any?
        private var onScroll: ((NSEvent, CGPoint) -> Void)?

        func attach(to view: ScrollWheelMonitorNSView, onScroll: @escaping (NSEvent, CGPoint) -> Void) {
            self.view = view
            self.onScroll = onScroll
            installMonitorIfNeeded()
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            view = nil
            onScroll = nil
        }

        deinit {
            detach()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let view = self.view,
                      let window = view.window,
                      event.window === window,
                      !view.isHiddenOrHasHiddenAncestor else {
                    return event
                }
                let localPoint = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(localPoint) else { return event }
                self.onScroll?(event, localPoint)
                return nil
            }
        }
    }

    final class ScrollWheelMonitorNSView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { false }
    }
}

@available(macOS 26.0, *)
private struct PlacesWorldCapturePinView: View {
    let capture: PlacesWorldbuildingSnapshot.Capture
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(pinFill)
                .frame(width: isSelected ? 22 : 16, height: isSelected ? 22 : 16)
                .overlay {
                    Circle()
                        .stroke(isSelected ? Color.yellow : (capture.shouldMirrorPreview ? Color.orange : Color.black.opacity(0.28)), lineWidth: isSelected ? 3 : (capture.shouldMirrorPreview ? 2 : 1))
                }

            if let rating = capture.rating, rating > 0 {
                Text("\(rating)")
                    .font(.system(size: isSelected ? 9 : 8, weight: .bold))
                    .foregroundStyle(capture.isRejected ? Color.white : Color.black.opacity(0.75))
            } else {
                Image(systemName: capture.isRejected ? "xmark" : "photo")
                    .font(.system(size: isSelected ? 9 : 8, weight: .bold))
                    .foregroundStyle(capture.isRejected ? Color.white : Color.black.opacity(0.75))
            }
        }
        .shadow(color: .black.opacity(0.16), radius: isSelected ? 8 : 4, x: 0, y: 2)
    }

    private var pinFill: Color {
        if capture.isRejected { return .red }
        if capture.isCanon { return .green }
        if capture.sceneKind == .interior { return .mint.opacity(0.92) }
        if let rating = capture.rating, rating >= 4 { return .yellow }
        return .white.opacity(0.94)
    }
}

@available(macOS 26.0, *)
struct PlacesWorldCaptureInspectorCard: View {
    let capture: PlacesWorldbuildingSnapshot.Capture?
    let store: AnimateStore
    let onOpenPlace: (UUID?) -> Void
    let onOpenLibrary: () -> Void
    let onOpenUnconfirmed: () -> Void
    let onReveal: (String) -> Void

    @State private var mirrorPreviewOverride: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Pinned Image", systemImage: "photo.badge.location")
                    .font(.headline)
                Spacer()
                if let capture {
                    Text(capture.placeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let capture {
                HStack(alignment: .top, spacing: 14) {
                    preview(for: capture)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(capture.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(capture.poseLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(String(format: "Map %.3f • %.3f", Double(capture.position.x), Double(capture.position.y)))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            if let rating = capture.rating {
                                inspectorPill(title: "Rating", value: "\(rating)★", systemImage: "star.fill")
                            }
                            inspectorPill(title: "Status", value: capture.isRejected ? "Rejected" : (capture.isCanon ? "Canon" : "Candidate"), systemImage: capture.isRejected ? "xmark.circle.fill" : "checkmark.circle")
                            inspectorPill(title: "Placement", value: "\(capture.sceneKind.displayName) • \(Int((capture.placementConfidence * 100).rounded()))%", systemImage: capture.sceneKind == .interior ? "house.lodge" : "mappin.and.ellipse")
                            inspectorPill(title: "Map", value: capture.mapPlacementStatus.displayName, systemImage: capture.mapPlacementStatus == .confirmed ? "checkmark.seal.fill" : "mappin.slash.circle")
                            if capture.orientationState != .unknown {
                                inspectorPill(title: "Orientation", value: capture.orientationState.displayName, systemImage: capture.orientationState == .mirrored ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "rectangle")
                            }
                            if !capture.qaFlags.isEmpty {
                                inspectorPill(title: "Flags", value: "\(capture.qaFlags.count)", systemImage: "exclamationmark.triangle.fill")
                            }
                            if capture.shouldMirrorPreview {
                                inspectorPill(title: "Mirror", value: "Preview mirrored", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            }
                        }

                        if !capture.placementDiagnostics.isEmpty {
                            FlowTagCloud(tags: capture.placementDiagnostics, tint: .orange)
                        }

                        if capture.shouldMirrorPreview || capture.placementDiagnostics.contains(where: { $0.localizedCaseInsensitiveContains("mirror") }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Mirror confirmation")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    Button {
                                        mirrorPreviewOverride = false
                                    } label: {
                                        Label("Original", systemImage: effectiveMirrorPreview(for: capture) ? "rectangle" : "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        mirrorPreviewOverride = true
                                    } label: {
                                        Label("Mirrored", systemImage: effectiveMirrorPreview(for: capture) ? "checkmark.circle.fill" : "rectangle.on.rectangle")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let recordID = capture.recordID {
                                    HStack(spacing: 8) {
                                        Button {
                                            mirrorPreviewOverride = false
                                            store.setGeneratedBackgroundOrientation(.original, for: recordID)
                                        } label: {
                                            Label("Confirm Original", systemImage: capture.orientationState == .original ? "checkmark.circle.fill" : "rectangle")
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            mirrorPreviewOverride = true
                                            store.setGeneratedBackgroundOrientation(.mirrored, for: recordID)
                                        } label: {
                                            Label("Confirm Mirrored", systemImage: capture.orientationState == .mirrored ? "checkmark.circle.fill" : "rectangle.on.rectangle")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }

                                Text("Save the orientation decision once you know whether this image should stay original or mirrored. The preview still lets you compare both states.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                onOpenLibrary()
                            } label: {
                                Label("Open Library", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.borderedProminent)
                            .fixedSize(horizontal: true, vertical: false)

                            if capture.requiresPlacementReview {
                                Button {
                                    onOpenUnconfirmed()
                                } label: {
                                    Label("Review Unconfirmed", systemImage: "mappin.slash.circle")
                                }
                                .buttonStyle(.bordered)
                                .fixedSize(horizontal: true, vertical: false)
                            }

                            Button {
                                onOpenPlace(capture.placeID)
                            } label: {
                                Label("Open Place", systemImage: "building.2")
                            }
                            .buttonStyle(.bordered)
                            .disabled(capture.placeID == nil)
                            .fixedSize(horizontal: true, vertical: false)

                            Button {
                                onReveal(capture.imagePath)
                            } label: {
                                Label("Reveal", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        if let anchorPlace = resolvedPlace(for: capture) {
                            HStack(spacing: 8) {
                                Button {
                                    anchor(place: anchorPlace, for: capture)
                                } label: {
                                    Label(capture.sceneKind == .interior ? "Link Interior to Building" : "Update Building Anchor", systemImage: capture.sceneKind == .interior ? "building.2.crop.circle" : "mappin.circle")
                                }
                                .buttonStyle(.bordered)
                                .fixedSize(horizontal: true, vertical: false)

                                if capture.sceneKind == .interior {
                                    Text("Uses the current map position to keep this interior tied to the building anchor.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .task(id: capture.id) {
                    mirrorPreviewOverride = nil
                }
            } else {
                emptyCard(title: "No image selected", message: "Click a pin on the map to inspect the generated image, its inferred camera pose, and its continuity state.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func preview(for capture: PlacesWorldbuildingSnapshot.Capture) -> some View {
        if let url = store.resolvedCharacterAssetURL(for: capture.imagePath) ?? (capture.imagePath.hasPrefix("/") ? URL(fileURLWithPath: capture.imagePath) : nil) {
            AsyncResolvedImageView(path: url.path, maxPixelSize: 960, contentMode: .fill)
                .frame(width: 180, height: 120)
                .scaleEffect(x: effectiveMirrorPreview(for: capture) ? -1 : 1, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quinary.opacity(0.22))
                .frame(width: 180, height: 120)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func inspectorPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.85), in: Capsule())
    }

    private func effectiveMirrorPreview(for capture: PlacesWorldbuildingSnapshot.Capture) -> Bool {
        mirrorPreviewOverride ?? (capture.orientationState == .mirrored || (capture.orientationState == .unknown && capture.shouldMirrorPreview))
    }

    private func resolvedPlace(for capture: PlacesWorldbuildingSnapshot.Capture) -> BackgroundPlate? {
        if let placeID = capture.placeID,
           let direct = store.backgrounds.first(where: { $0.id == placeID }) {
            return direct
        }

        let lowerTitle = capture.title.lowercased()
        return store.backgrounds.first(where: { place in
            let lowerPlace = place.name.lowercased()
            return lowerTitle.contains(lowerPlace) || lowerPlace.contains(lowerTitle)
        })
    }

    private func anchor(place: BackgroundPlate, for capture: PlacesWorldbuildingSnapshot.Capture) {
        let mapPoint = WorldMapPoint(x: Double(capture.position.x), y: Double(capture.position.y))
        let nodeID = store.upsertWorldPlaceAnchor(
            placeID: place.id,
            title: place.name,
            mapPoint: mapPoint,
            role: .landmark
        )
        if let recordID = capture.recordID {
            let pose = worldPose(for: capture)
            if capture.sceneKind == .interior {
                store.setPlaceInteriorLink(
                    place.id,
                    linkedExteriorPlaceID: place.linkedExteriorPlaceID,
                    buildingAnchorNodeID: nodeID
                )
                store.confirmGeneratedBackgroundPlacement(
                    recordID,
                    mapPoint: mapPoint,
                    pose: pose,
                    worldNodeID: nil,
                    routeID: nil,
                    placeID: place.id,
                    buildingAnchorNodeID: nodeID
                )
            } else {
                store.confirmGeneratedBackgroundPlacement(
                    recordID,
                    mapPoint: mapPoint,
                    pose: pose,
                    worldNodeID: nodeID,
                    routeID: nil,
                    placeID: place.id,
                    buildingAnchorNodeID: nodeID
                )
            }
        }
        store.statusMessage = capture.sceneKind == .interior
            ? "Linked \(place.name) interior to the current building anchor."
            : "Updated building anchor for \(place.name)."
    }

    private func worldPose(for capture: PlacesWorldbuildingSnapshot.Capture) -> WorldCameraPose? {
        guard capture.heading != nil || capture.pitch != nil || capture.focalLength != nil else { return nil }
        return WorldCameraPose(
            yawDegrees: capture.heading ?? 0,
            pitchDegrees: capture.pitch ?? 0,
            rollDegrees: 0,
            focalLengthMM: capture.focalLength ?? 35
        )
    }

    private func emptyCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@available(macOS 26.0, *)
private struct PlacesWorldPlacementReviewItem: Identifiable {
    enum State: String, Hashable {
        case suggested
        case homeless
        case relink

        var title: String {
            switch self {
            case .suggested: "Suggested placement"
            case .homeless: "Homeless image"
            case .relink: "Needs node link"
            }
        }

        var color: Color {
            switch self {
            case .suggested: .blue
            case .homeless: .orange
            case .relink: .purple
            }
        }
    }

    var id: String { capture.id }
    var capture: PlacesWorldbuildingSnapshot.Capture
    var placement: PlaceWorldAutoPlacement?
    var suggestedNode: PlacesWorldbuildingSnapshot.Node?
    var suggestedPlaceID: UUID?
    var suggestedPlaceName: String?
    var state: State

    var confidenceLabel: String {
        let score = Int(((placement?.confidence ?? capture.placementConfidence) * 100).rounded())
        return "\(score)%"
    }

    var mapPoint: WorldMapPoint? {
        placement?.mapPoint
            ?? (capture.hasTrustedMapPosition ? WorldMapPoint(x: Double(capture.position.x), y: Double(capture.position.y)) : nil)
            ?? suggestedNode.map { WorldMapPoint(x: Double($0.position.x), y: Double($0.position.y)).clamped() }
    }

    var canCreateAnchor: Bool {
        suggestedPlaceID != nil && mapPoint != nil
    }

    var canConfirm: Bool {
        capture.recordID != nil && (suggestedPlaceID != nil || mapPoint != nil || suggestedNode != nil)
    }

    var tags: [String] {
        var tags: [String] = [state.title, capture.sceneKind.displayName]
        if let suggestedNode {
            tags.append("Node \(suggestedNode.sequenceIndex + 1)")
        } else if suggestedPlaceName != nil {
            tags.append("Place match")
        }
        if capture.shouldMirrorPreview {
            tags.append("Mirror")
        }
        tags.append(contentsOf: capture.placementDiagnostics)
        var ordered: [String] = []
        var seen = Set<String>()
        for tag in tags {
            guard let normalized = tag.nilIfBlank, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }
}

@available(macOS 26.0, *)
struct PlacesWorldUnconfirmedPlacementSection: View {
    let store: AnimateStore
    let snapshot: PlacesWorldbuildingSnapshot
    let workflowMode: PlaceWorkflowMode
    let selectedCaptureRecordID: UUID?
    let onSelectCapture: (PlacesWorldbuildingSnapshot.Capture) -> Void
    let onOpenPlace: (UUID?) -> Void
    let onOpenLibrary: () -> Void
    let onFocusMap: (PlacesWorldbuildingSnapshot.Capture) -> Void

    @StateObject private var autoPlacementModel = PlacesWorldAutoPlacementModel()
    @State private var selectedItemID: String?

    private var items: [PlacesWorldPlacementReviewItem] {
        snapshot.captures.compactMap { capture in
            let placement = capture.recordID.flatMap { autoPlacementModel.placements[$0] }
            let suggestedPlaceID = placement?.inferredPlaceID ?? capture.placeID
            let suggestedPlaceName = placement?.inferredPlaceName ?? ((capture.placeName == "Unassigned") ? nil : capture.placeName)
            let suggestedNode = bestNode(for: capture, placement: placement, placeID: suggestedPlaceID)

            let state: PlacesWorldPlacementReviewItem.State?
            if !capture.hasTrustedMapPosition {
                state = placement == nil ? .homeless : .suggested
            } else if capture.placeID == nil || capture.worldNodeID == nil {
                state = suggestedNode == nil ? .homeless : .relink
            } else {
                state = nil
            }

            guard let state else { return nil }
            if state == .homeless, suggestedPlaceID == nil, placement == nil, capture.recordID == nil {
                return nil
            }

            return PlacesWorldPlacementReviewItem(
                capture: capture,
                placement: placement,
                suggestedNode: suggestedNode,
                suggestedPlaceID: suggestedPlaceID,
                suggestedPlaceName: suggestedPlaceName,
                state: state
            )
        }
        .sorted { lhs, rhs in
            let lhsRank = sortRank(for: lhs)
            let rhsRank = sortRank(for: rhs)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.capture.title.localizedCaseInsensitiveCompare(rhs.capture.title) == .orderedAscending
        }
    }

    private var selectedItem: PlacesWorldPlacementReviewItem? {
        if let selectedItemID,
           let explicit = items.first(where: { $0.id == selectedItemID }) {
            return explicit
        }
        if let selectedCaptureRecordID,
           let fromCapture = items.first(where: { $0.capture.recordID == selectedCaptureRecordID }) {
            return fromCapture
        }
        return items.first
    }

    private var suggestedCount: Int {
        items.filter { $0.state == .suggested || $0.state == .relink }.count
    }

    private var homelessCount: Int {
        items.filter { $0.state == .homeless }.count
    }

    private var interiorCount: Int {
        items.filter { $0.capture.sceneKind == .interior }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Unconfirmed Placements")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Inspect provisional map suggestions, homeless captures, and interior-to-building links before trusting them as world truth.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    summaryPill(title: "Unconfirmed", value: "\(items.count)", systemImage: "mappin.slash.circle")
                    summaryPill(title: "Suggested", value: "\(suggestedCount)", systemImage: "sparkles")
                    summaryPill(title: "Homeless", value: "\(homelessCount)", systemImage: "house.slash")
                    summaryPill(title: "Interiors", value: "\(interiorCount)", systemImage: "house.lodge")
                }
            }

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("No unconfirmed placements right now.")
                        .font(.callout.weight(.medium))
                    Text("New route batches and low-confidence pins will appear here whenever they need a human confirmation pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    listColumn
                        .frame(width: 340)

                    if let selectedItem {
                        detailColumn(selectedItem)
                    }
                }
            }
        }
        .task(id: workflowMode) {
            autoPlacementModel.refresh(store: store, snapshot: snapshot, workflowMode: workflowMode)
        }
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = selectedItem?.id
            }
        }
        .onChange(of: snapshot.captures.map(\.id).joined(separator: "|")) { _, _ in
            autoPlacementModel.refresh(store: store, snapshot: snapshot, workflowMode: workflowMode)
        }
        .onChange(of: selectedCaptureRecordID) { _, newValue in
            if let newValue,
               let item = items.first(where: { $0.capture.recordID == newValue }) {
                selectedItemID = item.id
            }
        }
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        selectedItemID = item.id
                        onSelectCapture(item.capture)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            PlacesWorldReviewImagePreview(
                                store: store,
                                path: item.capture.imagePath,
                                title: nil
                            )
                            .frame(width: 104)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(item.capture.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Spacer(minLength: 6)
                                    Text(item.state.title)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(item.state.color.opacity(0.12), in: Capsule())
                                        .foregroundStyle(item.state.color)
                                }

                                Text(item.suggestedPlaceName ?? "No place match yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    itemMetricChip(value: item.confidenceLabel, label: "match", tint: item.state.color)
                                    if let suggestedNode = item.suggestedNode {
                                        itemMetricChip(value: "#\(suggestedNode.sequenceIndex + 1)", label: "node", tint: .secondary)
                                    }
                    if item.capture.shouldMirrorPreview {
                        itemMetricChip(value: "Mirror", label: "check", tint: .orange)
                    }
                    if item.capture.orientationState != .unknown {
                        itemMetricChip(value: item.capture.orientationState.displayName, label: "orientation", tint: .secondary)
                    }
                }
            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (selectedItemID == item.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 520)
    }

    private func detailColumn(_ item: PlacesWorldPlacementReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.capture.title)
                        .font(.headline)
                    Text(item.suggestedPlaceName ?? "No confirmed place anchor yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.state.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(item.state.color.opacity(0.12), in: Capsule())
                    .foregroundStyle(item.state.color)
            }

            HStack(alignment: .top, spacing: 14) {
                PlacesWorldReviewImagePreview(
                    store: store,
                    path: item.capture.imagePath,
                    title: "Candidate"
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        summaryPill(title: "Scene", value: item.capture.sceneKind.displayName, systemImage: item.capture.sceneKind == .interior ? "house.lodge" : "map")
                        summaryPill(title: "Match", value: item.confidenceLabel, systemImage: "sparkles")
                    }

                    if let suggestedNode = item.suggestedNode {
                        Text("Suggested node: \(suggestedNode.title) • #\(suggestedNode.sequenceIndex + 1)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let suggestedPlaceName = item.suggestedPlaceName {
                        Text("Suggested place: \(suggestedPlaceName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No reliable place match yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let mapPoint = item.mapPoint {
                        Text(String(format: "Suggested map point: %.3f • %.3f", mapPoint.x, mapPoint.y))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let pose = item.placement?.cameraPose {
                        Text(String(format: "Suggested pose: H %.0f° • P %.0f° • %.0fmm", pose.yawDegrees, pose.pitchDegrees, pose.focalLengthMM))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.capture.poseLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    FlowTagCloud(tags: item.tags, tint: item.state.color)
                }
            }

            HStack(spacing: 8) {
                Button {
                    confirm(item, createAnchorIfNeeded: false)
                } label: {
                    Label(item.suggestedNode == nil ? "Confirm Placement" : "Confirm to Node", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!item.canConfirm)

                Button {
                    confirm(item, createAnchorIfNeeded: true)
                } label: {
                    Label(item.capture.sceneKind == .interior ? "Link Interior to Building" : "Create Building Anchor", systemImage: item.capture.sceneKind == .interior ? "building.2.crop.circle" : "mappin.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!item.canCreateAnchor)

                Button {
                    onFocusMap(item.capture)
                } label: {
                    Label("Focus in Map", systemImage: "map")
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenLibrary()
                } label: {
                    Label("Open Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenPlace(item.suggestedPlaceID ?? item.capture.placeID)
                } label: {
                    Label("Open Place", systemImage: "building.2")
                }
                .buttonStyle(.bordered)
                .disabled(item.suggestedPlaceID == nil && item.capture.placeID == nil)
            }

            if let recordID = item.capture.recordID,
               item.capture.shouldMirrorPreview || item.capture.orientationState != .unknown {
                HStack(spacing: 8) {
                    Button {
                        store.setGeneratedBackgroundOrientation(.original, for: recordID)
                    } label: {
                        Label("Use Original", systemImage: item.capture.orientationState == .original ? "checkmark.circle.fill" : "rectangle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.setGeneratedBackgroundOrientation(.mirrored, for: recordID)
                    } label: {
                        Label("Use Mirrored", systemImage: item.capture.orientationState == .mirrored ? "checkmark.circle.fill" : "rectangle.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if item.state == .homeless {
                Text("This image still needs a place or node attachment before it should influence canon continuity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func confirm(_ item: PlacesWorldPlacementReviewItem, createAnchorIfNeeded: Bool) {
        guard let recordID = item.capture.recordID else {
            store.statusMessage = "This placement is not backed by a generated image record yet."
            return
        }

        let resolvedPlaceID = item.suggestedPlaceID ?? item.capture.placeID
        let resolvedPlaceName = item.suggestedPlaceName ?? (item.capture.placeName == "Unassigned" ? item.capture.title : item.capture.placeName)
        var targetNodeID = item.suggestedNode.flatMap { uuid(from: $0.id) }
        var targetRouteID = item.suggestedNode?.routeID.flatMap(uuid(from:))
        let mapPoint = item.mapPoint
        let pose = item.placement?.cameraPose ?? worldPose(for: item.capture)
        var buildingAnchorNodeID = item.capture.buildingAnchorNodeID.flatMap(uuid(from:))

        if let resolvedPlaceID, let mapPoint,
           createAnchorIfNeeded || (item.capture.sceneKind == .interior && targetNodeID == nil) {
            buildingAnchorNodeID = store.upsertWorldPlaceAnchor(
                placeID: resolvedPlaceID,
                title: resolvedPlaceName,
                mapPoint: mapPoint,
                role: .landmark
            )
            if item.capture.sceneKind == .interior {
                store.setPlaceInteriorLink(
                    resolvedPlaceID,
                    linkedExteriorPlaceID: store.backgrounds.first(where: { $0.id == resolvedPlaceID })?.linkedExteriorPlaceID,
                    buildingAnchorNodeID: buildingAnchorNodeID
                )
                targetNodeID = nil
                targetRouteID = nil
            } else if targetNodeID == nil {
                targetNodeID = buildingAnchorNodeID
                targetRouteID = nil
            }
        }

        if let mapPoint {
            store.confirmGeneratedBackgroundPlacement(
                recordID,
                mapPoint: mapPoint,
                pose: pose,
                worldNodeID: targetNodeID,
                routeID: targetRouteID,
                placeID: resolvedPlaceID,
                buildingAnchorNodeID: buildingAnchorNodeID
            )
        } else {
            store.attachGeneratedBackgroundRecord(
                recordID,
                toWorldNodeID: targetNodeID,
                routeID: targetRouteID,
                placeID: resolvedPlaceID,
                pose: pose,
                mapPoint: nil,
                canonStatus: item.capture.isCanon ? .canon : .candidate,
                placementStatus: .inferred,
                buildingAnchorNodeID: buildingAnchorNodeID
            )
        }
        store.selectGeneratedBackgroundRecord(for: item.capture.imagePath)
        selectedItemID = item.id
        onSelectCapture(item.capture)

        if createAnchorIfNeeded {
            store.statusMessage = item.capture.sceneKind == .interior
                ? "Linked \(resolvedPlaceName) interior to a building anchor."
                : "Created/updated building anchor for \(resolvedPlaceName)."
        } else if let suggestedNode = item.suggestedNode {
            store.statusMessage = "Confirmed placement onto \(suggestedNode.title)."
        } else {
            store.statusMessage = "Confirmed placement for \(resolvedPlaceName)."
        }
    }

    private func bestNode(
        for capture: PlacesWorldbuildingSnapshot.Capture,
        placement: PlaceWorldAutoPlacement?,
        placeID: UUID?
    ) -> PlacesWorldbuildingSnapshot.Node? {
        guard let placeID else { return nil }
        let candidates = snapshot.nodes.filter { $0.placeID == placeID }
        guard !candidates.isEmpty else { return nil }

        if capture.sceneKind == .interior,
           let anchorNode = candidates.first(where: { $0.routeID == nil }) {
            return anchorNode
        }

        let targetPoint = placement.map { PlacesWorldMapPoint(x: CGFloat($0.mapPoint.x), y: CGFloat($0.mapPoint.y)).clamped }
            ?? (capture.hasTrustedMapPosition ? capture.position : nil)
        if let targetPoint {
            return candidates.min { lhs, rhs in
                distance(lhs.position, targetPoint) < distance(rhs.position, targetPoint)
            }
        }

        return candidates.first(where: { $0.routeID == nil })
            ?? candidates.sorted { $0.sequenceIndex < $1.sequenceIndex }.first
    }

    private func distance(_ lhs: PlacesWorldMapPoint, _ rhs: PlacesWorldMapPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt((dx * dx) + (dy * dy))
    }

    private func worldPose(for capture: PlacesWorldbuildingSnapshot.Capture) -> WorldCameraPose? {
        guard capture.heading != nil || capture.pitch != nil || capture.focalLength != nil else { return nil }
        return WorldCameraPose(
            yawDegrees: capture.heading ?? 0,
            pitchDegrees: capture.pitch ?? 0,
            rollDegrees: 0,
            focalLengthMM: capture.focalLength ?? 35
        )
    }

    private func uuid(from rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func sortRank(for item: PlacesWorldPlacementReviewItem) -> Int {
        var rank = 0
        switch item.state {
        case .suggested: rank += 30
        case .relink: rank += 20
        case .homeless: rank += 10
        }
        if item.capture.sceneKind == .interior { rank += 4 }
        if item.capture.shouldMirrorPreview { rank += 2 }
        rank += Int(((item.placement?.confidence ?? item.capture.placementConfidence) * 10).rounded())
        return rank
    }

    private func summaryPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
    }

    private func itemMetricChip(value: String, label: String, tint: Color) -> some View {
        Text("\(value) \(label)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

@available(macOS 26.0, *)
struct PlacesWorldCoverageDashboardView: View {
    private struct ExteriorCoverageGap: Identifiable {
        let place: BackgroundPlate
        let captureCount: Int
        let trustedCount: Int
        let confirmedCount: Int
        let provisionalCount: Int
        let flaggedCount: Int

        var id: UUID { place.id }
        var isMissing: Bool { captureCount == 0 }
        var statusTitle: String { isMissing ? "Missing" : "Weak" }
        var statusTint: Color { isMissing ? .red : .orange }
        var summary: String {
            if isMissing {
                return "No generated captures are pinned for this exterior yet."
            }
            if confirmedCount == 0 {
                return "\(captureCount) capture\(captureCount == 1 ? "" : "s"), but none are confirmed onto the world map yet."
            }
            return "\(captureCount) capture\(captureCount == 1 ? "" : "s") exist, but trust is still thin."
        }
    }

    private struct InteriorCoverageGap: Identifiable {
        let place: BackgroundPlate
        let captureCount: Int
        let linkedCaptureCount: Int

        var id: UUID { place.id }
        var isMissing: Bool { captureCount == 0 }
        var isUnlinked: Bool { !isMissing && linkedCaptureCount == 0 }
        var statusTitle: String { isMissing ? "Missing" : "Unlinked" }
        var statusTint: Color { isMissing ? .red : .orange }
        var summary: String {
            if isMissing {
                return "No interior captures are attached to this place for \(place.name)."
            }
            return "\(captureCount) interior capture\(captureCount == 1 ? "" : "s"), but none are linked to a building anchor yet."
        }
    }

    private struct CaptureIssue: Identifiable {
        let capture: PlacesWorldbuildingSnapshot.Capture
        let reasons: [String]
        let rank: Int

        var id: String { capture.id }
    }

    let store: AnimateStore
    let snapshot: PlacesWorldbuildingSnapshot
    let workflowMode: PlaceWorkflowMode
    let onOpenPlace: (UUID?) -> Void
    let onOpenReviewUnconfirmed: () -> Void

    private var capturesByPlace: [UUID: [PlacesWorldbuildingSnapshot.Capture]] {
        snapshot.captures.reduce(into: [:]) { partialResult, capture in
            guard let placeID = capture.placeID else { return }
            partialResult[placeID, default: []].append(capture)
        }
    }

    private var exteriorPlaces: [BackgroundPlate] {
        store.backgrounds
            .filter(\.isExteriorLike)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var interiorPlaces: [BackgroundPlate] {
        store.backgrounds
            .filter { !$0.isExteriorLike }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var exteriorGaps: [ExteriorCoverageGap] {
        exteriorPlaces.compactMap { place in
            let captures = capturesByPlace[place.id] ?? []
            let trustedCount = captures.filter(\.hasTrustedMapPosition).count
            let confirmedCount = captures.filter { $0.mapPlacementStatus == .confirmed }.count
            let provisionalCount = captures.filter { $0.mapPlacementStatus != .confirmed }.count
            let flaggedCount = snapshot.placeFlaggedCounts[place.id] ?? 0
            let isMissing = captures.isEmpty
            let isWeak = !isMissing && (trustedCount == 0 || confirmedCount == 0)
            guard isMissing || isWeak else { return nil }
            return ExteriorCoverageGap(
                place: place,
                captureCount: captures.count,
                trustedCount: trustedCount,
                confirmedCount: confirmedCount,
                provisionalCount: provisionalCount,
                flaggedCount: flaggedCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMissing != rhs.isMissing { return lhs.isMissing }
            if lhs.confirmedCount != rhs.confirmedCount { return lhs.confirmedCount < rhs.confirmedCount }
            if lhs.trustedCount != rhs.trustedCount { return lhs.trustedCount < rhs.trustedCount }
            if lhs.captureCount != rhs.captureCount { return lhs.captureCount < rhs.captureCount }
            if lhs.flaggedCount != rhs.flaggedCount { return lhs.flaggedCount > rhs.flaggedCount }
            return lhs.place.name.localizedCaseInsensitiveCompare(rhs.place.name) == .orderedAscending
        }
    }

    private var interiorGaps: [InteriorCoverageGap] {
        interiorPlaces.compactMap { place in
            let captures = capturesByPlace[place.id] ?? []
            let linkedCount = captures.filter { $0.isInteriorLinkedToBuilding || $0.buildingAnchorNodeID != nil }.count
            let hasPlaceAnchor = place.buildingAnchorNodeID != nil || place.linkedExteriorPlaceID != nil
            let isMissing = captures.isEmpty
            let isUnlinked = !isMissing && !hasPlaceAnchor && linkedCount == 0
            guard isMissing || isUnlinked else { return nil }
            return InteriorCoverageGap(
                place: place,
                captureCount: captures.count,
                linkedCaptureCount: linkedCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMissing != rhs.isMissing { return lhs.isMissing }
            if lhs.captureCount != rhs.captureCount { return lhs.captureCount < rhs.captureCount }
            return lhs.place.name.localizedCaseInsensitiveCompare(rhs.place.name) == .orderedAscending
        }
    }

    private var captureIssues: [CaptureIssue] {
        snapshot.captures.compactMap { capture in
            var reasons: [String] = []
            var rank = 0
            if capture.placeID == nil {
                reasons.append("Homeless")
                rank += 4
            }
            if capture.mapPlacementStatus == .unplaced || !capture.hasTrustedMapPosition {
                reasons.append(capture.mapPlacementStatus == .unplaced ? "Unplaced" : "Weak placement")
                rank += 3
            }
            if capture.sceneKind == .interior && !capture.isInteriorLinkedToBuilding {
                reasons.append("Interior unlinked")
                rank += 2
            }
            if capture.mapPlacementStatus == .inferred {
                reasons.append("Provisional")
                rank += 1
            }
            guard !reasons.isEmpty else { return nil }
            return CaptureIssue(capture: capture, reasons: reasons, rank: rank)
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return lhs.capture.title.localizedCaseInsensitiveCompare(rhs.capture.title) == .orderedAscending
        }
    }

    private var exteriorMissingCount: Int {
        exteriorGaps.filter(\.isMissing).count
    }

    private var exteriorWeakCount: Int {
        exteriorGaps.filter { !$0.isMissing }.count
    }

    private var exteriorReadyCount: Int {
        max(exteriorPlaces.count - exteriorGaps.count, 0)
    }

    private var interiorMissingCount: Int {
        interiorGaps.filter(\.isMissing).count
    }

    private var interiorUnlinkedCount: Int {
        interiorGaps.filter(\.isUnlinked).count
    }

    private var interiorReadyCount: Int {
        max(interiorPlaces.count - interiorGaps.count, 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coverage Dashboard")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("See where the world map is solid, where exterior pins are still weak, and which interiors still need a building anchor before your next batch pass.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    Button {
                        onOpenReviewUnconfirmed()
                    } label: {
                        Label("Open Review Queue", systemImage: "mappin.slash.circle")
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    coverageMetricCard(
                        title: "Exterior Places Ready",
                        value: "\(exteriorReadyCount) / \(exteriorPlaces.count)",
                        subtitle: exteriorGaps.isEmpty ? "Every exterior has at least one trusted confirmed pin." : "\(exteriorMissingCount) missing • \(exteriorWeakCount) weak",
                        systemImage: "mountain.2",
                        tint: .green
                    )
                    coverageMetricCard(
                        title: "Interior Places Linked",
                        value: "\(interiorReadyCount) / \(interiorPlaces.count)",
                        subtitle: interiorGaps.isEmpty ? "Every interior has coverage plus a building anchor." : "\(interiorMissingCount) missing • \(interiorUnlinkedCount) unlinked",
                        systemImage: "house.lodge",
                        tint: .mint
                    )
                    coverageMetricCard(
                        title: "Unplaced Captures",
                        value: "\(snapshot.unplacedCaptureCount)",
                        subtitle: snapshot.unplacedCaptureCount == 0 ? "No captures are currently floating without a reliable map point." : "These still need stronger placement confidence or confirmation.",
                        systemImage: "mappin.slash",
                        tint: .orange
                    )
                    coverageMetricCard(
                        title: "Homeless Captures",
                        value: "\(snapshot.homelessCaptureCount)",
                        subtitle: snapshot.homelessCaptureCount == 0 ? "Every rendered capture is assigned to a place." : "These captures still need a place association before they can become canon.",
                        systemImage: "house.slash",
                        tint: .red
                    )
                }

                coverageSectionCard(
                    title: "Exterior gaps",
                    subtitle: "Exterior places that still need at least one trustworthy confirmed world-map placement.",
                    systemImage: "map"
                ) {
                    if exteriorGaps.isEmpty {
                        readyStateRow(
                            title: "Exterior coverage looks healthy.",
                            message: "No exterior places currently need attention in this workflow."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(exteriorGaps.prefix(8))) { gap in
                                exteriorGapRow(gap)
                            }
                            if exteriorGaps.count > 8 {
                                moreCountFooter(exteriorGaps.count - 8)
                            }
                        }
                    }
                }

                coverageSectionCard(
                    title: "Interior gaps",
                    subtitle: "Interior places that still need first-pass coverage or a building anchor before they behave like indoor Google Maps pins.",
                    systemImage: "building.2"
                ) {
                    if interiorGaps.isEmpty {
                        readyStateRow(
                            title: "Interior linking is caught up.",
                            message: "Every interior place in this workflow already has coverage and a building-anchor relationship."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(interiorGaps.prefix(8))) { gap in
                                interiorGapRow(gap)
                            }
                            if interiorGaps.count > 8 {
                                moreCountFooter(interiorGaps.count - 8)
                            }
                        }
                    }
                }

                coverageSectionCard(
                    title: "Capture issues",
                    subtitle: "The most urgent homeless, unplaced, or provisional captures that still need a human pass in Review Unconfirmed.",
                    systemImage: "exclamationmark.bubble"
                ) {
                    if captureIssues.isEmpty {
                        readyStateRow(
                            title: "No capture-level blockers right now.",
                            message: "The snapshot does not currently expose any homeless, unplaced, or unlinked captures for this workflow."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(captureIssues.prefix(10))) { issue in
                                captureIssueRow(issue)
                            }
                            if captureIssues.count > 10 {
                                moreCountFooter(captureIssues.count - 10)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 2)
        }
    }

    private func exteriorGapRow(_ gap: ExteriorCoverageGap) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(gap.place.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge(gap.statusTitle, tint: gap.statusTint)
                }

                Text(gap.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                flowMetrics([
                    ("Captures", "\(gap.captureCount)", .secondary),
                    ("Trusted", "\(gap.trustedCount)", .secondary),
                    ("Confirmed", "\(gap.confirmedCount)", .green),
                    ("Provisional", "\(gap.provisionalCount)", gap.provisionalCount > 0 ? .orange : .secondary),
                    ("Flags", "\(gap.flaggedCount)", gap.flaggedCount > 0 ? .orange : .secondary)
                ])
            }

            Spacer(minLength: 12)

            Button {
                onOpenPlace(gap.place.id)
            } label: {
                Label("Open Place", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func interiorGapRow(_ gap: InteriorCoverageGap) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(gap.place.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge(gap.statusTitle, tint: gap.statusTint)
                }

                Text(gap.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                flowMetrics([
                    ("Category", gap.place.locationCategory.isEmpty ? "Interior" : gap.place.locationCategory, .secondary),
                    ("Captures", "\(gap.captureCount)", .secondary),
                    ("Linked", "\(gap.linkedCaptureCount)", gap.linkedCaptureCount > 0 ? .mint : .orange),
                    ("Workflow", workflowMode.shortLabel, .secondary)
                ])
            }

            Spacer(minLength: 12)

            Button {
                onOpenPlace(gap.place.id)
            } label: {
                Label("Open Place", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func captureIssueRow(_ issue: CaptureIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.capture.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(issue.capture.placeName)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                flowMetrics(issue.reasons.map { ($0, "", reasonTint(for: $0)) })
            }

            Spacer(minLength: 12)

            if let placeID = issue.capture.placeID {
                Button {
                    onOpenPlace(placeID)
                } label: {
                    Label("Open Place", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(14)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func coverageMetricCard(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(16)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func coverageSectionCard<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer(minLength: 12)
            }

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func readyStateRow(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func moreCountFooter(_ count: Int) -> some View {
        Text("+\(count) more item\(count == 1 ? "" : "s") hidden in this summary")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func statusBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func metricChip(title: String, value: String, tint: Color) -> some View {
        let label = value.isEmpty ? title : "\(title) \(value)"
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func flowMetrics(_ metrics: [(String, String, Color)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { entry in
                    let metric = entry.element
                    metricChip(title: metric.0, value: metric.1, tint: metric.2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reasonTint(for reason: String) -> Color {
        if reason.localizedCaseInsensitiveContains("homeless") { return .red }
        if reason.localizedCaseInsensitiveContains("unplaced") { return .orange }
        if reason.localizedCaseInsensitiveContains("unlinked") { return .mint }
        return .secondary
    }
}

@available(macOS 26.0, *)
struct PlacesWorldRouteInspectorCard: View {
    let route: PlacesWorldbuildingSnapshot.Route?
    let flaggedReviewCount: Int
    let onAnalyzeContinuity: (PlacesWorldbuildingSnapshot.Route) -> Void
    let onPrepareGeneration: (PlacesWorldbuildingSnapshot.Route) -> Void
    let onOpenPlace: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Route Review + Generation", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.headline)
                Spacer()
                if let route {
                    Text(route.coverageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let route {
                VStack(alignment: .leading, spacing: 10) {
                    Text(route.title)
                        .font(.title3.weight(.semibold))
                    Text(route.generationSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        statPill(title: "Coverage", value: route.coverageLabel, systemImage: "camera.viewfinder")
                        statPill(title: "Flagged", value: "\(flaggedReviewCount)", systemImage: flaggedReviewCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        statPill(title: "Length", value: route.lengthLabel, systemImage: "ruler")
                    }

                    HStack(spacing: 8) {
                        Button {
                            onAnalyzeContinuity(route)
                        } label: {
                            Label("Analyze Continuity", systemImage: "sparkles.rectangle.stack")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            onPrepareGeneration(route)
                        } label: {
                            Label("Prepare Route Generation", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onOpenPlace(route.placeID)
                        } label: {
                            Label("Open Place", systemImage: "building.2")
                        }
                        .buttonStyle(.bordered)
                        .disabled(route.placeID == nil)
                    }
                }
            } else {
                emptyCard(title: "No route selected", message: "Choose a route on the map to inspect continuity, review flag counts, or queue a generation batch.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.8), in: Capsule())
    }

    private func emptyCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@available(macOS 26.0, *)
struct PlacesWorldNodeInspectorCard: View {
    let node: PlacesWorldbuildingSnapshot.Node?
    let store: AnimateStore
    let draft: PlacesWorldNodeDraft?
    let onApplyDraft: (PlacesWorldbuildingSnapshot.Node, PlacesWorldNodeDraft) -> Void
    let onUseCanon: (PlacesWorldbuildingSnapshot.Node) -> Void
    let onOpenPlace: (UUID?) -> Void

    @State private var localDraftTitle = ""
    @State private var localHeading: Double = 0
    @State private var localPitch: Double = 0
    @State private var localRoll: Double = 0
    @State private var localFocalLength: Double = 35
    @State private var localLandmarks = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Node Inspector", systemImage: "scope")
                    .font(.headline)
                Spacer()
                if let node {
                    Text(node.canonStatusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(node.isFlagged ? .orange : .green)
                }
            }

            if let node {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        thumbnail(for: node)
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Node title", text: $localDraftTitle)
                                .textFieldStyle(.roundedBorder)
                            LabeledContent("Place") {
                                Text(node.placeName)
                            }
                            LabeledContent("Map position") {
                                Text(node.positionLabel)
                            }
                            LabeledContent("Canon") {
                                Text(node.canonImagePath == nil ? "No canon image linked" : "Canon image linked")
                            }
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Heading")
                                .foregroundStyle(.secondary)
                            AngleValueField(value: $localHeading, suffix: "°")
                        }
                        GridRow {
                            Text("Pitch")
                                .foregroundStyle(.secondary)
                            AngleValueField(value: $localPitch, suffix: "°")
                        }
                        GridRow {
                            Text("Roll")
                                .foregroundStyle(.secondary)
                            AngleValueField(value: $localRoll, suffix: "°")
                        }
                        GridRow {
                            Text("Focal Length")
                                .foregroundStyle(.secondary)
                            AngleValueField(value: $localFocalLength, suffix: "mm")
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Expected landmarks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Bridge, terraces, clinic facade…", text: $localLandmarks, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }

                    if !node.qaFlags.isEmpty {
                        FlowTagCloud(tags: node.qaFlags, tint: node.isFlagged ? .orange : .secondary)
                    }

                    Text("Edits update the live worldbuilding inspector now and will persist through the dedicated world graph store once those APIs are wired.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            onApplyDraft(node, currentDraft)
                        } label: {
                            Label("Apply Draft", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            onUseCanon(node)
                        } label: {
                            Label("Use Canon Image", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.bordered)
                        .disabled(node.canonImagePath == nil && node.sourceImagePath == nil)

                        Button {
                            onOpenPlace(node.placeID)
                        } label: {
                            Label("Open Place", systemImage: "building.2")
                        }
                        .buttonStyle(.bordered)
                        .disabled(node.placeID == nil)
                    }
                }
                .task(id: node.id) {
                    syncLocalDraft(with: draft ?? PlacesWorldNodeDraft(node: node))
                }
            } else {
                emptyCard(title: "No node selected", message: "Choose a node on the map to review camera pose, expected landmarks, and canon status.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var currentDraft: PlacesWorldNodeDraft {
        PlacesWorldNodeDraft(
            node: PlacesWorldbuildingSnapshot.Node(
                id: node?.id ?? UUID().uuidString,
                title: localDraftTitle,
                placeID: node?.placeID,
                placeName: node?.placeName ?? "",
                routeID: node?.routeID,
                sequenceIndex: node?.sequenceIndex ?? 0,
                position: node?.position ?? .zero,
                heading: localHeading,
                pitch: localPitch,
                roll: localRoll,
                focalLength: localFocalLength,
                expectedLandmarks: localLandmarksList,
                canonImagePath: node?.canonImagePath,
                sourceImagePath: node?.sourceImagePath,
                imageRecordID: node?.imageRecordID,
                angleImageID: node?.angleImageID,
                statusText: node?.statusText ?? "",
                isFlagged: node?.isFlagged ?? false,
                qaFlags: node?.qaFlags ?? []
            )
        )
    }

    private var localLandmarksList: [String] {
        localLandmarks
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func thumbnail(for node: PlacesWorldbuildingSnapshot.Node) -> some View {
        if let path = node.canonImagePath ?? node.sourceImagePath,
           let url = resolvedAssetURL(for: path) {
            CachedThumbnailView(path: url.path, size: 124)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(width: 124, height: 124)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quinary.opacity(0.35))
                .frame(width: 124, height: 124)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func resolvedAssetURL(for path: String) -> URL? {
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func syncLocalDraft(with draft: PlacesWorldNodeDraft) {
        localDraftTitle = draft.title
        localHeading = draft.heading
        localPitch = draft.pitch
        localRoll = draft.roll
        localFocalLength = draft.focalLength
        localLandmarks = draft.expectedLandmarks.joined(separator: ", ")
    }

    private func emptyCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@available(macOS 26.0, *)
struct PlacesWorldBatchMonitorSnapshot {
    struct ErrorDetail: Identifiable, Hashable, Sendable {
        var id: String
        var key: String
        var code: Int?
        var message: String

        init(key: String, code: Int? = nil, message: String) {
            self.key = key
            self.code = code
            self.message = message
            self.id = "\(key.lowercased())-\(code ?? -1)-\(message)"
        }

        var rowLabel: String {
            key.replacingOccurrences(of: "-", with: " ")
        }
    }

    struct Batch: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        var batchName: String
        var routeID: String?
        var routeTitle: String?
        var placeID: UUID?
        var placeName: String
        var workflow: PlaceWorkflowMode
        var state: String
        var promptCount: Int
        var successCount: Int
        var failureCount: Int
        var pendingCount: Int
        var imageSize: String
        var modelName: String
        var submittedAt: Date?
        var lastStatusCheck: Date?
        var metadataPath: String?
        var outputRootPath: String?
        var decodedImagePaths: [String]
        var generatedImagePaths: [String]
        var errors: [ErrorDetail]
        var sourceLabel: String
        var isRegisteredInStore: Bool

        var stateLabel: String {
            switch state.uppercased() {
            case let value where value.contains("SUCCEEDED"): return "Succeeded"
            case let value where value.contains("RUNNING") || value.contains("ACTIVE") || value.contains("PROCESSING"): return "Running"
            case let value where value.contains("PENDING") || value.contains("QUEUED") || value.contains("CREATED"): return "Pending"
            case let value where value.contains("FAILED") || value.contains("ERROR"): return "Failed"
            case let value where value.contains("CANCEL"): return "Cancelled"
            default:
                return state
                    .replacingOccurrences(of: "JOB_STATE_", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
            }
        }

        var stateColor: Color {
            switch state.uppercased() {
            case let value where value.contains("SUCCEEDED"): return .green
            case let value where value.contains("FAILED") || value.contains("ERROR"): return .red
            case let value where value.contains("RUNNING") || value.contains("ACTIVE") || value.contains("PROCESSING"): return .blue
            case let value where value.contains("PENDING") || value.contains("QUEUED") || value.contains("CREATED"): return .orange
            default: return .secondary
            }
        }

        var completedCount: Int { successCount + failureCount }

        var progressLabel: String {
            let pieces = [
                "\(successCount) ok",
                failureCount > 0 ? "\(failureCount) failed" : nil,
                pendingCount > 0 ? "\(pendingCount) pending" : nil
            ].compactMap { $0 }
            return pieces.joined(separator: " • ")
        }

        var contextLabel: String {
            let routePart = routeTitle?.nilIfBlank
            let placePart = placeName.nilIfBlank
            if let routePart, let placePart, routePart.localizedCaseInsensitiveContains(placePart) == false {
                return "\(placePart) • \(routePart)"
            }
            if let routePart { return routePart }
            if let placePart { return placePart }
            return "Terminal-submitted batch"
        }

        var primaryOutputCount: Int {
            max(decodedImagePaths.count, generatedImagePaths.count)
        }
    }

    var batches: [Batch]
    var refreshedAt: Date

    var activeCount: Int {
        batches.filter {
            let state = $0.state.uppercased()
            return state.contains("PENDING") || state.contains("RUNNING") || state.contains("PROCESSING") || state.contains("ACTIVE") || state.contains("QUEUED")
        }.count
    }

    var failedCount: Int { batches.filter { $0.failureCount > 0 || $0.state.uppercased().contains("FAILED") }.count }

    @MainActor
    static func make(
        store: AnimateStore,
        worldSnapshot: PlacesWorldbuildingSnapshot,
        projectURL: URL?,
        workflowMode: PlaceWorkflowMode,
        selectedRouteID: String?,
        selectedPlaceID: UUID?
    ) -> Self {
        let routesByID = Dictionary(uniqueKeysWithValues: worldSnapshot.routes.map { ($0.id, $0) })
        let registered = store.placesWorkflowLibrary.worldGenerationBatches
            .filter { $0.workflow == workflowMode }
        let discovered = scanBatchMetadataFiles(projectURL: projectURL, workflowMode: workflowMode)

        var discoveredByKey: [String: ParsedBatchMetadata] = [:]
        for item in discovered {
            for key in item.mergeKeys where discoveredByKey[key] == nil {
                discoveredByKey[key] = item
            }
        }

        var consumedKeys = Set<String>()
        var merged: [Batch] = []

        for batch in registered {
            let routeIDString = batch.routeID?.uuidString.lowercased()
            let route = routeIDString.flatMap { routesByID[$0] }
            let metadataURL = resolvedURL(for: batch.metadataPath, store: store, projectURL: projectURL)
            let outputURL = resolvedURL(for: batch.outputRootPath, store: store, projectURL: projectURL)
            let candidateKeys = [
                normalizedMergeKey(for: metadataURL?.path),
                normalizedMergeKey(for: batch.metadataPath),
                normalizedMergeKey(for: outputURL?.path),
                normalizedMergeKey(for: batch.outputRootPath),
                normalizedMergeKey(for: batch.title),
                normalizedMergeKey(for: batch.id.uuidString)
            ].compactMap { $0 }
            let parsed = candidateKeys.lazy.compactMap { discoveredByKey[$0] }.first
            if let parsed {
                consumedKeys.formUnion(parsed.mergeKeys)
            }
            merged.append(
                buildBatch(
                    workflowMode: workflowMode,
                    registeredBatch: batch,
                    parsed: parsed,
                    route: route,
                    matchedRoute: parsed.flatMap { matchRoute(for: $0, routes: worldSnapshot.routes) }
                )
            )
        }

        for parsed in discovered where consumedKeys.isDisjoint(with: parsed.mergeKeys) {
            let matchedRoute = matchRoute(for: parsed, routes: worldSnapshot.routes)
            merged.append(
                buildBatch(
                    workflowMode: workflowMode,
                    registeredBatch: nil,
                    parsed: parsed,
                    route: nil,
                    matchedRoute: matchedRoute
                )
            )
            consumedKeys.formUnion(parsed.mergeKeys)
        }

        let sorted = merged.sorted { lhs, rhs in
            let lhsRank = relevanceRank(for: lhs, selectedRouteID: selectedRouteID, selectedPlaceID: selectedPlaceID)
            let rhsRank = relevanceRank(for: rhs, selectedRouteID: selectedRouteID, selectedPlaceID: selectedPlaceID)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return (lhs.submittedAt ?? .distantPast) > (rhs.submittedAt ?? .distantPast)
        }

        return PlacesWorldBatchMonitorSnapshot(batches: Array(sorted.prefix(24)), refreshedAt: Date())
    }

    private static func relevanceRank(for batch: Batch, selectedRouteID: String?, selectedPlaceID: UUID?) -> Int {
        var score = 0
        if let selectedRouteID, batch.routeID == selectedRouteID { score += 12 }
        if let selectedPlaceID, batch.placeID == selectedPlaceID { score += 8 }
        let state = batch.state.uppercased()
        if state.contains("RUNNING") || state.contains("PENDING") || state.contains("PROCESSING") || state.contains("ACTIVE") { score += 6 }
        if batch.failureCount > 0 { score += 4 }
        if batch.isRegisteredInStore { score += 2 }
        return score
    }

    private static func buildBatch(
        workflowMode: PlaceWorkflowMode,
        registeredBatch: PlaceWorldGenerationBatch?,
        parsed: ParsedBatchMetadata?,
        route: PlacesWorldbuildingSnapshot.Route?,
        matchedRoute: PlacesWorldbuildingSnapshot.Route?
    ) -> Batch {
        let resolvedRoute = route ?? matchedRoute
        let placeID = resolvedRoute?.placeID
        let placeName = resolvedRoute?.placeName
            ?? parsed?.placeNameGuess
            ?? registeredBatch?.title.nilIfBlank
            ?? "World route"
        let registeredSuccessCount = registeredBatch.map {
            Reflection.int(named: "successCount", in: $0)
                ?? Reflection.int(named: "remoteSuccessfulCount", in: $0)
                ?? $0.generatedImagePaths.count
        } ?? 0
        let registeredFailureCount = registeredBatch.map {
            Reflection.int(named: "failureCount", in: $0)
                ?? Reflection.int(named: "remoteFailureCount", in: $0)
                ?? Reflection.int(named: "errorCount", in: $0)
                ?? 0
        } ?? 0
        let promptCount = max(
            registeredBatch?.promptCount ?? 0,
            parsed?.promptCount ?? 0,
            parsed?.rowCount ?? 0
        )
        let successCount = parsed?.successCount ?? registeredSuccessCount
        let failureCount = parsed?.failureCount ?? registeredFailureCount
        let pendingCount = max(promptCount - successCount - failureCount, 0)
        let metadataPath = parsed?.metadataPath ?? registeredBatch?.metadataPath
        let outputRootPath = parsed?.outputRootPath ?? registeredBatch?.outputRootPath
        let batchID = normalizedMergeKey(for: metadataPath)
            ?? normalizedMergeKey(for: outputRootPath)
            ?? normalizedMergeKey(for: parsed?.batchName)
            ?? registeredBatch?.id.uuidString.lowercased()
            ?? UUID().uuidString.lowercased()
        let title = parsed?.title.nilIfBlank
            ?? registeredBatch?.title.nilIfBlank
            ?? resolvedRoute?.title
            ?? parsed?.routeTitleGuess
            ?? "World batch"
        return Batch(
            id: batchID,
            title: title,
            batchName: parsed?.batchName?.nilIfBlank ?? registeredBatch?.title ?? title,
            routeID: resolvedRoute?.id ?? registeredBatch?.routeID?.uuidString.lowercased(),
            routeTitle: resolvedRoute?.title ?? parsed?.routeTitleGuess,
            placeID: placeID,
            placeName: placeName,
            workflow: registeredBatch?.workflow ?? workflowMode,
            state: parsed?.state ?? registeredBatch?.state ?? "queued",
            promptCount: promptCount,
            successCount: successCount,
            failureCount: failureCount,
            pendingCount: pendingCount,
            imageSize: parsed?.imageSize ?? registeredBatch?.imageSize ?? "2K",
            modelName: parsed?.modelName ?? registeredBatch?.model.rawValue ?? "gemini",
            submittedAt: parsed?.submittedAt ?? registeredBatch?.submittedAt,
            lastStatusCheck: parsed?.lastStatusCheck
                ?? registeredBatch.flatMap { reflectedDate(named: "lastCheckedAt", in: $0) }
                ?? registeredBatch.flatMap { reflectedDate(named: "remoteUpdatedAt", in: $0) }
                ?? registeredBatch.flatMap { reflectedDate(named: "remoteFinishedAt", in: $0) },
            metadataPath: metadataPath,
            outputRootPath: outputRootPath,
            decodedImagePaths: parsed?.decodedImagePaths ?? [],
            generatedImagePaths: registeredBatch?.generatedImagePaths ?? [],
            errors: parsed?.errors ?? [],
            sourceLabel: registeredBatch == nil ? "Terminal / watcher" : (parsed == nil ? "Library registration" : "Library + watcher"),
            isRegisteredInStore: registeredBatch != nil
        )
    }

    private static func matchRoute(for parsed: ParsedBatchMetadata, routes: [PlacesWorldbuildingSnapshot.Route]) -> PlacesWorldbuildingSnapshot.Route? {
        let clues = [parsed.routeTitleGuess, parsed.title, parsed.batchName].compactMap { $0?.lowercased() }
        guard !clues.isEmpty else { return nil }
        return routes.first { route in
            let routeTitle = route.title.lowercased()
            return clues.contains(where: { clue in
                let normalizedClue = clue.replacingOccurrences(of: "-", with: " ")
                return routeTitle == normalizedClue || routeTitle.contains(normalizedClue) || normalizedClue.contains(routeTitle)
            })
        }
    }

    private static func scanBatchMetadataFiles(projectURL: URL?, workflowMode: PlaceWorkflowMode) -> [ParsedBatchMetadata] {
        guard let root = projectURL.map({ ProjectPaths(root: $0).animatePlaceBatches }),
              FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var urls: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.lastPathComponent == "batch_submission.json" else { continue }
            let workflowFolder = fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if workflowMode == .photorealistic {
                guard workflowFolder.lowercased().contains("photo") else { continue }
            } else {
                guard workflowFolder.lowercased().contains("anim") else { continue }
            }
            urls.append(fileURL)
        }

        urls.sort { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        return urls.prefix(40).compactMap(parseBatchMetadataFile)
    }

    private static func parseBatchMetadataFile(_ url: URL) -> ParsedBatchMetadata? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let latestStatus = json["latest_status"] as? [String: Any]
        let resultSummary = latestStatus?["result_summary"] as? [String: Any]
        let localFiles = json["local_files"] as? [String: Any]
        let promptManifest = json["prompt_manifest"] as? [[String: Any]] ?? []

        let routeGuess = promptManifest.compactMap { entry -> String? in
            guard let prompt = entry["prompt"] as? String else { return nil }
            return extractRouteName(from: prompt)
        }.first

        let successCount = resultSummary?["success_count"] as? Int
            ?? ((latestStatus?["completion_stats"] as? [String: Any])?["successful_count"] as? Int)
            ?? (latestStatus?["decoded_images"] as? [String])?.count
            ?? 0
        let failureCount = resultSummary?["error_count"] as? Int ?? 0
        let rowCount = resultSummary?["row_count"] as? Int ?? (json["prompt_count"] as? Int ?? promptManifest.count)

        let errors = ((resultSummary?["errors"] as? [[String: Any]]) ?? []).map { error in
            ErrorDetail(
                key: (error["key"] as? String) ?? "row",
                code: error["code"] as? Int,
                message: (error["message"] as? String) ?? (error["details"] as? String) ?? "Unknown error"
            )
        }

        return ParsedBatchMetadata(
            title: cleaned((json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? url.deletingLastPathComponent().lastPathComponent,
            batchName: cleaned((json["batch_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)),
            state: (latestStatus?["state"] as? String)
                ?? (json["batch_state"] as? String)
                ?? "JOB_STATE_PENDING",
            promptCount: json["prompt_count"] as? Int ?? promptManifest.count,
            rowCount: rowCount,
            successCount: successCount,
            failureCount: failureCount,
            imageSize: (json["image_size"] as? String) ?? "2K",
            modelName: (json["model"] as? String) ?? "gemini",
            submittedAt: parsedDate(json["submitted_at"]),
            lastStatusCheck: parsedDate(json["last_status_check"]),
            metadataPath: url.path,
            outputRootPath: (localFiles?["batch_plan"] as? String).flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? url.deletingLastPathComponent().path,
            decodedImagePaths: latestStatus?["decoded_images"] as? [String] ?? [],
            errors: errors,
            routeTitleGuess: routeGuess,
            placeNameGuess: inferPlaceName(from: json, routeTitleGuess: routeGuess)
        )
    }

    private static func inferPlaceName(from json: [String: Any], routeTitleGuess: String?) -> String? {
        if let routeTitleGuess, routeTitleGuess.localizedCaseInsensitiveContains("clinic") {
            return "Village Clinic"
        }
        let displayName = (json["display_name"] as? String) ?? (json["character_name"] as? String)
        return displayName?.replacingOccurrences(of: "-", with: " ").capitalized.nilIfBlank
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func extractRouteName(from prompt: String) -> String? {
        let marker = "This frame is route "
        guard let start = prompt.range(of: marker)?.upperBound else { return nil }
        let remaining = prompt[start...]
        if let end = remaining.range(of: ", node")?.lowerBound {
            return String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        return nil
    }

    private static func parsedDate(_ rawValue: Any?) -> Date? {
        guard let string = rawValue as? String else { return nil }
        return parsedDate(string)
    }

    @MainActor
    private static func resolvedURL(for path: String?, store: AnimateStore, projectURL: URL?) -> URL? {
        guard let path = path?.nilIfBlank else { return nil }
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return projectURL?.appendingPathComponent(path)
    }

    private static func normalizedMergeKey(for value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }
        return trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private static func reflectedDate(named label: String, in value: Any) -> Date? {
        guard let child = Mirror(reflecting: value).children.first(where: { $0.label == label })?.value else {
            return nil
        }
        if let date = child as? Date { return date }
        if let string = child as? String { return parsedDate(string) }
        return nil
    }

    private static func parsedDate(_ string: String) -> Date? {
        AmiraDateFormatter.parse(string)
    }

    private struct ParsedBatchMetadata {
        var title: String
        var batchName: String?
        var state: String
        var promptCount: Int
        var rowCount: Int
        var successCount: Int
        var failureCount: Int
        var imageSize: String
        var modelName: String
        var submittedAt: Date?
        var lastStatusCheck: Date?
        var metadataPath: String
        var outputRootPath: String
        var decodedImagePaths: [String]
        var errors: [ErrorDetail]
        var routeTitleGuess: String?
        var placeNameGuess: String?

        var mergeKeys: Set<String> {
            Set([
                normalizedMergeKey(for: metadataPath),
                normalizedMergeKey(for: outputRootPath),
                normalizedMergeKey(for: batchName),
                normalizedMergeKey(for: title)
            ].compactMap { $0 })
        }
    }
}

@available(macOS 26.0, *)
struct PlacesWorldBatchMonitorSection: View {
    let store: AnimateStore
    let snapshot: PlacesWorldbuildingSnapshot
    let projectURL: URL?
    let workflowMode: PlaceWorkflowMode
    let selectedRouteID: String?
    let selectedPlaceID: UUID?
    let onOpenPlace: (UUID?) -> Void
    let onFocusRoute: (String?) -> Void

    @State private var refreshToken = Date()
    @State private var selectedBatchID: String?

    private var monitorSnapshot: PlacesWorldBatchMonitorSnapshot {
        _ = refreshToken
        return PlacesWorldBatchMonitorSnapshot.make(
            store: store,
            worldSnapshot: snapshot,
            projectURL: projectURL,
            workflowMode: workflowMode,
            selectedRouteID: selectedRouteID,
            selectedPlaceID: selectedPlaceID
        )
    }

    private var selectedBatch: PlacesWorldBatchMonitorSnapshot.Batch? {
        if let selectedBatchID,
           let match = monitorSnapshot.batches.first(where: { $0.id == selectedBatchID }) {
            return match
        }
        if let selectedRouteID,
           let routeMatch = monitorSnapshot.batches.first(where: { $0.routeID == selectedRouteID }) {
            return routeMatch
        }
        if let selectedPlaceID,
           let placeMatch = monitorSnapshot.batches.first(where: { $0.placeID == selectedPlaceID }) {
            return placeMatch
        }
        return monitorSnapshot.batches.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Batch Monitor")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Terminal-submitted and in-app world route batches are discovered from the place-batches metadata files and refreshed automatically while the app window stays open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    monitorPill(title: "Watching", value: "\(monitorSnapshot.batches.count)", systemImage: "dot.radiowaves.left.and.right")
                    monitorPill(title: "Active", value: "\(monitorSnapshot.activeCount)", systemImage: "hourglass")
                    monitorPill(title: "Issues", value: "\(monitorSnapshot.failedCount)", systemImage: "exclamationmark.triangle")
                }
            }

            if let selectedRouteID,
               let route = snapshot.route(withID: selectedRouteID) {
                Label("Prioritizing batches for \(route.title)", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monitorSnapshot.batches.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 16) {
                    batchList
                        .frame(width: 320)

                    if let selectedBatch {
                        batchDetail(selectedBatch)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: workflowMode) {
            await runRefreshLoop()
        }
        .onChange(of: selectedRouteID) { _, _ in
            if let selectedRouteID,
               let routeMatch = monitorSnapshot.batches.first(where: { $0.routeID == selectedRouteID }) {
                selectedBatchID = routeMatch.id
            }
        }
        .onAppear {
            if selectedBatchID == nil {
                selectedBatchID = selectedBatch?.id
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No world route batches found yet.")
                .font(.callout.weight(.medium))
            Text("Submit a route batch from the terminal or from Places, and this panel will start watching the batch_submission.json metadata automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var batchList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(monitorSnapshot.batches) { batch in
                    Button {
                        selectedBatchID = batch.id
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(batch.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(batch.contextLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Text(batch.stateLabel)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(batch.stateColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(batch.stateColor)
                            }

                            HStack(spacing: 8) {
                                metricChip(value: "\(batch.promptCount)", label: "prompts", tint: .secondary)
                                metricChip(value: "\(batch.successCount)", label: "ok", tint: .green)
                                metricChip(value: "\(batch.failureCount)", label: "failed", tint: batch.failureCount > 0 ? .red : .secondary)
                            }

                            Text(batch.progressLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            HStack {
                                Text(batch.sourceLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let submittedAt = batch.submittedAt {
                                    Text(submittedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (selectedBatchID == batch.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 420)
    }

    private func batchDetail(_ batch: PlacesWorldBatchMonitorSnapshot.Batch) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: batch.state.uppercased().contains("FAILED") ? "exclamationmark.triangle.fill" : (batch.state.uppercased().contains("SUCCEEDED") ? "checkmark.circle.fill" : "hourglass"))
                            .foregroundStyle(batch.stateColor)
                        Text(batch.title)
                            .font(.headline)
                        Text(batch.stateLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(batch.stateColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(batch.stateColor)
                    }

                    Text(batch.contextLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let batchName = batch.batchName.nilIfBlank {
                        Text(batchName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let lastStatusCheck = batch.lastStatusCheck {
                        Text("Updated \(lastStatusCheck.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Auto-refreshing")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                monitorPill(title: "Prompts", value: "\(batch.promptCount)", systemImage: "list.number")
                monitorPill(title: "Succeeded", value: "\(batch.successCount)", systemImage: "checkmark.circle")
                monitorPill(title: "Failed", value: "\(batch.failureCount)", systemImage: "xmark.circle")
                if batch.pendingCount > 0 {
                    monitorPill(title: "Pending", value: "\(batch.pendingCount)", systemImage: "hourglass")
                }
                monitorPill(title: batch.imageSize, value: batch.modelName, systemImage: "sparkles")
            }

            HStack(spacing: 8) {
                if batch.routeID != nil {
                    Button {
                        onFocusRoute(batch.routeID)
                    } label: {
                        Label("Focus Route", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    onOpenPlace(batch.placeID)
                } label: {
                    Label("Open Place", systemImage: "building.2")
                }
                .buttonStyle(.bordered)
                .disabled(batch.placeID == nil)

                if let outputRootPath = batch.outputRootPath {
                    Button {
                        showInFinder(path: outputRootPath)
                    } label: {
                        Label("Show Output Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                if let metadataPath = batch.metadataPath {
                    Button {
                        showInFinder(path: metadataPath)
                    } label: {
                        Label("Reveal Metadata", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                pathRow(title: "Output", value: batch.outputRootPath)
                pathRow(title: "Metadata", value: batch.metadataPath)
            }

            if !batch.errors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Key errors")
                        .font(.subheadline.weight(.semibold))
                    ForEach(batch.errors.prefix(4)) { error in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(error.rowLabel)
                                    .font(.caption.weight(.semibold))
                                if let code = error.code {
                                    Text("Code \(code)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            if !batch.decodedImagePaths.isEmpty || !batch.generatedImagePaths.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Decoded outputs")
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(previewPaths(for: batch).prefix(6)), id: \.self) { path in
                                PlacesWorldReviewImagePreview(
                                    store: store,
                                    path: path,
                                    title: nil
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(18)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func previewPaths(for batch: PlacesWorldBatchMonitorSnapshot.Batch) -> [String] {
        let preferred = !batch.decodedImagePaths.isEmpty ? batch.decodedImagePaths : batch.generatedImagePaths
        return Array(NSOrderedSet(array: preferred)) as? [String] ?? preferred
    }

    private func pathRow(title: String, value: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func monitorPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
    }

    private func metricChip(value: String, label: String, tint: Color) -> some View {
        Text("\(value) \(label)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private func showInFinder(path: String) {
        let fileURL: URL?
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            fileURL = resolved
        } else if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = projectURL?.appendingPathComponent(path)
        }
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            refreshToken = Date()
            if selectedBatchID == nil {
                selectedBatchID = selectedBatch?.id
            }
        }
    }
}

@available(macOS 26.0, *)
struct PlacesWorldReviewQueueSection: View {
    let store: AnimateStore
    let snapshot: PlacesWorldbuildingSnapshot
    let selectedReviewID: String?
    let onSelectReview: (PlacesWorldbuildingSnapshot.Review) -> Void
    let onApproveReview: (PlacesWorldbuildingSnapshot.Review) -> Void
    let onRejectReview: (PlacesWorldbuildingSnapshot.Review) -> Void
    let onJumpToNode: (PlacesWorldbuildingSnapshot.Review) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuity Review Queue")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Review flagged captures, compare neighboring canon candidates, and decide which images should become world truth.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    queuePill(title: "Items", value: "\(snapshot.reviews.count)", systemImage: "list.bullet.clipboard")
                    queuePill(title: "Routes", value: "\(Set(snapshot.reviews.compactMap(\.routeID)).count)", systemImage: "map")
                    queuePill(title: "Critical", value: "\(snapshot.reviews.filter { $0.severity == .critical }.count)", systemImage: "xmark.octagon.fill")
                }
            }

            if snapshot.reviews.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("No continuity flags right now.")
                        .font(.callout.weight(.medium))
                    Text("Run route analysis after each batch to surface mismatches, missing landmarks, or canon decisions that still need a human call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(snapshot.reviews) { review in
                        reviewCard(review)
                    }
                }
            }
        }
    }

    private func queuePill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
    }

    private func reviewCard(_ review: PlacesWorldbuildingSnapshot.Review) -> some View {
        PlacesWorldReviewCard(
            store: store,
            review: review,
            isSelected: selectedReviewID == review.id,
            onSelect: { onSelectReview(review) },
            onApprove: { onApproveReview(review) },
            onReject: { onRejectReview(review) },
            onJumpToNode: { onJumpToNode(review) }
        )
    }
}

@MainActor
@available(macOS 26.0, *)
private struct PlacesWorldReviewCard: View {
    let store: AnimateStore
    let review: PlacesWorldbuildingSnapshot.Review
    let isSelected: Bool
    let onSelect: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onJumpToNode: () -> Void

    private var neighborPreviewPaths: [String] {
        Array(review.neighborPaths.prefix(3))
    }

    private var canJumpToNode: Bool {
        review.nodeID != nil || review.routeID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlacesWorldReviewCardHeader(review: review)

            PlacesWorldReviewCardMedia(
                store: store,
                candidatePath: review.candidatePath,
                neighborPaths: neighborPreviewPaths
            )

            PlacesWorldReviewCardActions(
                isSelected: isSelected,
                canJumpToNode: canJumpToNode,
                onApprove: onApprove,
                onReject: onReject,
                onJumpToNode: onJumpToNode
            )
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

@MainActor
@available(macOS 26.0, *)
private struct PlacesWorldReviewCardHeader: View {
    let review: PlacesWorldbuildingSnapshot.Review

    private var routeLabel: String? {
        review.routeID?.replacingOccurrences(of: "-", with: " ")
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: review.severity.icon)
                        .foregroundStyle(review.severity.color)

                    Text(review.title)
                        .font(.headline)

                    Text(review.statusText)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(review.severity.color.opacity(0.12), in: Capsule())
                        .foregroundStyle(review.severity.color)
                }

                Text(review.shortSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(review.placeName, systemImage: "building.2")

                    if let routeLabel {
                        Label(routeLabel, systemImage: "map")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !review.mismatchTags.isEmpty {
                FlowTagCloud(tags: review.mismatchTags, tint: review.severity.color)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }
}

@MainActor
@available(macOS 26.0, *)
private struct PlacesWorldReviewCardMedia: View {
    let store: AnimateStore
    let candidatePath: String?
    let neighborPaths: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PlacesWorldReviewImagePreview(
                store: store,
                path: candidatePath,
                title: "Candidate"
            )

            if !neighborPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Neighboring references")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(neighborPaths, id: \.self) { path in
                            PlacesWorldReviewImagePreview(
                                store: store,
                                path: path,
                                title: nil
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

@MainActor
@available(macOS 26.0, *)
private struct PlacesWorldReviewCardActions: View {
    let isSelected: Bool
    let canJumpToNode: Bool
    let onApprove: () -> Void
    let onReject: () -> Void
    let onJumpToNode: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onApprove) {
                Label("Approve Canon", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onReject) {
                Label("Reject", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)

            Button(action: onJumpToNode) {
                Label("Jump to Node", systemImage: "scope")
            }
            .buttonStyle(.bordered)
            .disabled(!canJumpToNode)

            Spacer()

            if isSelected {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

@MainActor
@available(macOS 26.0, *)
private struct PlacesWorldReviewImagePreview: View {
    let store: AnimateStore
    let path: String?
    let title: String?

    private var resolvedURL: URL? {
        guard let path else { return nil }

        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }

        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let resolvedURL {
                CachedThumbnailView(path: resolvedURL.path, size: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(width: 140, height: 110)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quinary.opacity(0.35))
                    .frame(width: 140, height: 110)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PlacesWorldRoutePathShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

@available(macOS 26.0, *)
private struct PlacesWorldViewCone: Shape {
    let heading: Double
    let focalLength: Double
    let origin: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 42
        let spreadDegrees = max(18, min(70, 1800 / max(focalLength, 18)))
        let centerRadians = CGFloat((heading - 90) * .pi / 180)
        let halfSpread = CGFloat(spreadDegrees * .pi / 360)
        let left = CGPoint(
            x: origin.x + cos(centerRadians - halfSpread) * radius,
            y: origin.y + sin(centerRadians - halfSpread) * radius
        )
        let right = CGPoint(
            x: origin.x + cos(centerRadians + halfSpread) * radius,
            y: origin.y + sin(centerRadians + halfSpread) * radius
        )
        path.move(to: origin)
        path.addLine(to: left)
        path.addQuadCurve(to: right, control: CGPoint(
            x: origin.x + cos(centerRadians) * radius * 1.25,
            y: origin.y + sin(centerRadians) * radius * 1.25
        ))
        path.addLine(to: origin)
        return path
    }
}

@available(macOS 26.0, *)
private struct AngleValueField: View {
    @Binding var value: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                "0",
                value: $value,
                format: .number.precision(.fractionLength(0...1))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 88)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
    }
}

@available(macOS 26.0, *)
private struct FlowTagCloud: View {
    let tags: [String]
    let tint: Color

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        tagView(tag)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        tagView(tag)
                    }
                }
            }
        }
    }

    private func tagView(_ tag: String) -> some View {
        Text(tag)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

@available(macOS 26.0, *)
private enum Reflection {
    static func child(named label: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first(where: { $0.label == label })?.value
    }

    static func collection(named label: String, in value: Any) -> [Any] {
        guard let child = child(named: label, in: value) else { return [] }
        return Mirror(reflecting: child).children.map(\.value)
    }

    static func string(named label: String, in value: Any) -> String? {
        guard let child = child(named: label, in: value) else { return nil }
        if let string = child as? String { return string }
        if let uuid = child as? UUID { return uuid.uuidString.lowercased() }
        return String(describing: child)
    }

    static func stringArray(named label: String, in value: Any) -> [String] {
        guard let child = child(named: label, in: value) else { return [] }
        return Mirror(reflecting: child).children.compactMap { element in
            if let string = element.value as? String { return string }
            if let uuid = element.value as? UUID { return uuid.uuidString.lowercased() }
            return nil
        }
    }

    static func uuid(named label: String, in value: Any) -> UUID? {
        guard let child = child(named: label, in: value) else { return nil }
        if let uuid = child as? UUID { return uuid }
        if let string = child as? String { return UUID(uuidString: string) }
        return nil
    }

    static func double(named label: String, in value: Any) -> Double? {
        guard let child = child(named: label, in: value) else { return nil }
        if let double = child as? Double { return double }
        if let cgFloat = child as? CGFloat { return Double(cgFloat) }
        if let int = child as? Int { return Double(int) }
        if let string = child as? String { return Double(string) }
        return nil
    }

    static func int(named label: String, in value: Any) -> Int? {
        guard let child = child(named: label, in: value) else { return nil }
        if let int = child as? Int { return int }
        if let double = child as? Double { return Int(double) }
        if let string = child as? String { return Int(string) }
        return nil
    }

    static func bool(named label: String, in value: Any) -> Bool? {
        guard let child = child(named: label, in: value) else { return nil }
        if let bool = child as? Bool { return bool }
        if let string = child as? String { return NSString(string: string).boolValue }
        return nil
    }
}

private extension Array {
    func ifEmpty(_ fallback: () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
