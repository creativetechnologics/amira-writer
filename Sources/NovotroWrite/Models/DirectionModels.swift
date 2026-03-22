import Foundation

// MARK: - Direction Address

/// Hierarchical numbering for a direction/shot: act.scene.subsection.direction
/// Example: 1.09.0.001
///
/// The numbering scheme extends the opera's structural hierarchy:
/// - `act`: Act number (1-based)
/// - `scene`: Scene within the act (1-based, zero-padded to 2 digits)
/// - `subsection`: Subsection within the scene (0 = no subsection)
/// - `direction`: Sequential direction/shot number (1-based, zero-padded to 3 digits)
struct DirectionAddress: Codable, Hashable, Comparable, Sendable {
    var act: Int
    var scene: Int
    var subsection: Int
    var direction: Int

    /// Canonical display string: "1.09.0.001"
    var displayString: String {
        String(format: "%d.%02d.%d.%03d", act, scene, subsection, direction)
    }

    /// Short label without the direction number: "1.09.0"
    var scenePrefix: String {
        String(format: "%d.%02d.%d", act, scene, subsection)
    }

    static func < (lhs: DirectionAddress, rhs: DirectionAddress) -> Bool {
        if lhs.act != rhs.act { return lhs.act < rhs.act }
        if lhs.scene != rhs.scene { return lhs.scene < rhs.scene }
        if lhs.subsection != rhs.subsection { return lhs.subsection < rhs.subsection }
        return lhs.direction < rhs.direction
    }

    init(act: Int = 1, scene: Int = 1, subsection: Int = 0, direction: Int = 1) {
        self.act = max(1, act)
        self.scene = max(1, scene)
        self.subsection = max(0, subsection)
        self.direction = max(1, direction)
    }
}

// MARK: - Storyboard Direction

/// A single parsed direction/shot extracted from lyrics markup.
///
/// Directions are embedded inline in song lyrics using double-bracket markup:
/// `[[1.09.0.001 - Wide shot of the marketplace]]`
///
/// The lyrics text is the single source of truth; these parsed objects are
/// cached in ProjectStore for efficient UI consumption.
struct StoryboardDirection: Identifiable, Hashable, Sendable {
    let id: UUID
    var address: DirectionAddress
    var descriptionText: String
    var songPath: String

    /// The raw markup string: "[[1.09.0.001 - Description text]]"
    var rawMarkup: String {
        "[[\(address.displayString) - \(descriptionText)]]"
    }

    /// Short display label: "001 - Description text"
    var shortLabel: String {
        String(format: "%03d - %@", address.direction, descriptionText)
    }

    init(
        id: UUID = UUID(),
        address: DirectionAddress,
        descriptionText: String,
        songPath: String
    ) {
        self.id = id
        self.address = address
        self.descriptionText = descriptionText
        self.songPath = songPath
    }
}

// MARK: - Song Scene Assignment

/// Per-song metadata mapping a song to its position in the opera structure.
///
/// Stored at the project level in `Metadata/scene_assignments.json` because
/// act/scene numbering describes the song's role in the overall opera, which
/// may change during re-ordering without modifying the song's content.
struct SongSceneAssignment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var songPath: String
    var act: Int
    var scene: Int
    var subsection: Int

    init(
        id: UUID = UUID(),
        songPath: String,
        act: Int = 1,
        scene: Int = 1,
        subsection: Int = 0
    ) {
        self.id = id
        self.songPath = songPath
        self.act = max(1, act)
        self.scene = max(1, scene)
        self.subsection = max(0, subsection)
    }
}

/// Wrapper for serializing scene assignments to JSON.
struct SceneAssignmentsFile: Codable {
    var version: Int
    var assignments: [SongSceneAssignment]

    init(version: Int = 1, assignments: [SongSceneAssignment] = []) {
        self.version = version
        self.assignments = assignments
    }
}

// MARK: - Direction Group (Hierarchy)

/// Grouping structure for hierarchical sidebar display on the Storyboard page.
///
/// Directions are grouped into a tree: Act > Scene > Subsection > Directions.
/// Used by `StoryboardSidebarView` to render a collapsible outline.
struct DirectionGroup: Identifiable {
    let id: String
    let label: String
    let songPath: String?
    var children: [DirectionGroup]
    var directions: [StoryboardDirection]

    /// Total direction count including all children recursively.
    var totalDirectionCount: Int {
        directions.count + children.reduce(0) { $0 + $1.totalDirectionCount }
    }

