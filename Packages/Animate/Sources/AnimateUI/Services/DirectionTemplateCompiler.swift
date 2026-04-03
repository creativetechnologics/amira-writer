import Foundation
import simd

/// Compiles scene blocking data into camera choreography plans.
///
/// Uses cinematic convention: establishing shot → coverage → emphasis.
/// Produces `CameraChoreographyPlan.CameraKeyframe` values that the
/// existing `ScenePreviewRenderer` / `SceneProductionCompiler` pipeline
/// can consume directly.
@available(macOS 26.0, *)
struct DirectionTemplateCompiler: Sendable {

    // MARK: - Public Output Type

    /// A single camera cut or move instruction.
    struct CameraInstruction: Sendable {
        /// The frame at which this instruction becomes active.
        let frame: Int
        /// Shot type using the existing `CameraShot` enum.
        let shotType: CameraShot
        /// Focal length in mm (18–135).
        let focalLength: Double
        /// Slug of the character to focus on, or `nil` for a scene-wide shot.
        let focusCharacterSlug: String?
        /// Human-readable rationale for this cut.
        let motivation: String
        /// Easing using the existing `EasingCurve` type.
        let easing: EasingCurve
    }

    // MARK: - Public API

    /// Compile camera instructions from blocking plans.
    ///
    /// - Parameters:
    ///   - blockingPlans: Per-character blocking data produced by `SceneProductionCompiler`.
    ///   - sceneDurationFrames: Total frame count of the scene.
    ///   - fps: Frames per second (default 24).
    /// - Returns: Ordered array of camera instructions, starting at frame 0.
    static func compileCameraChoreography(
        blockingPlans: [CharacterBlockingPlan],
        sceneDurationFrames: Int,
        fps: Int = 24
    ) -> [CameraInstruction] {
        guard !blockingPlans.isEmpty, sceneDurationFrames > 0 else {
            return [defaultEstablishingShot()]
        }

        var instructions: [CameraInstruction] = []

        // 1. Establishing shot (first 2–4 seconds, up to 25% of scene length).
        let establishDuration = min(fps * 4, sceneDurationFrames / 4)
        instructions.append(CameraInstruction(
            frame: 0,
            shotType: .wide,
            focalLength: AnimationCamera.focalRange(for: .wide).mid,
            focusCharacterSlug: nil,
            motivation: "Establishing shot — show the full scene",
            easing: .easeInOut
        ))

        // 2. Collect all significant dramatic events.
        var events = collectDramaticEvents(from: blockingPlans, fps: fps)
        events.sort { $0.frame < $1.frame }

        // 3. Generate camera cuts for each dramatic event.
        // Initialise to establishDuration so the minimum cut interval is measured
        // from the *end* of the establishing shot, not its start.
        var lastCutFrame = establishDuration
        let minimumCutInterval = fps * 2  // Never cut faster than every 2 seconds.

        for event in events {
            guard event.frame >= establishDuration else { continue }
            guard event.frame - lastCutFrame >= minimumCutInterval else { continue }
            guard event.frame < sceneDurationFrames else { break }

            let instruction = cameraForEvent(event, blockingPlans: blockingPlans)
            instructions.append(instruction)
            lastCutFrame = event.frame
        }

        // 4. Add a closing wide shot when there is a long gap at the end.
        let closingThreshold = fps * 6
        if let lastInstruction = instructions.last,
           sceneDurationFrames - lastInstruction.frame > closingThreshold {
            instructions.append(CameraInstruction(
                frame: sceneDurationFrames - fps * 3,
                shotType: .wide,
                focalLength: AnimationCamera.focalRange(for: .wide).mid,
                focusCharacterSlug: nil,
                motivation: "Closing wide shot",
                easing: .easeInOut
            ))
        }

        return instructions
    }

    // MARK: - Conversion to CameraChoreographyPlan

