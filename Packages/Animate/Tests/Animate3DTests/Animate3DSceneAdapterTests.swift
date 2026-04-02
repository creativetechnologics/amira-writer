import Foundation
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class Animate3DSceneAdapterTests: XCTestCase {
    func testPlaybackStyleQuantizesAnimeExposureFrames() {
        XCTAssertEqual(Animate3DPlaybackStyle.onTwos.quantizedFrame(5, baseFPS: 24), 4)
        XCTAssertEqual(Animate3DPlaybackStyle.onThrees.quantizedFrame(7, baseFPS: 24), 6)
        XCTAssertEqual(Animate3DPlaybackStyle.onFours.quantizedFrame(11, baseFPS: 24), 8)
        XCTAssertEqual(Animate3DPlaybackStyle.onOnes.quantizedFrame(11, baseFPS: 24), 11)
    }

    func testFixtureScenarioIsReadyWithShotMarkers() {
        let scenario = Animate3DSceneAdapter().makeScenario(
            store: makeStore(),
            mode: .fixture
        )

        XCTAssertEqual(scenario.sourceKind, .fixture)
        XCTAssertTrue(scenario.validation.ready)
        XCTAssertGreaterThanOrEqual(scenario.castNames.count, 2)
        XCTAssertGreaterThanOrEqual(scenario.shotMarkers.count, 2)
        XCTAssertGreaterThanOrEqual(scenario.diagnostics.attachmentCount, 1)
        XCTAssertNotNil(scenario.compiledScene)
    }

    func testFixtureScenarioProducesMotionTrails() async {
        let store = makeStore()
        let adapter = Animate3DSceneAdapter()
        let scenario = adapter.makeScenario(
            store: store,
            mode: .fixture
        )

        let trails = await adapter.motionTrails(
            for: scenario,
            store: store,
            playbackStyle: .onTwos
        )

        XCTAssertFalse(trails.isEmpty)
        XCTAssertTrue(trails.contains(where: { $0.kind == .character }))
        XCTAssertTrue(trails.allSatisfy { $0.points.count >= 2 })
    }

    func testSelectedSceneModeFallsBackWhenNoSceneIsAvailable() {
        let scenario = Animate3DSceneAdapter().makeScenario(
            store: makeStore(scenes: [], selectedSceneID: nil),
            mode: .selectedScene
        )

        XCTAssertEqual(scenario.sourceKind, .fixture)
        XCTAssertFalse(scenario.validation.ready)
        XCTAssertTrue(scenario.validation.warnings.contains("Fallback fixture loaded so the 3D pane stays usable."))
    }

    func testAdapterBuildsParsedDirectionsScenarioFromLyrics() {
        let scene = AnimationScene(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Parsed Scene",
            backgroundID: nil,
            characterIDs: [],
            keyframes: [],
            owpSongPath: "Songs/parsed.ows",
            tracks: [:]
        )
        let store = makeStore(scenes: [scene], selectedSceneID: scene.id)
        store.currentSongData = OWSSongData(
            title: "Parsed",
            tempoEvents: [OWPTempoPoint(tick: 0, bpm: 120)],
            lyricsText: """
            [scene: "Parsed Scene" | bg=Debug Stage]
            [enter: "Luke" | position=center_left | facing=right | bars=1]
            [camera: hold | from=wide | to=medium | bars=1-2]
            [camera: push_in | from=medium | to=close_up | bars=3-4]
            """
        )

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)

        XCTAssertEqual(scenario.sourceKind, .parsedDirections)
        XCTAssertGreaterThan(scenario.parsedDirectionCount, 0)
        XCTAssertTrue(scenario.validation.ready)
        XCTAssertNotNil(scenario.compiledScene)
        XCTAssertTrue(scenario.castNames.contains("Luke"))
        XCTAssertGreaterThanOrEqual(scenario.shotMarkers.count, 2)
        XCTAssertNotEqual(scenario.shotMarkers.first?.title, "Opening Wide")
        XCTAssertGreaterThanOrEqual(scenario.diagnostics.cameraTrackCount, 1)
    }

    func testAdapterBuildsLiveSceneShotsFromCameraTrackWhenAuthoredShotsAreEmpty() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let cameraTrack = TimelineTrack(
            name: "camera:shot",
            keyframes: [
                TimelineKeyframe(
                    frame: 0,
                    kind: .expression,
                    value: .expression(name: CameraShot.wide.rawValue)
                ),
                TimelineKeyframe(
                    frame: 24,
                    kind: .expression,
                    value: .expression(name: CameraShot.mediumClose.rawValue)
                )
            ],
            role: .cameraShot
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            name: "Cue-derived Live Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/live-cues.ows",
            tracks: ["camera:shot": cameraTrack],
            shots: []
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)

        XCTAssertEqual(scenario.sourceKind, .selectedTimeline)
        XCTAssertGreaterThanOrEqual(scenario.shotMarkers.count, 2)
        XCTAssertEqual(scenario.diagnostics.shotSegmentCount, scenario.shotMarkers.count)
        XCTAssertEqual(scenario.shotMarkers.first?.cameraShot, .wide)
    }

    func testAdapterBuildsLiveSceneScenarioFromShotData() {
        let luke = AnimationCharacter(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Luke",
            description: "Lead",
            owpSlug: "luke",
            parts: []
        )
        let scene = AnimationScene(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Live Scene",
            backgroundID: nil,
            characterIDs: [luke.id],
            keyframes: [],
            owpSongPath: "Songs/live.ows",
            tracks: [:],
            shots: [
                AnimationSceneShot(
                    name: "Opening Wide",
                    startFrame: 0,
                    endFrame: 24,
                    cameraShot: .wide,
                    notes: "Establish the stage.",
                    source: .manual
                )
            ]
        )
        let store = makeStore(characters: [luke], scenes: [scene], selectedSceneID: scene.id)

        let scenario = Animate3DSceneAdapter().makeScenario(store: store, mode: .selectedScene)

        XCTAssertEqual(scenario.sourceKind, .selectedTimeline)
        XCTAssertEqual(scenario.castNames, ["Luke"])
        XCTAssertEqual(scenario.shotMarkers.count, 1)
        XCTAssertEqual(scenario.diagnostics.shotSegmentCount, 1)
        XCTAssertTrue(scenario.validation.ready)
    }

    func testPlaceholderPoseProfileInfersPresentingSpeaker() {
        let snapshot = Animate3DCharacterSnapshot(
            id: "luke",
            name: "Luke",
            worldPosition: SIMD3<Double>(0, 0, 0),
            yawDegrees: 0,
            opacity: 1,
            visible: true,
            pose: "presenting to the crowd",
            expression: "curious",
            action: "speak and gesture",
            colorIndex: 0
        )

        let profile = Animate3DPlaceholderPoseProfile.evaluate(snapshot)

        XCTAssertEqual(profile.primaryTag, "present")
        XCTAssertTrue(profile.tags.contains("present"))
        XCTAssertTrue(profile.tags.contains("speaking"))
        XCTAssertTrue(profile.tags.contains("curious"))
    }

    func testPlaceholderPoseProfileFallsBackToNeutral() {
        let snapshot = Animate3DCharacterSnapshot(
            id: "mara",
            name: "Mara",
            worldPosition: SIMD3<Double>(1, 0, 0),
            yawDegrees: 30,
            opacity: 1,
            visible: true,
            pose: nil,
            expression: nil,
            action: nil,
            colorIndex: 1
        )

        let profile = Animate3DPlaceholderPoseProfile.evaluate(snapshot)

        XCTAssertEqual(profile.primaryTag, "neutral")
        XCTAssertEqual(profile.tags, ["neutral"])
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
}
