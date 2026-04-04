import Foundation

/// Blend mode for an NLA track. Determines how the track's sampled pose
/// combines with the accumulated pose from lower tracks.
@available(macOS 26.0, *)
enum NLABlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Lerp with accumulated lower layers based on influence weight.
    case replace
    /// Adds delta rotations/values on top of accumulated pose.
    case additive
    /// Replaces accumulated values entirely where body mask matches.
    case override_

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replace: "Replace"
        case .additive: "Additive"
        case .override_: "Override"
        }
    }

    // Use "override" in JSON but avoid Swift keyword collision.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "replace": self = .replace
        case "additive": self = .additive
        case "override": self = .override_
        default: throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown NLABlendMode: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .replace: try container.encode("replace")
        case .additive: try container.encode("additive")
        case .override_: try container.encode("override")
        }
    }
}

/// A reference to a motion clip placed on an NLA track, with timing and trim info.
@available(macOS 26.0, *)
struct NLAClip: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    /// UUID of the MotionClip in the motion library.
    var motionClipID: UUID
    /// Frame on the NLA timeline where this clip begins playing.
    var startFrame: Int
    /// Playback speed multiplier (1.0 = normal).
    var speed: Float
    /// How many frames to skip at the beginning of the source clip.
    var trimStartFrame: Int
    /// How many frames to skip at the end of the source clip.
    var trimEndFrame: Int
    /// Cross-fade frames at the clip's start.
    var blendInFrames: Int
    /// Cross-fade frames at the clip's end.
    var blendOutFrames: Int
    /// Per-clip influence (multiplied with track influence).
    var influence: Float

    init(
        id: UUID = UUID(),
        motionClipID: UUID,
        startFrame: Int = 0,
        speed: Float = 1.0,
        trimStartFrame: Int = 0,
        trimEndFrame: Int = 0,
        blendInFrames: Int = 0,
        blendOutFrames: Int = 0,
        influence: Float = 1.0
    ) {
        self.id = id
        self.motionClipID = motionClipID
        self.startFrame = startFrame
        self.speed = speed
        self.trimStartFrame = trimStartFrame
        self.trimEndFrame = trimEndFrame
        self.blendInFrames = blendInFrames
        self.blendOutFrames = blendOutFrames
        self.influence = influence
    }

    /// The effective number of source frames this clip plays (after trim, before speed).
    func effectiveSourceFrames(motionClipFrameCount: Int) -> Int {
        max(0, motionClipFrameCount - trimStartFrame - trimEndFrame)
    }

    /// How many NLA timeline frames this clip occupies, accounting for speed.
    func timelineDuration(motionClipFrameCount: Int) -> Int {
        let sourceFrames = effectiveSourceFrames(motionClipFrameCount: motionClipFrameCount)
        guard speed > 0 else { return sourceFrames }
        return Int(ceil(Float(sourceFrames) / speed))
    }

    /// The last NLA timeline frame this clip occupies (exclusive).
    func endFrame(motionClipFrameCount: Int) -> Int {
        startFrame + timelineDuration(motionClipFrameCount: motionClipFrameCount)
    }
}

/// A single NLA track lane. Tracks stack bottom-to-top; higher sortOrder tracks
/// blend on top of lower ones.
@available(macOS 26.0, *)
struct NLATrack: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var blendMode: NLABlendMode
    var bodyMask: BodyPartMask
    /// Track-level influence weight (0.0-1.0). Multiplied with per-clip influence.
    var influence: Float
    var muted: Bool
    var solo: Bool
    var clips: [NLAClip]
    /// Display order; lower values render at the bottom of the track stack.
    var sortOrder: Int
    /// Color tag for clip rectangles. Computed from source type at creation time.
    var colorTag: NLATrackColorTag

    init(
        id: UUID = UUID(),
        name: String = "Track",
        blendMode: NLABlendMode = .replace,
        bodyMask: BodyPartMask = .everything,
        influence: Float = 1.0,
        muted: Bool = false,
        solo: Bool = false,
        clips: [NLAClip] = [],
        sortOrder: Int = 0,
        colorTag: NLATrackColorTag = .webcam
    ) {
        self.id = id
        self.name = name
        self.blendMode = blendMode
        self.bodyMask = bodyMask
        self.influence = influence
        self.muted = muted
        self.solo = solo
        self.clips = clips
        self.sortOrder = sortOrder
        self.colorTag = colorTag
    }
}

/// Color tags for NLA track clip rectangles, derived from the motion source type.
@available(macOS 26.0, *)
enum NLATrackColorTag: String, Codable, Sendable, CaseIterable {
    case webcam     // orange
    case ai         // blue (HunyuanMotion)
    case imported   // green (BVH)
    case manual     // gray

    var displayName: String {
        switch self {
        case .webcam: "Webcam"
        case .ai: "AI Generated"
        case .imported: "Imported"
        case .manual: "Manual"
        }
    }
}

/// Top-level NLA timeline for a scene. Contains an ordered list of tracks.
@available(macOS 26.0, *)
struct NLATimeline: Codable, Sendable {
    var tracks: [NLATrack]
    var duration: TimeInterval
    var fps: Int

    init(tracks: [NLATrack] = [], duration: TimeInterval = 0, fps: Int = 24) {
        self.tracks = tracks
        self.duration = duration
        self.fps = fps
    }

    /// Total frame count derived from duration and fps.
    var totalFrames: Int {
        max(1, Int(ceil(duration * Double(fps))))
    }

    /// All tracks sorted by sortOrder (bottom-to-top evaluation order).
    var sortedTracks: [NLATrack] {
        tracks.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Add a new track at the top of the stack.
    mutating func addTrack(_ track: NLATrack) {
        var t = track
        t.sortOrder = (tracks.map(\.sortOrder).max() ?? -1) + 1
        tracks.append(t)
    }

    /// Remove a track by ID.
    mutating func removeTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
    }

    /// Find the track index for a given ID.
    func trackIndex(for id: UUID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }
}
