import Foundation
import simd

// MARK: - MotionClip

/// A serializable container for captured or imported motion data.
/// Stores per-frame joint rotations (as quaternions), root translations,
/// and optional facial blend shape weights.
@available(macOS 26.0, *)
struct MotionClip: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    let source: MotionClipSource
    let fps: Int
    let frameCount: Int
    let duration: TimeInterval

    /// Per-joint quaternion rotations indexed by joint name.
    /// Each array has exactly `frameCount` entries.
    /// Quaternions stored as SIMD4<Float> (ix, iy, iz, r).
    var jointRotations: [String: [SIMD4<Float>]]

    /// Root (pelvis) world-space translation per frame.
    var rootPositions: [SIMD3<Float>]

    /// Per-blend-shape weight arrays indexed by blend shape name.
    /// Each array has exactly `frameCount` entries.
    var blendShapeWeights: [String: [Float]]

    var createdAt: Date
    var tags: [String]

    /// Slug of the character this clip was retargeted for (nil = generic).
    var characterSlug: String?

    // MARK: - Hashable (identity only)

    static func == (lhs: MotionClip, rhs: MotionClip) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        source: MotionClipSource,
        fps: Int,
        frameCount: Int,
        duration: TimeInterval,
        jointRotations: [String: [SIMD4<Float>]],
        rootPositions: [SIMD3<Float>],
        blendShapeWeights: [String: [Float]] = [:],
        createdAt: Date = Date(),
        tags: [String] = [],
        characterSlug: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.fps = fps
        self.frameCount = frameCount
        self.duration = duration
        self.jointRotations = jointRotations
        self.rootPositions = rootPositions
        self.blendShapeWeights = blendShapeWeights
        self.createdAt = createdAt
        self.tags = tags
        self.characterSlug = characterSlug
    }
}

// MARK: - MotionClipSource

@available(macOS 26.0, *)
enum MotionClipSource: Codable, Sendable, Hashable {
    case webcamCapture(sessionID: UUID)
    case videoFileCapture(fileURL: String)
    case hunyuanMotion(prompt: String)
    case importedBVH(filePath: String)
    case importedFBX(filePath: String)
    case manual
}

// MARK: - Sampling

@available(macOS 26.0, *)
extension MotionClip {
    /// Sample the clip at an arbitrary time, returning interpolated quaternions.
    /// Returns nil if the clip has no frames.
    func sample(at time: TimeInterval) -> MotionClipFrame? {
        guard frameCount > 0, duration > 0 else {
            // Single-frame clip: return frame 0 directly
            guard frameCount == 1 else { return nil }
            return frame(at: 0)
        }

        let clampedTime = max(0, min(duration, time))
        let fractionalFrame = clampedTime / duration * Double(frameCount - 1)
        let lo = Int(fractionalFrame)
        let hi = min(lo + 1, frameCount - 1)
        let t = Float(fractionalFrame - Double(lo))

        guard let a = frame(at: lo), let b = frame(at: hi) else { return nil }
        return MotionClipFrame.lerp(from: a, to: b, t: t)
    }

    /// Extract a single frame by index.
    func frame(at index: Int) -> MotionClipFrame? {
        guard index >= 0, index < frameCount else { return nil }
        var rotations: [String: simd_quatf] = [:]
        for (joint, quats) in jointRotations {
            let v = quats[index]
            rotations[joint] = simd_quatf(ix: v.x, iy: v.y, iz: v.z, r: v.w)
        }
        var blendShapes: [String: Float] = [:]
        for (name, weights) in blendShapeWeights {
            blendShapes[name] = weights[index]
        }
        return MotionClipFrame(
            rootPosition: rootPositions[index],
            jointRotations: rotations,
            blendShapeWeights: blendShapes
        )
    }
}

// MARK: - MotionClipFrame

/// A single interpolated frame extracted from a MotionClip.
@available(macOS 26.0, *)
struct MotionClipFrame: Sendable {
    let rootPosition: SIMD3<Float>
    let jointRotations: [String: simd_quatf]
    let blendShapeWeights: [String: Float]

    /// Spherical-linear interpolation between two frames.
    static func lerp(from a: MotionClipFrame, to b: MotionClipFrame, t: Float) -> MotionClipFrame {
        let pos = a.rootPosition + (b.rootPosition - a.rootPosition) * t

        var rotations: [String: simd_quatf] = [:]
        let allJoints = Set(a.jointRotations.keys).union(b.jointRotations.keys)
        for joint in allJoints {
            let ra = a.jointRotations[joint] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            let rb = b.jointRotations[joint] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            rotations[joint] = simd_slerp(ra, rb, t)
        }

        var blendShapes: [String: Float] = [:]
        let allShapes = Set(a.blendShapeWeights.keys).union(b.blendShapeWeights.keys)
        for shape in allShapes {
            let wa = a.blendShapeWeights[shape] ?? 0
            let wb = b.blendShapeWeights[shape] ?? 0
            blendShapes[shape] = wa + (wb - wa) * t
        }

        return MotionClipFrame(
            rootPosition: pos,
            jointRotations: rotations,
            blendShapeWeights: blendShapes
        )
    }
}