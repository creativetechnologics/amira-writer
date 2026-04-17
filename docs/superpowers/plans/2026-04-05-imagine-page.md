# Imagine Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new top-level "Imagine" page to Opera with Characters and Scenes sub-pages for AI image generation, galleries, and bulk workflows using DrawThings and Gemini.

**Architecture:** Imagine is a new `OperaMode` that shares the existing `AnimateWorkspaceController`/`AnimateStore`. It has two sub-pages — Characters (moved inspiration/profile sections from the current Characters page) and Scenes (scene sidebar + shot timeline + Beginning/Middle/End galleries). Image generation uses existing `DrawThingsPlaceGenerationService`, `GeminiImageService`, and `MiniMaxPromptService`. A new universal image picker modal enables cross-page image selection. All generated images save to project directories under `Animate/imagine/` so they auto-appear in galleries.

**Tech Stack:** SwiftUI (macOS 26.0+), `@Observable`/`@Bindable` pattern via `AnimateStore`, Draw Things HTTP API, Gemini REST API, MiniMax REST API, `ProjectDatabaseBridge` for persistence.

---

## Delegation & Retry Policy

Tasks are delegated via OpenCode to external providers. If a dispatch fails:

0. **INVESTIGATE FIRST:** Run `opencode_health`, check `ps aux | grep opencode` for stuck processes (git snapshots, port contention). Wait for transient issues to resolve. Only proceed to retries once root cause is understood or server is confirmed healthy.
1. **Retry 1:** Re-dispatch to the SAME provider/model with a simplified or clarified prompt.
2. **Retry 2:** Re-dispatch to an ALTERNATIVE provider (e.g., MiniMax failed → try GPT 5.4 Mini; GPT failed → try MiniMax).
3. **Fallback:** Only after both retries fail, fall back to a local Claude subagent (Sonnet or Haiku).

Provider routing:
- **MiniMax M2.7** — simple new files, mechanical tasks (1-2 files, clear spec)
- **GPT 5.3 Codex** — complex modifications to existing files, multi-file integration
- **GPT 5.4** — code review only (after all tasks complete)
- **Opus** — orchestration only, never implementation

---

## File Map

### New Files (Create)

| File | Responsibility |
|------|---------------|
| `Packages/Animate/Sources/AnimateUI/ImagineWorkspace.swift` | Public `ImagineWorkspace` view + private `ImagineWorkspaceContent` — top-level shell with Characters/Scenes tab picker, sidebar, inspector |
| `Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift` | Imagine > Characters sub-page — character sidebar, profile header, inspiration gallery, Gemini generation controls (moved from CharactersPageView) |
| `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift` | Imagine > Scenes sub-page — scene sidebar, shot timeline strip, large preview, B/M/E tab galleries, pinned generation controls |
| `Packages/Animate/Sources/AnimateUI/Views/ImagineSceneShotGalleryView.swift` | Reusable gallery grid for one shot's Beginning/Middle/End images — thumbnail grid with selection, right-click, drag, import |
| `Packages/Animate/Sources/AnimateUI/Views/UniversalImagePickerSheet.swift` | Hierarchical image browser modal — top-level categories (Imagine, Characters, Places, Props), drill-down to thumbnails, checkbox selection, staging tray, Quick Look |
| `Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift` | Inspector pane for Imagine — Tools tab (Gemini master switch), Bulk tab (DrawThings bulk generation config), Properties tab |
| `Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift` | Data models: `ImagineSceneShotGallery` (B/M/E paths per shot), `ImaginePage` enum, `ImagineDrawThingsModel` enum, `ImagineBulkRunConfig` |
| `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift` | MiniMax-powered auto-prompt generation for scenes — builds rich descriptive prompts from script context, characters, settings, camera angles |
| `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift` | Orchestrator for both DrawThings and Gemini scene image generation — routes to correct service, saves to correct project directory, handles bulk runs |
| `Packages/Animate/Sources/AnimateUI/Services/ImagineProjectStorage.swift` | File I/O for imagine galleries — directory creation, image scanning, gallery JSON persistence, Finder reveal |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/Opera/OperaShellView.swift` | Add `OperaMode.imagine` case, route to `ImagineWorkspace`, sidebar visibility, save indicator, scene selection sync |
| `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` | Add imagine-related state: `selectedImaginePage`, `imagineSceneGalleries`, `geminiMasterSwitch`, bulk run state, gallery load/save methods |
| `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift` | Export `AnimateWorkspaceLoadOverlay` as internal (not private) so ImagineWorkspace can reuse it |
| `Packages/Animate/Sources/AnimateUI/Models/AnimatePage.swift` | No change needed — Imagine is a separate OperaMode, not an AnimatePage |
| `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift` | Remove inspiration pane, profile image picker, animated images pane, and Gemini generation controls — these move to ImagineCharactersPageView. Keep: Character Notes, Look Development, Reference Workflow, Packages, Expression Library, Motion Generation |
| `Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift` | Add load/save for imagine gallery JSON and Gemini master switch |
| `Packages/Animate/Sources/AnimateUI/Models/PlacesIndexModels.swift` | Add `ImagineDrawThingsConfig` struct (extends DrawThingsPlaceConfig with model enum for Flux.2 Klein 4B / Z-Image Turbo) |
| `Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift` | Add convenience method accepting `geminiMasterSwitch` guard — all calls check the master switch before proceeding |

---

## Task Group A: Foundation — Mode, Models, Storage

### Task 1: Add ImagineModels

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift`

- [ ] **Step 1: Create the models file**

```swift
import Foundation

// MARK: - Imagine Sub-Pages

enum ImaginePage: String, CaseIterable, Identifiable, Codable {
    case characters = "Characters"
    case scenes = "Scenes"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .characters: "person.2.fill"
        case .scenes: "film.stack"
        }
    }
}

// MARK: - Scene Shot Gallery (Beginning / Middle / End)

enum ImagineShotMoment: String, CaseIterable, Identifiable, Codable {
    case beginning = "Beginning"
    case middle = "Middle"
    case end = "End"

    var id: String { rawValue }

    var directoryName: String {
        switch self {
        case .beginning: "beginning"
        case .middle: "middle"
        case .end: "end"
        }
    }
}

struct ImagineSceneShotGallery: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var beginningImagePaths: [String] = []
    var middleImagePaths: [String] = []
    var endImagePaths: [String] = []
    var beginningPrompt: String = ""
    var middlePrompt: String = ""
    var endPrompt: String = ""
    var selectedBeginningPath: String?
    var selectedMiddlePath: String?
    var selectedEndPath: String?

    func paths(for moment: ImagineShotMoment) -> [String] {
        switch moment {
        case .beginning: beginningImagePaths
        case .middle: middleImagePaths
        case .end: endImagePaths
        }
    }

    mutating func setSelectedPath(_ path: String?, for moment: ImagineShotMoment) {
        switch moment {
        case .beginning: selectedBeginningPath = path
        case .middle: selectedMiddlePath = path
        case .end: selectedEndPath = path
        }
    }

    func selectedPath(for moment: ImagineShotMoment) -> String? {
        switch moment {
        case .beginning: selectedBeginningPath
        case .middle: selectedMiddlePath
        case .end: selectedEndPath
        }
    }

    mutating func appendPath(_ path: String, for moment: ImagineShotMoment) {
        switch moment {
        case .beginning: beginningImagePaths.append(path)
        case .middle: middleImagePaths.append(path)
        case .end: endImagePaths.append(path)
        }
    }
}

// MARK: - DrawThings Model Selection

enum ImagineDrawThingsModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case fluxKlein = "flux2_klein_4b"
    case zImageTurbo = "z_image_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fluxKlein: "Flux.2 Klein 4B"
        case .zImageTurbo: "Z-Image Turbo"
        }
    }

    /// Default step count for best quality.
    var defaultSteps: Int {
        switch self {
        case .fluxKlein: 20
        case .zImageTurbo: 8
        }
    }

    /// Default CFG scale (text adherence).
    var defaultCFGScale: Double {
        switch self {
        case .fluxKlein: 3.5
        case .zImageTurbo: 1.0
        }
    }
}

// MARK: - Bulk Run Configuration

struct ImagineBulkRunConfig: Codable, Sendable {
    var imagesPerMoment: Int = 10
    var model: ImagineDrawThingsModel = .fluxKlein
    var autoGeneratePrompts: Bool = true
    var includeBeginning: Bool = true
    var includeMiddle: Bool = true
    var includeEnd: Bool = true
    /// If nil, runs for all scenes. Otherwise, only the listed scene IDs.
    var sceneFilter: [UUID]? = nil
}

// MARK: - Bulk Run State

struct ImagineBulkRunProgress: Sendable {
    var isRunning: Bool = false
    var totalImages: Int = 0
    var completedImages: Int = 0
    var currentSceneName: String = ""
    var currentShotIndex: Int = 0
    var currentMoment: ImagineShotMoment = .beginning
    var errorMessage: String?

    var fractionComplete: Double {
        guard totalImages > 0 else { return 0 }
        return Double(completedImages) / Double(totalImages)
    }
}

// MARK: - Universal Image Picker

enum ImagineImageCategory: String, CaseIterable, Identifiable {
    case imagine = "Imagine"
    case characters = "Characters"
    case places = "Places"
    case props = "Props"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .imagine: "sparkles"
        case .characters: "person.2"
        case .places: "map"
        case .props: "shippingbox"
        }
    }
}

struct ImagineImagePickerEntry: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var categoryLabel: String
    var subcategoryLabel: String
}
```

