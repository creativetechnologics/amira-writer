import Foundation

// MARK: - Scene Direction DSL Models
//
// The scene direction system uses a bracketed markup language embedded in scripts.
// Each direction is a single line wrapped in square brackets with pipe-delimited key=value pairs.
//
// Format:  [TAG: primary_value | key=value | key=value]
//
// Tags:
//   [scene: "name" | bg=background_name | lighting=day/night/custom]
//   [enter: "character" | position=stage_position | facing=direction | emotion=expression]
//   [exit: "character" | direction=left/right/fade]
//   [move: "character" | to=position | from=position | bars=N-M | easing=curve]
//   [emotion: "character" | expression=name | bar=N]
//   [action: "character" | description | bars=N-M | easing=curve]
//   [gesture: "character" | type=gesture_name | hand=left/right | bars=N-M]
//   [object: "lantern" | position=stage_left | y=0.62 | state=lit | layer=foreground]
//   [object_move: "lantern" | from=stage_left | to=center_left | bars=9-12 | easing=ease_in_out]
//   [object_state: "lantern" | state=dim | beats=33-36]
//   [object_visibility: "lantern" | visible=false | frames=240-264]
//   [camera: type | from=shot | to=shot | bars=N-M | easing=curve]
//   [lipsync: "character" | mode=singing/speech | song=name | bars=N-M]
//   [pause: bars=N or beats=N or frames=N]
//   [sfx: "sound_name" | bar=N]
//   [transition: type | duration=bars:N]

// MARK: - Parsed Direction

/// A single parsed scene direction from the bracketed markup.
struct SceneDirection: Identifiable, Codable, Sendable {
    var id: UUID
    var tag: DirectionTag
    var primaryValue: String
    var parameters: [String: String]
    var sourceLineNumber: Int

    init(id: UUID = UUID(), tag: DirectionTag, primaryValue: String = "",
         parameters: [String: String] = [:], sourceLineNumber: Int = 0) {
        self.id = id
        self.tag = tag
        self.primaryValue = primaryValue
        self.parameters = parameters
        self.sourceLineNumber = sourceLineNumber
    }
}

enum DirectionTag: String, Codable, Sendable, CaseIterable {
    case scene
    case enter
    case exit
    case move
    case emotion
    case action
    case gesture
    case object
    case objectMove = "object_move"
    case objectState = "object_state"
    case objectVisibility = "object_visibility"
    case camera
    case lipsync
    case pause
    case sfx
    case transition
}

// MARK: - Stage Positions

/// Predefined stage positions normalized to 0...1 coordinate space.
enum StagePosition: String, Codable, Sendable, CaseIterable {
    case stageLeft = "stage_left"
    case left
    case centerLeft = "center_left"
    case center
    case centerRight = "center_right"
    case right
    case stageRight = "stage_right"
    case offscreenLeft = "offscreen_left"
    case offscreenRight = "offscreen_right"

    /// Normalized X position (0.0 = left edge, 1.0 = right edge).
    var normalizedX: Double {
        switch self {
        case .offscreenLeft: -0.15
        case .stageLeft: 0.1
        case .left: 0.2
        case .centerLeft: 0.35
        case .center: 0.5
        case .centerRight: 0.65
        case .right: 0.8
        case .stageRight: 0.9
        case .offscreenRight: 1.15
        }
    }

    /// Initialize from a string, supporting both enum and numeric values.
    static func from(_ string: String) -> StagePosition? {
        StagePosition(rawValue: string.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// Predefined facing directions.
enum FacingDirection: String, Codable, Sendable {
    case left
    case right
    case camera  // facing the viewer
    case away    // facing away from viewer

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .camera: "To Camera"
        case .away: "Away"
        }
    }
}

/// Camera shot types.
enum CameraShot: String, Codable, Sendable {
    case extremeWide = "extreme_wide"
    case wide
    case medium
    case mediumClose = "medium_close"
    case close = "close"
    case extremeClose = "extreme_close"

    /// Zoom level (higher = more zoomed in).
    var zoomLevel: Double {
        switch self {
        case .extremeWide: 0.5
        case .wide: 0.75
        case .medium: 1.0
        case .mediumClose: 1.3
        case .close: 1.8
        case .extremeClose: 2.5
        }
    }

