/// ProjectPaths — single source of truth for project-relative URLs.
///
/// All accessors reflect the **current** on-disk layout.
/// Accessors annotated `/// Wave E target:` will be re-pointed after the
/// corresponding directory migration is complete.
///
/// Usage:
/// ```swift
/// let paths = ProjectPaths(root: projectURL)
/// let dir = paths.mixExports          // <project>/Mix/exports/
/// let rig = paths.characterRigJSON(slug: "luke")  // <project>/Animate/characters/luke/rig.json
/// ```
public struct ProjectPaths: Sendable {

    // MARK: - Root

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Top-level directories

    /// `<project>/Songs/`
    public var songs: URL {
        root.appendingPathComponent("Songs", isDirectory: true)
    }

    /// `<project>/Metadata/`
    public var metadata: URL {
        root.appendingPathComponent("Metadata", isDirectory: true)
    }

    /// `<project>/Characters/`
    public var characters: URL {
        root.appendingPathComponent("Characters", isDirectory: true)
    }

    /// `<project>/Synopsis/`
    public var synopsis: URL {
        root.appendingPathComponent("Synopsis", isDirectory: true)
    }

    /// `<project>/Write/`
    public var write: URL {
        root.appendingPathComponent("Write", isDirectory: true)
    }

    /// `<project>/Mix/`
    public var mix: URL {
        root.appendingPathComponent("Mix", isDirectory: true)
    }

    /// `<project>/Mixes/`  (legacy browser root)
    public var mixes: URL {
        root.appendingPathComponent("Mixes", isDirectory: true)
    }

    /// `<project>/Suno/`
    /// Wave E target: keep as-is (canonical Suno generation output)
    public var suno: URL {
        root.appendingPathComponent("Suno", isDirectory: true)
    }

    /// `<project>/SunoRenders/`
    public var sunoRenders: URL {
        root.appendingPathComponent("SunoRenders", isDirectory: true)
    }

    /// `<project>/SoundFonts/`
    public var soundFonts: URL {
        root.appendingPathComponent("SoundFonts", isDirectory: true)
    }

    /// `<project>/ChatHistory/`
    public var chatHistory: URL {
        root.appendingPathComponent("ChatHistory", isDirectory: true)
    }

    /// `<project>/config/`
    public var config: URL {
        root.appendingPathComponent("config", isDirectory: true)
    }

    /// `<project>/.novotro/`  (SQLite database directory)
    public var novotroDir: URL {
        root.appendingPathComponent(".novotro", isDirectory: true)
    }

    /// `<project>/Animate/`
    public var animate: URL {
        root.appendingPathComponent("Animate", isDirectory: true)
    }

    // MARK: - Well-known files

    /// `<project>/Metadata/project.json`
    public var projectJSON: URL {
        metadata.appendingPathComponent("project.json")
    }

    /// `<project>/project.json`  (legacy root-level fallback)
    public var legacyProjectJSON: URL {
        root.appendingPathComponent("project.json")
    }

    /// `<project>/Instruments.json`
    public var instrumentsJSON: URL {
        root.appendingPathComponent("Instruments.json")
    }

    /// `<project>/index.json`
    public var indexJSON: URL {
        root.appendingPathComponent("index.json")
    }

    /// `<project>/characters.json`  (root-level legacy; canonical is Characters/characters.json)
    public var legacyCharactersJSON: URL {
        root.appendingPathComponent("characters.json")
    }

    /// `<project>/Characters/characters.json`
    public var charactersJSON: URL {
        characters.appendingPathComponent("characters.json")
    }

    /// `<project>/Synopsis/synopsis.txt`
    public var synopsisTxt: URL {
        synopsis.appendingPathComponent("synopsis.txt")
    }

    /// `<project>/Write/libretto-scratchpad.txt`
    public var librettoScratchpad: URL {
        write.appendingPathComponent("libretto-scratchpad.txt")
    }

    /// `<project>/config/api-credentials.json`
    public var apiCredentialsJSON: URL {
        config.appendingPathComponent("api-credentials.json")
    }