- [ ] **Step 2: Verify the file compiles**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift
git commit -m "feat(imagine): add data models for Imagine page galleries and bulk config"
```

---

### Task 2: Add ImagineProjectStorage service

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/ImagineProjectStorage.swift`

This service handles all file I/O for the Imagine feature — creating directory structures, scanning for images, loading/saving gallery JSON.

- [ ] **Step 1: Create the storage service**

```swift
import AppKit
import Foundation

/// Manages on-disk storage for the Imagine feature.
///
/// Directory structure inside the OWP project:
/// ```
/// Animate/imagine/
///   scenes/
///     <scene-slug>/
///       shot-001/
///         beginning/   ← PNG/JPEG files
///         middle/
///         end/
///       shot-002/
///         ...
///   characters/
///     <character-slug>/
///       inspiration/   ← same as existing inspiration path
///       profile/       ← profile image
///   galleries.json     ← ImagineSceneShotGallery array
/// ```
@available(macOS 26.0, *)
struct ImagineProjectStorage {

    // MARK: - Directory Paths

    static func imagineRoot(owpURL: URL) -> URL {
        owpURL.appendingPathComponent("Animate/imagine", isDirectory: true)
    }

    static func scenesRoot(owpURL: URL) -> URL {
        imagineRoot(owpURL: owpURL).appendingPathComponent("scenes", isDirectory: true)
    }

    static func sceneDirectory(owpURL: URL, sceneSlug: String) -> URL {
        scenesRoot(owpURL: owpURL).appendingPathComponent(sceneSlug, isDirectory: true)
    }

    static func shotDirectory(owpURL: URL, sceneSlug: String, shotIndex: Int) -> URL {
        sceneDirectory(owpURL: owpURL, sceneSlug: sceneSlug)
            .appendingPathComponent("shot-\(String(format: "%03d", shotIndex + 1))", isDirectory: true)
    }

