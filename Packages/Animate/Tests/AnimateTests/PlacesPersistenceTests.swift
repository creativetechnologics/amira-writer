import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class PlacesPersistenceTests: XCTestCase {
    private func makeStore(projectURL: URL) throws -> (AnimateStore, UUID) {
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("Animate", isDirectory: true),
            withIntermediateDirectories: true
        )

        let placeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let store = AnimateStore()
        store.disableExternalFileWatch = true
        store.owpURL = projectURL
        store.backgrounds = [
            BackgroundPlate(
                id: placeID,
                name: "Bridge Landing",
                filename: "bridge-landing.png",
                notes: "Canon geography.",
                imagePaths: ["Animate/backgrounds/bridge-landing.png"],
                approvedImagePath: "Animate/backgrounds/bridge-landing.png"
            )
        ]
        store.placesWorkflowLibrary = PlacesWorkflowLibrary(
            masterMapImagePath: "Animate/backgrounds/master-map.png",
            landmarkReferences: [
                PlaceReferenceImage(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                    title: "Bridge",
                    imagePath: "Animate/backgrounds/bridge-ref.png",
                    category: .bridge
                )
            ]
        )
        return (store, placeID)
    }

    @discardableResult
    private func seedAsset(_ relativePath: String, in projectURL: URL, contents: Data = Data("stub".utf8)) throws -> URL {
        let fileURL = projectURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        return fileURL
    }

    private func makeFixedDate() -> Date {
        ISO8601DateFormatter().date(from: "2026-04-13T12:34:56Z")!
    }

    func testGeneralSaveDoesNotWritePlacesSidecars() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlacesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let (store, _) = try makeStore(projectURL: projectURL)
        let animateDir = projectURL.appendingPathComponent("Animate", isDirectory: true)

        store.save()

        XCTAssertFalse(FileManager.default.fileExists(atPath: animateDir.appendingPathComponent("places.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: animateDir.appendingPathComponent("places-workflow.json").path))
    }

    func testExplicitPlaceSaveWritesPlacesSidecarsAndPreservesPlaceIDs() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlacesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let (store, placeID) = try makeStore(projectURL: projectURL)
        let animateDir = projectURL.appendingPathComponent("Animate", isDirectory: true)

        store.save(writePlaces: true)

        let placesData = try Data(contentsOf: animateDir.appendingPathComponent("places.json"))
        let decodedPlaces = try JSONDecoder().decode([BackgroundPlate].self, from: placesData)
        XCTAssertEqual(decodedPlaces.map(\.id), [placeID])

        let workflowData = try Data(contentsOf: animateDir.appendingPathComponent("places-workflow.json"))
        let workflow = try JSONDecoder().decode(PlacesWorkflowLibrary.self, from: workflowData)
        XCTAssertEqual(workflow.masterMapImagePath, "Animate/backgrounds/master-map.png")
    }

    func testExplicitPlaceSavePersistsWorldbuildingWorkflowAndAngleMetadata() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlacesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let (store, placeID) = try makeStore(projectURL: projectURL)
        let animateDir = projectURL.appendingPathComponent("Animate", isDirectory: true)
        let fixedDate = makeFixedDate()

        let routeID = UUID(uuidString: "66666666-7777-8888-9999-000000000001")!
        let nodeID = UUID(uuidString: "66666666-7777-8888-9999-000000000002")!
        let linkedNodeID = UUID(uuidString: "66666666-7777-8888-9999-000000000003")!
        let reviewID = UUID(uuidString: "66666666-7777-8888-9999-000000000004")!
        let batchID = UUID(uuidString: "66666666-7777-8888-9999-000000000005")!
        let recordID = UUID(uuidString: "66666666-7777-8888-9999-000000000006")!
        let flagID = UUID(uuidString: "66666666-7777-8888-9999-000000000007")!
        let angleImageID = UUID(uuidString: "66666666-7777-8888-9999-000000000008")!
        let landmarkID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        let masterMapPath = "Animate/backgrounds/master-map.png"
        let landmarkPath = "Animate/backgrounds/bridge-ref.png"
        let angleImagePath = "Animate/backgrounds/places/bridge-landing/photoreal/node-01.png"
        let approvedPhotorealPath = "Animate/backgrounds/places/bridge-landing/photoreal/node-01-canon.png"
        let approvedAnimatedPath = "Animate/backgrounds/places/bridge-landing/animated/node-01-canon.png"
        let reviewCandidatePath = "Animate/backgrounds/place-batches/review-candidate.png"
        let reviewNeighborPath = "Animate/backgrounds/place-batches/review-neighbor.png"
        let batchMetadataPath = "Animate/backgrounds/place-batches/batch-001/metadata.json"
        let batchOutputRootPath = "Animate/backgrounds/place-batches/batch-001"
        let generatedImagePath = "Animate/backgrounds/place-batches/batch-001/node-01.png"

        _ = try seedAsset(masterMapPath, in: projectURL)
        _ = try seedAsset(landmarkPath, in: projectURL)
        _ = try seedAsset(angleImagePath, in: projectURL)
        _ = try seedAsset(approvedPhotorealPath, in: projectURL)
        _ = try seedAsset(approvedAnimatedPath, in: projectURL)
        _ = try seedAsset(reviewCandidatePath, in: projectURL)
        _ = try seedAsset(reviewNeighborPath, in: projectURL)
        _ = try seedAsset(batchMetadataPath, in: projectURL, contents: Data("{}".utf8))
        let batchOutputRootURL = projectURL.appendingPathComponent(batchOutputRootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: batchOutputRootURL, withIntermediateDirectories: true)
        _ = try seedAsset(generatedImagePath, in: projectURL)

        let pose = WorldCameraPose(
            yawDegrees: 87.5,
            pitchDegrees: -2.0,
            rollDegrees: 0.5,
            focalLengthMM: 28,
            horizontalFOVDegrees: 64,
            verticalFOVDegrees: 38
        )
        let mapPoint = WorldMapPoint(x: 0.18, y: 0.73)
        let qaFlag = PlaceQAFlag(
            id: flagID,
            code: "missing_building",
            message: "Building edge drifted out of frame.",
            severity: .critical
        )

        store.backgrounds[0].angleImages = [
            PlaceAngleImage(
                id: angleImageID,
                imagePath: projectURL.appendingPathComponent(angleImagePath).path,
                cameraShot: "wide",
                angle: "front-right",
                timeOfDay: "day",
                notes: "Primary canon view.",
                worldNodeID: nodeID,
                routeID: routeID,
                sequenceIndex: 1,
                cameraPose: pose,
                mapPoint: mapPoint,
                linkedGeneratedRecordID: recordID,
                canonStatus: .canon
            )
        ]

        store.placesWorkflowLibrary = PlacesWorkflowLibrary(
            masterMapImagePath: projectURL.appendingPathComponent(masterMapPath).path,
            landmarkReferences: [
                PlaceReferenceImage(
                    id: landmarkID,
                    title: "Bridge",
                    imagePath: projectURL.appendingPathComponent(landmarkPath).path,
                    category: .bridge,
                    notes: "Main continuity anchor."
                )
            ],
            worldGraph: PlaceWorldGraph(
                routes: [
                    PlaceWorldRoute(
                        id: routeID,
                        name: "Harbor Walk",
                        placeID: placeID,
                        notes: "Main traversal road.",
                        colorHex: "#123456",
                        isClosedLoop: true
                    )
                ],
                nodes: [
                    PlaceWorldNode(
                        id: nodeID,
                        routeID: routeID,
                        placeID: placeID,
                        title: "Node 01",
                        sequenceIndex: 1,
                        role: .hero,
                        mapPoint: mapPoint,
                        cameraPose: pose,
                        notes: "Keep the bridge visible on frame right.",
                        linkedNodeIDs: [linkedNodeID],
                        expectedLandmarkIDs: [landmarkID],
                        expectedLandmarkTitles: ["Bridge"],
                        forbiddenLandmarkTitles: ["Clocktower"],
                        approvedPhotorealImagePath: projectURL.appendingPathComponent(approvedPhotorealPath).path,
                        approvedAnimatedImagePath: projectURL.appendingPathComponent(approvedAnimatedPath).path,
                        lastReviewID: reviewID
                    )
                ]
            ),
            continuityReviews: [
                PlaceContinuityReview(
                    id: reviewID,
                    nodeID: nodeID,
                    routeID: routeID,
                    workflow: .photorealistic,
                    candidateRecordID: recordID,
                    candidateImagePath: projectURL.appendingPathComponent(reviewCandidatePath).path,
                    comparedNodeIDs: [linkedNodeID],
                    comparedImagePaths: [
                        projectURL.appendingPathComponent(reviewNeighborPath).path,
                        projectURL.appendingPathComponent(reviewNeighborPath).path,
                    ],
                    similarityScore: 0.91,
                    histogramScore: 0.83,
                    metadataScore: 0.77,
                    overallScore: 0.84,
                    flags: [qaFlag],
                    status: .approved,
                    analyzedAt: fixedDate
                )
            ],
            worldGenerationBatches: [
                PlaceWorldGenerationBatch(
                    id: batchID,
                    routeID: routeID,
                    workflow: .photorealistic,
                    title: "Harbor Walk Batch 01",
                    state: "submitted",
                    nodeIDs: [nodeID],
                    promptCount: 5,
                    imageSize: "2K",
                    model: .flash,
                    submittedAt: fixedDate,
                    metadataPath: projectURL.appendingPathComponent(batchMetadataPath).path,
                    outputRootPath: batchOutputRootURL.path,
                    generatedImagePaths: [
                        projectURL.appendingPathComponent(generatedImagePath).path,
                        projectURL.appendingPathComponent(generatedImagePath).path,
                    ]
                )
            ],
            generatedImageRecords: [
                GeneratedBackgroundLibraryRecord(
                    id: recordID,
                    activePath: projectURL.appendingPathComponent(generatedImagePath).path,
                    workflow: .photorealistic,
                    contentFingerprint: "fingerprint-01",
                    rating: 5,
                    summary: "Harbor walk candidate.",
                    keywords: ["harbor", "bridge"],
                    sourcePrompt: "Forward along the harbor road.",
                    linkedPlaceID: placeID,
                    worldNodeID: nodeID,
                    routeID: routeID,
                    cameraPose: pose,
                    mapPoint: mapPoint,
                    qaFlags: [qaFlag],
                    continuityReviewIDs: [reviewID],
                    canonStatus: .candidate,
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            ]
        )

        store.save(writePlaces: true)

        let placesData = try Data(contentsOf: animateDir.appendingPathComponent("places.json"))
        let persistedPlaces = try JSONDecoder().decode([BackgroundPlate].self, from: placesData)
        let persistedAngleImage = try XCTUnwrap(persistedPlaces.first?.angleImages.first)
        XCTAssertEqual(persistedAngleImage.id, angleImageID)
        XCTAssertEqual(persistedAngleImage.imagePath, angleImagePath)
        XCTAssertEqual(persistedAngleImage.worldNodeID, nodeID)
        XCTAssertEqual(persistedAngleImage.routeID, routeID)
        XCTAssertEqual(persistedAngleImage.sequenceIndex, 1)
        XCTAssertEqual(persistedAngleImage.cameraPose, pose)
        XCTAssertEqual(persistedAngleImage.mapPoint, mapPoint)
        XCTAssertEqual(persistedAngleImage.linkedGeneratedRecordID, recordID)
        XCTAssertEqual(persistedAngleImage.canonStatus, .canon)

        let workflowData = try Data(contentsOf: animateDir.appendingPathComponent("places-workflow.json"))
        let persistedWorkflow = try JSONDecoder().decode(PlacesWorkflowLibrary.self, from: workflowData)
        XCTAssertEqual(persistedWorkflow.masterMapImagePath, masterMapPath)
        XCTAssertEqual(persistedWorkflow.landmarkReferences.first?.imagePath, landmarkPath)

        let persistedRoute = try XCTUnwrap(persistedWorkflow.worldGraph.routes.first)
        XCTAssertEqual(persistedRoute.id, routeID)
        XCTAssertEqual(persistedRoute.placeID, placeID)
        XCTAssertTrue(persistedRoute.isClosedLoop)

        let persistedNode = try XCTUnwrap(persistedWorkflow.worldGraph.nodes.first)
        XCTAssertEqual(persistedNode.id, nodeID)
        XCTAssertEqual(persistedNode.routeID, routeID)
        XCTAssertEqual(persistedNode.placeID, placeID)
        XCTAssertEqual(persistedNode.mapPoint, mapPoint)
        XCTAssertEqual(persistedNode.cameraPose, pose)
        XCTAssertEqual(persistedNode.expectedLandmarkIDs, [landmarkID])
        XCTAssertEqual(persistedNode.expectedLandmarkTitles, ["Bridge"])
        XCTAssertEqual(persistedNode.forbiddenLandmarkTitles, ["Clocktower"])
        XCTAssertEqual(persistedNode.approvedPhotorealImagePath, approvedPhotorealPath)
        XCTAssertEqual(persistedNode.approvedAnimatedImagePath, approvedAnimatedPath)
        XCTAssertEqual(persistedNode.lastReviewID, reviewID)

        let persistedReview = try XCTUnwrap(persistedWorkflow.continuityReviews.first)
        XCTAssertEqual(persistedReview.id, reviewID)
        XCTAssertEqual(persistedReview.candidateImagePath, reviewCandidatePath)
        XCTAssertEqual(persistedReview.comparedImagePaths, [reviewNeighborPath])
        XCTAssertEqual(persistedReview.flags, [qaFlag])
        XCTAssertEqual(persistedReview.status, .approved)
        XCTAssertEqual(persistedReview.analyzedAt, fixedDate)

        let persistedBatch = try XCTUnwrap(persistedWorkflow.worldGenerationBatches.first)
        XCTAssertEqual(persistedBatch.id, batchID)
        XCTAssertEqual(persistedBatch.routeID, routeID)
        XCTAssertEqual(persistedBatch.metadataPath, batchMetadataPath)
        XCTAssertEqual(persistedBatch.outputRootPath, batchOutputRootPath)
        XCTAssertEqual(persistedBatch.generatedImagePaths, [generatedImagePath])
        XCTAssertEqual(persistedBatch.imageSize, "2K")
        XCTAssertEqual(persistedBatch.model, .flash)
        XCTAssertEqual(persistedBatch.submittedAt, fixedDate)

        let persistedRecord = try XCTUnwrap(persistedWorkflow.generatedImageRecords.first)
        XCTAssertEqual(persistedRecord.id, recordID)
        XCTAssertEqual(persistedRecord.activePath, generatedImagePath)
        XCTAssertEqual(persistedRecord.linkedPlaceID, placeID)
        XCTAssertEqual(persistedRecord.worldNodeID, nodeID)
        XCTAssertEqual(persistedRecord.routeID, routeID)
        XCTAssertEqual(persistedRecord.cameraPose, pose)
        XCTAssertEqual(persistedRecord.mapPoint, mapPoint)
        XCTAssertEqual(persistedRecord.qaFlags, [qaFlag])
        XCTAssertEqual(persistedRecord.continuityReviewIDs, [reviewID])
        XCTAssertEqual(persistedRecord.canonStatus, .candidate)
    }

    func testStoreGeneratedPlaceImageWritesWorldMetadataSidecarAndWorkflowRecord() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlacesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let (store, placeID) = try makeStore(projectURL: projectURL)
        let animateDir = projectURL.appendingPathComponent("Animate", isDirectory: true)

        let routeID = UUID(uuidString: "77777777-8888-9999-aaaa-bbbbbbbbbbbb")!
        let worldNodeID = UUID(uuidString: "77777777-8888-9999-aaaa-bbbbbbbbbbbc")!
        let pose = WorldCameraPose(
            yawDegrees: 42,
            pitchDegrees: -1,
            rollDegrees: 0,
            focalLengthMM: 32,
            horizontalFOVDegrees: 58,
            verticalFOVDegrees: 34
        )
        let mapPoint = WorldMapPoint(x: 0.41, y: 0.22)

        store.placesWorkflowLibrary.worldGraph = PlaceWorldGraph(
            routes: [
                PlaceWorldRoute(
                    id: routeID,
                    name: "Harbor Walk",
                    placeID: placeID,
                    notes: "Traversal route."
                )
            ],
            nodes: [
                PlaceWorldNode(
                    id: worldNodeID,
                    routeID: routeID,
                    placeID: placeID,
                    title: "Node 07",
                    sequenceIndex: 7,
                    role: .traverse,
                    mapPoint: mapPoint,
                    cameraPose: pose
                )
            ]
        )

        let storedPath = try store.storeGeneratedPlaceImage(
            Data("generated-image".utf8),
            prompt: "Forward along the harbor road with the bridge visible on frame right.",
            model: .flash,
            filenameStem: "street-view",
            for: placeID,
            workflow: .photorealistic,
            aspectRatio: "16:9",
            imageSize: "2K",
            routeID: routeID,
            worldNodeID: worldNodeID,
            mapPoint: mapPoint,
            cameraPose: pose
        )

        XCTAssertTrue(storedPath.hasPrefix("Animate/backgrounds/places/bridge-landing/photoreal/street-view-"))
        XCTAssertTrue(store.backgrounds[0].imagePaths.contains(storedPath))

        let metadata = try XCTUnwrap(store.generationMetadata(for: storedPath))
        XCTAssertEqual(metadata.prompt, "Forward along the harbor road with the bridge visible on frame right.")
        XCTAssertEqual(metadata.model, GeminiModel.flash.rawValue)
        XCTAssertEqual(metadata.aspectRatio, "16:9")
        XCTAssertEqual(metadata.imageSize, "2K")
        XCTAssertEqual(metadata.placeID, placeID)
        XCTAssertEqual(metadata.routeID, routeID)
        XCTAssertEqual(metadata.worldNodeID, worldNodeID)
        XCTAssertEqual(metadata.mapPoint, mapPoint)
        XCTAssertEqual(metadata.cameraPose, pose)

        let sidecarURL = projectURL
            .appendingPathComponent(storedPath)
            .deletingPathExtension()
            .appendingPathExtension("json")
        let sidecarData = try Data(contentsOf: sidecarURL)
        let sidecarJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecarData) as? [String: Any])
        let request = try XCTUnwrap(sidecarJSON["request"] as? [String: Any])
        XCTAssertEqual(request["place_id"] as? String, placeID.uuidString)
        XCTAssertEqual(request["route_id"] as? String, routeID.uuidString)
        XCTAssertEqual(request["world_node_id"] as? String, worldNodeID.uuidString)
        XCTAssertEqual(request["image_size"] as? String, "2K")
        XCTAssertEqual(request["aspect_ratio"] as? String, "16:9")
        let sidecarMapPoint = try XCTUnwrap(request["map_point"] as? [String: Any])
        XCTAssertEqual(sidecarMapPoint["x"] as? Double, mapPoint.x)
        XCTAssertEqual(sidecarMapPoint["y"] as? Double, mapPoint.y)
        let sidecarPose = try XCTUnwrap(request["camera_pose"] as? [String: Any])
        XCTAssertEqual(sidecarPose["yaw_degrees"] as? Double, pose.yawDegrees)
        XCTAssertEqual(sidecarPose["pitch_degrees"] as? Double, pose.pitchDegrees)
        XCTAssertEqual(sidecarPose["roll_degrees"] as? Double, pose.rollDegrees)
        XCTAssertEqual(sidecarPose["focal_length_mm"] as? Double, pose.focalLengthMM)
        XCTAssertEqual(sidecarPose["horizontal_fov_degrees"] as? Double, pose.horizontalFOVDegrees)
        XCTAssertEqual(sidecarPose["vertical_fov_degrees"] as? Double, pose.verticalFOVDegrees)

        let record = try XCTUnwrap(store.generatedBackgroundRecord(for: storedPath))
        XCTAssertEqual(record.linkedPlaceID, placeID)
        XCTAssertEqual(record.routeID, routeID)
        XCTAssertEqual(record.worldNodeID, worldNodeID)
        XCTAssertEqual(record.mapPoint, mapPoint)
        XCTAssertEqual(record.cameraPose, pose)
        XCTAssertEqual(record.canonStatus, .candidate)

        let workflowData = try Data(contentsOf: animateDir.appendingPathComponent("places-workflow.json"))
        let persistedWorkflow = try JSONDecoder().decode(PlacesWorkflowLibrary.self, from: workflowData)
        let persistedRecord = try XCTUnwrap(persistedWorkflow.generatedImageRecords.first(where: { $0.activePath == storedPath }))
        XCTAssertEqual(persistedRecord.linkedPlaceID, placeID)
        XCTAssertEqual(persistedRecord.routeID, routeID)
        XCTAssertEqual(persistedRecord.worldNodeID, worldNodeID)
        XCTAssertEqual(persistedRecord.mapPoint, mapPoint)
        XCTAssertEqual(persistedRecord.cameraPose, pose)
        XCTAssertEqual(persistedRecord.canonStatus, .candidate)
    }
}