    /// `<project>/.novotro/project.sqlite`
    public var projectSQLite: URL {
        novotroDir.appendingPathComponent("project.sqlite")
    }

    // MARK: - Mix

    /// `<project>/Mix/exports/`
    /// Wave E target: keep as-is
    public var mixExports: URL {
        mix.appendingPathComponent("exports", isDirectory: true)
    }

    /// `<project>/Metadata/mix_session.json`
    public var mixSessionJSON: URL {
        metadata.appendingPathComponent("mix_session.json")
    }

    // MARK: - Suno per-song directory

    /// `<project>/Suno/<baseTitle>/`
    public func sunoSongDir(baseTitle: String) -> URL {
        suno.appendingPathComponent(baseTitle, isDirectory: true)
    }

    /// `<project>/SunoRenders/render-<uuid>/`
    public func sunoRenderDir(renderID: String) -> URL {
        sunoRenders.appendingPathComponent("render-\(renderID)", isDirectory: true)
    }

    // MARK: - Animate top-level files

    /// `<project>/Animate/animate.json`
    public var animateJSON: URL {
        animate.appendingPathComponent("animate.json")
    }

    /// `<project>/Animate/scenes.json`
    public var animateScenesJSON: URL {
        animate.appendingPathComponent("scenes.json")
    }

    /// `<project>/Animate/places.json`
    public var animatePlacesJSON: URL {
        animate.appendingPathComponent("places.json")
    }

    /// `<project>/Animate/places-workflow.json`
    public var animatePlacesWorkflowJSON: URL {
        animate.appendingPathComponent("places-workflow.json")
    }

    /// `<project>/Animate/places-generated-review-state.json`
    public var animatePlacesGeneratedReviewStateJSON: URL {
        animate.appendingPathComponent("places-generated-review-state.json")
    }

    /// `<project>/Animate/places-generated-review-events.jsonl`
    public var animatePlacesGeneratedReviewEventsJSONL: URL {
        animate.appendingPathComponent("places-generated-review-events.jsonl")
    }

    /// `<project>/Animate/places-world-map-canon.json`
    public var animatePlacesWorldMapCanonJSON: URL {
        animate.appendingPathComponent("places-world-map-canon.json")
    }

    /// `<project>/Animate/character-package-selections.json`
    public var animateCharacterPackageSelectionsJSON: URL {
        animate.appendingPathComponent("character-package-selections.json")
    }

    /// `<project>/Animate/shot-presets.json`
    public var animateShotPresetsJSON: URL {
        animate.appendingPathComponent("shot-presets.json")
    }

    /// `<project>/Animate/imagine/gemini-switch.json`
    public var animateGeminiSwitchJSON: URL {
        animateImagine.appendingPathComponent("gemini-switch.json")
    }

    /// `<project>/animate/drawThingsPlacesConfig.json`  (lowercase animate — legacy 3D stub path)
    public var animateDrawThingsPlacesConfigJSON: URL {
        root.appendingPathComponent("animate/drawThingsPlacesConfig.json")
    }

    // MARK: - Animate subdirectories

    /// `<project>/Animate/characters/`
    public var animateCharacters: URL {
        animate.appendingPathComponent("characters", isDirectory: true)
    }

    /// `<project>/Animate/backgrounds/`
    public var animateBackgrounds: URL {
        animate.appendingPathComponent("backgrounds", isDirectory: true)
    }

    /// `<project>/Animate/backgrounds/place-batches/`
    public var animatePlaceBatches: URL {
        animateBackgrounds.appendingPathComponent("place-batches", isDirectory: true)
    }

    /// `<project>/Animate/backgrounds/library-edits/`
    public var animateBackgroundLibraryEdits: URL {
        animateBackgrounds.appendingPathComponent("library-edits", isDirectory: true)
    }

    /// `<project>/Animate/imagine/`
    public var animateImagine: URL {
        animate.appendingPathComponent("imagine", isDirectory: true)
    }

    /// `<project>/Animate/props/`
    public var animateProps: URL {
        animate.appendingPathComponent("props", isDirectory: true)
    }

    /// `<project>/Animate/objects/`
    public var animateObjects: URL {
        animate.appendingPathComponent("objects", isDirectory: true)
    }

