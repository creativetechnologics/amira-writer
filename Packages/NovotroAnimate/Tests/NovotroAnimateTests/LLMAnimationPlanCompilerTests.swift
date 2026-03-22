import Foundation
import XCTest
@testable import NovotroAnimate

@available(macOS 26.0, *)
@MainActor
final class LLMAnimationPlanCompilerTests: XCTestCase {
    func testCompilerInfersMotionDurationFromPace() throws {
        let compiler = LLMAnimationPlanCompiler()
        let plan = LLMAnimationPlan(
            sceneName: "Luke Walk",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.1, y: 0.56),
                    viewAngle: .front
                )
            ],
            motions: [
                LLMCharacterMotion(
                    characterName: "Luke",
                    startFrame: 0,
                    to: .init(x: 0.5, y: 0.56),
                    easing: .linear,
                    paceUnitsPerSecond: 0.2,
                    pose: .walking,
                    movementStyle: "walk"
                )
            ]
        )

        let compiled = compiler.compile(plan, fps: 24)
        let track = try XCTUnwrap(compiled.tracks["Luke:transform"])
        let frames = track.map(\.frame).sorted()

        XCTAssertEqual(frames, [0, 0, 48])
        XCTAssertEqual(compiled.totalFrames, 48)
        XCTAssertEqual(compiled.tracks["Luke:view"]?.first?.frame, 0)
        XCTAssertEqual(compiled.tracks["Luke:pose"]?.last?.frame, 0)
    }

    func testStoreRejectsUnknownCharactersInAnimationPlan() {
        let store = makeStore()
        let plan = LLMAnimationPlan(
            sceneName: "Unknown Cast",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Ghost",
                    frame: 0,
                    position: .init(x: 0.5, y: 0.56)
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .unknownCharacter }))
        XCTAssertTrue(store.sceneTracks.isEmpty)
    }

    func testStoreRejectsAnimationPlanWithoutSceneContext() {
        let store = makeStore(scenes: [], selectedSceneID: nil)
        let plan = LLMAnimationPlan(sceneName: "No Scene")

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .noSceneAvailable }))
    }

    func testStoreAppliesAnimationPlanAndEvaluatesRuntimeState() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            name: "Act 1",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/act1.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let plan = LLMAnimationPlan(
            sceneName: "Luke Enters",
            backgroundName: "Valley",
            lighting: "day",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.2, y: 0.56),
                    viewAngle: .front,
                    emotion: "neutral"
                )
            ],
            motions: [
                LLMCharacterMotion(
                    characterName: "Luke",
                    startFrame: 12,
                    endFrame: 36,
                    to: .init(x: 0.8, y: 0.56),
                    easing: .easeInOut,
                    viewAngle: .side,
                    pose: .walking,
                    movementStyle: "walk"
                )
            ],
            expressions: [
                LLMCharacterExpressionCue(
                    characterName: "Luke",
                    frame: 24,
                    expression: "determined"
                )
            ],
            cameraMoves: [
                LLMCameraMove(
                    movement: .panRight,
                    startFrame: 0,
                    endFrame: 24,
                    fromShot: .medium,
                    toShot: .close,
                    easing: .easeInOut
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(store.statusMessage, "Applied LLM animation plan: Luke Enters")
        XCTAssertEqual(store.selectedScene?.backgroundID, nil)
        XCTAssertEqual(store.selectedScene?.characterIDs, [luke.id])
        XCTAssertNotNil(store.selectedScene?.tracks["Luke:transform"])
        XCTAssertNotNil(store.selectedScene?.tracks["Luke:expression"])
        XCTAssertNotNil(store.selectedScene?.tracks["Luke:facing"])
        XCTAssertNotNil(store.selectedScene?.tracks["camera:shot"])
        XCTAssertNotNil(store.selectedScene?.tracks["camera"])
        XCTAssertEqual(store.selectedScene?.tracks["Luke:transform"]?.targetCharacterID, luke.id)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:transform"]?.role, .transform)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:view"]?.role, .view)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:facing"]?.role, .facing)
        XCTAssertEqual(store.selectedScene?.tracks["camera:shot"]?.role, .cameraShot)

        store.currentFrame = 24
        let transform = try XCTUnwrap(store.evaluatedTransform(for: luke.id))
        XCTAssertGreaterThan(transform.x, 0.2)
        XCTAssertLessThan(transform.x, 0.8)
        XCTAssertEqual(store.evaluatedExpression(for: luke.id), "determined")
        XCTAssertEqual(store.evaluatedAction(for: luke.id), "walk")
        XCTAssertEqual(store.evaluatedPose(for: luke.id), .walking)
        XCTAssertEqual(store.evaluatedViewAngle(for: luke.id), .side)
        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .right)
        XCTAssertEqual(store.evaluatedCameraShot(at: 0), .medium)
        XCTAssertEqual(store.evaluatedCameraShot(), .close)

        let camera = try XCTUnwrap(store.evaluatedCameraTransform())
        XCTAssertGreaterThan(camera.x, 0)
        XCTAssertGreaterThan(camera.scaleX, 1.0)
    }

    func testCompilerBuildsDialogueAndShadowTracks() throws {
        let compiler = LLMAnimationPlanCompiler()
        let plan = LLMAnimationPlan(
            sceneName: "Dialogue Beat",
            dialogueBeats: [
                LLMDialogueBeat(
                    characterName: "Luke",
                    startFrame: 18,
                    audioPath: "Assets/dialogue/luke-line.wav",
                    transcript: "We should move now.",
                    expression: "focused",
                    action: "speak"
                )
            ],
            shadowCues: [
                LLMCharacterShadowCue(
                    characterName: "Luke",
                    frame: 18,
                    style: .softGround,
                    opacity: 0.45
                )
            ]
        )

        let compiled = compiler.compile(plan, fps: 24)

        XCTAssertEqual(compiled.tracks["Luke:action"]?.last?.frame, 18)
        XCTAssertEqual(compiled.tracks["Luke:expression"]?.last?.frame, 18)
        XCTAssertEqual(compiled.tracks["Luke:shadow-style"]?.last?.frame, 18)

        if case .expression(let shadowName)? = compiled.tracks["Luke:shadow-style"]?.last?.value {
            XCTAssertEqual(shadowName, ShadowStyle.softGround.rawValue)
        } else {
            XCTFail("Expected a shadow-style expression keyframe.")
        }

        if case .expression(let opacity)? = compiled.tracks["Luke:shadow-opacity"]?.last?.value {
            XCTAssertEqual(opacity, "0.45")
        } else {
            XCTFail("Expected a shadow-opacity expression keyframe.")
        }
    }

    func testStoreAppliesShadowCueAndEvaluatesShadowState() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            name: "Act 1",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/act1.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        let plan = LLMAnimationPlan(
            sceneName: "Shadow Test",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.5, y: 0.56)
                )
            ],
            shadowCues: [
                LLMCharacterShadowCue(
                    characterName: "Luke",
                    frame: 0,
                    style: .softGround,
                    opacity: 0.35
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(store.evaluatedShadowStyle(for: luke.id, at: 0), .softGround)
        XCTAssertEqual(try XCTUnwrap(store.evaluatedShadowOpacity(for: luke.id, at: 0)), 0.35, accuracy: 0.0001)
    }

    func testStoreAppliesAnimationPlanIncludingGeneratedDialogueAssets() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let assetsURL = rootURL.appendingPathComponent("Assets/dialogue", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let lineURL = assetsURL.appendingPathComponent("luke-line.wav")
        let mixURL = rootURL.appendingPathComponent("Assets/scene-mix.wav")
        FileManager.default.createFile(atPath: lineURL.path, contents: Data())
        FileManager.default.createFile(atPath: mixURL.path, contents: Data())

        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            name: "Act 1",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/act1.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.owpURL = rootURL.appendingPathComponent("Project.owp")

        let plan = LLMAnimationPlan(
            sceneName: "Dialogue Automation",
            sceneAudioPath: "Assets/scene-mix.wav",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.45, y: 0.56)
                )
            ],
            dialogueBeats: [
                LLMDialogueBeat(
                    characterName: "Luke",
                    startFrame: 12,
                    audioPath: "Assets/dialogue/luke-line.wav",
                    transcript: "We should move now."
                )
            ]
        )

        let expectedFPS = store.fps
        let report = await store.applyLLMAnimationPlanIncludingGeneratedDialogue(plan) { url, fps, transcript in
            XCTAssertEqual(url.path, lineURL.path)
            XCTAssertEqual(fps, expectedFPS)
            XCTAssertEqual(transcript, "We should move now.")
            return [
                LipSyncEngine.VisemeKeyframe(frame: 0, viseme: .mbp, duration: 2)
            ]
        }

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(store.selectedScene?.defaultAudioPath, "Assets/scene-mix.wav")
        XCTAssertEqual(store.evaluatedMouthCue(for: luke.id, at: 12), "viseme:mbp")
        XCTAssertEqual(store.evaluatedAction(for: luke.id, at: 12), "speak")
        XCTAssertEqual(store.statusMessage, "Applied LLM animation plan with generated dialogue: Dialogue Automation")
        XCTAssertEqual(store.suggestedExportAudioURL()?.path, mixURL.path)
    }

    func testStoreAppliesAnimationPlanJSONIncludingGeneratedDialogueAssets() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let assetsURL = rootURL.appendingPathComponent("Assets/dialogue", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let lineURL = assetsURL.appendingPathComponent("luke-line.wav")
        FileManager.default.createFile(atPath: lineURL.path, contents: Data())

        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            name: "Act 1",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/act1.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.owpURL = rootURL.appendingPathComponent("Project.owp")

        let json = """
        {
          "schemaVersion": 6,
          "sceneName": "JSON Dialogue",
          "characterPlacements": [
            {
              "characterName": "Luke",
              "frame": 0,
              "position": { "x": 0.45, "y": 0.56 }
            }
          ],
          "dialogueBeats": [
            {
              "characterName": "Luke",
              "startFrame": 8,
              "audioPath": "Assets/dialogue/luke-line.wav",
              "transcript": "Hold here."
            }
          ]
        }
        """

        let report = await store.applyLLMAnimationPlanJSONIncludingGeneratedDialogue(json) { url, _, transcript in
            XCTAssertEqual(url.path, lineURL.path)
            XCTAssertEqual(transcript, "Hold here.")
            return [LipSyncEngine.VisemeKeyframe(frame: 0, viseme: .ai, duration: 2)]
        }

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(store.evaluatedMouthCue(for: luke.id, at: 8), "viseme:ai")
        XCTAssertEqual(store.statusMessage, "Applied LLM animation plan with generated dialogue: JSON Dialogue")
    }

    func testAssetRequestPlannerFlagsMissingDialogueAndPoseCoverage() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: [
                RigPart(
                    name: "Head",
                    partType: .head,
                    zOrder: 10,
                    drawingSets: [
                        .front: DrawingSet(
                            angle: .front,
                            variants: [
                                DrawingVariant(
                                    name: "Luke Neutral Front",
                                    filename: "head-front.png",
                                    sourceTags: ["neutral", "front"]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let store = makeStore(characters: [luke])
        let plan = LLMAnimationPlan(
            sceneName: "Needs Assets",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.4, y: 0.56),
                    viewAngle: .side,
                    pose: .seated,
                    emotion: "determined"
                )
            ],
            dialogueBeats: [
                LLMDialogueBeat(
                    characterName: "Luke",
                    startFrame: 12,
                    audioPath: "Assets/dialogue/luke-line.wav"
                )
            ]
        )

        let requests = store.missingAssetRequests(for: plan)

        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.contains(where: { $0.kind == .visemeSheet }))
        XCTAssertTrue(requests.contains(where: { $0.kind == .expressionVariant && $0.target == "determined" }))
        XCTAssertTrue(requests.contains(where: { $0.kind == .poseVariant && $0.target == CharacterPackagePose.seated.rawValue }))
        XCTAssertTrue(requests.contains(where: { $0.kind == .angleCoverage && $0.target == AngleView.side.rawValue }))
    }

    func testAssetRequestPlannerSkipsSatisfiedCoverageAndShadowOnlyPlans() {
        let mouthVariant = DrawingVariant(
            name: "MBP Mouth",
            filename: "mouth-mbp.png",
            sourceAssetRole: .viseme,
            sourcePartType: .mouth,
            sourceTags: ["viseme", "mbp"]
        )
        let expressionVariant = DrawingVariant(
            name: "Determined Face",
            filename: "face-determined.png",
            sourceAssetRole: .expression,
            sourceTags: ["determined"]
        )
        let seatedVariant = DrawingVariant(
            name: "Luke Seated Side",
            filename: "luke-seated-side.png",
            sourceAngle: .side,
            sourcePose: .seated,
            sourceTags: ["seated", "side"]
        )
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: [
                RigPart(
                    name: "Mouth",
                    partType: .mouth,
                    zOrder: 20,
                    drawingSets: [.front: DrawingSet(angle: .front, variants: [mouthVariant])]
                ),
                RigPart(
                    name: "Face",
                    partType: .face,
                    zOrder: 21,
                    drawingSets: [
                        .front: DrawingSet(angle: .front, variants: [expressionVariant]),
                        .side: DrawingSet(angle: .side, variants: [seatedVariant])
                    ]
                )
            ]
        )
        let store = makeStore(characters: [luke])
        let plan = LLMAnimationPlan(
            sceneName: "Covered",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.4, y: 0.56),
                    viewAngle: .side,
                    pose: .seated,
                    emotion: "determined"
                )
            ],
            dialogueBeats: [
                LLMDialogueBeat(
                    characterName: "Luke",
                    startFrame: 12,
                    audioPath: "Assets/dialogue/luke-line.wav"
                )
            ],
            shadowCues: [
                LLMCharacterShadowCue(
                    characterName: "Luke",
                    frame: 12,
                    style: .softGround,
                    opacity: 0.4
                )
            ]
        )

        XCTAssertTrue(store.missingAssetRequests(for: plan).isEmpty)
    }

    func testSelectedSceneSwitchesTimelineStateIncludingCameraTrack() throws {
        let transformTrack = TimelineTrack(
            name: "Luke:transform",
            keyframes: [
                TimelineKeyframe(
                    frame: 0,
                    kind: .transform,
                    value: .transform(
                        CharacterTransform(
                            x: 0.3,
                            y: 0.56,
                            rotation: 0,
                            scaleX: 1,
                            scaleY: 1,
                            opacity: 1,
                            zOrder: 1
                        )
                    )
                )
            ]
        )
        let cameraTrack = TimelineTrack(
            name: "camera",
            keyframes: [
                TimelineKeyframe(
                    frame: 0,
                    kind: .transform,
                    value: .transform(
                        CharacterTransform(
                            x: 0.1,
                            y: 0,
                            rotation: 0,
                            scaleX: 1.2,
                            scaleY: 1.2,
                            opacity: 1,
                            zOrder: 0
                        )
                    )
                )
            ]
        )

        let firstScene = AnimationScene(
            id: UUID(uuidString: "CCCCCCCC-1111-1111-1111-CCCCCCCCCCCC")!,
            name: "Scene 1",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/one.ows",
            tracks: [
                "Luke:transform": transformTrack,
                "camera": cameraTrack
            ]
        )
        let secondScene = AnimationScene(
            id: UUID(uuidString: "DDDDDDDD-1111-1111-1111-DDDDDDDDDDDD")!,
            name: "Scene 2",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/two.ows",
            tracks: [:]
        )

        let store = makeStore(scenes: [firstScene, secondScene], selectedSceneID: firstScene.id)
        XCTAssertNotNil(store.evaluatedTransform(for: "Luke"))
        XCTAssertNotNil(store.evaluatedCameraTransform())

        store.selectedSceneID = secondScene.id

        XCTAssertNil(store.evaluatedTransform(for: "Luke"))
        XCTAssertNil(store.evaluatedCameraTransform())
        XCTAssertTrue(store.sceneTracks.isEmpty)
    }

    func testJSONApplicationReportsDecodeFailures() {
        let store = makeStore()
        let report = store.applyLLMAnimationPlanJSON("{ not valid json }")

        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.issues.first?.code, .invalidJSON)
    }

    func testCompilerRejectsEmptyShotPresetName() {
        let compiler = LLMAnimationPlanCompiler()
        let plan = LLMAnimationPlan(
            sceneName: "Preset Validation",
            shotPresetApplications: [
                LLMShotPresetApplication(presetName: "   ", frame: 12)
            ]
        )

        let report = compiler.validate(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .emptyShotPresetName }))
    }

    func testStoreAppliesNamedShotPresetReferencesFromAnimationPlan() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "67676767-1111-1111-1111-676767676767")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "68686868-1111-1111-1111-686868686868")!,
            name: "Preset LLM Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/preset-llm.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "69696969-1111-1111-1111-696969696969")!,
                name: "Luke Walk In",
                notes: "Favor Luke on the entrance.",
                shotIntent: .reveal,
                cameraShot: .mediumClose,
                defaultCameraShot: .wide,
                focusCharacterSlug: "luke",
                characterCues: [
                    SceneShotPresetCharacterCue(
                        characterSlug: "luke",
                        facing: .right,
                        viewAngle: .side,
                        pose: .walking,
                        expression: "determined",
                        action: "walk"
                    )
                ]
            )
        ]

        let plan = LLMAnimationPlan(
            sceneName: "Preset Driven Entrance",
            shotPresetApplications: [
                LLMShotPresetApplication(presetName: "Luke Walk In", frame: 12)
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        store.currentFrame = 12
        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .right)
        XCTAssertEqual(store.evaluatedViewAngle(for: luke.id), .side)
        XCTAssertEqual(store.evaluatedPose(for: luke.id), .walking)
        XCTAssertEqual(store.evaluatedExpression(for: luke.id), "determined")
        XCTAssertEqual(store.evaluatedAction(for: luke.id), "walk")
        XCTAssertEqual(store.evaluatedCameraShot(), .mediumClose)
        XCTAssertEqual(store.evaluatedCameraDefaultShot(at: 12), .wide)
        XCTAssertEqual(store.evaluatedCameraFocusCharacterID(at: 12), luke.id)
        XCTAssertEqual(store.evaluatedCameraShotIntent(at: 12), .reveal)
        XCTAssertEqual(store.evaluatedCameraBeatLabel(at: 12), "Luke Walk In")
        XCTAssertEqual(store.evaluatedCameraBeatNotes(at: 12), "Favor Luke on the entrance.")
        XCTAssertNil(store.selectedScene?.directionTemplate)
    }

    func testStoreAppliesShotPresetOverridesFromAnimationPlan() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "6A6A6A6A-1111-1111-1111-6A6A6A6A6A6A")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "6B6B6B6B-1111-1111-1111-6B6B6B6B6B6B")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "6C6C6C6C-1111-1111-1111-6C6C6C6C6C6C")!,
            name: "Preset Override Application Scene",
            backgroundID: nil,
            characterIDs: [luke.id, amira.id],
            keyframes: [],
            owpSongPath: "Songs/preset-override-application.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "6D6D6D6D-1111-1111-1111-6D6D6D6D6D6D")!,
                name: "Luke Walk In",
                notes: "Favor Luke on the entrance.",
                shotIntent: .movement,
                cameraShot: .mediumClose,
                defaultCameraShot: .wide,
                focusCharacterSlug: "luke",
                characterCues: [
                    SceneShotPresetCharacterCue(
                        characterSlug: "luke",
                        facing: .right,
                        viewAngle: .side,
                        pose: .walking,
                        expression: "determined",
                        action: "walk"
                    )
                ]
            )
        ]

        let plan = LLMAnimationPlan(
            sceneName: "Preset With Overrides",
            shotPresetApplications: [
                LLMShotPresetApplication(
                    presetName: "Luke Walk In",
                    frame: 24,
                    cameraShot: .close,
                    focusCharacterName: "Amira",
                    shotIntent: .reaction,
                    beatLabel: "Luke And Amira Turn",
                    beatNotes: "Shift emotional weight toward Amira while Luke stays visible.",
                    characterOverrides: [
                        LLMShotPresetCharacterOverride(
                            characterName: "Luke",
                            viewAngle: .front,
                            expression: "calm"
                        ),
                        LLMShotPresetCharacterOverride(
                            characterName: "Amira",
                            facing: .camera,
                            expression: "watchful"
                        )
                    ]
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        store.currentFrame = 24
        XCTAssertEqual(store.evaluatedCameraShot(), .close)
        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .right)
        XCTAssertEqual(store.evaluatedViewAngle(for: luke.id), .front)
        XCTAssertEqual(store.evaluatedPose(for: luke.id), .walking)
        XCTAssertEqual(store.evaluatedExpression(for: luke.id), "calm")
        XCTAssertEqual(store.evaluatedAction(for: luke.id), "walk")
        XCTAssertEqual(store.evaluatedFacingDirection(for: amira.id), .camera)
        XCTAssertEqual(store.evaluatedExpression(for: amira.id), "watchful")
        XCTAssertEqual(store.evaluatedCameraDefaultShot(at: 24), .wide)
        XCTAssertEqual(store.evaluatedCameraFocusCharacterID(at: 24), amira.id)
        XCTAssertEqual(store.evaluatedCameraShotIntent(at: 24), .reaction)
        XCTAssertEqual(store.evaluatedCameraBeatLabel(at: 24), "Luke And Amira Turn")
        XCTAssertEqual(store.evaluatedCameraBeatNotes(at: 24), "Shift emotional weight toward Amira while Luke stays visible.")
        XCTAssertNil(store.selectedScene?.directionTemplate)
    }

    func testExplicitPlanCuesOverridePresetReferencesAtSameFrame() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "70707070-1111-1111-1111-707070707070")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "71717171-1111-1111-1111-717171717171")!,
            name: "Preset Override Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/preset-override.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "72727272-1111-1111-1111-727272727272")!,
                name: "Luke Entrance Block",
                notes: "",
                cameraShot: .wide,
                defaultCameraShot: .wide,
                focusCharacterSlug: "luke",
                characterCues: [
                    SceneShotPresetCharacterCue(
                        characterSlug: "luke",
                        facing: .left,
                        viewAngle: .side,
                        pose: .walking,
                        expression: "determined",
                        action: "walk"
                    )
                ]
            )
        ]

        let plan = LLMAnimationPlan(
            sceneName: "Explicit Wins",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.5, y: 0.56),
                    facing: .camera,
                    viewAngle: .front,
                    pose: .neutral,
                    emotion: "calm"
                )
            ],
            cameraMoves: [
                LLMCameraMove(
                    movement: .hold,
                    startFrame: 0,
                    endFrame: 0,
                    fromShot: .close,
                    toShot: .close,
                    easing: .linear
                )
            ],
            shotPresetApplications: [
                LLMShotPresetApplication(
                    presetName: "Luke Entrance Block",
                    frame: 0,
                    cameraShot: .wide,
                    characterOverrides: [
                        LLMShotPresetCharacterOverride(
                            characterName: "Luke",
                            viewAngle: .back,
                            pose: .pointing,
                            expression: "angry",
                            action: "charge"
                        )
                    ]
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .camera)
        XCTAssertEqual(store.evaluatedViewAngle(for: luke.id), .front)
        XCTAssertEqual(store.evaluatedPose(for: luke.id), .neutral)
        XCTAssertEqual(store.evaluatedExpression(for: luke.id), "calm")
        XCTAssertEqual(store.evaluatedAction(for: luke.id), "charge")
        XCTAssertEqual(store.evaluatedCameraShot(), .close)
    }

    func testStoreRejectsUnknownShotPresetReferencesInAnimationPlan() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "73737373-1111-1111-1111-737373737373")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "74747474-1111-1111-1111-747474747474")!,
            name: "Unknown Preset Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/unknown-preset.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        let plan = LLMAnimationPlan(
            sceneName: "Missing Preset",
            shotPresetApplications: [
                LLMShotPresetApplication(presetName: "Does Not Exist", frame: 0)
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .unknownShotPreset }))
        XCTAssertTrue(store.sceneTracks.isEmpty)
    }

    func testStoreRejectsAmbiguousShotPresetReferencesInAnimationPlan() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "75757575-1111-1111-1111-757575757575")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "76767676-1111-1111-1111-767676767676")!,
            name: "Ambiguous Preset Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/ambiguous-preset.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "77777777-1111-1111-1111-777777777777")!,
                name: "Luke Beat",
                characterCues: []
            ),
            SceneShotPreset(
                id: UUID(uuidString: "78797979-1111-1111-1111-787979797979")!,
                name: " luke beat ",
                characterCues: []
            )
        ]
        let plan = LLMAnimationPlan(
            sceneName: "Ambiguous Preset",
            shotPresetApplications: [
                LLMShotPresetApplication(presetName: "Luke Beat", frame: 0)
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .ambiguousShotPreset }))
        XCTAssertTrue(store.sceneTracks.isEmpty)
    }

    func testStoreRejectsUnknownCharactersReferencedByShotPresetOverrides() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "79797979-1111-1111-1111-797979797979")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "7A7A7A7A-1111-1111-1111-7A7A7A7A7A7A")!,
            name: "Unknown Override Character Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/unknown-override-character.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "7B7B7B7B-1111-1111-1111-7B7B7B7B7B7B")!,
                name: "Luke Beat",
                characterCues: []
            )
        ]
        let plan = LLMAnimationPlan(
            sceneName: "Unknown Override Character",
            shotPresetApplications: [
                LLMShotPresetApplication(
                    presetName: "Luke Beat",
                    frame: 12,
                    focusCharacterName: "Ghost",
                    characterOverrides: [
                        LLMShotPresetCharacterOverride(characterName: "Ghost", expression: "angry")
                    ]
                )
            ]
        )

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .unknownCharacter }))
        XCTAssertTrue(store.sceneTracks.isEmpty)
    }

    func testApplyShotPresetWritesTimelineFramingCuesWithoutMutatingSceneTemplate() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "7C7C7C7C-1111-1111-1111-7C7C7C7C7C7C")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "7D7D7D7D-1111-1111-1111-7D7D7D7D7D7D")!,
            name: "Manual Preset Apply Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/manual-preset-apply.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.currentFrame = 18

        let preset = SceneShotPreset(
            id: UUID(uuidString: "7E7E7E7E-1111-1111-1111-7E7E7E7E7E7E")!,
            name: "Luke Focus Beat",
            notes: "Center the entrance beat.",
            shotIntent: .emotional,
            cameraShot: .medium,
            defaultCameraShot: .close,
            focusCharacterSlug: "luke",
            characterCues: []
        )

        store.applyShotPreset(preset)

        XCTAssertEqual(store.evaluatedCameraShot(at: 18), .medium)
        XCTAssertEqual(store.evaluatedCameraDefaultShot(at: 18), .close)
        XCTAssertEqual(store.evaluatedCameraFocusCharacterID(at: 18), luke.id)
        XCTAssertEqual(store.evaluatedCameraShotIntent(at: 18), .emotional)
        XCTAssertEqual(store.evaluatedCameraBeatLabel(at: 18), "Luke Focus Beat")
        XCTAssertEqual(store.evaluatedCameraBeatNotes(at: 18), "Center the entrance beat.")
        XCTAssertEqual(store.selectedScene?.tracks["camera:default-shot"]?.role, .cameraDefaultShot)
        XCTAssertEqual(store.selectedScene?.tracks["camera:focus"]?.role, .cameraFocus)
        XCTAssertEqual(store.selectedScene?.tracks["camera:intent"]?.role, .cameraIntent)
        XCTAssertEqual(store.selectedScene?.tracks["camera:beat"]?.role, .cameraBeat)
        XCTAssertEqual(store.selectedScene?.tracks["camera:notes"]?.role, .cameraNotes)
        XCTAssertNil(store.selectedScene?.directionTemplate)
    }

    func testCaptureShotPresetUsesLiveTimelineFramingCues() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "80808080-1111-1111-1111-808080808080")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "81818181-1111-1111-1111-818181818181")!,
            name: "Capture Live Framing Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/capture-live-framing.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        store.setCameraDefaultShotCue(.mediumClose, at: 12)
        store.setCameraFocusCue(luke.id, at: 12)
        store.setCameraShotIntentCue(.reveal, at: 12)
        store.setCameraBeatLabelCue("Luke Reveal", at: 12)
        store.setCameraBeatNotesCue("Let the reveal breathe for a moment.", at: 12)
        store.currentFrame = 12
        store.captureShotPreset(named: "Live Framing Capture", notes: "Uses current framing cues.")

        let preset = try XCTUnwrap(store.shotPresets.first)
        XCTAssertEqual(preset.defaultCameraShot, .mediumClose)
        XCTAssertEqual(preset.focusCharacterSlug, "luke")
        XCTAssertEqual(preset.shotIntent, .reveal)
        XCTAssertEqual(store.evaluatedCameraBeatLabel(at: 12), "Luke Reveal")
        XCTAssertEqual(store.evaluatedCameraBeatNotes(at: 12), "Let the reveal breathe for a moment.")
    }

    func testPresetApplicationFramingCuesStayTimeLocal() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "82828282-1111-1111-1111-828282828282")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let transformTrack = TimelineTrack(
            name: "Luke:transform",
            keyframes: [
                TimelineKeyframe(
                    frame: 0,
                    kind: .transform,
                    value: .transform(
                        CharacterTransform(
                            x: 0.78,
                            y: 0.56,
                            rotation: 0,
                            scaleX: 1,
                            scaleY: 1,
                            opacity: 1,
                            zOrder: 1
                        )
                    )
                )
            ],
            targetCharacterID: luke.id,
            role: .transform
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "83838383-1111-1111-1111-838383838383")!,
            name: "Time Local Preset Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/time-local-preset.ows",
            tracks: ["Luke:transform": transformTrack]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "84848484-1111-1111-1111-848484848484")!,
                name: "Luke Close Focus",
                defaultCameraShot: .close,
                focusCharacterSlug: "luke",
                characterCues: []
            )
        ]
        let plan = LLMAnimationPlan(
            sceneName: "Time Local Beat",
            characterPlacements: [
                LLMCharacterPlacement(
                    characterName: "Luke",
                    frame: 0,
                    position: .init(x: 0.78, y: 0.56)
                )
            ],
            shotPresetApplications: [
                LLMShotPresetApplication(presetName: "Luke Close Focus", frame: 24)
            ]
        )
        let composer = SceneFrameRenderComposer()

        let report = store.applyLLMAnimationPlan(plan)

        XCTAssertTrue(report.isValid)
        let baseCameraState = composer.resolvedCameraState(
            store: store,
            scene: try! XCTUnwrap(store.selectedScene),
            frame: 0,
            viewportSize: CGSize(width: 1920, height: 1080)
        )
        let framedCameraState = composer.resolvedCameraState(
            store: store,
            scene: try! XCTUnwrap(store.selectedScene),
            frame: 24,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(baseCameraState.zoom, 1.0, accuracy: 0.0001)
        XCTAssertEqual(baseCameraState.offset.x, 0, accuracy: 0.0001)
        XCTAssertEqual(baseCameraState.offset.y, 0, accuracy: 0.0001)
        XCTAssertEqual(framedCameraState.zoom, Float(CameraShot.close.zoomLevel), accuracy: 0.0001)
        XCTAssertGreaterThan(framedCameraState.offset.x, 0)
        XCTAssertNil(store.evaluatedCameraBeatLabel(at: 0))
        XCTAssertEqual(store.evaluatedCameraBeatLabel(at: 24), "Luke Close Focus")
        XCTAssertNil(store.selectedScene?.directionTemplate)
    }

    func testStoreSemanticCueAuthoringUpdatesSceneTracks() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "FFFFFFFF-1111-1111-1111-FFFFFFFFFFFF")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "ABABABAB-1111-1111-1111-ABABABABABAB")!,
            name: "Cue Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/cue.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.currentFrame = 18

        store.setViewAngleCue(.side, for: "Luke")
        store.setPoseCue(.walking, for: "Luke")
        store.setExpressionCue("determined", for: "Luke")
        store.setActionCue("walk", for: "Luke")

        XCTAssertEqual(store.evaluatedViewAngle(for: "Luke"), .side)
        XCTAssertEqual(store.evaluatedPose(for: "Luke"), .walking)
        XCTAssertEqual(store.evaluatedExpression(for: "Luke"), "determined")
        XCTAssertEqual(store.evaluatedAction(for: "Luke"), "walk")
        XCTAssertEqual(store.selectedScene?.tracks["Luke:view"]?.keyframes.first?.frame, 18)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:pose"]?.keyframes.first?.frame, 18)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:expression"]?.keyframes.first?.frame, 18)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:action"]?.keyframes.first?.frame, 18)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:view"]?.targetCharacterID, luke.id)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:view"]?.role, .view)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:action"]?.role, .action)
    }

    func testManualFacingAndCameraShotCuesPersistMetadata() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "12121212-1111-1111-1111-121212121212")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "34343434-1111-1111-1111-343434343434")!,
            name: "Manual Cue Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/manual.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.currentFrame = 12

        store.setFacingCue(.left, for: luke.id)
        store.setCameraShotCue(.close)

        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .left)
        XCTAssertEqual(store.evaluatedCameraShot(), .close)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:facing"]?.targetCharacterID, luke.id)
        XCTAssertEqual(store.selectedScene?.tracks["Luke:facing"]?.role, .facing)
        XCTAssertEqual(store.selectedScene?.tracks["camera:shot"]?.role, .cameraShot)
    }

    func testManualBeatMetadataCuesPersistMetadata() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "14141414-1111-1111-1111-141414141414")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "45454545-1111-1111-1111-454545454545")!,
            name: "Manual Beat Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/manual-beat.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        store.currentFrame = 12

        store.setCameraShotIntentCue(.reveal)
        store.setCameraBeatLabelCue("Luke Reveal")
        store.setCameraBeatNotesCue("Hold the close-up for the emotional turn.")

        XCTAssertEqual(store.evaluatedCameraShotIntent(), .reveal)
        XCTAssertEqual(store.evaluatedCameraBeatLabel(), "Luke Reveal")
        XCTAssertEqual(store.evaluatedCameraBeatNotes(), "Hold the close-up for the emotional turn.")
        XCTAssertEqual(store.selectedScene?.tracks["camera:intent"]?.role, .cameraIntent)
        XCTAssertEqual(store.selectedScene?.tracks["camera:beat"]?.role, .cameraBeat)
        XCTAssertEqual(store.selectedScene?.tracks["camera:notes"]?.role, .cameraNotes)
    }

    func testSceneDirectionTemplateStoresFocusCharacterSlug() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "9A9A9A9A-1111-1111-1111-9A9A9A9A9A9A")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "9B9B9B9B-1111-1111-1111-9B9B9B9B9B9B")!,
            name: "Template Save Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/template-save.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        store.updateSelectedSceneDirectionTemplate(
            defaultCameraShot: .mediumClose,
            focusCharacterID: luke.id,
            notes: "Favor Luke."
        )

        XCTAssertEqual(store.selectedScene?.directionTemplate?.focusCharacterID, luke.id)
        XCTAssertEqual(store.selectedScene?.directionTemplate?.focusCharacterSlug, "luke")
        XCTAssertEqual(store.selectedScene?.directionTemplate?.defaultCameraShot, .mediumClose)
    }

    func testShotPresetCaptureAndApplyUsesCharacterSlugs() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAA0000-1111-1111-1111-AAAAAAAAAAAA")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "BBBB0000-1111-1111-1111-BBBBBBBBBBBB")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "CCCC0000-1111-1111-1111-CCCCCCCCCCCC")!,
            name: "Preset Scene",
            backgroundID: nil,
            characterIDs: [luke.id, amira.id],
            keyframes: [],
            owpSongPath: "Songs/preset.ows",
            tracks: [:],
            directionTemplate: SceneDirectionTemplate(
                defaultCameraShot: .wide,
                focusCharacterID: luke.id,
                focusCharacterSlug: "luke",
                notes: "Favor Luke in wide framing."
            )
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        store.currentFrame = 18

        store.setFacingCue(.right, for: luke.id)
        store.setViewAngleCue(.side, for: luke.id)
        store.setPoseCue(.walking, for: luke.id)
        store.setActionCue("walk", for: luke.id)
        store.setExpressionCue("determined", for: luke.id)
        store.setCameraShotCue(.mediumClose)

        store.captureShotPreset(named: "Luke Walk In", notes: "Entrance beat")
        let preset = try XCTUnwrap(store.shotPresets.first)
        XCTAssertEqual(preset.focusCharacterSlug, "luke")
        XCTAssertEqual(preset.cameraShot, .mediumClose)
        XCTAssertTrue(preset.characterCues.contains(where: {
            $0.characterSlug == "luke" && $0.facing == .right && $0.viewAngle == .side
        }))

        store.setFacingCue(.left, for: luke.id)
        store.setViewAngleCue(.front, for: luke.id)
        store.setPoseCue(.neutral, for: luke.id)
        store.setActionCue("idle", for: luke.id)
        store.setExpressionCue("calm", for: luke.id)
        store.setCameraShotCue(.close)
        store.updateSelectedSceneDirectionTemplate(
            defaultCameraShot: .close,
            focusCharacterID: amira.id,
            notes: "Shift focus to Amira."
        )

        store.applyShotPreset(preset)

        XCTAssertEqual(store.evaluatedFacingDirection(for: luke.id), .right)
        XCTAssertEqual(store.evaluatedViewAngle(for: luke.id), .side)
        XCTAssertEqual(store.evaluatedPose(for: luke.id), .walking)
        XCTAssertEqual(store.evaluatedAction(for: luke.id), "walk")
        XCTAssertEqual(store.evaluatedExpression(for: luke.id), "determined")
        XCTAssertEqual(store.evaluatedCameraShot(), .mediumClose)
        XCTAssertEqual(store.evaluatedCameraDefaultShot(at: 18), .wide)
        XCTAssertEqual(store.evaluatedCameraFocusCharacterID(at: 18), luke.id)
        XCTAssertEqual(store.selectedScene?.directionTemplate?.defaultCameraShot, .close)
        XCTAssertEqual(store.selectedScene?.directionTemplate?.focusCharacterSlug, "amira")
    }

    func testShotPresetStoreRoundTripsManifest() throws {
        let animateURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: animateURL) }

        let manifest = SceneShotPresetManifest(
            presets: [
                SceneShotPreset(
                    id: UUID(uuidString: "DDDD0000-1111-1111-1111-DDDDDDDDDDDD")!,
                    name: "Close On Luke",
                    notes: "Use for emotional emphasis.",
                    cameraShot: .close,
                    defaultCameraShot: .mediumClose,
                    focusCharacterSlug: "luke",
                    characterCues: [
                        SceneShotPresetCharacterCue(
                            characterSlug: "luke",
                            facing: .camera,
                            viewAngle: .front,
                            pose: .frontal,
                            expression: "determined",
                            action: nil
                        )
                    ]
                )
            ]
        )

        let store = SceneShotPresetStore()
        try store.save(manifest, to: animateURL)
        let loaded = store.load(from: animateURL)

        XCTAssertEqual(loaded.presets.count, 1)
        XCTAssertEqual(loaded.presets.first?.name, "Close On Luke")
        XCTAssertEqual(loaded.presets.first?.focusCharacterSlug, "luke")
        XCTAssertEqual(loaded.presets.first?.cameraShot, .close)
    }

    func testOrderedTimelineTracksGroupsCharacterTracksBeforeCamera() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "CDCDCDCD-1111-1111-1111-CDCDCDCDCDCD")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "EFEFEFEF-1111-1111-1111-EFEFEFEFEFEF")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "BCBCBCBC-1111-1111-1111-BCBCBCBCBCBC")!,
            name: "Ordered Scene",
            backgroundID: nil,
            characterIDs: [amira.id, luke.id],
            keyframes: [],
            owpSongPath: "Songs/order.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        store.sceneTracks = [
            "Luke:action": TimelineTrack(name: "Luke:action", keyframes: []),
            "Amira:transform": TimelineTrack(name: "Amira:transform", keyframes: []),
            "Luke:transform": TimelineTrack(name: "Luke:transform", keyframes: []),
            "Amira:view": TimelineTrack(name: "Amira:view", keyframes: [])
        ]
        store.cameraTrack = TimelineTrack(name: "camera", keyframes: [])

        let ordered = store.orderedTimelineTracks().map(\.name)

        XCTAssertEqual(
            ordered,
            ["Amira:transform", "Amira:view", "Luke:transform", "Luke:action", "camera"]
        )
    }

    func testIdentityBackedTrackLookupSurvivesStaleTrackNames() throws {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "ABCDEFAB-1111-1111-1111-ABCDEFABCDEF")!,
            name: "Luke Prime",
            description: "",
            owpSlug: "luke-prime",
            parts: []
        )
        let transform = CharacterTransform(
            x: 0.42,
            y: 0.56,
            rotation: 0,
            scaleX: 1,
            scaleY: 1,
            opacity: 1,
            zOrder: 2
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "A1B2C3D4-1111-1111-1111-A1B2C3D4E5F6")!,
            name: "Rename Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/rename.ows",
            tracks: [
                "Old Luke:transform": TimelineTrack(
                    name: "Old Luke:transform",
                    keyframes: [
                        TimelineKeyframe(
                            frame: 0,
                            kind: .transform,
                            value: .transform(transform)
                        )
                    ],
                    targetCharacterID: luke.id,
                    role: .transform
                )
            ]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let evaluated = try XCTUnwrap(store.evaluatedTransform(for: luke.id))

        XCTAssertEqual(evaluated.x, transform.x, accuracy: 0.0001)
        XCTAssertEqual(store.displayName(for: try XCTUnwrap(store.orderedTimelineTracks().first)), "Luke Prime:Transform")
    }

    func testSceneDirectionTemplateProvidesCameraShotFallbackAndFocusOffset() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "56565656-1111-1111-1111-565656565656")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let transformTrack = TimelineTrack(
            name: "Luke:transform",
            keyframes: [
                TimelineKeyframe(
                    frame: 0,
                    kind: .transform,
                    value: .transform(
                        CharacterTransform(
                            x: 0.78,
                            y: 0.56,
                            rotation: 0,
                            scaleX: 1,
                            scaleY: 1,
                            opacity: 1,
                            zOrder: 1
                        )
                    )
                )
            ],
            targetCharacterID: luke.id,
            role: .transform
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "78787878-1111-1111-1111-787878787878")!,
            name: "Template Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/template.ows",
            tracks: ["Luke:transform": transformTrack],
            directionTemplate: SceneDirectionTemplate(
                defaultCameraShot: .close,
                focusCharacterID: luke.id,
                notes: "Favor Luke close coverage."
            )
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        let composer = SceneFrameRenderComposer()

        let cameraState = composer.resolvedCameraState(
            store: store,
            scene: scene,
            frame: 0,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(cameraState.zoom, Float(CameraShot.close.zoomLevel), accuracy: 0.0001)
        XCTAssertGreaterThan(cameraState.offset.x, 0)
    }

    func testEffectiveCameraShotFallsBackToIntentRecommendation() {
        let scene = AnimationScene(
            id: UUID(uuidString: "79797979-1111-1111-1111-797979797979")!,
            name: "Intent Fallback Scene",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/intent-fallback.ows",
            tracks: [:]
        )
        let store = makeStore(scenes: [scene], selectedSceneID: scene.id)

        store.setCameraShotIntentCue(.reaction, at: 24)

        XCTAssertNil(store.evaluatedCameraShot(at: 24))
        XCTAssertNil(store.evaluatedCameraDefaultShot(at: 24))
        XCTAssertEqual(store.recommendedCameraShotFromIntent(at: 24), .close)
        XCTAssertEqual(store.evaluatedEffectiveCameraShot(at: 24), .close)
    }

    func testExplicitCameraShotFallbackWinsOverIntentRecommendation() {
        let scene = AnimationScene(
            id: UUID(uuidString: "7A7A7A7A-1111-1111-1111-7A7A7A7A7A7A")!,
            name: "Intent Override Scene",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/intent-override.ows",
            tracks: [:]
        )
        let store = makeStore(scenes: [scene], selectedSceneID: scene.id)

        store.setCameraShotIntentCue(.reaction, at: 12)
        store.setCameraDefaultShotCue(.wide, at: 12)
        XCTAssertEqual(store.evaluatedEffectiveCameraShot(at: 12), .wide)

        store.setCameraShotCue(.mediumClose, at: 12)
        XCTAssertEqual(store.evaluatedEffectiveCameraShot(at: 12), .mediumClose)
    }

    func testComposerUsesIntentRecommendedShotWhenNoExplicitFramingExists() {
        let scene = AnimationScene(
            id: UUID(uuidString: "7B7B7B7B-1111-1111-1111-7B7B7B7B7B7B")!,
            name: "Intent Camera Scene",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/intent-camera.ows",
            tracks: [:]
        )
        let store = makeStore(scenes: [scene], selectedSceneID: scene.id)
        let composer = SceneFrameRenderComposer()

        store.setCameraShotIntentCue(.establishing, at: 8)

        let cameraState = composer.resolvedCameraState(
            store: store,
            scene: scene,
            frame: 8,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(cameraState.zoom, Float(CameraShot.extremeWide.zoomLevel), accuracy: 0.0001)
        XCTAssertEqual(cameraState.offset.x, 0, accuracy: 0.0001)
        XCTAssertEqual(cameraState.offset.y, 0, accuracy: 0.0001)
    }

    func testSuggestedShotPresetsPreferMatchingIntentAndFocus() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "7C7C7C7C-1111-1111-1111-7C7C7C7C7C7C")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "7D7D7D7D-1111-1111-1111-7D7D7D7D7D7D")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "7E7E7E7E-1111-1111-1111-7E7E7E7E7E7E")!,
            name: "Suggested Presets Scene",
            backgroundID: nil,
            characterIDs: [luke.id, amira.id],
            keyframes: [],
            owpSongPath: "Songs/suggested-presets.ows",
            tracks: [:]
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        store.shotPresets = [
            SceneShotPreset(
                id: UUID(uuidString: "7F7F7F7F-1111-1111-1111-7F7F7F7F7F7F")!,
                name: "Luke Reaction Close",
                notes: "",
                shotIntent: .reaction,
                cameraShot: .close,
                focusCharacterSlug: "luke",
                characterCues: []
            ),
            SceneShotPreset(
                id: UUID(uuidString: "80808080-2222-2222-2222-808080808080")!,
                name: "Amira Reaction",
                notes: "",
                shotIntent: .reaction,
                cameraShot: .mediumClose,
                focusCharacterSlug: "amira",
                characterCues: []
            ),
            SceneShotPreset(
                id: UUID(uuidString: "81818181-2222-2222-2222-818181818181")!,
                name: "Luke Walk Wide",
                notes: "",
                shotIntent: .movement,
                cameraShot: .wide,
                focusCharacterSlug: "luke",
                characterCues: []
            )
        ]

        let suggestions = store.suggestedShotPresets(for: .reaction, focusCharacterID: luke.id, limit: 2)

        XCTAssertEqual(suggestions.map(\.name), ["Luke Reaction Close", "Amira Reaction"])
    }

    func testComposerUsesIntentDrivenLeadRoomForMovementWithoutExplicitFocus() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "82828282-2222-2222-2222-828282828282")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let transformTrack = TimelineTrack(
            name: "Luke:transform",
            keyframes: [
                TimelineKeyframe(
                    frame: 9,
                    kind: .transform,
                    value: .transform(CharacterTransform(x: 0.40, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                ),
                TimelineKeyframe(
                    frame: 10,
                    kind: .transform,
                    value: .transform(CharacterTransform(x: 0.50, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                ),
                TimelineKeyframe(
                    frame: 11,
                    kind: .transform,
                    value: .transform(CharacterTransform(x: 0.60, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                )
            ],
            targetCharacterID: luke.id,
            role: .transform
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "83838383-2222-2222-2222-838383838383")!,
            name: "Intent Lead Room Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/intent-lead-room.ows",
            tracks: ["Luke:transform": transformTrack]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)
        let composer = SceneFrameRenderComposer()

        store.setCameraShotIntentCue(.movement, at: 10)

        let cameraState = composer.resolvedCameraState(
            store: store,
            scene: scene,
            frame: 10,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(cameraState.zoom, Float(CameraShot.wide.zoomLevel), accuracy: 0.0001)
        XCTAssertGreaterThan(cameraState.offset.x, 150)
    }

    func testComposerCentersDialogueIntentAcrossTwoVisibleSubjectsWithoutExplicitFocus() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "84848484-2222-2222-2222-848484848484")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "85858585-2222-2222-2222-858585858585")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "86868686-2222-2222-2222-868686868686")!,
            name: "Intent Dialogue Scene",
            backgroundID: nil,
            characterIDs: [luke.id, amira.id],
            keyframes: [],
            owpSongPath: "Songs/intent-dialogue.ows",
            tracks: [
                "Luke:transform": TimelineTrack(
                    name: "Luke:transform",
                    keyframes: [
                        TimelineKeyframe(
                            frame: 0,
                            kind: .transform,
                            value: .transform(CharacterTransform(x: 0.30, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                        )
                    ],
                    targetCharacterID: luke.id,
                    role: .transform
                ),
                "Amira:transform": TimelineTrack(
                    name: "Amira:transform",
                    keyframes: [
                        TimelineKeyframe(
                            frame: 0,
                            kind: .transform,
                            value: .transform(CharacterTransform(x: 0.70, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                        )
                    ],
                    targetCharacterID: amira.id,
                    role: .transform
                )
            ]
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        let composer = SceneFrameRenderComposer()

        store.setCameraShotIntentCue(.dialogue, at: 0)

        let cameraState = composer.resolvedCameraState(
            store: store,
            scene: scene,
            frame: 0,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(cameraState.zoom, Float(CameraShot.mediumClose.zoomLevel), accuracy: 0.0001)
        XCTAssertEqual(cameraState.offset.x, 0, accuracy: 0.0001)
    }

    func testExplicitFocusStillWinsOverIntentDrivenFallbackOffset() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "87878787-2222-2222-2222-878787878787")!,
            name: "Luke",
            description: "",
            owpSlug: "luke",
            parts: []
        )
        let amira = AnimationCharacter(
            id: UUID(uuidString: "88888888-2222-2222-2222-888888888888")!,
            name: "Amira",
            description: "",
            owpSlug: "amira",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "89898989-2222-2222-2222-898989898989")!,
            name: "Intent Focus Priority Scene",
            backgroundID: nil,
            characterIDs: [luke.id, amira.id],
            keyframes: [],
            owpSongPath: "Songs/intent-focus-priority.ows",
            tracks: [
                "Luke:transform": TimelineTrack(
                    name: "Luke:transform",
                    keyframes: [
                        TimelineKeyframe(
                            frame: 5,
                            kind: .transform,
                            value: .transform(CharacterTransform(x: 0.20, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                        )
                    ],
                    targetCharacterID: luke.id,
                    role: .transform
                ),
                "Amira:transform": TimelineTrack(
                    name: "Amira:transform",
                    keyframes: [
                        TimelineKeyframe(
                            frame: 5,
                            kind: .transform,
                            value: .transform(CharacterTransform(x: 0.75, y: 0.56, rotation: 0, scaleX: 1, scaleY: 1, opacity: 1, zOrder: 1))
                        )
                    ],
                    targetCharacterID: amira.id,
                    role: .transform
                )
            ]
        )
        let store = makeStore(characters: [luke, amira], scenes: [scene], selectedSceneID: scene.id)
        let composer = SceneFrameRenderComposer()

        store.setCameraShotIntentCue(.movement, at: 5)
        store.setCameraFocusCue(amira.id, at: 5)

        let cameraState = composer.resolvedCameraState(
            store: store,
            scene: scene,
            frame: 5,
            viewportSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(cameraState.zoom, Float(CameraShot.wide.zoomLevel), accuracy: 0.0001)
        XCTAssertEqual(cameraState.offset.x, 480, accuracy: 0.0001)
    }

    private func makeStore(
        characters: [AnimationCharacter] = [],
        scenes: [AnimationScene] = [
            AnimationScene(
                id: UUID(uuidString: "EEEEEEEE-1111-1111-1111-EEEEEEEEEEEE")!,
                name: "Default Scene",
                backgroundID: nil,
                characterIDs: [],
                keyframes: [],
                owpSongPath: "Songs/default.ows",
                tracks: [:]
            )
        ],
        selectedSceneID: UUID? = nil
    ) -> AnimateStore {
        let store = AnimateStore()
        store.characters = characters
        store.scenes = scenes
        store.selectedSceneID = selectedSceneID ?? scenes.first?.id
        return store
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovotroAnimateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
