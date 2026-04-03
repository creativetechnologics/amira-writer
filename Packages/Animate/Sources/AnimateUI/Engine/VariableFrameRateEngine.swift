import Foundation

// MARK: - Animation Hold Style

/// Describes how many base-rate frames each unique drawing is held for,
/// using traditional animation terminology (ones, twos, threes, fours).
///
/// At a 24fps base rate:
///   - On ones: 24 unique drawings/second (full fluidity)
///   - On twos: 12 unique drawings/second (standard anime)
///   - On threes: 8 unique drawings/second (limited animation)
///   - On fours: 6 unique drawings/second (very stylized holds)
@available(macOS 26.0, *)
enum AnimationHoldStyle: String, Codable, Sendable, CaseIterable {
    case onOnes = "1s"
    case onTwos = "2s"
    case onThrees = "3s"
    case onFours = "4s"

    var holdFrames: Int {
        switch self {
        case .onOnes: 1
        case .onTwos: 2
        case .onThrees: 3
        case .onFours: 4
        }
    }

    /// Given a raw frame number, returns the quantized frame (held frame).
    /// Frames within the same hold period all map to the same drawing.
    func quantize(_ frame: Int) -> Int {
        (frame / holdFrames) * holdFrames
    }

    /// Effective visual frame rate at a given base rate.
    func effectiveFPS(baseFPS: Int) -> Int {
        max(1, baseFPS / holdFrames)
    }
}

// MARK: - Variable Frame Rate Profile

/// Per-element hold style configuration for a scene.
///
/// In Spider-Verse style, different scene elements animate at different rates:
/// the camera stays smooth while characters switch between ones and twos
/// depending on action intensity, and background characters use threes or fours.
///
/// This profile drives `VariableFrameRateEngine` to produce per-element
/// quantized frames from a single raw frame counter.
@available(macOS 26.0, *)
struct VariableFrameRateProfile: Codable, Sendable, Hashable {

    /// Per-character hold style (character name -> hold style).
    var characterHoldStyles: [String: AnimationHoldStyle] = [:]

    /// Default hold style for characters not explicitly specified.
    var defaultCharacterHold: AnimationHoldStyle = .onTwos

    /// Camera is typically always smooth (on ones).
    var cameraHold: AnimationHoldStyle = .onOnes

    /// Background parallax hold style.
    var backgroundHold: AnimationHoldStyle = .onOnes

    /// Default hold style for objects/props.
    var defaultObjectHold: AnimationHoldStyle = .onTwos
}

// MARK: - Variable Frame Rate Engine

/// Converts raw frame numbers into per-element display frames based on a
/// `VariableFrameRateProfile`. Each element type (character, camera, background,
/// object) can animate at a different effective frame rate while sharing the
/// same master timeline.
///
/// ## Integration Point
///
/// `Animate3DSceneAdapter.frameSnapshot(for:store:rawFrame:playbackStyle:)` currently
/// applies a single `Animate3DPlaybackStyle` uniformly to the entire scene. To enable
/// Spider-Verse-style per-element rates, that method should accept a
/// `VariableFrameRateProfile` and use this engine to quantize character frames
/// independently from camera frames. The existing `Animate3DPlaybackStyle` enum
/// parallels `AnimationHoldStyle` and can serve as a fallback for uniform mode.
@available(macOS 26.0, *)
struct VariableFrameRateEngine: Sendable {

    let profile: VariableFrameRateProfile
    let baseFPS: Int

    // MARK: Per-Element Frame Queries

    /// Returns the display frame for a character at the given raw frame.
    func characterFrame(name: String, rawFrame: Int) -> Int {
        let style = profile.characterHoldStyles[name] ?? profile.defaultCharacterHold
        return style.quantize(rawFrame)
    }

    /// Returns the display frame for the camera.
    func cameraFrame(rawFrame: Int) -> Int {
        profile.cameraHold.quantize(rawFrame)
    }

    /// Returns the display frame for a background layer.
    func backgroundFrame(rawFrame: Int) -> Int {
        profile.backgroundHold.quantize(rawFrame)
    }

    /// Returns the display frame for an object/prop.
    func objectFrame(name: String, rawFrame: Int) -> Int {
        profile.defaultObjectHold.quantize(rawFrame)
    }