    static func momentDirectory(owpURL: URL, sceneSlug: String, shotIndex: Int, moment: ImagineShotMoment) -> URL {
        shotDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex)
            .appendingPathComponent(moment.directoryName, isDirectory: true)
    }

    // MARK: - Directory Creation

    static func ensureDirectories(owpURL: URL, sceneSlug: String, shotCount: Int) throws {
        let fm = FileManager.default
        for shotIndex in 0..<shotCount {
            for moment in ImagineShotMoment.allCases {
                let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
        }
    }

    // MARK: - Image Scanning

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tiff"]

    static func scanImages(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { (a, b) in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
            .map(\.path)
    }

    static func scanShotGallery(owpURL: URL, sceneSlug: String, shotIndex: Int, shotID: UUID, sceneID: UUID) -> ImagineSceneShotGallery {
        var gallery = ImagineSceneShotGallery(shotID: shotID, sceneID: sceneID)
        for moment in ImagineShotMoment.allCases {
            let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
            let paths = scanImages(in: dir)
            switch moment {
            case .beginning: gallery.beginningImagePaths = paths
            case .middle: gallery.middleImagePaths = paths
            case .end: gallery.endImagePaths = paths
            }
        }
        return gallery
    }

    // MARK: - Gallery JSON Persistence

    private static func galleriesJSONURL(owpURL: URL) -> URL {
        imagineRoot(owpURL: owpURL).appendingPathComponent("galleries.json")
    }

    static func loadGalleries(owpURL: URL) -> [ImagineSceneShotGallery] {
        let url = galleriesJSONURL(owpURL: owpURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ImagineSceneShotGallery].self, from: data)) ?? []
    }

    static func saveGalleries(_ galleries: [ImagineSceneShotGallery], owpURL: URL) throws {
        let url = galleriesJSONURL(owpURL: owpURL)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(galleries)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Image Save

    static func saveGeneratedImage(
        _ imageData: Data,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        filePrefix: String = "gen"
    ) throws -> URL {
        let dir = momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "\(filePrefix)_\(timestamp).png"
        let outputURL = dir.appendingPathComponent(filename)
        try imageData.write(to: outputURL)
        return outputURL
    }

    // MARK: - Finder Integration

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func revealDirectoryInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: - Import

    static func importImage(from sourceURL: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationDir.path) {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }
        let destURL = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: destURL.path) {
            // Avoid overwrite — add timestamp suffix
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let newName = "\(stem)_\(timestamp).\(ext)"
            let uniqueURL = destinationDir.appendingPathComponent(newName)
            try fm.copyItem(at: sourceURL, to: uniqueURL)
            return uniqueURL
        }
        try fm.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Universal Image Picker: Scan All Project Images

    static func scanAllProjectImages(owpURL: URL, characters: [AnimationCharacter], scenes: [AnimationScene]) -> [ImagineImageCategory: [ImagineImagePickerEntry]] {
        var result: [ImagineImageCategory: [ImagineImagePickerEntry]] = [:]

        // Imagine > Scenes
        let scenesDir = scenesRoot(owpURL: owpURL)
        var imagineEntries: [ImagineImagePickerEntry] = []
        if FileManager.default.fileExists(atPath: scenesDir.path) {
            if let sceneDirs = try? FileManager.default.contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for sceneDir in sceneDirs where sceneDir.hasDirectoryPath {
                    let sceneSlug = sceneDir.lastPathComponent
                    // Scan all shot/moment subdirectories
                    if let shotDirs = try? FileManager.default.contentsOfDirectory(at: sceneDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for shotDir in shotDirs where shotDir.hasDirectoryPath {
                            for moment in ImagineShotMoment.allCases {
                                let momentDir = shotDir.appendingPathComponent(moment.directoryName)
                                for path in scanImages(in: momentDir) {
                                    imagineEntries.append(ImagineImagePickerEntry(
                                        path: path,
                                        categoryLabel: "Scenes",
                                        subcategoryLabel: "\(sceneSlug) / \(shotDir.lastPathComponent) / \(moment.rawValue)"
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }
        result[.imagine] = imagineEntries

        // Characters — scan inspiration + animated directories
        let animateURL = owpURL.appendingPathComponent("Animate")
        var charEntries: [ImagineImagePickerEntry] = []
        for character in characters {
            let slug = character.assetFolderSlug
            let inspirationDir = animateURL.appendingPathComponent("characters/\(slug)/inspiration")
            for path in scanImages(in: inspirationDir) {
                charEntries.append(ImagineImagePickerEntry(
                    path: path,
                    categoryLabel: character.name,
                    subcategoryLabel: "Inspiration"
                ))
            }
            let animatedDir = animateURL.appendingPathComponent("characters/\(slug)/animated")
            for path in scanImages(in: animatedDir) {
                charEntries.append(ImagineImagePickerEntry(
                    path: path,
                    categoryLabel: character.name,
                    subcategoryLabel: "Animated"
                ))
            }
        }
        result[.characters] = charEntries

        // Places — scan backgrounds
        let backgroundsDir = animateURL.appendingPathComponent("backgrounds")
        var placeEntries: [ImagineImagePickerEntry] = []
        for path in scanImages(in: backgroundsDir) {
            placeEntries.append(ImagineImagePickerEntry(
                path: path,
                categoryLabel: "Backgrounds",
                subcategoryLabel: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ))
        }
        result[.places] = placeEntries

        // Props — scan props directory if it exists
        let propsDir = animateURL.appendingPathComponent("props")
        var propEntries: [ImagineImagePickerEntry] = []
        for path in scanImages(in: propsDir) {
            propEntries.append(ImagineImagePickerEntry(
                path: path,
                categoryLabel: "Props",
                subcategoryLabel: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ))
        }
        result[.props] = propEntries

        return result
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Services/ImagineProjectStorage.swift
git commit -m "feat(imagine): add project storage service for imagine galleries and image scanning"
```

---

### Task 3: Add AnimateStore imagine state

**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

Add all imagine-related state properties and methods to AnimateStore. This goes in the existing store because Imagine shares characters and scenes data.

- [ ] **Step 1: Add imagine state properties**

Find the `// MARK: - Characters` section near line 64 in AnimateStore.swift. Add a new MARK section after the Motion Capture State section (around line 80):

```swift
// MARK: - Imagine State

var selectedImaginePage: ImaginePage = .characters
var imagineSceneGalleries: [UUID: [ImagineSceneShotGallery]] = [:]  // sceneID -> galleries per shot
var imagineBulkRunConfig: ImagineBulkRunConfig = .init()
var imagineBulkRunProgress: ImagineBulkRunProgress = .init()
var geminiMasterSwitch: Bool = false  // false = Gemini API calls BLOCKED
var imagineSelectedShotIndex: Int? = nil
var imagineSelectedMoment: ImagineShotMoment = .beginning
var imaginePreviewImagePath: String? = nil
```

- [ ] **Step 2: Add imagine gallery load/save methods**

Add these methods to AnimateStore (at the end of the file, before the closing brace):

```swift
// MARK: - Imagine Gallery Management

func loadImagineGalleries() {
    guard let owpURL = fileOWPURL else { return }
    let stored = ImagineProjectStorage.loadGalleries(owpURL: owpURL)
    var byScene: [UUID: [ImagineSceneShotGallery]] = [:]
    for gallery in stored {
        byScene[gallery.sceneID, default: []].append(gallery)
    }
    imagineSceneGalleries = byScene
}

func saveImagineGalleries() {
    guard let owpURL = fileOWPURL else { return }
    let all = imagineSceneGalleries.values.flatMap { $0 }
    try? ImagineProjectStorage.saveGalleries(Array(all), owpURL: owpURL)
}

func refreshImagineGalleryFromDisk(sceneID: UUID) {
    guard let owpURL = fileOWPURL,
          let scene = scenes.first(where: { $0.id == sceneID }) else { return }
    let sceneSlug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "/", with: "-")
    var galleries: [ImagineSceneShotGallery] = []
    for (index, shot) in scene.shots.enumerated() {
        let gallery = ImagineProjectStorage.scanShotGallery(
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: index,
            shotID: shot.id,
            sceneID: sceneID
        )
        galleries.append(gallery)
    }
    imagineSceneGalleries[sceneID] = galleries
}

func ensureImagineDirectories(for sceneID: UUID) {
    guard let owpURL = fileOWPURL,
          let scene = scenes.first(where: { $0.id == sceneID }) else { return }
    let sceneSlug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "/", with: "-")
    try? ImagineProjectStorage.ensureDirectories(owpURL: owpURL, sceneSlug: sceneSlug, shotCount: scene.shots.count)
}

func imagineGallery(for sceneID: UUID, shotIndex: Int) -> ImagineSceneShotGallery? {
    guard let galleries = imagineSceneGalleries[sceneID],
          shotIndex < galleries.count else { return nil }
    return galleries[shotIndex]
}

/// Check the gemini master switch before any Gemini call. Returns true if allowed.
func isGeminiAllowed() -> Bool {
    geminiMasterSwitch
}
```

- [ ] **Step 3: Add geminiMasterSwitch persistence**

In the existing `save()` method of AnimateStore, add a call to persist the master switch. Find where `drawThingsPlaceConfig` is saved and add nearby:

```swift
try? ProjectDatabaseBridge.saveGeminiMasterSwitch(geminiMasterSwitch, projectURL: effectiveProjectURL)
```

In the OWP loading section (the `openOWP` method), add:

```swift
geminiMasterSwitch = ProjectDatabaseBridge.loadGeminiMasterSwitch(projectURL: normalizedURL) ?? false
loadImagineGalleries()
```

- [ ] **Step 4: Add ProjectDatabaseBridge methods**

In `Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift`, add:

```swift
// MARK: - Gemini Master Switch

static func saveGeminiMasterSwitch(_ enabled: Bool, projectURL: URL) throws {
    let url = projectURL.appendingPathComponent("Animate/imagine/gemini-switch.json")
    let dir = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let data = try JSONEncoder().encode(["enabled": enabled])
    try data.write(to: url, options: .atomic)
}

static func loadGeminiMasterSwitch(projectURL: URL) -> Bool? {
    let url = projectURL.appendingPathComponent("Animate/imagine/gemini-switch.json")
    guard let data = try? Data(contentsOf: url),
          let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return nil }
    return dict["enabled"]
}
```

- [ ] **Step 5: Verify compilation**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/AnimateStore.swift Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift
git commit -m "feat(imagine): add imagine state to AnimateStore with gallery load/save and Gemini master switch"
```

---

### Task 4: Add OperaMode.imagine to OperaShellView

**Files:**
- Modify: `Sources/Opera/OperaShellView.swift`

- [ ] **Step 1: Add `.imagine` case to OperaMode enum**

In the `OperaMode` enum (line 11), add the new case after `.mix`:

```swift
case imagine
```

Add to `title`:
```swift
case .imagine: return "Imagine"
```

Add to `subtitle`:
```swift
case .imagine: return "Character and scene image generation"
```

Add to `systemImage`:
```swift
case .imagine: return "sparkles"
```

- [ ] **Step 2: Route `.imagine` in activeWorkspace**

In the `activeWorkspace` ViewBuilder (around line 562), add before the `.characters` case:

```swift
case .imagine:
    ImagineWorkspace(controller: animateController)
```

- [ ] **Step 3: Add `.imagine` to load, saveIndicator, and sidebarVisible**

In the `load(mode:projectURL:)` switch (around line 816), add:
```swift
case .imagine:
    return await animateController.ensureProjectLoaded(projectURL)
```

In the `saveIndicator` switch, add:
```swift
case .imagine: return animateController.saveIndicator
```

In `loadForDisplayTransition`, add `.imagine` to the guard that checks for modes needing timeout handling:
```swift
guard mode == .animate || mode == .characters || mode == .places || mode == .props || mode == .imagine || mode == .mix else {
```

In the `sidebarVisible` binding switch, add:
```swift
case .imagine: return imagineSidebarVisible
```

Add the AppStorage property alongside the other sidebar visibility properties:
```swift
@AppStorage("novotro.imagine.sidebarVisible") private var imagineSidebarVisible: Bool = true
```

- [ ] **Step 4: Add scene selection sync for imagine**

In the `.onChange(of: animateController.selectedScenePath)` handler, ensure imagine mode is covered. The existing handler already fires for animateController changes, so no additional onChange is needed — but add `.imagine` to any switch statements that filter by mode.

- [ ] **Step 5: Handle remote command**

In the file-based remote control switch (around line 302), add:
```swift
case "imagine": selectedMode = .imagine
```

- [ ] **Step 6: Verify compilation**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'`
Expected: BUILD SUCCEEDED (even though ImagineWorkspace doesn't exist yet — add a stub first if needed)

- [ ] **Step 7: Commit**

```bash
git add Sources/Opera/OperaShellView.swift
git commit -m "feat(imagine): add OperaMode.imagine with routing, sidebar, and save indicator"
```

---

## Task Group B: Workspace Shell and Inspector

### Task 5: Create ImagineWorkspace

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/ImagineWorkspace.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift` (make `AnimateWorkspaceLoadOverlay` internal)

This follows the exact same pattern as `CharactersWorkspace`, `PlacesWorkspace`, etc.

- [ ] **Step 1: Make AnimateWorkspaceLoadOverlay internal**

In `AnimateWorkspace.swift`, change the access level of `AnimateWorkspaceLoadOverlay` from `struct` (internal by default, but it's in a `private` scope) — find `struct AnimateWorkspaceLoadOverlay` and ensure it's accessible from the same module. If it's currently unqualified (no `private`/`fileprivate`), it's already internal. If it's private, remove the `private` qualifier.

Current (around line 481):
```swift
struct AnimateWorkspaceLoadOverlay: View {
```

This is already internal — no change needed. Verify by checking if it compiles when referenced from ImagineWorkspace.

- [ ] **Step 2: Create ImagineWorkspace.swift**

```swift
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct ImagineWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            ImagineWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Imagine" : "Refreshing Imagine",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ImagineWorkspaceContent: View {
    @Bindable var store: AnimateStore

    @AppStorage("novotro.imagine.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.imagine.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.imagine.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.imagine.inspector.width") private var inspectorWidth: Double = 320

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var activeDetailTitle: String {
        switch store.selectedImaginePage {
        case .characters:
            store.selectedCharacter?.name ?? "Character image generation"
        case .scenes:
            store.selectedScene?.name ?? "Scene image generation"
        }
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "sparkles",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebarContent
                    .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IMAGINE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(activeDetailTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 6) {
                        ForEach(ImaginePage.allCases) { page in
                            OperaChromeActionButton(
                                title: page.rawValue,
                                systemImage: page.systemImage,
                                isSelected: store.selectedImaginePage == page
                            ) {
                                store.selectedImaginePage = page
                            }
                        }
                    }

                    EmptyView()
                }
            } content: {
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "IMAGINE",
                        title: "Inspector",
                        subtitle: store.selectedImaginePage.rawValue
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    ImagineInspectorView(store: store)
                }
                .frame(width: max(inspectorWidth, 250))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch store.selectedImaginePage {
        case .characters:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "IMAGINE",
                    title: "Characters",
                    subtitle: "\(store.characters.count) characters"
                ) { EmptyView() }
            } content: {
                CharactersSidebarView(store: store)
            }
        case .scenes:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "IMAGINE",
                    title: "Scenes",
                    subtitle: "\(store.scenes.count) scenes"
                ) { EmptyView() }
            } content: {
                SidebarView(store: store)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch store.selectedImaginePage {
        case .characters:
            ImagineCharactersPageView(store: store)
        case .scenes:
            ImagineScenesPageView(store: store)
        }
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 250),
            600
        )
    }
}
```

- [ ] **Step 3: Verify compilation (will fail until page views exist — create stubs)**

Create minimal stubs for `ImagineCharactersPageView`, `ImagineScenesPageView`, and `ImagineInspectorView` that just show placeholder text, then verify build.

- [ ] **Step 4: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/ImagineWorkspace.swift
git commit -m "feat(imagine): add ImagineWorkspace shell with Characters/Scenes sub-pages and sidebar"
```

---

### Task 6: Create ImagineInspectorView

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift`

The inspector has three tabs: Tools (Gemini master switch + settings), Bulk (DrawThings bulk config), Properties (selected image metadata).

- [ ] **Step 1: Create the inspector view**

```swift
import SwiftUI

@available(macOS 26.0, *)
struct ImagineInspectorView: View {
    @Bindable var store: AnimateStore

    private enum InspectorTab: String { case tools, bulk, properties }
    @AppStorage("imagine.inspector.selectedTab") private var selectedTab = InspectorTab.tools.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("Tools", tab: .tools, icon: "gearshape.fill")
                tabButton("Bulk", tab: .bulk, icon: "tray.full")
                tabButton("Properties", tab: .properties, icon: "slider.horizontal.3")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                switch InspectorTab(rawValue: selectedTab) ?? .tools {
                case .tools:
                    toolsContent
                case .bulk:
                    bulkContent
                case .properties:
                    propertiesContent
                }
            }
        }
    }

    // MARK: - Tools Tab

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Gemini Master Switch
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $store.geminiMasterSwitch) {
                        Label("Gemini API Calls", systemImage: "bolt.fill")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)

                    Text(store.geminiMasterSwitch
                         ? "Gemini API calls are ENABLED. Image generation via Gemini is allowed."
                         : "Gemini API calls are BLOCKED. No Gemini requests will be sent.")
                        .font(.caption)
                        .foregroundStyle(store.geminiMasterSwitch ? .green : .red)
                }
            } label: {
                Label("API Control", systemImage: "shield.checkered")
                    .font(.subheadline.weight(.semibold))
            }

            // DrawThings Connection
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Host") {
                        Text(store.drawThingsPlaceConfig.apiHost)
                            .font(.caption.monospaced())
                    }
                    LabeledContent("Port") {
                        Text("\(store.drawThingsPlaceConfig.apiPort)")
                            .font(.caption.monospaced())
                    }
                }
            } label: {
                Label("Draw Things", systemImage: "paintbrush.pointed")
                    .font(.subheadline.weight(.semibold))
            }

            // Gemini API Key Status
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("API Key") {
                        Text(store.geminiAPIKey.isEmpty ? "Not set" : "Configured")
                            .font(.caption)
                            .foregroundStyle(store.geminiAPIKey.isEmpty ? .red : .green)
                    }
                    LabeledContent("Model") {
                        Text(store.selectedGeminiModel.displayName)
                            .font(.caption)
                    }
                }
            } label: {
                Label("Gemini", systemImage: "sparkle")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding()
    }

    // MARK: - Bulk Tab

    private var bulkContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DrawThings Bulk Generation")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model", selection: $store.imagineBulkRunConfig.model) {
                        ForEach(ImagineDrawThingsModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }

                    Stepper("Images per moment: \(store.imagineBulkRunConfig.imagesPerMoment)",
                            value: $store.imagineBulkRunConfig.imagesPerMoment,
                            in: 1...50)

                    Toggle("Auto-generate prompts (MiniMax)", isOn: $store.imagineBulkRunConfig.autoGeneratePrompts)

                    Divider()

                    Text("Include Moments:")
                        .font(.subheadline.weight(.semibold))
                    Toggle("Beginning", isOn: $store.imagineBulkRunConfig.includeBeginning)
                    Toggle("Middle", isOn: $store.imagineBulkRunConfig.includeMiddle)
                    Toggle("End", isOn: $store.imagineBulkRunConfig.includeEnd)

                    Divider()

                    Text("Scene Filter:")
                        .font(.subheadline.weight(.semibold))
                    Text(store.imagineBulkRunConfig.sceneFilter == nil
                         ? "All scenes"
                         : "\(store.imagineBulkRunConfig.sceneFilter!.count) scenes selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Select Scenes...") {
                        // Scene filter picker — toggle between all and selected
                        if store.imagineBulkRunConfig.sceneFilter == nil {
                            store.imagineBulkRunConfig.sceneFilter = []
                        } else {
                            store.imagineBulkRunConfig.sceneFilter = nil
                        }
                    }
                    .controlSize(.small)

                    if let filter = store.imagineBulkRunConfig.sceneFilter {
                        ForEach(store.scenes) { scene in
                            Toggle(scene.name, isOn: Binding(
                                get: { filter.contains(scene.id) },
                                set: { include in
                                    if include {
                                        store.imagineBulkRunConfig.sceneFilter?.append(scene.id)
                                    } else {
                                        store.imagineBulkRunConfig.sceneFilter?.removeAll { $0 == scene.id }
                                    }
                                }
                            ))
                            .font(.caption)
                        }
                    }
                }
            }

            // Run / Progress
            if store.imagineBulkRunProgress.isRunning {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: store.imagineBulkRunProgress.fractionComplete)
                        Text("\(store.imagineBulkRunProgress.completedImages)/\(store.imagineBulkRunProgress.totalImages) images")
                            .font(.caption)
                        Text("Scene: \(store.imagineBulkRunProgress.currentSceneName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = store.imagineBulkRunProgress.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } else {
                Button {
                    startBulkRun()
                } label: {
                    Label("Start Bulk Generation", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Gemini bulk generation is NOT available here. Use the Gemini controls in the main Imagine area for the 27-scene character inspiration workflow.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Properties Tab

    private var propertiesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = store.imaginePreviewImagePath {
                Text("Selected Image")
                    .font(.headline)

                LabeledContent("Path") {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }

                Button("Show in Finder") {
                    ImagineProjectStorage.revealInFinder(path)
                }
                .controlSize(.small)
            } else {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, tab: InspectorTab, icon: String) -> some View {
        Button {
            selectedTab = tab.rawValue
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .fontWeight(selectedTab == tab.rawValue ? .semibold : .regular)
                .foregroundStyle(selectedTab == tab.rawValue ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    selectedTab == tab.rawValue
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bulk Run

    private func startBulkRun() {
        // This will be implemented in Task 12 (ImagineGenerationService)
        // For now, placeholder
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E 'error:|BUILD'`

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift
git commit -m "feat(imagine): add inspector with Tools (Gemini switch), Bulk (DrawThings config), and Properties tabs"
```

---

## Task Group C: Imagine > Characters Sub-Page

### Task 7: Create ImagineCharactersPageView

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift`

This page shows: profile image/header at top, inspiration gallery with Gemini generation controls, and the 27-scene batch inspiration workflow. It pulls from the same character data as the Characters page but ONLY shows imagine-related content.

- [ ] **Step 1: Create the characters imagine page**

```swift
import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct ImagineCharactersPageView: View {
    @Bindable var store: AnimateStore
    @State private var promptPreview: ImagePromptPreview?
    @State private var previewImageIndex: Int?
    @State private var previewImagePaths: [String] = []
    @State private var inspirationSelectedPaths: Set<String> = []
    @State private var inspirationLastClicked: String?
    @State private var thumbnailBaseSize: CGFloat = 120
    @State private var showInspirationGallery: Bool = false
    @State private var showProfileImagePicker: Bool = false
    @State private var inspirationPendingPlan: PendingInspirationGenerationPlan?
    @State private var inspirationDrafts: [GeminiGenerationDraft] = []
    @State private var inspirationActiveWardrobe: CharacterInspirationWardrobe?
    @State private var inspirationGenerationErrorMessage: String?
    @State private var inspirationGenerationStatus: String?
    @State private var inspirationStatusCharacterID: UUID?
    @State private var inspirationGenerationProgress: Double = 0
    @State private var isGeneratingInspiration: Bool = false
    @State private var generatingInspirationCharacterID: UUID?
    @State private var isSubmittingInspirationBatch: Bool = false
    @State private var submittingInspirationBatchCharacterID: UUID?

    var body: some View {
        if let character = store.selectedCharacter {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    characterHeader(character)

                    inspirationSection(character)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if let index = previewImageIndex {
                    ImagePreviewOverlay(
                        store: store,
                        paths: previewImagePaths,
                        currentIndex: Binding(
                            get: { index },
                            set: { newIndex in
                                previewImageIndex = newIndex
                            }
                        ),
                        onDismiss: { previewImageIndex = nil }
                    )
                }
            }
            .sheet(isPresented: $showProfileImagePicker) {
                if let character = store.selectedCharacter {
                    ProfileImagePickerSheet(
                        character: character,
                        store: store,
                        onChooseImagePath: { path in
                            showProfileImagePicker = false
                            if let resolvedURL = store.resolvedCharacterAssetURL(for: path) {
                                store.pendingCropImagePath = resolvedURL.path
                                store.pendingCropCharacterID = character.id
                                store.showImageCropper = true
                            } else {
                                store.setCharacterProfileImage(path, for: character.id)
                            }
                        },
                        onChooseFromDisk: {
                            showProfileImagePicker = false
                            DispatchQueue.main.async {
                                store.setCharacterProfileImageFromPicker(for: character.id)
                            }
                        },
                        onDismiss: { showProfileImagePicker = false }
                    )
                }
            }
            .sheet(item: $inspirationPendingPlan) { plan in
                GeminiGenerationPreflightSheet(
                    store: store,
                    drafts: $inspirationDrafts,
                    title: plan.title,
                    confirmTitle: plan.confirmTitle,
                    onConfirm: { drafts, mode in
                        inspirationPendingPlan = nil
                        switch mode {
                        case .standard:
                            runInspirationGeneration(drafts)
                        case .batch:
                            submitInspirationBatch(drafts, wardrobe: inspirationActiveWardrobe ?? .soldier)
                        }
                    },
                    onCancel: {
                        inspirationPendingPlan = nil
                    }
                )
            }
            .sheet(item: $promptPreview) { preview in
                StoredImagePromptPreviewSheet(preview: preview)
            }
            .onChange(of: store.selectedCharacterID) { _, _ in
                store.saveCharacterPromptEdits()
                inspirationSelectedPaths = []
                inspirationLastClicked = nil
                previewImageIndex = nil
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a character to view inspiration images")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // NOTE: The characterHeader, inspirationSection, gallery grid, generation menu items,
    // runInspirationGeneration, submitInspirationBatch, and related helper methods
    // should be MOVED (not copied) from CharactersPageView.swift.
    //
    // The methods to move are:
    //   - characterHeader(_:)
    //   - profileImageView(character:owpChar:)
    //   - inspirationImagesSection(_:)
    //   - inspirationGenerationMenuItems(for:wardrobe:)
    //   - runInspirationGeneration(_:)
    //   - submitInspirationBatch(_:wardrobe:)
    //   - Any helper methods these depend on (collapsiblePane is in CharactersPageView — 
    //     either extract to a shared file or re-implement inline)
    //
    // The key principle: These methods are being MOVED, not duplicated.
    // After moving, CharactersPageView should no longer contain these methods.

    // MARK: - Placeholder stubs (replace with moved code from CharactersPageView)

    @ViewBuilder
    private func characterHeader(_ character: AnimationCharacter) -> some View {
        let owpChar = store.owpCharacter(for: character)
        HStack(spacing: 16) {
            Button {
                showProfileImagePicker = true
            } label: {
                // Profile image — move profileImageView from CharactersPageView
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .overlay {
                        if let colorHex = owpChar?.colorHex {
                            Circle().stroke(Color(hex: colorHex) ?? .clear, lineWidth: 3)
                        }
                        Text(character.name.prefix(1))
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(character.name)
                    .font(.title2.weight(.semibold))
                Text("\(character.inspirationImagePaths.count) inspiration images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func inspirationSection(_ character: AnimationCharacter) -> some View {
        // Placeholder — move inspirationImagesSection + generation controls from CharactersPageView
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inspiration Gallery")
                    .font(.headline)
                Spacer()
                Button("Import") {
                    store.importInspirationImages(for: character.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if character.inspirationImagePaths.isEmpty {
                Text("No inspiration images yet. Use the generation tools below or import images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                // Thumbnail grid — will be populated with moved code
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailBaseSize))], spacing: 8) {
                    ForEach(character.inspirationImagePaths, id: \.self) { path in
                        imageThumbnail(path: path, character: character)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func imageThumbnail(path: String, character: AnimationCharacter) -> some View {
        let isSelected = inspirationSelectedPaths.contains(path)
        AsyncImage(url: store.resolvedCharacterAssetURL(for: path)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailBaseSize, height: thumbnailBaseSize)
                    .clipped()
            default:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: thumbnailBaseSize, height: thumbnailBaseSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            previewImagePaths = character.inspirationImagePaths
            if let idx = previewImagePaths.firstIndex(of: path) {
                previewImageIndex = idx
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                if let url = store.resolvedCharacterAssetURL(for: path) {
                    ImagineProjectStorage.revealInFinder(url.path)
                }
            }
            Button("Copy Image") {
                if let url = store.resolvedCharacterAssetURL(for: path),
                   let image = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
        }
        .draggable(store.resolvedCharacterAssetURL(for: path) ?? URL(fileURLWithPath: path)) // Enable drag-out
    }

    // MARK: - Generation (stubs — wire to existing inspiration generation logic from CharactersPageView)

    private func runInspirationGeneration(_ drafts: [GeminiGenerationDraft]) {
        // Move from CharactersPageView
    }

    private func submitInspirationBatch(_ drafts: [GeminiGenerationDraft], wardrobe: CharacterInspirationWardrobe) {
        // Move from CharactersPageView
    }
}
```

**Implementation note for the executing agent:** The stubs above are scaffolding. The actual implementation requires MOVING the following methods from `CharactersPageView.swift` into this file:
- `characterHeader(_:)` and `profileImageView(character:owpChar:)` — lines ~633-700
- `inspirationImagesSection(_:)` — search for this method name in CharactersPageView
- `inspirationGenerationMenuItems(for:wardrobe:)` — the menu builder
- `runInspirationGeneration(_:)` — the generation executor
- `submitInspirationBatch(_:wardrobe:)` — the batch submitter
- Any private helper methods these reference

After moving, update CharactersPageView to remove the moved methods and the `showInspirationPane` collapsible section.

- [ ] **Step 2: Verify compilation**

Run build. Fix any missing references by either moving additional helper methods or adding imports.

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift
git commit -m "feat(imagine): add Imagine > Characters page with inspiration gallery and generation controls"
```

---

### Task 8: Strip inspiration sections from CharactersPageView

**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`

Remove the inspiration pane, profile image picker (move to Imagine), and animated images pane. Keep: Character Notes, Look Development, Reference Workflow, Packages, Expression Library, Motion Generation.

- [ ] **Step 1: Remove inspiration pane from characterDetail**

In the `characterDetail` computed property (around line 452), remove the collapsiblePane block for "Inspiration Images" (lines ~479-524). Also remove the "Animated Images" collapsiblePane (lines ~544-558).

Remove these `@State` and `@AppStorage` properties from the top of the struct:
- `showInspirationGallery`
- `showProfileImagePicker`
- `showInspirationPane`
- `showAnimatedImagesPane`
- `inspirationPendingPlan`
- `inspirationDrafts`
- `inspirationActiveWardrobe`
- `inspirationGenerationErrorMessage`
- `inspirationGenerationStatus`
- `inspirationStatusCharacterID`
- `inspirationGenerationProgress`
- `isGeneratingInspiration`
- `generatingInspirationCharacterID`
- `isSubmittingInspirationBatch`
- `submittingInspirationBatchCharacterID`
- `animatedSelectedPaths`
- `animatedLastClicked`

Remove the corresponding `.sheet` modifiers for `showInspirationGallery`, `showProfileImagePicker`, and `inspirationPendingPlan`.

Remove the `inspirationImagesSection(_:)` method and `animatedImagesSection(_:)` method.
Remove `inspirationGenerationMenuItems(for:wardrobe:)`.
Remove `runInspirationGeneration(_:)` and `submitInspirationBatch(_:wardrobe:)`.

- [ ] **Step 2: Keep the profile image in the header but simplify**

The character header should still show the profile image (it's part of the character identity), but the "click to change profile" functionality moves to Imagine. Keep the header display-only — remove the Button wrapping the profile image and just show it as a static image.

- [ ] **Step 3: Remove batch job polling task**

Remove the `.task(id: store.workingOWPURL?.path)` block that polls `refreshInspirationBatchJobs()` (around line 300-310). This polling now belongs in ImagineCharactersPageView.

- [ ] **Step 4: Verify compilation**

Run build. Fix any broken references.

- [ ] **Step 5: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift
git commit -m "refactor(characters): remove inspiration and animated image panes — moved to Imagine page"
```

---

## Task Group D: Imagine > Scenes Sub-Page

### Task 9: Create ImagineScenesPageView

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`

Layout (top to bottom): Shot timeline strip → Large preview → B/M/E tab bar → Gallery grid → [pinned to bottom] Generation controls.

- [ ] **Step 1: Create the scenes page view**

```swift
import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ImagineScenesPageView: View {
    @Bindable var store: AnimateStore
    @State private var selectedMoment: ImagineShotMoment = .beginning
    @State private var previewImagePath: String?
    @State private var showImagePicker: Bool = false
    @State private var generationPrompt: String = ""
    @State private var isGeneratingPrompt: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generationError: String?
    @State private var selectedDrawThingsModel: ImagineDrawThingsModel = .fluxKlein
    @State private var useGemini: Bool = false
    @State private var geminiReferenceImages: [GeminiImageService.ReferenceImage] = []
    @State private var showReferenceImagePicker: Bool = false
    @State private var thumbnailBaseSize: CGFloat = 100

    private var selectedScene: AnimationScene? {
        store.selectedScene
    }

    private var shots: [AnimationSceneShot] {
        selectedScene?.shots ?? []
    }

    private var currentGallery: ImagineSceneShotGallery? {
        guard let scene = selectedScene,
              let idx = store.imagineSelectedShotIndex else { return nil }
        return store.imagineGallery(for: scene.id, shotIndex: idx)
    }

    private var currentMomentPaths: [String] {
        currentGallery?.paths(for: selectedMoment) ?? []
    }

    var body: some View {
        if let scene = selectedScene {
            VStack(spacing: 0) {
                // Shot timeline strip
                shotTimeline(scene: scene)

                Divider()

                // Main content (scrollable)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Large preview
                        previewSection

                        // B/M/E tab bar
                        momentTabBar

                        // Gallery grid
                        galleryGrid
                    }
                    .padding()
                }

                Divider()

                // Pinned generation controls at bottom
                generationControls
            }
            .onChange(of: store.selectedSceneID) { _, _ in
                store.imagineSelectedShotIndex = shots.isEmpty ? nil : 0
                if let sceneID = store.selectedSceneID {
                    store.ensureImagineDirectories(for: sceneID)
                    store.refreshImagineGalleryFromDisk(sceneID: sceneID)
                }
            }
            .onChange(of: store.imagineSelectedShotIndex) { _, _ in
                previewImagePath = nil
            }
            .onAppear {
                if store.imagineSelectedShotIndex == nil && !shots.isEmpty {
                    store.imagineSelectedShotIndex = 0
                }
                if let sceneID = store.selectedSceneID {
                    store.ensureImagineDirectories(for: sceneID)
                    store.refreshImagineGalleryFromDisk(sceneID: sceneID)
                }
            }
            .sheet(isPresented: $showReferenceImagePicker) {
                UniversalImagePickerSheet(
                    store: store,
                    maxSelections: 5,
                    onConfirm: { selectedPaths in
                        showReferenceImagePicker = false
                        loadReferenceImages(from: selectedPaths)
                    },
                    onCancel: {
                        showReferenceImagePicker = false
                    }
                )
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a scene to generate images")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shot Timeline

    private func shotTimeline(scene: AnimationScene) -> some View {
        HStack(spacing: 8) {
            Button {
                if let idx = store.imagineSelectedShotIndex, idx > 0 {
                    store.imagineSelectedShotIndex = idx - 1
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(store.imagineSelectedShotIndex == nil || store.imagineSelectedShotIndex == 0)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(scene.shots.enumerated()), id: \.element.id) { index, shot in
                            shotChip(index: index, shot: shot)
                                .id(index)
                                .onTapGesture { store.imagineSelectedShotIndex = index }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: store.imagineSelectedShotIndex) { _, newIndex in
                    if let idx = newIndex {
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }

            Button {
                if let idx = store.imagineSelectedShotIndex, idx < shots.count - 1 {
                    store.imagineSelectedShotIndex = idx + 1
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(store.imagineSelectedShotIndex == nil || store.imagineSelectedShotIndex == shots.count - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shotChip(index: Int, shot: AnimationSceneShot) -> some View {
        let isSelected = store.imagineSelectedShotIndex == index
        let gallery = store.imagineGallery(for: shot.sceneID ?? selectedScene?.id ?? UUID(), shotIndex: index)
        let totalImages = (gallery?.beginningImagePaths.count ?? 0)
            + (gallery?.middleImagePaths.count ?? 0)
            + (gallery?.endImagePaths.count ?? 0)

        return VStack(spacing: 2) {
            Text("S\(index + 1)")
                .font(.caption.weight(.bold))
            Text(shot.cameraShot?.rawValue ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if totalImages > 0 {
                Text("\(totalImages)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    // MARK: - Preview

    private var previewSection: some View {
        Group {
            if let path = previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment) {
                AsyncImage(url: URL(fileURLWithPath: path)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    default:
                        previewPlaceholder
                    }
                }
            } else {
                previewPlaceholder
            }
        }
    }

    private var previewPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.05))
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                    Text("Select a thumbnail below to preview").font(.caption).foregroundStyle(.tertiary)
                }
            }
    }

    // MARK: - Moment Tab Bar

    private var momentTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ImagineShotMoment.allCases) { moment in
                Button {
                    selectedMoment = moment
                } label: {
                    Text(moment.rawValue)
                        .font(.subheadline.weight(selectedMoment == moment ? .semibold : .regular))
                        .foregroundStyle(selectedMoment == moment ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedMoment == moment
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        Group {
            if currentMomentPaths.isEmpty {
                Text("No \(selectedMoment.rawValue.lowercased()) images for this shot yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailBaseSize))], spacing: 8) {
                    ForEach(currentMomentPaths, id: \.self) { path in
                        galleryThumbnail(path: path)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func galleryThumbnail(path: String) -> some View {
        let isSelected = previewImagePath == path

        AsyncImage(url: URL(fileURLWithPath: path)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailBaseSize, height: thumbnailBaseSize)
                    .clipped()
            default:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: thumbnailBaseSize, height: thumbnailBaseSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            previewImagePath = path
            store.imaginePreviewImagePath = path
        }
        .contextMenu {
            Button("Show in Finder") {
                ImagineProjectStorage.revealInFinder(path)
            }
            Button("Copy Image") {
                if let image = NSImage(contentsOfFile: path) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(atPath: path)
                if let sceneID = selectedScene?.id {
                    store.refreshImagineGalleryFromDisk(sceneID: sceneID)
                }
            }
        }
        .draggable(URL(fileURLWithPath: path))
    }

    // MARK: - Generation Controls (pinned bottom)

    private var generationControls: some View {
        VStack(spacing: 10) {
            // Generator toggle
            HStack(spacing: 12) {
                Picker("Generator", selection: $useGemini) {
                    Text("Draw Things").tag(false)
                    Text("Gemini").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if !useGemini {
                    Picker("Model", selection: $selectedDrawThingsModel) {
                        ForEach(ImagineDrawThingsModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .frame(maxWidth: 200)
                } else {
                    Picker("Model", selection: $store.selectedGeminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .frame(maxWidth: 200)
                    .disabled(!store.geminiMasterSwitch)

                    // Reference images
                    Button {
                        showReferenceImagePicker = true
                    } label: {
                        Label("\(geminiReferenceImages.count)/5 Refs", systemImage: "photo.on.rectangle.angled")
                    }
                    .controlSize(.small)
                    .disabled(!store.geminiMasterSwitch)
                }
            }

            // Prompt
            HStack(spacing: 8) {
                TextEditor(text: $generationPrompt)
                    .font(.caption)
                    .frame(height: 50)
                    .padding(4)
                    .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

                VStack(spacing: 4) {
                    Button {
                        autoGeneratePrompt()
                    } label: {
                        Label("Auto", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                    .disabled(isGeneratingPrompt)

                    Button {
                        generateImage()
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(generationPrompt.isEmpty || isGenerating || (useGemini && !store.geminiMasterSwitch))
                }
            }

            // Reference image staging (Gemini only)
            if useGemini && !geminiReferenceImages.isEmpty {
                HStack(spacing: 6) {
                    Text("References:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(0..<geminiReferenceImages.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Text("\(i + 1)")
                                    .font(.caption2)
                            }
                    }
                    Button("Clear") {
                        geminiReferenceImages = []
                    }
                    .controlSize(.mini)
                }
            }

            if let error = generationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Generation Actions

    private func autoGeneratePrompt() {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex < scene.shots.count else { return }
        isGeneratingPrompt = true

        Task {
            defer { isGeneratingPrompt = false }
            do {
                let service = ImagineScenePromptService(store: store)
                let prompt = try await service.generatePrompt(
                    scene: scene,
                    shotIndex: shotIndex,
                    moment: selectedMoment
                )
                generationPrompt = prompt
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func generateImage() {
        guard let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex else { return }
        isGenerating = true
        generationError = nil

        let sceneSlug = scene.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        Task {
            defer {
                isGenerating = false
                store.refreshImagineGalleryFromDisk(sceneID: scene.id)
            }
            do {
                let service = ImagineGenerationService()
                if useGemini {
                    guard store.isGeminiAllowed() else {
                        generationError = "Gemini API calls are blocked. Enable them in the Inspector > Tools tab."
                        return
                    }
                    try await service.generateWithGemini(
                        prompt: generationPrompt,
                        referenceImages: geminiReferenceImages,
                        model: store.selectedGeminiModel,
                        apiKey: store.geminiAPIKey,
                        owpURL: owpURL,
                        sceneSlug: sceneSlug,
                        shotIndex: shotIndex,
                        moment: selectedMoment
                    )
                } else {
                    try await service.generateWithDrawThings(
                        prompt: generationPrompt,
                        model: selectedDrawThingsModel,
                        config: store.drawThingsPlaceConfig,
                        owpURL: owpURL,
                        sceneSlug: sceneSlug,
                        shotIndex: shotIndex,
                        moment: selectedMoment
                    )
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func loadReferenceImages(from paths: [String]) {
        geminiReferenceImages = paths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let mime: String
            switch ext {
            case "png": mime = "image/png"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            return GeminiImageService.ReferenceImage(data: data.base64EncodedString(), mimeType: mime)
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run build. The view references `ImagineScenePromptService` and `ImagineGenerationService` which will be created in later tasks — add minimal stubs if needed to compile.

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift
git commit -m "feat(imagine): add Imagine > Scenes page with shot timeline, B/M/E galleries, and generation controls"
```

---

### Task 10: Create ImagineSceneShotGalleryView (reusable gallery component)

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ImagineSceneShotGalleryView.swift`

A reusable gallery grid component with right-click context menus (Show in Finder, Copy, Crop, Delete), drag-out support, and import via button or drag-in.

- [ ] **Step 1: Create the gallery view**

```swift
import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ImagineSceneShotGalleryView: View {
    let imagePaths: [String]
    let thumbnailSize: CGFloat
    let onSelect: (String) -> Void
    let onImport: () -> Void
    let onDelete: (String) -> Void
    var selectedPath: String? = nil

    @State private var isDragTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(imagePaths.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .controlSize(.mini)
            }

            if imagePaths.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize))], spacing: 6) {
                    ForEach(imagePaths, id: \.self) { path in
                        thumbnail(for: path)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.03))
            .frame(minHeight: 60)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Drop images here or click Import")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    @ViewBuilder
    private func thumbnail(for path: String) -> some View {
        let isSelected = selectedPath == path
        let url = URL(fileURLWithPath: path)

        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .clipped()
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: thumbnailSize, height: thumbnailSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onSelect(path)
        }
        .contextMenu {
            Button("Show in Finder") {
                ImagineProjectStorage.revealInFinder(path)
            }
            Button("Copy Image") {
                if let image = NSImage(contentsOfFile: path) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete(path)
            }
        }
        .draggable(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) else { return }
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "webp", "tiff"].contains(ext) else { return }
                DispatchQueue.main.async {
                    // The parent view handles the actual import via onImport or a custom handler
                    // For now, we signal that a drop occurred
                    onSelect(url.path)
                }
            }
            handled = true
        }
        return handled
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/ImagineSceneShotGalleryView.swift
git commit -m "feat(imagine): add reusable gallery grid with right-click, drag-out, drag-in, and import"
```

---

## Task Group E: Image Generation Services

### Task 11: Create ImagineScenePromptService

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift`

Auto-generates detailed image prompts using MiniMax M2.7, drawing from the scene's script context, characters, costumes, time/place/setting, camera angles, and moment (beginning/middle/end). NEVER includes character names, show name, or song names in the output.

- [ ] **Step 1: Create the prompt service**

```swift
import Foundation

@available(macOS 26.0, *)
final class ImagineScenePromptService: Sendable {
    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    func generatePrompt(
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws -> String {
        let apiKey = store.miniMaxAPIKey
        guard !apiKey.isEmpty else {
            throw PromptError.noAPIKey
        }
        guard shotIndex < scene.shots.count else {
            throw PromptError.invalidShot
        }

        let shot = scene.shots[shotIndex]
        let contextBlock = buildContextBlock(scene: scene, shot: shot, shotIndex: shotIndex, moment: moment)
        let service = MiniMaxPromptService(apiKey: apiKey)

        let systemPrompt = """
        You are an expert at writing image generation prompts for cinematic scenes in animated shows.

        CRITICAL RULES:
        1. NEVER include character names, show titles, song names, or any proper nouns in the prompt.
        2. Use ONLY descriptive physical attributes: hair color, eye color, body type, clothing, accessories.
        3. Describe the scene visually: composition, lighting, camera angle, atmosphere, color palette, time of day.
        4. For the BEGINNING of a scene: describe the opening state, establishing shot, initial positions.
        5. For the MIDDLE of a scene: describe the peak action, emotional climax, dynamic movement.
        6. For the END of a scene: describe the resolution, final positions, closing atmosphere.
        7. Output ONLY the prompt text. No explanations, no labels, no markdown.
        8. The prompt should be detailed enough for a Stable Diffusion or Gemini image generator.
        9. Include art style: high quality anime/animation style, detailed backgrounds, cinematic lighting.
        """

        let userPrompt = """
        Generate a detailed image generation prompt for this scene moment.

        \(contextBlock)

        Generate a \(moment.rawValue.uppercased()) image prompt for shot \(shotIndex + 1).
        """

        // Use MiniMax to generate the prompt
        let body: [String: Any] = [
            "model": "MiniMax-M2.7",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 600,
            "temperature": 0.7
        ]

        var request = URLRequest(url: URL(string: "https://api.minimaxi.chat/v1/text/chatcompletion_v2")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PromptError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw PromptError.invalidResponse }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildContextBlock(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) -> String {
        var parts: [String] = []

        // Scene direction template (extracted from script)
        if let template = scene.directionTemplate {
            if let setting = template.setting {
                parts.append("SETTING: \(setting)")
            }
            if let timeOfDay = template.timeOfDay {
                parts.append("TIME OF DAY: \(timeOfDay)")
            }
            if let mood = template.mood {
                parts.append("MOOD/ATMOSPHERE: \(mood)")
            }
            if let weather = template.weather {
                parts.append("WEATHER: \(weather)")
            }
        }

        // Characters in the scene — describe by appearance, NOT by name
        let sceneCharacters = store.characters.filter { scene.characterSlugs.contains($0.owpSlug) }
        if !sceneCharacters.isEmpty {
            var charDescs: [String] = []
            for char in sceneCharacters {
                var desc = "A \(char.genderType.rawValue)"
                if let age = char.age { desc += ", approximately \(age) years old" }
                // Add physical description from notes if available
                if !char.appearance.isEmpty {
                    desc += ". Appearance: \(char.appearance)"
                }
                charDescs.append(desc)
            }
            parts.append("CHARACTERS PRESENT: \(charDescs.joined(separator: " | "))")
        }

        // Shot info
        if let camera = shot.cameraShot {
            parts.append("CAMERA: \(camera.rawValue)")
        }
        if let intent = shot.shotIntent {
            parts.append("SHOT INTENT: \(intent.rawValue)")
        }
        if !shot.notes.isEmpty {
            parts.append("SHOT NOTES: \(shot.notes)")
        }

        // Lyric excerpt for emotional context (but strip any names)
        if let lyric = shot.sourceLyricExcerpt, !lyric.isEmpty {
            parts.append("EMOTIONAL CONTEXT FROM LYRICS: \(lyric)")
        }

        // Shot position context
        let totalShots = scene.shots.count
        parts.append("SHOT \(shotIndex + 1) of \(totalShots)")

        return parts.joined(separator: "\n")
    }

    enum PromptError: LocalizedError {
        case noAPIKey
        case invalidShot
        case requestFailed(statusCode: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "MiniMax API key is not set."
            case .invalidShot: "Invalid shot index."
            case .requestFailed(let code): "MiniMax request failed with status \(code)."
            case .invalidResponse: "Invalid response from MiniMax."
            }
        }
    }
}
```

**Note for executing agent:** Check if `store.miniMaxAPIKey` exists. If not, look for how the MiniMax API key is stored — it may be in `MiniMaxCredentialStore`. Adjust the key access accordingly.

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift
git commit -m "feat(imagine): add MiniMax-powered auto-prompt service for scene image generation"
```

---

### Task 12: Create ImagineGenerationService

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`

Orchestrator that routes generation to DrawThings or Gemini, saves images to the correct project directory, and handles bulk runs.

- [ ] **Step 1: Create the generation service**

```swift
import AppKit
import Foundation

@available(macOS 26.0, *)
struct ImagineGenerationService {

    // MARK: - DrawThings Generation

    func generateWithDrawThings(
        prompt: String,
        model: ImagineDrawThingsModel,
        config: DrawThingsPlaceConfig,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws {
        var effectiveConfig = config
        effectiveConfig.imageWidth = 1920
        effectiveConfig.imageHeight = 1088
        effectiveConfig.steps = model.defaultSteps
        effectiveConfig.cfgScale = model.defaultCFGScale

        let service = DrawThingsPlaceGenerationService()
        let outputURL = try ImagineProjectStorage.saveGeneratedImage(
            Data(), // placeholder — will be replaced
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: moment,
            filePrefix: "dt"
        )

        // Generate directly to the output URL
        try await service.generateImage(
            prompt: prompt,
            config: effectiveConfig,
            outputURL: outputURL
        )
    }

    // MARK: - Gemini Generation

    func generateWithGemini(
        prompt: String,
        referenceImages: [GeminiImageService.ReferenceImage],
        model: GeminiModel,
        apiKey: String,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws {
        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            aspectRatio: "16:9",
            imageSize: "2K"
        )

        let result = try await service.generate(request: request, apiKey: apiKey)

        // Save the generated image to the correct directory
        _ = try ImagineProjectStorage.saveGeneratedImage(
            result.imageData,
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: moment,
            filePrefix: "gemini"
        )
    }

    // MARK: - Bulk Generation (DrawThings only)

    func runBulk(
        config: ImagineBulkRunConfig,
        scenes: [AnimationScene],
        store: AnimateStore,
        onProgress: @MainActor (ImagineBulkRunProgress) -> Void
    ) async throws {
        guard let owpURL = store.fileOWPURL else { return }

        let targetScenes: [AnimationScene]
        if let filter = config.sceneFilter {
            targetScenes = scenes.filter { filter.contains($0.id) }
        } else {
            targetScenes = scenes
        }

        let moments = ImagineShotMoment.allCases.filter { moment in
            switch moment {
            case .beginning: config.includeBeginning
            case .middle: config.includeMiddle
            case .end: config.includeEnd
            }
        }

        let totalImages = targetScenes.reduce(0) { $0 + $1.shots.count } * moments.count * config.imagesPerMoment

        var progress = ImagineBulkRunProgress()
        progress.isRunning = true
        progress.totalImages = totalImages
        await onProgress(progress)

        let promptService = ImagineScenePromptService(store: store)

        for scene in targetScenes {
            let sceneSlug = scene.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "/", with: "-")

            try? ImagineProjectStorage.ensureDirectories(owpURL: owpURL, sceneSlug: sceneSlug, shotCount: scene.shots.count)

            for (shotIndex, _) in scene.shots.enumerated() {
                for moment in moments {
                    progress.currentSceneName = scene.name
                    progress.currentShotIndex = shotIndex
                    progress.currentMoment = moment
                    await onProgress(progress)

                    // Auto-generate prompt if configured
                    var prompt = ""
                    if config.autoGeneratePrompts {
                        prompt = (try? await promptService.generatePrompt(
                            scene: scene,
                            shotIndex: shotIndex,
                            moment: moment
                        )) ?? ""
                    }

                    guard !prompt.isEmpty else {
                        progress.completedImages += config.imagesPerMoment
                        await onProgress(progress)
                        continue
                    }

                    for _ in 0..<config.imagesPerMoment {
                        do {
                            try await generateWithDrawThings(
                                prompt: prompt,
                                model: config.model,
                                config: store.drawThingsPlaceConfig,
                                owpURL: owpURL,
                                sceneSlug: sceneSlug,
                                shotIndex: shotIndex,
                                moment: moment
                            )
                        } catch {
                            progress.errorMessage = "Shot \(shotIndex + 1) \(moment.rawValue): \(error.localizedDescription)"
                        }
                        progress.completedImages += 1
                        await onProgress(progress)
                    }
                }
            }
        }

        progress.isRunning = false
        await onProgress(progress)
    }
}
```

- [ ] **Step 2: Wire bulk run into ImagineInspectorView**

In `ImagineInspectorView.swift`, replace the `startBulkRun()` stub:

```swift
private func startBulkRun() {
    store.imagineBulkRunProgress = ImagineBulkRunProgress(isRunning: true)
    Task {
        let service = ImagineGenerationService()
        try? await service.runBulk(
            config: store.imagineBulkRunConfig,
            scenes: store.scenes,
            store: store,
            onProgress: { progress in
                store.imagineBulkRunProgress = progress
            }
        )
    }
}
```

- [ ] **Step 3: Verify compilation**

- [ ] **Step 4: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift
git commit -m "feat(imagine): add generation service orchestrator for DrawThings, Gemini, and bulk runs"
```

---

## Task Group F: Universal Image Picker

### Task 13: Create UniversalImagePickerSheet

**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/UniversalImagePickerSheet.swift`

A hierarchical image browser: top level = Imagine / Characters / Places / Props. Drill down into subcategories. Thumbnails with checkbox selection. Quick Look on spacebar. Staging tray at bottom showing selected images. Confirm/Cancel.

- [ ] **Step 1: Create the picker sheet**

```swift
import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct UniversalImagePickerSheet: View {
    @Bindable var store: AnimateStore
    var maxSelections: Int = 5
    var onConfirm: ([String]) -> Void
    var onCancel: () -> Void

    @State private var allImages: [ImagineImageCategory: [ImagineImagePickerEntry]] = [:]
    @State private var selectedCategory: ImagineImageCategory? = nil
    @State private var selectedPaths: [String] = []
    @State private var searchText: String = ""
    @State private var quickLookPath: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Reference Images")
                    .font(.headline)
                Spacer()
                Text("\(selectedPaths.count)/\(maxSelections) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Content
            HStack(spacing: 0) {
                // Category sidebar
                categorySidebar
                    .frame(width: 180)

                Divider()

                // Image grid
                imageGrid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Staging tray
            if !selectedPaths.isEmpty {
                stagingTray
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Confirm (\(selectedPaths.count))") {
                    onConfirm(selectedPaths)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPaths.isEmpty)
            }
            .padding()
        }
        .frame(width: 700, height: 550)
        .onAppear {
            loadAllImages()
        }
        .sheet(item: quickLookBinding) { path in
            QuickLookSheet(path: path)
        }
    }

    // MARK: - Category Sidebar

    private var categorySidebar: some View {
        List(selection: $selectedCategory) {
            ForEach(ImagineImageCategory.allCases) { category in
                let count = allImages[category]?.count ?? 0
                Label {
                    VStack(alignment: .leading) {
                        Text(category.rawValue)
                        Text("\(count) images")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: category.systemImage)
                }
                .tag(category)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Image Grid

    private var imageGrid: some View {
        ScrollView {
            if let category = selectedCategory,
               let entries = filteredEntries(for: category) {
                if entries.isEmpty {
                    Text("No images in this category")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                } else {
                    // Group by subcategory
                    let grouped = Dictionary(grouping: entries, by: \.subcategoryLabel)
                    let sortedKeys = grouped.keys.sorted()

                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedKeys, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                                    ForEach(grouped[key] ?? [], id: \.id) { entry in
                                        pickerThumbnail(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Choose a category from the sidebar")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 100)
            }
        }
    }

    @ViewBuilder
    private func pickerThumbnail(entry: ImagineImagePickerEntry) -> some View {
        let isSelected = selectedPaths.contains(entry.path)

        ZStack(alignment: .topTrailing) {
            AsyncImage(url: URL(fileURLWithPath: entry.path)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipped()
                default:
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 80)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            // Checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(Circle().fill(.ultraThinMaterial).frame(width: 18, height: 18))
                .padding(4)
        }
        .onTapGesture {
            toggleSelection(entry.path)
        }
        .onTapGesture(count: 2) {
            quickLookPath = entry.path
        }
    }

    // MARK: - Staging Tray

    private var stagingTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedPaths, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: URL(fileURLWithPath: path)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .clipped()
                            default:
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 50, height: 50)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button {
                            selectedPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .background(Circle().fill(.red).frame(width: 16, height: 16))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 66)
        .background(.bar)
    }

    // MARK: - Helpers

    private func loadAllImages() {
        guard let owpURL = store.fileOWPURL else { return }
        allImages = ImagineProjectStorage.scanAllProjectImages(
            owpURL: owpURL,
            characters: store.characters,
            scenes: store.scenes
        )
    }

    private func filteredEntries(for category: ImagineImageCategory) -> [ImagineImagePickerEntry]? {
        guard let entries = allImages[category] else { return nil }
        if searchText.isEmpty { return entries }
        return entries.filter {
            $0.categoryLabel.localizedCaseInsensitiveContains(searchText) ||
            $0.subcategoryLabel.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func toggleSelection(_ path: String) {
        if let index = selectedPaths.firstIndex(of: path) {
            selectedPaths.remove(at: index)
        } else if selectedPaths.count < maxSelections {
            selectedPaths.append(path)
        }
    }

    private var quickLookBinding: Binding<String?> {
        Binding(
            get: { quickLookPath },
            set: { quickLookPath = $0 }
        )
    }
}

// Simple Quick Look sheet
@available(macOS 26.0, *)
private struct QuickLookSheet: View, Identifiable {
    let path: String
    var id: String { path }

    var body: some View {
        VStack {
            AsyncImage(url: URL(fileURLWithPath: path)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    ProgressView()
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
        .padding()
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/UniversalImagePickerSheet.swift
git commit -m "feat(imagine): add universal hierarchical image picker with categories, thumbnails, and staging tray"
```

---

## Task Group G: Guard Gemini Calls with Master Switch

### Task 14: Add Gemini master switch guard to GeminiImageService

**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift`

All existing Gemini generation call sites should check `store.isGeminiAllowed()` before proceeding. The service itself should also have a static guard.

- [ ] **Step 1: Add a static guard method to GeminiImageService**

At the top of the `GeminiImageService` class, add:

```swift
/// Call this before any generation to enforce the master switch.
/// Returns true if Gemini calls are allowed.
static func checkMasterSwitch(_ enabled: Bool) throws {
    guard enabled else {
        throw ServiceError.masterSwitchOff
    }
}
```

Add a new case to `ServiceError`:
```swift
case masterSwitchOff
```

And its description:
```swift
case .masterSwitchOff: "Gemini API calls are disabled. Enable them in the Imagine > Inspector > Tools tab."
```

- [ ] **Step 2: Add guard call at the top of the `generate` method**

In the `generate(request:apiKey:)` method of GeminiImageService, the existing rate limit and circuit breaker checks are at the top. Add the master switch check as the very first line of the method. However, the service doesn't have access to the store — so the guard should be called by the CALLER, not inside the service. Instead, document this in the method's doc comment:

```swift
/// Callers MUST check `AnimateStore.isGeminiAllowed()` before calling this method.
/// The Imagine inspector's Tools tab controls the master switch.
```

The actual enforcement happens at the call sites (ImagineScenesPageView, ImagineCharactersPageView, etc.) which already check `store.isGeminiAllowed()` or `store.geminiMasterSwitch`.

- [ ] **Step 3: Verify compilation**

- [ ] **Step 4: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift
git commit -m "feat(imagine): add Gemini master switch guard and documentation for API call control"
```

---

## Task Group H: Integration and Polish

### Task 15: Wire up AnimateStore.fileOWPURL accessibility

**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

The `fileOWPURL` property is currently `private`. Several new services need access to it. Make it internal.

- [ ] **Step 1: Change access level**

Find:
```swift
private var fileOWPURL: URL? {
```

Change to:
```swift
var fileOWPURL: URL? {
```

(It's already internal by default since there's no access modifier — but verify it's not explicitly `private`.)

- [ ] **Step 2: Verify the AnimationCharacter.appearance property exists**

The `ImagineScenePromptService` references `char.appearance`. Check if `AnimationCharacter` has an `appearance` property. If not, add one or use the character notes instead. Common alternatives in the existing model:
- Check for `descriptionText`, `physicalDescription`, `notes`, or similar.
- If none exists, derive from the character's existing data or add a simple stored property.

- [ ] **Step 3: Verify the store.miniMaxAPIKey property exists**

Check if `AnimateStore` has a `miniMaxAPIKey` property. If not, look for how MiniMax credentials are stored (`MiniMaxCredentialStore`). Wire it up:

```swift
var miniMaxAPIKey: String {
    MiniMaxCredentialStore().loadAPIKey()
}
```

- [ ] **Step 4: Verify compilation**

- [ ] **Step 5: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/AnimateStore.swift
git commit -m "fix(imagine): expose fileOWPURL and wire miniMax/character appearance for prompt service"
```

---

### Task 16: Build and deploy

**Files:** None new — this is a build verification + deploy step.

- [ ] **Step 1: Full build**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' -derivedDataPath build CONFIGURATION_BUILD_DIR="$(pwd)/build/app" build 2>&1 | grep -E 'error:|BUILD'
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Fix any compilation errors**

If the build fails, read the errors and fix them. Common issues:
- Missing imports
- Type mismatches between task implementations
- Property access level issues
- Missing method stubs

- [ ] **Step 3: Deploy to !Applications**

```bash
rm -rf "/Volumes/Storage VIII/Programming/!Applications/Opera.app"
cp -R "/Volumes/Storage VIII/Programming/Amira Writer/build/app/Opera.app" "/Volumes/Storage VIII/Programming/!Applications/Opera.app"
```

- [ ] **Step 4: Smoke test**

Open the app and verify:
1. The "Imagine" tab appears in the top bar between Mix and Characters
2. Clicking Imagine shows the Characters/Scenes sub-page toggle
3. Characters sub-page shows character sidebar and inspiration gallery
4. Scenes sub-page shows scene sidebar and shot timeline
5. Inspector has Tools/Bulk/Properties tabs
6. Gemini master switch defaults to OFF

- [ ] **Step 5: Commit all remaining changes**

```bash
git add -A
git commit -m "feat(imagine): complete Imagine page with Characters/Scenes sub-pages, generation, and galleries"
```

---

## Summary of Task Dependencies

```
Task 1 (Models) ──────────┐
Task 2 (Storage) ─────────┤
Task 3 (Store State) ─────┼──> Task 5 (Workspace) ──> Task 7 (Characters Page)
Task 4 (OperaMode) ───────┘                     ├──> Task 9 (Scenes Page) ──> Task 10 (Gallery Component)
                                                  ├──> Task 6 (Inspector)
                                                  └──> Task 13 (Image Picker)

Task 11 (Prompt Service) ──┐
Task 12 (Gen Service) ─────┼──> Task 9 (Scenes Page wiring)
Task 14 (Gemini Guard) ────┘

Task 8 (Strip Characters) ──> After Task 7

Task 15 (Integration) ──> After all Tasks 1-14
Task 16 (Build/Deploy) ──> After Task 15
```

Tasks 1-4 can run in parallel.
Tasks 5-6 depend on 1-4.
Tasks 7, 8, 9, 10, 11, 12, 13, 14 can mostly run in parallel after 5-6.
Tasks 15-16 are sequential finalization.