    var displayName: String {
        switch self {
        case .extremeWide: "Extreme Wide"
        case .wide: "Wide"
        case .medium: "Medium"
        case .mediumClose: "Medium Close"
        case .close: "Close"
        case .extremeClose: "Extreme Close"
        }
    }
}

/// Camera movement types.
enum CameraMovement: String, Codable, Sendable {
    case zoomIn = "zoom_in"
    case zoomOut = "zoom_out"
    case panLeft = "pan_left"
    case panRight = "pan_right"
    case panUp = "pan_up"
    case panDown = "pan_down"
    case track        // follow a character
    case shake
    case hold         // static

    var displayName: String {
        switch self {
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .panLeft: "Pan Left"
        case .panRight: "Pan Right"
        case .panUp: "Pan Up"
        case .panDown: "Pan Down"
        case .track: "Track"
        case .shake: "Shake"
        case .hold: "Hold"
        }
    }
}

/// Transition types between scenes.
enum TransitionType: String, Codable, Sendable {
    case cut
    case fade
    case crossfade
    case wipeLeft = "wipe_left"
    case wipeRight = "wipe_right"
    case iris
}

// MARK: - Timing

/// Represents a timing range from the direction markup.
struct DirectionTiming: Codable, Sendable {
    var startBar: Int?
    var endBar: Int?
    var startBeat: Int?
    var endBeat: Int?
    var startFrame: Int?
    var endFrame: Int?
    var durationBeats: Int?

    /// Parse a timing string like "1-4", "bars:12-24", "beats:1-8", "frames:0-48"
    static func parse(_ string: String) -> DirectionTiming {
        var timing = DirectionTiming()

        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Check for prefixed format
        if trimmed.hasPrefix("bars:") || trimmed.hasPrefix("bar:") {
            let value = String(trimmed.drop(while: { $0 != ":" }).dropFirst())
            let range = parseRange(value)
            timing.startBar = range.0
            timing.endBar = range.1
        } else if trimmed.hasPrefix("beats:") || trimmed.hasPrefix("beat:") {
            let value = String(trimmed.drop(while: { $0 != ":" }).dropFirst())
            let range = parseRange(value)
            timing.startBeat = range.0
            timing.endBeat = range.1
        } else if trimmed.hasPrefix("frames:") || trimmed.hasPrefix("frame:") {
            let value = String(trimmed.drop(while: { $0 != ":" }).dropFirst())
            let range = parseRange(value)
            timing.startFrame = range.0
            timing.endFrame = range.1
        } else {
            // Default: assume bars
            let range = parseRange(trimmed)
            timing.startBar = range.0
            timing.endBar = range.1
        }

        return timing
    }

    private static func parseRange(_ string: String) -> (Int?, Int?) {
        let parts = string.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
            return (parts[0], parts[1])
        } else if parts.count == 1 {
            return (parts[0], parts[0])
        }
        return (nil, nil)
    }

    /// Convert to frame range given a tempo context.
    func toFrameRange(fps: Int, bpm: Double, beatsPerBar: Int = 4) -> (start: Int, end: Int)? {
        let framesPerBeat = Double(fps) * 60.0 / bpm
        let framesPerBar = framesPerBeat * Double(beatsPerBar)

        if let sf = startFrame, let ef = endFrame {
            return (sf, ef)
        } else if let sb = startBar, let eb = endBar {
            return (Int(Double(sb - 1) * framesPerBar), Int(Double(eb) * framesPerBar))
        } else if let sb = startBeat, let eb = endBeat {
            return (Int(Double(sb - 1) * framesPerBeat), Int(Double(eb) * framesPerBeat))
        }
        return nil
    }
}

// MARK: - Compiled Scene