    init(
        id: String,
        label: String,
        songPath: String? = nil,
        children: [DirectionGroup] = [],
        directions: [StoryboardDirection] = []
    ) {
        self.id = id
        self.label = label
        self.songPath = songPath
        self.children = children
        self.directions = directions
    }
}

// MARK: - Storyboard Image

/// A single generated or imported storyboard frame image.
///
/// Images are stored on disk in the OWP package at:
/// `Storyboard/images/<address>/<filename>`
///
/// The `addressKey` is the stable identifier (`DirectionAddress.displayString`)
/// that persists across sessions. Direction UUIDs are ephemeral (reparsed each
/// session), so all image linkage uses the address string.
struct StoryboardImage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var addressKey: String           // e.g. "1.09.0.001" — stable across sessions
    var filename: String             // e.g. "v1_seed42.png"
    var isSelected: Bool             // the chosen frame for the storyboard
    var generationPrompt: String?    // prompt sent to Draw Things
    var generationSeed: Int?         // seed for reproducibility
    var createdAt: Date

    init(
        id: UUID = UUID(),
        addressKey: String,
        filename: String,
        isSelected: Bool = false,
        generationPrompt: String? = nil,
        generationSeed: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.addressKey = addressKey
        self.filename = filename
        self.isSelected = isSelected
        self.generationPrompt = generationPrompt
        self.generationSeed = generationSeed
        self.createdAt = createdAt
    }
}

// MARK: - Draw Things Configuration

/// Configuration for the Draw Things local API integration.
struct DrawThingsConfig: Codable, Hashable, Sendable {
    var apiHost: String
    var apiPort: Int
    var defaultWidth: Int
    var defaultHeight: Int
    var defaultSteps: Int?           // nil = use Draw Things UI setting
    var defaultNegativePrompt: String
    var globalPromptPrefix: String   // e.g. "oil painting style, opera stage,"
    var globalPromptSuffix: String

    init(
        apiHost: String = "http://localhost",
        apiPort: Int = 7860,
        defaultWidth: Int = 1024,
        defaultHeight: Int = 576,
        defaultSteps: Int? = nil,
        defaultNegativePrompt: String = "",
        globalPromptPrefix: String = "",
        globalPromptSuffix: String = ""
    ) {
        self.apiHost = apiHost
        self.apiPort = apiPort
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.defaultSteps = defaultSteps
        self.defaultNegativePrompt = defaultNegativePrompt
        self.globalPromptPrefix = globalPromptPrefix
        self.globalPromptSuffix = globalPromptSuffix
    }

    var baseURL: String {
        "\(apiHost):\(apiPort)"
    }
}

// MARK: - Storyboard Manifest

/// Top-level manifest for all storyboard data in a project.
///
/// Stored at `Storyboard/storyboard.json` in the OWP package.
/// Contains image metadata and Draw Things configuration.
struct StoryboardManifest: Codable, Sendable {
    var version: Int
    var images: [StoryboardImage]
    var drawThingsConfig: DrawThingsConfig

    init(
        version: Int = 1,
        images: [StoryboardImage] = [],
        drawThingsConfig: DrawThingsConfig = .init()
    ) {
        self.version = version
        self.images = images
        self.drawThingsConfig = drawThingsConfig
    }

    /// All images for a given direction address.
    func images(forAddressKey key: String) -> [StoryboardImage] {
        images.filter { $0.addressKey == key }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The selected (chosen) image for a direction address, or nil.
    func selectedImage(forAddressKey key: String) -> StoryboardImage? {
        images.first { $0.addressKey == key && $0.isSelected }
            ?? images(forAddressKey: key).last
    }

    /// Set of all address keys that have at least one image.
    var addressKeysWithImages: Set<String> {
        Set(images.map(\.addressKey))
    }
}

// MARK: - Shot Timing

/// Computed timing information for a single direction/shot.
///
/// Calculated from the direction's position in the lyrics relative to the
/// MIDI tempo map. Duration is the time between this direction and the next
/// one (or end of song).
struct ShotTiming: Sendable {
    var startTick: Int
    var endTick: Int
    var durationTicks: Int
    var durationSeconds: Double
    var songPath: String

    var formattedDuration: String {
        if durationSeconds < 60 {
            return String(format: "%.1fs", durationSeconds)
        } else {
            let minutes = Int(durationSeconds) / 60
            let seconds = durationSeconds - Double(minutes * 60)
            return String(format: "%d:%04.1f", minutes, seconds)
        }
    }
}
