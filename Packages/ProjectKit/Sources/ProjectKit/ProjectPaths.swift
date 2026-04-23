/// ProjectPaths — single source of truth for project-relative URLs.
///
/// Post–Wave D/E layout. Accessors named with historical `animate*` or legacy
/// prefixes are retained for API stability but repointed to the canonical
/// post-migration locations (Characters/, Scenes/, Places/, Canvas/, Settings/,
/// _Archive/). Prefer the short-form accessors (`characters`, `scenes`,
/// `places`, `canvas`, `settings`, `archive`) for new call sites.
///
/// Usage:
/// ```swift
/// let paths = ProjectPaths(root: projectURL)
/// let dir = paths.mixExports          // <project>/Mix/exports/
/// let rig = paths.characterRigJSON(slug: "luke")  // <project>/Characters/luke/rig.json
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

    /// `<project>/Synopsis/` (legacy retired folder; synopsis now lives in embedded OWS blocks)
    @available(*, deprecated, message: "Synopsis/ is retired; synopsis now lives in embedded {{{SYNOPSIS}}} blocks in Songs/*.ows.")
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

    /// `<project>/Suno/`  (canonical Suno generation output)
    public var suno: URL {
        root.appendingPathComponent("Suno", isDirectory: true)
    }

    /// `<project>/Suno/covers/`  (Wave E target for cover WAV routing)
    public var sunoCovers: URL {
        suno.appendingPathComponent("covers", isDirectory: true)
    }

    /// `<project>/Suno/logs/`  (Wave E target for Suno CLI log output)
    public var sunoLogs: URL {
        suno.appendingPathComponent("logs", isDirectory: true)
    }

    /// `<project>/SunoRenders/`  (legacy; dead after Wave D — use `sunoCovers` for new work)
    @available(*, deprecated, message: "Use sunoCovers. SunoRenders/ was unused on disk at Wave D.")
    public var sunoRenders: URL {
        root.appendingPathComponent("SunoRenders", isDirectory: true)
    }

    /// `<project>/Scenes/`  (scenes.json + imagine/ — Wave D target)
    public var scenes: URL {
        root.appendingPathComponent("Scenes", isDirectory: true)
    }

    /// `<project>/Places/`  (places-*.json family — Wave D target)
    public var places: URL {
        root.appendingPathComponent("Places", isDirectory: true)
    }

    /// `<project>/Canvas/`  (free-form image generation canvas — Wave E target)
    public var canvas: URL {
        root.appendingPathComponent("Canvas", isDirectory: true)
    }

    /// `<project>/Settings/`  (project-settings.json + instruments.json + api-credentials.json)
    public var settings: URL {
        root.appendingPathComponent("Settings", isDirectory: true)
    }

    /// `<project>/_Archive/`  (retired/archived data)
    public var archive: URL {
        root.appendingPathComponent("_Archive", isDirectory: true)
    }

    /// `<project>/SoundFonts/`
    public var soundFonts: URL {
        root.appendingPathComponent("SoundFonts", isDirectory: true)
    }

    /// `<project>/ChatHistory/`
    public var chatHistory: URL {
        root.appendingPathComponent("ChatHistory", isDirectory: true)
    }

    /// `<project>/config/`  (Wave D: directory removed — api-credentials.json now in `settings`)
    @available(*, deprecated, message: "config/ was removed in Wave D; credentials moved to Settings/.")
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

    /// `<project>/Settings/instruments.json`  (Wave D: moved from root Instruments.json)
    public var instrumentsJSON: URL {
        settings.appendingPathComponent("instruments.json")
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

    /// `<project>/Synopsis/synopsis.txt` (legacy retired file; synopsis now lives in embedded OWS blocks)
    @available(*, deprecated, message: "Synopsis/synopsis.txt is retired; synopsis now lives in embedded {{{SYNOPSIS}}} blocks in Songs/*.ows.")
    public var synopsisTxt: URL {
        synopsis.appendingPathComponent("synopsis.txt")
    }

    /// `<project>/Write/libretto-scratchpad.txt`
    public var librettoScratchpad: URL {
        write.appendingPathComponent("libretto-scratchpad.txt")
    }

    /// `<project>/Settings/api-credentials.json`  (Wave D: moved from config/)
    public var apiCredentialsJSON: URL {
        settings.appendingPathComponent("api-credentials.json")
    }

    /// `<project>/Settings/animated-look-prompt.json`
    public var animatedLookPromptJSON: URL {
        settings.appendingPathComponent("animated-look-prompt.json")
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

    /// `<project>/Scenes/scenes.json`  (Wave D: moved from Animate/)
    public var animateScenesJSON: URL {
        scenes.appendingPathComponent("scenes.json")
    }

    /// `<project>/Places/places.json`  (Wave D: moved from Animate/)
    public var animatePlacesJSON: URL {
        places.appendingPathComponent("places.json")
    }

    /// `<project>/Places/places-workflow.json`  (Wave D: moved from Animate/)
    public var animatePlacesWorkflowJSON: URL {
        places.appendingPathComponent("places-workflow.json")
    }

    /// `<project>/Places/places-generated-review-state.json`  (Wave D: moved from Animate/)
    public var animatePlacesGeneratedReviewStateJSON: URL {
        places.appendingPathComponent("places-generated-review-state.json")
    }

    /// `<project>/Places/places-generated-review-events.jsonl`  (Wave D: moved from Animate/)
    public var animatePlacesGeneratedReviewEventsJSONL: URL {
        places.appendingPathComponent("places-generated-review-events.jsonl")
    }

    /// `<project>/Places/places-world-map-canon.json`  (Wave D: moved from Animate/)
    public var animatePlacesWorldMapCanonJSON: URL {
        places.appendingPathComponent("places-world-map-canon.json")
    }

    /// `<project>/Places/places-world-context.json`  (Wave D: moved from Animate/)
    public var placesWorldContextJSON: URL {
        places.appendingPathComponent("places-world-context.json")
    }

    /// `<project>/Places/places-master-map-layers.json`  (Wave D: moved from Animate/)
    public var placesMasterMapLayersJSON: URL {
        places.appendingPathComponent("places-master-map-layers.json")
    }

    /// `<project>/Places/places.people_briefs.json`  (Wave D: moved from Animate/)
    public var placesPeopleBriefsJSON: URL {
        places.appendingPathComponent("places.people_briefs.json")
    }

    /// `<project>/Places/draw-things-places.json`  (Wave D: moved from Animate/)
    public var drawThingsPlacesJSON: URL {
        places.appendingPathComponent("draw-things-places.json")
    }

    /// `<project>/Animate/character-package-selections.json`
    public var animateCharacterPackageSelectionsJSON: URL {
        animate.appendingPathComponent("character-package-selections.json")
    }

    /// `<project>/Animate/shot-presets.json`
    public var animateShotPresetsJSON: URL {
        animate.appendingPathComponent("shot-presets.json")
    }

    /// `<project>/Scenes/imagine/gemini-switch.json`  (auto-follows `animateImagine` repoint)
    public var animateGeminiSwitchJSON: URL {
        animateImagine.appendingPathComponent("gemini-switch.json")
    }

    /// `<project>/Places/drawThingsPlacesConfig.json`  (Wave D: moved from Animate/)
    public var animateDrawThingsPlacesConfigJSON: URL {
        places.appendingPathComponent("drawThingsPlacesConfig.json")
    }

    // MARK: - Animate subdirectories

    /// `<project>/Characters/`  (Wave D: moved from Animate/characters/ — alias to `characters`)
    public var animateCharacters: URL {
        characters
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

    /// `<project>/Scenes/imagine/`  (Wave D: moved from Animate/imagine/)
    public var animateImagine: URL {
        scenes.appendingPathComponent("imagine", isDirectory: true)
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

    /// `<project>/Canvas/`  (Wave E: promoted to top-level from Animate/debug/canvas)
    public var animateCanvasDir: URL {
        canvas
    }

    /// `<project>/Canvas/_index.json`  (auto-follows `animateCanvasDir` repoint)
    public var animateCanvasIndexJSON: URL {
        animateCanvasDir.appendingPathComponent("_index.json")
    }

    /// `<project>/_Archive/Animate-audio/`  (Wave D: archived from Animate/audio/)
    public var animateAudio: URL {
        archive.appendingPathComponent("Animate-audio", isDirectory: true)
    }

    /// `<project>/Animate/motions/`  (archived)
    public var animateMotions: URL {
        animate.appendingPathComponent("motions", isDirectory: true)
    }

    // MARK: - Animate/3d  (archived)

    /// `<project>/_Archive/Animate-3d/`  (Wave D: archived from Animate/3d/)
    public var animate3d: URL {
        archive.appendingPathComponent("Animate-3d", isDirectory: true)
    }

    /// `<project>/Animate/3d/registry-index.json`  (archived)
    public var animate3dRegistryIndexJSON: URL {
        animate3d.appendingPathComponent("registry-index.json")
    }

    /// `<project>/Animate/3d/world-catalog/world-catalog.json`  (archived)
    public var animate3dWorldCatalogJSON: URL {
        animate3d.appendingPathComponent("world-catalog/world-catalog.json")
    }

    // MARK: - Per-character paths (parameterized) — all under `<project>/Characters/<slug>/` post-Wave-D

    /// `<project>/Characters/<slug>/`
    public func characterFolder(slug: String) -> URL {
        characters.appendingPathComponent(slug, isDirectory: true)
    }

    /// `<project>/Characters/<slug>/rig.json`
    public func characterRigJSON(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("rig.json")
    }

    /// `<project>/Characters/<slug>/parts/`
    public func characterParts(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("parts", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/inspiration/`
    public func characterInspiration(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("inspiration", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/inspiration-batches/`
    public func characterInspirationBatches(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("inspiration-batches", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/reference/`
    public func characterReference(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/reference-workflow/`
    public func characterReferenceWorkflow(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference-workflow", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/reference-workflow-batches/`
    public func characterReferenceWorkflowBatches(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("reference-workflow-batches", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/profile-staging/`
    public func characterProfileStaging(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("profile-staging", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/profile/`
    public func characterProfile(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("profile", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/motions/`
    public func characterMotions(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("motions", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/packages/`
    public func characterPackages(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("packages", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/backups/`
    public func characterBackups(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("backups", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/action-images/`
    public func characterActionImages(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("action-images", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/animated/`
    public func characterAnimated(slug: String) -> URL {
        characterFolder(slug: slug).appendingPathComponent("animated", isDirectory: true)
    }

    /// `<project>/Characters/<slug>/inspiration-gallery-state.json`
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