/// A fully resolved scene with all directions converted to frame-based keyframes.
struct CompiledScene: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var backgroundName: String?
    var lighting: String?
    var characterSetups: [CharacterSetup]
    var objectSetups: [ObjectSetup]
    var tracks: [String: [TimelineKeyframe]]
    var cameraKeyframes: [TimelineKeyframe]
    var totalFrames: Int

    init(id: UUID = UUID(), name: String = "", backgroundName: String? = nil,
         lighting: String? = nil, characterSetups: [CharacterSetup] = [],
         objectSetups: [ObjectSetup] = [],
         tracks: [String: [TimelineKeyframe]] = [:],
         cameraKeyframes: [TimelineKeyframe] = [], totalFrames: Int = 0) {
        self.id = id
        self.name = name
        self.backgroundName = backgroundName
        self.lighting = lighting
        self.characterSetups = characterSetups
        self.objectSetups = objectSetups
        self.tracks = tracks
        self.cameraKeyframes = cameraKeyframes
        self.totalFrames = totalFrames
    }
}

struct CharacterSetup: Identifiable, Codable, Sendable {
    var id: UUID
    var characterName: String
    var initialPosition: Double  // normalized X
    var initialFacing: FacingDirection
    var initialEmotion: String
    var enterFrame: Int
    var exitFrame: Int?

    init(id: UUID = UUID(), characterName: String, initialPosition: Double = 0.5,
         initialFacing: FacingDirection = .camera, initialEmotion: String = "neutral",
         enterFrame: Int = 0, exitFrame: Int? = nil) {
        self.id = id
        self.characterName = characterName
        self.initialPosition = initialPosition
        self.initialFacing = initialFacing
        self.initialEmotion = initialEmotion
        self.enterFrame = enterFrame
        self.exitFrame = exitFrame
    }
}

struct ObjectSetup: Identifiable, Codable, Sendable {
    var id: UUID
    var objectName: String
    var initialX: Double
    var initialY: Double
    var initialState: String
    var enterFrame: Int
    var exitFrame: Int?
    var zOrder: Int
    var opacity: Double
    var visible: Bool
    var attachmentTarget: String?
    var imagePaths: [String]
    var approvedImagePath: String?
    var stateImagePaths: [String: String]
    var notes: String

    enum CodingKeys: String, CodingKey {
        case id
        case objectName
        case initialX
        case initialY
        case initialState
        case enterFrame
        case exitFrame
        case zOrder
        case opacity
        case visible
        case attachmentTarget
        case imagePaths
        case approvedImagePath
        case stateImagePaths
        case notes
    }

    init(
        id: UUID = UUID(),
        objectName: String,
        initialX: Double = 0.5,
        initialY: Double = 0.62,
        initialState: String = "default",
        enterFrame: Int = 0,
        exitFrame: Int? = nil,
        zOrder: Int = 0,
        opacity: Double = 1,
        visible: Bool = true,
        attachmentTarget: String? = nil,
        imagePaths: [String] = [],
        approvedImagePath: String? = nil,
        stateImagePaths: [String: String] = [:],
        notes: String = ""
    ) {
        self.id = id
        self.objectName = objectName
        self.initialX = initialX
        self.initialY = initialY
        self.initialState = initialState
        self.enterFrame = enterFrame
        self.exitFrame = exitFrame
        self.zOrder = zOrder
        self.opacity = opacity
        self.visible = visible
        self.attachmentTarget = attachmentTarget
        self.imagePaths = imagePaths
        self.approvedImagePath = approvedImagePath
        self.stateImagePaths = stateImagePaths
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        objectName = try container.decodeIfPresent(String.self, forKey: .objectName) ?? ""
        initialX = try container.decodeIfPresent(Double.self, forKey: .initialX) ?? 0.5
        initialY = try container.decodeIfPresent(Double.self, forKey: .initialY) ?? 0.62
        initialState = try container.decodeIfPresent(String.self, forKey: .initialState) ?? "default"
        enterFrame = try container.decodeIfPresent(Int.self, forKey: .enterFrame) ?? 0
        exitFrame = try container.decodeIfPresent(Int.self, forKey: .exitFrame)
        zOrder = try container.decodeIfPresent(Int.self, forKey: .zOrder) ?? 0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        attachmentTarget = try container.decodeIfPresent(String.self, forKey: .attachmentTarget)
        imagePaths = try container.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        approvedImagePath = try container.decodeIfPresent(String.self, forKey: .approvedImagePath)
        stateImagePaths = try container.decodeIfPresent([String: String].self, forKey: .stateImagePaths) ?? [:]
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    var resolvedApprovedImagePath: String? {
        approvedImagePath ?? imagePaths.first
    }
}