    /// `<project>/Animate/dialogue-audio/`
    public var animateDialogueAudio: URL {
        animate.appendingPathComponent("dialogue-audio", isDirectory: true)
    }

    /// `<project>/Animate/motion-clips/`
    public var animateMotionClips: URL {
        animate.appendingPathComponent("motion-clips", isDirectory: true)
    }

    /// `<project>/Animate/debug/canvas/`
    /// Wave E target: `<project>/Canvas/`
    public var animateCanvasDir: URL {
        animate.appendingPathComponent("debug/canvas", isDirectory: true)
    }

    /// `<project>/Animate/debug/canvas/_index.json`
    /// Wave E target: move with canvasDir
    public var animateCanvasIndexJSON: URL {
        animateCanvasDir.appendingPathComponent("_index.json")
    }

    /// `<project>/Animate/audio/`  (archived)
    public var animateAudio: URL {
        animate.appendingPathComponent("audio", isDirectory: true)
    }

    /// `<project>/Animate/motions/`  (archived)
    public var animateMotions: URL {
        animate.appendingPathComponent("motions", isDirectory: true)
    }

    // MARK: - Animate/3d  (archived)

    /// `<project>/Animate/3d/`  (archived)
    public var animate3d: URL {
        animate.appendingPathComponent("3d", isDirectory: true)
    }

    /// `<project>/Animate/3d/registry-index.json`  (archived)
    public var animate3dRegistryIndexJSON: URL {
        animate3d.appendingPathComponent("registry-index.json")
    }

    /// `<project>/Animate/3d/world-catalog/world-catalog.json`  (archived)
    public var animate3dWorldCatalogJSON: URL {
        animate3d.appendingPathComponent("world-catalog/world-catalog.json")
    }

    // MARK: - Per-character paths (parameterized)

    /// `<project>/Animate/characters/<slug>/`
    public func characterFolder(slug: String) -> URL {
        animateCharacters.appendingPathComponent(slug, isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/rig.json`
    public func characterRigJSON(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("rig.json")
    }

    /// `<project>/Animate/characters/<slug>/parts/`
    public func characterParts(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("parts", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/lora/`
    public func characterLora(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("lora", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/inspiration/`
    public func characterInspiration(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("inspiration", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/inspiration-batches/`
    public func characterInspirationBatches(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("inspiration-batches", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/reference/`
    public func characterReference(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/reference-workflow/`
    public func characterReferenceWorkflow(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference-workflow", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/reference-workflow-batches/`
    public func characterReferenceWorkflowBatches(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference-workflow-batches", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/profile-staging/`
    public func characterProfileStaging(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("profile-staging", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/profile/`
    public func characterProfile(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("profile", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/motions/`
    public func characterMotions(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("motions", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/packages/`
    public func characterPackages(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("packages", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/backups/`
    public func characterBackups(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("backups", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/action-images/`
    public func characterActionImages(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("action-images", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/animated/`
    public func characterAnimated(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("animated", isDirectory: true)
    }

    /// `<project>/Animate/characters/<slug>/inspiration-gallery-state.json`
    public func characterInspirationGalleryStateJSON(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("inspiration-gallery-state.json")
    }

    // MARK: - NLA motion timeline (per-scene)

    /// `<project>/Animate/motion-timeline-<sceneID>.json`
    public func animateMotionTimelineJSON(sceneID: String) -> URL {
        animate.appendingPathComponent("motion-timeline-\(sceneID).json")
    }

    // MARK: - Songs per-song lyric iterations

    /// `<project>/Songs/<songDir>/<songName>.lyric-iterations/`
    /// The folder lives next to the `.ows` file.
    public func songLyricIterationsFolder(songPath: String) -> URL {
        let nsPath = songPath as NSString
        let dir = nsPath.deletingLastPathComponent
        let name = (nsPath.lastPathComponent as NSString).deletingPathExtension
        let folderName = "\(name).lyric-iterations"
        if dir.isEmpty || dir == "." {
            return songs.appendingPathComponent(folderName, isDirectory: true)
        }
        return songs.appendingPathComponent(dir, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }
}