    /// Convert compiled instructions to a `CameraChoreographyPlan` for direct use
    /// in `SceneProductionPlan`.
    ///
    /// Positions and look-at targets use the same `Stage` coordinate conventions as
    /// `SceneProductionCompiler`.
    static func toCameraChoreographyPlan(
        instructions: [CameraInstruction],
        blockingPlans: [CharacterBlockingPlan]
    ) -> CameraChoreographyPlan {
        let keyframes = instructions.map { instruction -> CameraChoreographyPlan.CameraKeyframe in
            let lookAt = lookAtForSlug(
                instruction.focusCharacterSlug,
                at: instruction.frame,
                blockingPlans: blockingPlans
            )
            let camPos = camPosition(for: instruction.shotType, lookAt: lookAt)
            let shotIntent: ShotIntent? = shotIntentForMotivation(instruction.motivation)
            return CameraChoreographyPlan.CameraKeyframe(
                frame: instruction.frame,
                focalLength: instruction.focalLength,
                position: camPos,
                lookAt: lookAt,
                roll: 0,
                movement: .hold,
                easing: instruction.easing,
                shotType: instruction.shotType,
                shotIntent: shotIntent,
                focusCharacter: instruction.focusCharacterSlug
            )
        }
        return CameraChoreographyPlan(keyframes: keyframes)
    }

    // MARK: - Summary

    /// Human-readable summary of a set of camera instructions.
    static func summary(for instructions: [CameraInstruction]) -> String {
        guard !instructions.isEmpty else { return "No camera instructions" }
        let cuts = instructions.count
        let types = Set(instructions.map { $0.shotType.rawValue })
        return "\(cuts) camera cut\(cuts == 1 ? "" : "s") (\(types.sorted().joined(separator: ", ")))"
    }

    // MARK: - Dramatic Event Detection

    struct DramaticEvent: Sendable {
        let frame: Int
        let type: EventType
        let characterSlug: String?
        let characterName: String?
        let intensity: Double

        enum EventType: Sendable {
            case entrance
            case exit
            case speakingStart
            case singingStart
            case emotionChange(String)
            case highIntensityBeat
        }
    }

    private static func collectDramaticEvents(
        from plans: [CharacterBlockingPlan],
        fps: Int
    ) -> [DramaticEvent] {
        var events: [DramaticEvent] = []

        for plan in plans {
            // Character entrance.
            events.append(DramaticEvent(
                frame: plan.entranceFrame,
                type: .entrance,
                characterSlug: plan.characterSlug,
                characterName: plan.characterName,
                intensity: 0.5
            ))

            // Character exit (cut slightly before the exit).
            if let exitFrame = plan.exitFrame {
                let cutFrame = max(0, exitFrame - fps)
                events.append(DramaticEvent(
                    frame: cutFrame,
                    type: .exit,
                    characterSlug: plan.characterSlug,
                    characterName: plan.characterName,
                    intensity: 0.4
                ))
            }

            // Acting beats: speech, singing, high-intensity moments.
            for beat in plan.actingBeats {
                switch beat.action.lowercased() {
                case "speak", "talk":
                    events.append(DramaticEvent(
                        frame: beat.startFrame,
                        type: .speakingStart,
                        characterSlug: plan.characterSlug,
                        characterName: plan.characterName,
                        intensity: beat.intensity
                    ))
                case "sing":
                    events.append(DramaticEvent(
                        frame: beat.startFrame,
                        type: .singingStart,
                        characterSlug: plan.characterSlug,
                        characterName: plan.characterName,
                        intensity: beat.intensity
                    ))
                default:
                    if beat.intensity > 0.7 {
                        events.append(DramaticEvent(
                            frame: beat.startFrame,
                            type: .highIntensityBeat,
                            characterSlug: plan.characterSlug,
                            characterName: plan.characterName,
                            intensity: beat.intensity
                        ))
                    }
                }
            }

            // Emotion changes from keyframes (skip neutral / unchanged emotions).
            var lastEmotion = ""
            for kf in plan.keyPositions {
                let emotion = kf.emotion
                guard !emotion.isEmpty, emotion != "neutral", emotion != lastEmotion else { continue }
                events.append(DramaticEvent(
                    frame: kf.frame,
                    type: .emotionChange(emotion),
                    characterSlug: plan.characterSlug,
                    characterName: plan.characterName,
                    intensity: 0.6
                ))
                lastEmotion = emotion
            }
        }

        return events
    }

    // MARK: - Camera Selection