    // MARK: Hold Style for Element

    /// Returns the active hold style for a named element, checking character
    /// overrides first, then falling back to the default character hold.
    func holdStyle(for elementName: String) -> AnimationHoldStyle {
        profile.characterHoldStyles[elementName] ?? profile.defaultCharacterHold
    }
}

// MARK: - Auto Hold Selection

@available(macOS 26.0, *)
extension VariableFrameRateEngine {

    /// Speed thresholds in world units per second for automatic hold selection.
    private static let fastThreshold: Double = 2.0
    private static let moderateThreshold: Double = 0.5
    private static let idleThreshold: Double = 0.05

    /// Automatically determines hold style based on movement speed and context.
    ///
    /// Mirrors the Spider-Verse approach where animators shift between ones and
    /// twos based on how dynamic a character's motion is:
    /// - Fast movement (> 2.0 units/sec) -> ones (full fluidity)
    /// - Moderate movement or speaking -> twos (standard anime)
    /// - Slow/idle main-action character -> threes
    /// - Background character idle -> fours
    ///
    /// - Parameters:
    ///   - movementSpeed: Character speed in world units per second.
    ///   - isMainAction: Whether the character is a primary action subject.
    ///   - isSpeaking: Whether the character is currently in dialogue.
    /// - Returns: The recommended hold style.
    static func autoHoldStyle(
        movementSpeed: Double,
        isMainAction: Bool,
        isSpeaking: Bool
    ) -> AnimationHoldStyle {
        if movementSpeed > fastThreshold {
            return .onOnes
        }
        if movementSpeed > moderateThreshold || isSpeaking {
            return .onTwos
        }
        if isMainAction {
            return .onThrees
        }
        return .onFours
    }

    /// Returns a motion blur intensity factor (0...1) for the given hold style and speed.
    ///
    /// Characters on twos or threes benefit from a subtle motion blur to smooth
    /// the visual gap between held frames. The blur scales with both hold length
    /// and movement speed so that static holds stay crisp.
    static func motionBlurFactor(
        holdStyle: AnimationHoldStyle,
        movementSpeed: Double
    ) -> Double {
        guard holdStyle != .onOnes else { return 0 }
        let speedNorm = min(movementSpeed / fastThreshold, 1.0)
        let holdScale = Double(holdStyle.holdFrames - 1) / 3.0 // 0 for ones, ~1 for fours
        return min(speedNorm * holdScale, 1.0)
    }
}

// MARK: - Frame Stepping for Preview

@available(macOS 26.0, *)
extension VariableFrameRateEngine {

    /// Given the current frame, returns the next frame that would produce a
    /// different quantized output for the named element. Useful for skipping
    /// redundant evaluations during preview scrubbing or export.
    func nextEvaluationFrame(after currentFrame: Int, for element: String) -> Int {
        let style = holdStyle(for: element)
        let currentQuantized = style.quantize(currentFrame)
        return currentQuantized + style.holdFrames
    }

    /// Returns all unique (non-redundant) frames within a range that need
    /// evaluation for the given element. Each returned frame is the first
    /// frame of a distinct hold period.
    func uniqueFrames(in range: ClosedRange<Int>, for element: String) -> [Int] {
        let style = holdStyle(for: element)
        let firstHold = style.quantize(range.lowerBound)
        var frames: [Int] = []
        var frame = firstHold
        while frame <= range.upperBound {
            if frame >= range.lowerBound {
                frames.append(frame)
            }
            frame += style.holdFrames
        }
        return frames
    }

    /// Returns the union of all unique evaluation frames across every tracked
    /// element (characters + camera + background). Useful for determining which
    /// raw frames actually produce visual changes somewhere in the scene.
    func allUniqueFrames(
        in range: ClosedRange<Int>,
        characterNames: [String]
    ) -> [Int] {
        var frameSet = Set<Int>()

        // Camera frames
        for f in uniqueFrames(in: range, for: "__camera__") {
            frameSet.insert(f)
        }

        // Character frames
        for name in characterNames {
            for f in uniqueFrames(in: range, for: name) {
                frameSet.insert(f)
            }
        }

        return frameSet.sorted()
    }
}