    private static func cameraForEvent(
        _ event: DramaticEvent,
        blockingPlans: [CharacterBlockingPlan]
    ) -> CameraInstruction {
        switch event.type {
        case .entrance:
            return CameraInstruction(
                frame: event.frame,
                shotType: .medium,
                focalLength: AnimationCamera.focalRange(for: .medium).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "\(event.characterName ?? "Character") enters",
                easing: .easeInOut
            )

        case .exit:
            return CameraInstruction(
                frame: event.frame,
                shotType: .wide,
                focalLength: AnimationCamera.focalRange(for: .wide).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "\(event.characterName ?? "Character") exits",
                easing: .easeOut
            )

        case .speakingStart:
            // Close-up for emotionally intense dialogue, medium for conversational.
            let isIntense = event.intensity > 0.7
            let shot: CameraShot = isIntense ? .close : .medium
            return CameraInstruction(
                frame: event.frame,
                shotType: shot,
                focalLength: AnimationCamera.focalRange(for: shot).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "\(event.characterName ?? "Character") speaks",
                easing: .easeInOut
            )

        case .singingStart:
            return CameraInstruction(
                frame: event.frame,
                shotType: .medium,
                focalLength: AnimationCamera.focalRange(for: .mediumClose).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "\(event.characterName ?? "Character") sings",
                easing: .easeInOut
            )

        case .emotionChange(let emotion):
            // Strong emotions warrant close-ups; subtler shifts get medium coverage.
            let strongEmotions: Set<String> = ["angry", "fear", "surprised", "disgust", "contempt", "rage"]
            let isStrong = strongEmotions.contains(emotion.lowercased())
            let shot: CameraShot = isStrong ? .close : .medium
            return CameraInstruction(
                frame: event.frame,
                shotType: shot,
                focalLength: AnimationCamera.focalRange(for: shot).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "\(event.characterName ?? "Character") shows \(emotion)",
                easing: .easeInOut
            )

        case .highIntensityBeat:
            let shot: CameraShot = event.intensity > 0.85 ? .close : .medium
            return CameraInstruction(
                frame: event.frame,
                shotType: shot,
                focalLength: AnimationCamera.focalRange(for: shot).mid,
                focusCharacterSlug: event.characterSlug,
                motivation: "High intensity moment",
                easing: .easeIn
            )
        }
    }

    // MARK: - Private Helpers

    private static func defaultEstablishingShot() -> CameraInstruction {
        CameraInstruction(
            frame: 0,
            shotType: .wide,
            focalLength: AnimationCamera.focalRange(for: .wide).mid,
            focusCharacterSlug: nil,
            motivation: "Default establishing shot",
            easing: .easeInOut
        )
    }

    /// Resolve a world-space look-at target for a character slug at the given frame.
    private static func lookAtForSlug(
        _ slug: String?,
        at frame: Int,
        blockingPlans: [CharacterBlockingPlan]
    ) -> SIMD3<Double> {
        guard let slug,
              let plan = blockingPlans.first(where: { $0.characterSlug == slug }),
              let pos = interpolatedPosition(plan, frame: frame)
        else {
            return SIMD3<Double>(0, 1.0, -3.0)  // Stage centre at head height.
        }
        return SIMD3<Double>(pos.x, 1.0, pos.z)
    }

    /// Camera world position for a shot type, offset from the look-at target.
    private static func camPosition(for shot: CameraShot, lookAt: SIMD3<Double>) -> SIMD3<Double> {
        let distance: Double = switch shot {
        case .extremeWide: 12
        case .wide:        10
        case .medium:       8
        case .mediumClose:  6
        case .close:        4.5
        case .extremeClose: 3
        }
        return SIMD3<Double>(lookAt.x * 0.3, 1.5, distance)
    }

    /// Linear interpolation of a character's position between keyframes.
    private static func interpolatedPosition(
        _ plan: CharacterBlockingPlan,
        frame: Int
    ) -> SIMD3<Double>? {
        guard let first = plan.keyPositions.first,
              let last  = plan.keyPositions.last else { return nil }
        if frame <= first.frame { return first.position }
        if frame >= last.frame  { return last.position }
        for i in 0 ..< plan.keyPositions.count - 1 {
            let a = plan.keyPositions[i]
            let b = plan.keyPositions[i + 1]
            guard frame >= a.frame, frame <= b.frame else { continue }
            let span = Double(b.frame - a.frame)
            guard span > 0 else { return a.position }
            let t = Double(frame - a.frame) / span
            return simd_mix(a.position, b.position, SIMD3<Double>(repeating: t))
        }
        return last.position
    }

    /// Map a motivation string to a `ShotIntent` hint for downstream renderers.
    private static func shotIntentForMotivation(_ motivation: String) -> ShotIntent? {
        let lower = motivation.lowercased()
        if lower.contains("establishing") { return .establishing }
        if lower.contains("enters") || lower.contains("exits") { return .reveal }
        if lower.contains("speaks") || lower.contains("sings") { return .dialogue }
        if lower.contains("shows") { return .reaction }
        return nil
    }
}
