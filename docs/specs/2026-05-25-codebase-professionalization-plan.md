# Amira Writer Codebase Professionalization Plan

**Date:** 2026-05-25
**Spec file:** `docs/specs/2026-05-25-codebase-professionalization-plan.md`
**Prepared by:** OpenCode investigation session
**Incorporates:** `2026-05-24-monolith-splitting-plan.md` (all 24 steps) + `2026-05-24-refactor-execution-game-plan.md` (execution rules) + new professionalization work (utilities, directory restructure, view decomposition, consolidation)
**Rollback tag:** `pre-refactor-checkpoint-20260524` (existing)

---

## 1. Audience and Purpose

This spec is the **single source of truth** for the Amira Writer professionalization refactor. It is designed to be handed to a **cheaper execution agent** (e.g. a background Codex worker) that will:

1. Read this spec in its entirety before starting
2. Execute one phase at a time, in order
3. Run the verification gate after every step
4. Stop and ask Gary when a decision point is reached

The spec is **self-contained**: it derives all necessary context, names every file to touch, and provides exact verification commands. It does NOT defer to any other living document for store splitting or view decomposition.

---

## 2. Current Codebase State (verified 2026-05-25)

### 2.1 Monolithic files (by file size, top offenders)

| File | Size | Lines | Domain |
|------|------|-------|--------|
| `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` | 875.3K | **20,417** | Animation/Characters/Places |
| `Packages/Score/Sources/ScoreUI/ScoreStore.swift` | 383.4K | **8,819** | Score/Playback/Export |
| `Packages/Animate/Sources/AnimateUI/Views/PlacesWorldbuildingViews.swift` | 257.3K | ~7,000 | Places UI |
| `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift` | 234.0K | ~6,500 | Animate UI |
| `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift` | 217.8K | ~6,000 | Places UI |
| `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` | 209.9K | **4,851** | Audio engine |
| `Packages/Score/Sources/ScoreUI/Views/PianoRollViewController.swift` | 206.8K | ~5,700 | Score UI |
| `Packages/Animate/Sources/AnimateUI/AllProjectImagesWorkspace.swift` | 142.0K | ~3,900 | Image gallery |
| `Sources/WriteUI/Views/StructuredScriptTextEditor.swift` | 135.9K | ~3,645 | Write editor |
| `Packages/Animate/Sources/AnimateUI/Services/AutomationServices.swift` | 129.4K | ~3,400 | Scene automation |
| `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift` | 115.8K | ~3,200 | Animate inspector |
| `Packages/Animate/Sources/AnimateUI/Services/AnimateAPIServer.swift` | 114.0K | ~3,100 | Animate API |
| `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift` | 112.3K | ~3,100 | Characters UI |
| `Sources/WriteUI/Views/ScriptCenterView.swift` | 110.7K | ~3,000 | Write center |
| `Sources/Opera/OperaShellView.swift` | 81.8K | ~2,200 | App shell |
| `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneOrchestrationService.swift` | 89.0K | ~2,400 | Scene orchestration |
| `Packages/Score/Sources/ScoreUI/Views/PianoRollToolbarView.swift` | 87.3K | ~2,400 | Score toolbar |
| `Packages/Score/Sources/ScoreUI/Views/InstrumentMappingPanel.swift` | 58.7K | ~1,600 | Score panel |
| `Packages/Score/Sources/ScoreUI/Services/APIRouter.swift` | 57.5K | ~1,600 | Score API routing |
| `Packages/Animate/Sources/AnimateUI/Views/AllProjectImagesPageView.swift` | 57.5K | ~1,600 | Image gallery UI |
| `Packages/ProjectKit/Sources/ProjectKit/ProjectStore.swift` | 49.9K | ~1,350 | Project store |

**Any file over ~150K is a monolith that should be decomposed.**

### 2.2 Systemic duplication (verified by grep)

| Pattern | Occurrences | Where |
|---------|-------------|-------|
| `ISO8601DateFormatter()` instantiation | **58** raw instances, 20+ custom formatter declarations | Throughout |
| `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` | **271** | Every module |
| `JSONCoders.makeEncoder()` / `makeDecoder()` | **100+** | **Already centralized — GOOD, keep it** |
| `ProjectDatabaseBridge` | 3 distinct files | WriteUI, ScoreUI, AnimateUI Services |
| `amiraDebugLog` free function | 2 identical copies | ScriptStore.swift:7, ScoreStore.swift:18 |
| `Color(hex:)` usage | 6 call sites + duplicated palette helpers | Write, Score, Mix |
| `nilIfEmpty` as private String extension | 6 copies | InstrumentMappingPanel, ScriptCenterView, StructuredScriptDocument, ScriptShotMarkup, AnimateSceneShotSeedingService, CharacterExpressionEngine |
| `AppLog.swift` + `amiraDebugLog` + scattered `print()` | 3+ logging patterns | Animate has both AppLog and prints |
| `OperaChromeCollapsibleSection` vs raw `DisclosureGroup` | Mixed usage | Both exist; wrapper preferred |

### 2.3 Structural issues

- **Flat directories**: `AnimateUI/Services/` (~90 files), `AnimateUI/Views/` (80+ files).
- **No linting config** (no `.swiftlint.yml`, no `.editorconfig`, no SwiftFormat).
- **Stub re-exports** that do nothing:
  - `Sources/WriteUI/Services/AgentProcessManager.swift` (2 lines — just `import ProjectKit`)
  - `Sources/WriteUI/Services/LLMProviderConfig.swift` (2 lines — just `import ProjectKit`)

### 2.4 Existing good patterns (reference architecture to copy)

| Reference | Location | Why it's good |
|-----------|----------|---------------|
| MusicEngine | `Packages/Score/Sources/ScoreUI/Services/MusicEngine/` | 15 files (8-30K each), single responsibility per analyzer |
| ImageIntelligence | `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/` | 10 files + README.md |
| Animate3D | `Packages/Animate/Sources/AnimateUI/Services/Animate3D/` | Single `Stubs.swift` (small domain, single file is fine) |
| Views/Motion, Views/Unified, Views/Capture | AnimateUI/Views subdirs | Feature-aligned view grouping |

**Rule of thumb:**
- 1 file → flatten (no directory needed)
- 2-4 files → optional directory
- 5+ files → directory required
- 3+ file directory → gets a README.md (3-10 lines)

### 2.5 Build environment (verified)

- `swift build -c release` succeeds
- `swift test -c release` has known pre-existing failures (out of scope)
- Deploy: `Scripts/build-app.sh` (codesign + install to `!Applications/`)
- Fast-loop dev: `Scripts/build-opera-dev.sh` (debug, no bundle)

---

## 3. Phase 0 — ProjectKit Utilities Consolidation (LOW RISK, ~2 days)

**Goal:** eliminate duplicated tiny utilities in ProjectKit, then migrate all consumers.

### 3.1 New file: `Packages/ProjectKit/Sources/ProjectKit/DateFormatters.swift`

```swift
import Foundation

/// Thread-safe, Sendable-safe ISO8601 formatters shared across the entire app.
public enum AmiraDateFormatter {
    /// Standard ISO8601 (no fractional seconds).
    public nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 with fractional seconds (for log/audit timestamps).
    public nonisolated(unsafe) static let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Compact ISO8601 with colons replaced — safe for file system paths.
    public static func compact(_ date: Date) -> String {
        iso8601.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Parse that tries full first, then basic.
    public static func parse(_ value: String) -> Date? {
        iso8601Full.date(from: value) ?? iso8601.date(from: value)
    }
}
```

**Migration targets (58 call sites):** Replace every private `static let iso8601` and bare `ISO8601DateFormatter()` call.

**Files to touch (discovered in grep):**
- `Sources/MixUI/MixStore.swift` (replaces `MixDateParser`, ~7 lines deleted)
- `Sources/WriteUI/ScriptStore.swift` (deletes `isoFormatter` and `isoFormatterBasic`)
- `Packages/Score/Sources/ScoreUI/ScoreStore.swift` (deletes `iso8601Full`, `iso8601Basic`)
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` (~15 sites)
- `Packages/Animate/Sources/AnimateUI/Services/AutomationServices.swift` (~2 sites)
- `Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift` (1 site)
- `Packages/ProjectKit/Sources/ProjectKit/ProjectDatabase.swift`
- `Packages/ProjectKit/Sources/ProjectKit/ProjectStore.swift`
- `Packages/ProjectKit/Sources/ProjectKit/ScriptCardSidecarStore.swift`
- `Packages/ProjectKit/Sources/ProjectKit/ScenePackageStore.swift` (2 sites)
- `Packages/ProjectKit/Sources/ProjectKit/ProjectServiceHost.swift`
- Tests: `MixStoreTests`, `ScriptStoreTests`, `ProjectDatabaseBridgeTests`, `ScoreStoreExternalWatchTests`, `OWSSongDocumentTests`, `PlacesPersistenceTests`, `ProjectDatabaseTests`

### 3.2 New file: `Packages/ProjectKit/Sources/ProjectKit/StringExtensions.swift`

```swift
import Foundation

public extension String {
    /// Returns nil if the string is empty after trimming whitespace and newlines.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    /// True if the string is empty or contains only whitespace/newlines.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Convenience: `!isBlank`.
    var isPopulated: Bool {
        !isBlank
    }
}
```

**Migration:**
- `s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → `s.isBlank`
- `!s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → `s.isPopulated`
- Delete 6 private `nilIfEmpty` extensions from: `InstrumentMappingPanel.swift:1330`, `ScriptCenterView.swift:2509`, `StructuredScriptDocument.swift:1847`, `ScriptShotMarkup.swift:498`, `AnimateSceneShotSeedingService.swift:412`, `CharacterExpressionEngine.swift:172`

### 3.3 New file: `Packages/ProjectKit/Sources/ProjectKit/AmiraLogger.swift`

```swift
import Foundation
#if canImport(os)
import os
#endif

/// Subsystem-scoped structured logger.
/// Writes to os.Logger (Console.app/Instruments) AND to /tmp/<subsystem>-debug.log
/// so both developer observability and agent grep workflows are supported.
public enum AmiraLogger {
    public enum Subsystem: String, CaseIterable, Sendable {
        case write = "Write"
        case score = "Score"
        case animate = "Animate"
        case mix = "Mix"
        case opera = "Opera"
        case projectKit = "ProjectKit"

        var osSubsystem: String { "com.amira.writer.\(rawValue.lowercased())" }
        var fileName: String { "/tmp/\(rawValue.lowercased())-debug.log" }
    }

    public static func log(_ subsystem: Subsystem, _ message: String) {
        let ts = AmiraDateFormatter.iso8601Full.string(from: Date())
        let line = "[\(ts)] [\(subsystem.rawValue)] \(message)\n"

        #if canImport(os)
        if #available(macOS 11.0, *) {
            let logger = Logger(subsystem: subsystem.osSubsystem, category: "default")
            logger.log("\(line, privacy: .public)")
        }
        #endif

        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: subsystem.fileName)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
```

**Migration:**
- `Sources/WriteUI/ScriptStore.swift:7` — delete `private func amiraDebugLog`, replace all calls with `AmiraLogger.log(.write, ...)`
- `Packages/Score/Sources/ScoreUI/ScoreStore.swift:18` — same, subsystem `.score`
- `Packages/Animate/Sources/AnimateUI/Services/AppLog.swift` — review; likely replace with thin forwarding to `AmiraLogger.log(.animate, ...)`

### 3.4 New file: `Packages/ProjectKit/Sources/ProjectKit/ColorHex+SwiftUI.swift`

```swift
import SwiftUI

public extension Color {
    init(hex: String, fallback: String = "#FFFFFF") {
        self = ColorHex.color(from: hex) ?? ColorHex.color(from: fallback) ?? .white
    }
}
```

**Migration:**
- Delete `ScriptMarkupPalette` struct in `Sources/WriteUI/ScriptStore.swift:32-74` (duplicates `ColorHex`; the 4 hex constants become a small `enum ScriptPalette` with just strings, using `Color(hex:)`)
- Delete `Packages/Score/Sources/ScoreUI/Utilities/Color+Hex.swift`
- The 6 `Color(hex: hex)` call sites already use the pattern — just `import ProjectKit` once they lose the local extension

### 3.5 Consolidate stub re-exports

**Delete** these files, change any consumers to `import ProjectKit` directly:
- `Sources/WriteUI/Services/AgentProcessManager.swift` (2 lines)
- `Sources/WriteUI/Services/LLMProviderConfig.swift` (2 lines)

Verify nothing imports them via `import struct WriteUI.AgentProcessManager` before deletion.

### 3.6 Phase 0 verification

After ProjectKit utilities are created but before migration:
```bash
/usr/bin/swift build -c release --product ProjectKit
```

After migrating each consumer module:
```bash
/usr/bin/swift build -c release --product <product>
# Products in order: ProjectKit, WriteUI, MixUI, ScoreUI (via Score), AnimateUI (via Animate), Opera
```

Final gate:
```bash
/Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh
```

### 3.7 Phase 0 spot-checks

```bash
# Verify no ISO8601DateFormatter() allocations remain outside DateFormatters.swift and tests
rg "ISO8601DateFormatter\(\)" \
  --glob "*.swift" --glob "!*.build/**" --glob "!build/**" --glob "!**/*Tests.swift" \
  | grep -v "DateFormatters.swift"
# Should be empty.

# Verify no private nilIfEmpty duplicates remain
rg "var nilIfEmpty: String\?" \
  --glob "*.swift" --glob "!*.build/**" --glob "!StringExtensions.swift"
# Should be empty.

# Verify no private amiraDebugLog duplicates remain
rg "private func amiraDebugLog" \
  --glob "*.swift" --glob "!*.build/**"
# Should be empty.
```

### 3.8 Rollback

Each migration step: `git commit -am "Phase 0 step X: migrate <module> to ProjectKit utilities"`. Revert with `git revert <sha>` individually.

---

## 4. Phase 1 — MIDIPlaybackEngine Split (VERY LOW RISK, ~1 day)

**Goal:** split the 4,851-line MIDIPlaybackEngine into 5 focused files. Pure GCD-based audio engine code; no SwiftUI or Observation dependencies. Cannot break views.

Source: `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` (209.9K, 4,851 lines, 14 MARK sections — see Appendix H.1 for exact line numbers)

**New file location:** `Packages/Score/Sources/ScoreUI/Stores/Audio/` (new directory — created as part of Phase 2 directory restructure, so create early here to establish the pattern).

### 4.1 Step 1.1: Extract MetronomeEngine (~1,500 lines)

**Source MARK sections:**
- `// MARK: - Metronome` (line 145)
- `// MARK: - Metronome API` (line 1175)
- `// MARK: - Metronome Implementation` (line 1689)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/Audio/MetronomeEngine.swift`

**Type:** `final class MetronomeEngine`

**Contents:**
- Properties: `metronomeNode`, `metronomeDownbeatBuffer`, `metronomeUpbeatBuffer`, `metronomeEnabled`, `metronomeTimeSignatures`, `metronomeGain`, `metronomeGate`
- All 53 metronome functions
- Weak reference back to parent `MIDIPlaybackEngine` for the `AVAudioEngine` node attachment

**Parent relationship:** `MIDIPlaybackEngine` holds `private(set) var metronome: MetronomeEngine`

**ScoreStore facade:** Add passthrough properties, e.g.:
```swift
var metronomeEnabled: Bool {
    get { playbackEngine.metronome.isEnabled }
    set { playbackEngine.metronome.isEnabled = newValue }
}
```

**Risk:** Very Low. Metronome is self-contained — only touches engine to attach/detach nodes. ScoreStore sets `metronomeTimeSignatures` before playback but never accesses metronome internals.

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -n "metronome" Packages/Score/Sources/ScoreUI/ScoreStore.swift | wc -l` (should be smaller)
**Commit:** `git commit -am "Phase 1 step 1.1: extract MetronomeEngine from MIDIPlaybackEngine"`

### 4.2 Step 1.2: Extract RecordingEngine (~900 lines)

**Source MARK sections:**
- `// MARK: - Recording` (line 167)
- `// MARK: - Recording API` (line 1203)
- `// MARK: - Recording Implementation` (line 1251)
- `// MARK: - Loop Recording` (lines 195 and 1397)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/Audio/RecordingEngine.swift`

**Type:** `final class RecordingEngine`

**Contents:**
- Properties: `recordingLock`, `recordingFile`, `isRecordingAudio`, `mixdownWriteGroup`, `loopRecordingTimer`, `loopStartTick`, `loopEndTick`
- All 20 recording/loop-recording functions
- Callbacks: `onRecordingComplete`, `onMainMixRecordingComplete`, `onLoopPassComplete`

**Parent relationship:** `MIDIPlaybackEngine` holds `private(set) var recorder: RecordingEngine`

**Risk:** Low. Recording is self-contained. ScoreStore triggers start/stop but never touches internals.

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -n "isRecordingAudio" Packages/Score/Sources/ScoreUI/ScoreStore.swift | wc -l`
**Commit:** `git commit -am "Phase 1 step 1.2: extract RecordingEngine from MIDIPlaybackEngine"`

### 4.3 Step 1.3: Extract MeterManager (~350 lines)

**Source MARK sections:**
- `// MARK: - Metering API` (line 1160)
- `// MARK: - Metering` (line 4195)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/Audio/MeterManager.swift`

**Type:** `final class MeterManager`

**Contents:**
- Properties: `meterTapLevels`, `masterMeterRaw`, `meterPublishTimer`
- All 10 metering functions
- Callback: `onMeterUpdate`

**Parent relationship:** `MIDIPlaybackEngine` holds `private(set) var meters: MeterManager`

**ScoreStore facade:** `var leftPeakDB: Double { playbackEngine.meters.leftPeakDB }`

**Risk:** Very Low. ScoreStore reads computed properties — these become passthroughs on the parent engine.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 1 step 1.3: extract MeterManager from MIDIPlaybackEngine"`

### 4.4 Step 1.4: Extract ExportBufferConfig (~250 lines)

**Source MARK sections:**
- `// MARK: - Export Buffer Mode` (line 4567)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/Audio/ExportBufferConfig.swift`

**Contents:** Offline/export buffer flags and helpers. Used only by the Offline WAV Renderer path.

**Risk:** Very Low. Self-contained export configuration.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 1 step 1.4: extract ExportBufferConfig from MIDIPlaybackEngine"`

### 4.5 Step 1.5: Verify + Deploy

After all 4 extractions:
- `MIDIPlaybackEngine.swift` reduced from 4,851 → ~1,700 lines (core: audio graph, AU loading, sampler management, play/stop orchestration, send routing, AU MIDI helpers, silent export — see Appendix H.1 for what remains)
- 4 new files in `Stores/Audio/`
- All ScoreStore access via facade passthroughs; zero view changes
- Deploy via `Scripts/build-app.sh`
- **Commit:** `git commit -am "Phase 1: MIDIPlaybackEngine split complete"`

### 4.6 Phase 1 spot-checks

```bash
ls -la Packages/Score/Sources/ScoreUI/Stores/Audio/
# Should list: MetronomeEngine.swift, RecordingEngine.swift, MeterManager.swift, ExportBufferConfig.swift

wc -l Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift
# Should be ~1,700 lines (down from 4,851)

# Verify ScoreStore facade passthroughs
grep -A 3 "var metronomeEnabled" Packages/Score/Sources/ScoreUI/ScoreStore.swift
# Should be thin single-line wrappers
```

---

## 5. Phase 2 — Directory Structure Modernization (LOW RISK, FILESYSTEM ONLY, ~1 day)

**Goal:** reorganize flat 90-file directories into layered, navigable structures. Swift doesn't care about file paths within a target, so zero code changes are required (just `git mv`).

**Note:** `Stores/Audio/` from Phase 1 already exists. The rest is filesystem reorganization.

### 5.1 Target layouts

**`Packages/Animate/Sources/AnimateUI/Services/`** (~90 files) →
```
Services/
  Audio/              (AnimationAudioPlayer, AutoLipSyncService, LipSyncEngine, RunPodMouthSyncService, VideoExporter, FBXMotionClipLoader, AudioLipSyncRecorder, RhubarbLipSync, etc.)
  Characters/         (CharacterPackageImportService, CharacterPackageLibrary, CharacterPackageRigSyncService, CharacterPackageValidator, CharacterPartsLibraryService, CharacterCostumeGenerationRulesStore)
  Gemini/             (GeminiCredentialStore, GeminiImageService)
  ImageIntelligence/  (already a subdir — leave as-is, reference architecture)
  Imagine/            (ImagineGenerationService, ImagineProjectStorage, ImagineScenePromptService, ImagineThumbnailCache)
  Infrastructure/     (AnimateAPIServer, AnimateSceneExecutionService, AnimateSceneOrchestrationService, AnimateSceneShotSeedingService, ProjectDatabaseBridge→AnimateProjectBridge, ProjectCredentialStore, OWPProjectLoader, PerfSignposts, AppLog)
  LLM/                (AnimateLLMAgent, LLMAnimationPlanCompiler, LLMAnimationPlanGenerator, LLMShotPromptCompilerService, SupplementalLLMClient, ContinuityPromptMemoryCompiler, ContinuityRuleExtractionService, DirectionTemplateCompiler, CanvasPromptGeneratorService)
  Motion/             (ActingBeatMotionPlanner, AnimationEngine, HunyuanMotionService, MotionClipStore, VisionBodyTracker)
  Places/             (BackgroundGenerationService, BackgroundPlaceholderService, GenerationReferenceImageResolver, PlaceWorldContinuityAnalyzer, PlacesScriptIndexService, ReferenceSheetBackgroundRemover, ReferenceSheetCropService, ThumbnailBackgroundRemover)
  Scene/              (SceneAutomationPlanner, SceneDirectionParser, SceneShotPresetStore, ShotDirectorServices)
  Shot/               (AnimatePlanShotAnchorResolver, AnimationAssetRequestPlanner, ShotFrameGenerationDryRunPlanner, ShotFrameGenerationPlanResolver, ShotGenerationSettingsStore, ShotPromptProtocolStore, StoryboardComposerService)
  MiniMax/            (MiniMaxAutomationScaffoldService, MiniMaxCredentialStore, MiniMaxPromptService)
  ImagePreferences/   (ImagePreferenceProfileService, ImageReviewFeedbackService, ActionImageService)
  OpenAI/             (OpenAIImageGenerationService, OpenAITextGenerationService, VertexAIClient)
  Vidu/               (ViduAPIService, ViduCredentialStore)
  RunPod/             (RunPodAccountService, RunPodCredentialStore)
  Capture/            (CaptureSession)
  Animate3D/          (keep existing subdir structure)
```

**`Packages/Animate/Sources/AnimateUI/Views/`** (~80 files) →
```
Views/
  Characters/         (CharacterPackageCardView, CharacterPartsLibraryPane, CharacterRigEditor, CharacterLookDevelopment*, CostumesPane, CostumeSectionView, CharacterInspirationPromptCatalog, CharacterQueueControlsBar, etc.)
  Places/             (PlacesMap3DView, PlacesOverviewPill, PlacesPageView, PlacesWorldbuildingViews, PlaceGridCard, PlaceLandmarkDetailView, PlaceLandmarkProfileCard, PlaceReferenceThumbnailCard, Map3DCameraPickerSheet)
  Imagine/            (ImagineCanvasPageView, ImagineCharactersPageView, ImagineSceneShotGalleryView, ImagineScenesPageView)
  Animation/          (AnimatePageView, CanvasView, TimelinePageView, TimelineView, TransportBar)
  Inspector/          (InspectorView, UnifiedDetailsInspector, InspectorView+FormFieldHelpers)
  Gemini/             (GeminiGenerationPreflightSheet, GeminiGenerationView, GeminiSettingsSheet, GeminiStatusBadge)
  AllProjectImages/   (AllProjectImagesPageView, AngleImageCard, AsyncApprovedVariantView, AsyncStoreThumbnailImage, BackgroundRemovedThumbnailView, CachedPreviewImage, CachedThumbnailView)
  Common/             (DebouncedTextEditorRow, ResizableSheetWindowAccessor, SidebarView, UniversalImagePickerSheet, SceneDirectionEditorView)
  Motion/             (already a subdir)
  Unified/            (already a subdir)
  Export/             (ExportView)
  GlobalSettings/     (GlobalSettingsSheet)
  Expression/         (ExpressionBatchSheet, ExpressionLibraryView)
  Script/             (ScriptPageView)
  Shot/               (ShotFilmstripView, ShotFrameCard, ShotProductionStripView, ShotReferenceSectionView)
  ImageEraser/        (ImageEraserView)
  AudioWaveform/      (AudioWaveformTrackView)
```

**`Packages/Score/Sources/ScoreUI/Views/`** (~25 files) →
```
Views/
  PianoRoll/          (PianoRollEditorView, PianoRollToolbarView, PianoRollViewController, PianoRollMetalRenderer, IOSPianoRollView)
  Notation/           (ScoreNotationView, ChordTrackView, ArticulationLaneView, ExpressionLaneView, ExpressionMapEditorView, RehearsalMarkView)
  Inspector/          (ExportInspectorView, FilesInspectorView, VersionHistoryView, KeyboardShortcutsView, PlaybackEngineSelectorView)
  Mixer/              (MixerView, FXChainView)
  Instruments/        (InstrumentMappingPanel, InstrumentLibraryView)
  AudioUnit/          (AudioUnitBrowserView, AudioUnitPluginView)
  Arrangement/        (WavArrangementView, TemplateBrowserView)
  Automation/         (AutomateView)
  Common/             (ContentView, IOSContentView)
```

**`Packages/Score/Sources/ScoreUI/Stores/`** (new directory, populated in Phases 1 and 4A) →
```
Stores/
  Audio/              (MetronomeEngine, RecordingEngine, MeterManager, ExportBufferConfig — from Phase 1; MIDIPlaybackEngine core moves here from Services/)
  ExportStore.swift   (from Phase 4A)
  VersionManager.swift
  MusicIntelligenceStore.swift
  APIStore.swift
  CompositionStore.swift
```

**`Packages/Animate/Sources/AnimateUI/Stores/`** (new directory, populated in Phase 4B) →
```
Stores/
  Places/             (PlaceGenerationEngine, BackgroundStore, PlaceAngleManager, PlacesWorldbuildingCoordinator)
  MotionCaptureStore.swift
  NLATimelineStore.swift
  GenerationSettingsStore.swift
  CanvasStore.swift
  ImageEraserStore.swift
  AnimationPipelineStore.swift
  ImagineStore.swift
  CharacterStore.swift
  CharacterReferenceWorkflowStore.swift
  InspirationImagesStore.swift
  OWPCoordinator.swift
```

**`Sources/WriteUI/Views/`** (~11 files) →
```
Views/
  Editor/             (StructuredScriptTextEditor, ScriptCenterView, ScriptCardLaneView)
  Inspector/          (ScriptInspectorView, LLMInspectorView, LLMSettingsView)
  Sidebar/            (ScriptSidebarView, SynopsisSectionView)
  Common/             (ContentView)
  GlobalChangeLog/    (GlobalChangeLogWindowView)
  LyricOverlay/       (StructuredTextOnlyLyricOverlayView)
```

**`Sources/Opera/`** (~2 files) → split as OperaShellView is decomposed:
```
Opera/
  App/                (OperaApp.swift)
  Shell/              (OperaShellView decomposition pieces)
```

**`Sources/MixUI/Views/`** (~10 files) →
```
Views/
  Timeline/           (MixTimelineView, MixClipView, MixRulerView, MixTrackHeaderView)
  Inspector/          (MixInspectorView)
  Mixer/              (MixMixerDockView)
  Sidebar/            (MixSceneSidebarView)
  Toolbar/            (MixToolbarView)
  Automation/         (MixAutomationView)
  Workspace/          (MixWorkspaceContentView)
```

### 5.2 Migration procedure

1. Create all target subdirectories first (empty dirs).
2. `git mv <old-path> <new-path>` for each file. Verify after every ~10 moves with `swift build -c release`.
3. Commit per logical group: `git commit -m "Phase 2: reorganize AnimateUI/Services into subdirectories"`.
4. Update `AGENTS.md` canonical-paths references.
5. Update docs that cite file paths (`docs/API.md`).

### 5.3 Phase 2 verification
```bash
/usr/bin/swift build -c release --product Opera
```

### 5.4 Phase 2 spot-checks
```bash
# No Services/ directory has >30 files
find . -path '*/Sources/*/Services/*.swift' \
  -not -path '*/.build/*' -not -path '*/build/*' \
  -printf '%h\n' | sort -u | while read d; do
    count=$(ls -1 "$d"/*.swift 2>/dev/null | wc -l)
    echo "$count $d"
done | sort -rn | head

# Every new subdirectory has a README.md
find . -path '*/Sources/*/Services/*/' -type d \
  -not -path '*/.build/*' -not -path '*/build/*' \
  | while read d; do
    [ -f "$d/README.md" ] || echo "MISSING README: $d"
done
# Should be empty.
```

### 5.5 Rollback

Each commit reversible via `git revert`. Directories can be flattened again.

---

## 6. Phase 3 — View Layer Decomposition (MEDIUM RISK, ~3 days)

**Goal:** decompose the view-layer monoliths that hurt agent navigation. No store logic is touched.

### 6.1 Prioritized file list

| File | Size | MARK sections | Category | Priority |
|------|------|--------------|----------|----------|
| `PlacesWorldbuildingViews.swift` | 257K | 0 | B (pre-mark) | P0 |
| `AnimatePageView.swift` | 234K | 0 | B (pre-mark) | P0 |
| `PlacesPageView.swift` | 217K | 4 existing | A | P0 |
| `PianoRollViewController.swift` | 206K | 3 existing | A | P0 |
| `AllProjectImagesWorkspace.swift` | 142K | 7 existing | A | P1 |
| `StructuredScriptTextEditor.swift` | 135K | 0 | B (pre-mark) | P1 |
| `AutomationServices.swift` | 129K | 0 | B (pre-mark) | P1 |
| `InspectorView.swift` (AnimateUI) | 115K | some | A | P1 |
| `AnimateAPIServer.swift` | 114K | 4 existing | A | P1 |
| `CharactersPageView.swift` | 112K | 8 existing | A | P2 |
| `ScriptCenterView.swift` | 110K | 7 existing | A | P2 |
| `OperaShellView.swift` | 81K | unprofiled | TBD | P2 |
| `AnimateSceneOrchestrationService.swift` | 89K | 0 | B (pre-mark) | P2 |
| `PianoRollToolbarView.swift` | 87K | 9 existing | A | P2 |
| `AllProjectImagesPageView.swift` | 57K | 2 existing | A | P3 |

**Category A** (existing MARK structure): skip pre-marking, go straight to extraction
**Category B** (0-4 MARKs): full Appendix F MARK-first treatment

### 6.2 MARK-First Methodology — Two-Step Decomposition

**Step 3.X.1 — Add MARK sections (no behavior change, single commit)**
- Read the file completely
- Identify 8-15 logical groupings
- Insert `// MARK: - <Section>` comment-only lines at each boundary
- Verify build passes
- Commit: `Phase 3.X.1: add MARK structure to <filename>.swift`

**Step 3.X.2 — Extract each MARK group into a file (one per commit)**

Each MARK-bounded section becomes a new file. Commit message: `Phase 3.X.2: extract <section name> from <filename>.swift`

### 6.3 Proposed MARK Boundaries (verified 2026-05-25)

#### `PlacesWorldbuildingViews.swift` (257K, 0 MARKs, Category B)
```
// MARK: - Top-level Composition
// MARK: - Library Sidebar Panel
// MARK: - World Graph Editor Panel
// MARK: - World Graph Node Renderer
// MARK: - World Graph Edge Renderer
// MARK: - Inspector Panel
// MARK: - Route Management Panel
// MARK: - Node Properties Form
// MARK: - World Generation Controls
// MARK: - Shared Styles and Layout Constants
// MARK: - Preview Providers
```

#### `AnimatePageView.swift` (234K, 0 MARKs, Category B)
```
// MARK: - Top-level Page Composition
// MARK: - Characters Tab
// MARK: - Timeline Tab
// MARK: - Canvas Tab
// MARK: - Inspector Tab
// MARK: - Transport Bar
// MARK: - Tab Switcher Controls
// MARK: - Shared Layout Constants
// MARK: - Preview Providers
```

#### `PlacesPageView.swift` (217K, 4 existing MARKs, add only)
Existing: `Sidebar`, `Reference Card`, `Angle Image Card`, `Main Page View`
Add:
```
// MARK: - Library Panel
// MARK: - Map Panel
// MARK: - Landmarks Panel
// MARK: - World Map Panel
// MARK: - Inspector Panel
// MARK: - Shared Styles
```

#### `PianoRollViewController.swift` (206K, 3 existing MARKs, add only)
Existing: `Lane Resize Handle`, `Empty State View`, `Note Properties Popover`
Add:
```
// MARK: - View Controller Lifecycle
// MARK: - Metal Renderer Setup
// MARK: - Scroll and Zoom Handling
// MARK: - Note Selection and Drag
// MARK: - Velocity Editing
// MARK: - Context Menu
// MARK: - Keyboard Shortcuts
// MARK: - Piano Key Column
// MARK: - Beat Ruler Overlay
// MARK: - Playback Cursor
// MARK: - Inspector Binding
```

#### `StructuredScriptTextEditor.swift` (135K, 0 MARKs, Category B)
```
// MARK: - Top-level Editor Composition
// MARK: - Script Text Rendering
// MARK: - Bracket Markup Parser
// MARK: - Card Inline Renderer
// MARK: - Lyric Line Rendering
// MARK: - Text Selection and Cursor Management
// MARK: - Editing Operations
// MARK: - Undo Redo Coordination
// MARK: - Keyboard and Input Handling
// MARK: - Shared Text Utilities
```

#### `AutomationServices.swift` (129K, 0 MARKs, Category B)
```
// MARK: - Top-level Orchestration
// MARK: - Scene Automation Planner
// MARK: - Shot Generation Coordinator
// MARK: - Character Reference Resolver
// MARK: - Background Generation Service
// MARK: - Continuity Rules Engine
// MARK: - Prompt Template Compiler
// MARK: - Asset Pipeline Service
// MARK: - Batch Processing Controller
// MARK: - Vertex AI Integration
// MARK: - Shared Service Utilities
// MARK: - Service Configuration
```

#### `InspectorView.swift` (AnimateUI, 115K, verify MARKs)
Verify MARK structure via grep before extracting.

#### `AnimateAPIServer.swift` (114K, 4 existing MARKs, Category A)
Existing: `AnimateAPIServer`, `AnimateAPIRouter`, `AnimateHTTPRequest`, `AnimateHTTPResponse`
Consider further subdivision of `AnimateAPIRouter` (2,300+ lines at line 195).

#### `CharactersPageView.swift` (112K, 8 existing MARKs, Category A)
Existing: `Async Image Helper Views`, `Image Gallery Section`, `Image Gallery Thumbnail`, `Image Preview Overlay`, `Image Cropper View`, `Inspiration Gallery Sheet`, `Reference Images Sheet`, `Array Safe Subscript`.

#### `ScriptCenterView.swift` (110K, 7 existing MARKs, Category A)
Existing: `Center Content`, `Scrollable Script Body`, `Script Section (Editable)`, `Script Text Editor (NSTextView wrapper)`, `Inline Shot Cards`, `Script Text Host View`, `Preference Key for Section Visibility`.

#### `OperaShellView.swift` (81K, unprofiled)
Profile before extraction. Likely: shell chrome, workspace switcher, navigation rail, project toolbar.

#### `AnimateSceneOrchestrationService.swift` (89K, 0 MARKs, Category B)
```
// MARK: - Top-level Orchestration
// MARK: - Scene Execution Coordinator
// MARK: - Shot Sequencing Manager
// MARK: - Character Animation Resolver
// MARK: - Background Integration Service
// MARK: - Timeline Synchronization
// MARK: - Error Recovery and Retry Logic
// MARK: - Shared Orchestration Utilities
```

#### `PianoRollToolbarView.swift` (87K, 9 existing MARKs, Category A)
Existing: `Tool and Snap Enums`, `Scale Enums`, `Chord Detection and Stamp`, `PianoRollToolbarView`, `RepeatButton`, `Standalone LCD View`, `Audio Waveform Activity Indicator`, `Width-Aware Toolbar Hosting View`, `Status Bar View`.

#### `AllProjectImagesWorkspace.swift` (142K, 7 existing MARKs, Category A)
Existing: `Shared State (observable across the 3 panes)`, `Public Workspace`, `Three-Pane Content`, `Left Sidebar (source filter)`, `Right Inspector (Details | Edit with Gemini)`, `Image Intelligence Summary (Details tab)`, `Inspector Image Intelligence Tab`.

#### `AllProjectImagesPageView.swift` (57K, 2 existing MARKs, add only)
Existing: `Shared types`, `Center Pane`
Add:
```
// MARK: - Search Controls
// MARK: - Sort Controls
// MARK: - Grid Layout
// MARK: - Preview Sheet
```

### 6.4 Standard decomposition rules

1. **Read the file completely** before touching it.
2. **Extract each panel into its own file** as a `struct PanelName: View`.
3. **Preserve the exact render output** — no visual or behavioral changes.
4. **Never reconstruct stores inside a child view**. Use `@Bindable var store: SomeStore`.
5. **Verify after every extraction:** `/usr/bin/swift build -c release`.
6. **Never extract more than one panel per commit.**

### 6.5 Anti-patterns (DO NOT repeat)

- ❌ Replacing a full editing panel with a summary panel (`ScoreInstrumentSummaryPanel` regression).
- ❌ Automated `DisclosureGroup` → `OperaChromeCollapsibleSection` conversion via regex.
- ❌ Mass-search-and-replace on binding property names.
- ❌ Extracting a 50-line view that takes 15 parameters.

### 6.6 Phase 3 spot-checks
```bash
# No view file exceeds 150K after decomposition
find . -path '*/Sources/*/Views/*.swift' \
  -not -path '*/.build/*' -not -path '*/build/*' \
  -exec wc -c {} + | sort -rn | head -10
```

---

## 7. Phase 4A — ScoreStore Split (LOW-MEDIUM RISK, ~2 days)

**Goal:** split the 8,819-line ScoreStore into 6 focused pieces. Source: `Packages/Score/Sources/ScoreUI/ScoreStore.swift` (383.4K, 72+ MARK sections — see Appendix H.2 for exact line numbers).

**New file location:** `Packages/Score/Sources/ScoreUI/Stores/` (created in Phase 2).

### 7.1 Step 4A.1: Extract ExportStore (~3,800 lines)

**Source MARK sections:** `// MARK: - Full Mix Export`, `// MARK: - Batch / Send-to-Mix Export`, `// MARK: - Freeze / Bounce`, `// MARK: - Track Freeze / Bounce`

**New file:** `Packages/Score/Sources/ScoreUI/Stores/ExportStore.swift`

**Type:** `@Observable @MainActor final class ExportStore`

**Contents:**
- Full Mix Export
- Rehearsal Track Export
- Stem Export
- Batch Export (Send-to-Mix)
- Offline WAV Renderer
- All export properties and 36 functions

**Data access:** Each export creates its own `MIDIPlaybackEngine` instance (already the pattern). Pass `pianoRollNotes`, `instrumentMappings`, and `selectedMidiAsset` as parameters or snapshot at export start. Never keep weak references inside long-running async export work — use snapshots.

**Parent relationship:** ScoreStore holds `private(set) var exportStore: ExportStore`

**ScoreStore facade:** Keep `exportFullMix()`, `exportBatch()` as thin wrappers:
```swift
func exportFullMix(to url: URL) async throws {
    try await exportStore.exportFullMix(to: url)
}
```

**Risk:** Low-Medium. Exports are read-only consumers and create their own engines. Snapshot-based data access is the key discipline.

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -A 3 "func exportFullMix" Packages/Score/Sources/ScoreUI/ScoreStore.swift` (should be single-line delegation)
**Commit:** `git commit -am "Phase 4A step 1: extract ExportStore from ScoreStore"`

### 7.2 Step 4A.2: Extract VersionManager (~220 lines)

**Source:** Version-related functions (search for "version" or MARK sections in the 1200-1300 range).

**New file:** `Packages/Score/Sources/ScoreUI/Stores/VersionManager.swift`

**Type:** `final class VersionManager`

**Contents:** Pure CRUD on `songAssets[...].document.versions`.

**Risk:** Very Low. Self-contained.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4A step 2: extract VersionManager from ScoreStore"`

### 7.3 Step 4A.3: Extract MusicIntelligenceStore (~250 lines)

**Source MARK section:** `// MARK: - Music Intelligence Engine` (line 1255)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/MusicIntelligenceStore.swift`

**Type:** `@Observable @MainActor final class MusicIntelligenceStore`

**Contents:** Read-only analysis functions, 15 functions.

**Risk:** Low. Read-only, produces independent results.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4A step 3: extract MusicIntelligenceStore from ScoreStore"`

### 7.4 Step 4A.4: Extract APIStore (~300 lines)

**Source MARK section:** `// MARK: - API Server` (line 1283)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/APIStore.swift`

**Type:** `@Observable @MainActor final class APIStore`

**Contents:** `APIServer` lifecycle, 20 API diagnostic endpoints (read-only introspection).

**Risk:** Low. Already running on own port; read-only diagnostics.

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -n "APIServer" Packages/Score/Sources/ScoreUI/ScoreStore.swift` (should be minimal)
**Commit:** `git commit -am "Phase 4A step 4: extract APIStore from ScoreStore"`

### 7.5 Step 4A.5: Extract CompositionStore (~500 lines)

**Source MARK sections:** `// MARK: - LLM` (line 1310), `// MARK: - Style & Composition` (line 1331), `// MARK: - MidiAI` (line 1337)

**New file:** `Packages/Score/Sources/ScoreUI/Stores/CompositionStore.swift`

**Type:** `@Observable @MainActor final class CompositionStore`

**Contents:** LLM Methods, Style & Composition, MidiAI stubs, 18 functions. Uses external services (`LLMClient`, `MidiAI`) with read-only access to `pianoRollNotes`.

**Risk:** Low. Read-only analysis + external API calls.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4A step 5: extract CompositionStore from ScoreStore"`

### 7.6 Step 4A.6: InstrumentMappingPanel sub-structs (~370 lines)

**Source file:** `Packages/Score/Sources/ScoreUI/Views/InstrumentMappingPanel.swift` (already has MARK sections from Phase 3 extraction).

**Action:** Extract subviews as small files in `Views/Instruments/`.

**Risk:** Very Low. View-only extraction.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4A step 6: extract InstrumentMappingPanel sub-views"`

### 7.7 Step 4A.7: Verify + Deploy

After all 6 extractions:
- ScoreStore.swift reduced from 8,819 → ~4,000 lines (irreducible core: note editing, playback orchestration, instrument mapping CRUD, project I/O, the four entangled properties — see original spec Appendix H.2)
- 5 new stores in `Packages/Score/Sources/ScoreUI/Stores/`
- 1 view file split
- Deploy via `Scripts/build-app.sh`
- **Commit:** `git commit -am "Phase 4A: ScoreStore split complete"`

### 7.8 Phase 4A spot-checks
```bash
ls Packages/Score/Sources/ScoreUI/Stores/
# Should list: Audio/, ExportStore.swift, VersionManager.swift, MusicIntelligenceStore.swift, APIStore.swift, CompositionStore.swift

wc -l Packages/Score/Sources/ScoreUI/ScoreStore.swift
# Should be ~4,000 lines (down from 8,819)

# Verify facade methods are thin wrappers
grep -A 3 "func exportFullMix" Packages/Score/Sources/ScoreUI/ScoreStore.swift
# Should show single-line delegation
```

---

## 8. Phase 4B — AnimateStore Split (LOW → HIGH RISK, ~4 days)

**Goal:** decompose the 20,417-line AnimateStore into 14 focused pieces. Source: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` (875.3K, 74 MARK sections — see Appendix H.3 for exact line numbers).

**New file location:**
- `Packages/Animate/Sources/AnimateUI/Stores/` (general domain stores)
- `Packages/Animate/Sources/AnimateUI/Stores/Places/` (Places domain)

**Risk profile:** Steps 1-10 are Low-Medium. Steps 11-12 are **HIGH** (nested Backgrounds/Places monolith). Steps 13-14 are Low.

### 8.1 Step 4B.1: Extract MotionCaptureStore (~500 lines)

**Source MARK sections:** `// MARK: - Motion Capture State` (line 302), `// MARK: - Enhanced Tracking Mode (Phase 7)` (line 20212), `// MARK: - Audio Lip Sync Recording` (line 20190)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/MotionCaptureStore.swift`

**Type:** `@Observable @MainActor final class MotionCaptureStore`

**Contents:** `mocapCaptureSession`, `mocapBodyTracker`, `mocapLatestPoseFrame`, `mocapIsRunning`, all NLA/bone/pose state. Note: `nonisolated(unsafe)` on the capture session.

**Risk:** Low. Nearly self-contained.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 1: extract MotionCaptureStore from AnimateStore"`

### 8.2 Step 4B.2: Extract NLATimelineStore (~190 lines)

**Source MARK sections:** `// MARK: - NLA Evaluation` (line 2571), `// MARK: - NLA Motion Clip Placement` (line 19995), `// MARK: - Motion Clip Management (Phase 3)` (line 19989), `// MARK: - BVH Export` (line 20097), `// MARK: - Clip Speed` (line 20118)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/NLATimelineStore.swift`

**Type:** `@Observable @MainActor final class NLATimelineStore`

**Contents:** `nlaTimeline`, `motionClips`, NLA evaluation, clip management, BVH export, clip speed.

**References:** `currentFrame` for evaluation.

**Risk:** Low. Only references currentFrame.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 2: extract NLATimelineStore from AnimateStore"`

### 8.3 Step 4B.3: Extract GenerationSettingsStore (~250 lines)

**Source:** Search for "Gemini", "MiniMax", "Vidu" credential/settings in AnimateStore.

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/GenerationSettingsStore.swift`

**Type:** `@Observable @MainActor final class GenerationSettingsStore`

**Contents:** Gemini/MiniMax/Vidu settings, API keys, credential stores, image analysis settings.

**Risk:** Very Low. Pure credential/settings management.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 3: extract GenerationSettingsStore from AnimateStore"`

### 8.4 Step 4B.4: Extract CanvasStore (~120 lines)

**Source MARK section:** `// MARK: - Canvas Generation` (line 317)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/CanvasStore.swift`

**Type:** `@Observable @MainActor final class CanvasStore`

**Risk:** Very Low. Self-contained state machine.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 4: extract CanvasStore from AnimateStore"`

### 8.5 Step 4B.5: Extract ImageEraserStore (~135 lines)

**Source MARK section:** `// MARK: - Background Removal (Re-mask transparent PNGs)` (line 10982)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/ImageEraserStore.swift`

**Type:** `@Observable @MainActor final class ImageEraserStore`

**Risk:** Very Low. Self-contained state machine.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 5: extract ImageEraserStore from AnimateStore"`

### 8.6 Step 4B.6: Extract AnimationPipelineStore (~420 lines)

**Source MARK sections:** `// MARK: - Lip Sync Generation` (line 19541), `// MARK: - Video Export` (line 19480), `// MARK: - Camera Choreography` (line 19646), `// MARK: - Batch Scene Processing (Item 17)` (line 19950), `// MARK: - LLM Animation Plan Generation` (line 19733)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/AnimationPipelineStore.swift`

**Type:** `@Observable @MainActor final class AnimationPipelineStore`

**Contents:** Lip Sync, Video Export, Camera Choreography, Batch Scene Processing, LLM Animation Plan. All read-only pipelines consuming scene/character data without mutating shared state.

**Risk:** Very Low. All read-only consumers.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 6: extract AnimationPipelineStore from AnimateStore"`

### 8.7 Step 4B.7: Extract ImagineStore (~200 lines)

**Source MARK sections:** `// MARK: - Imagine State` (line 364), `// MARK: - Imagine Gallery Management` (line 20243)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/ImagineStore.swift`

**Type:** `@Observable @MainActor final class ImagineStore`

**Risk:** Very Low. Self-contained.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 7: extract ImagineStore from AnimateStore"`

### 8.8 Step 4B.8: Extract CharacterStore (~1,750 lines)

**Source MARK section:** `// MARK: - Characters` (line 275)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/CharacterStore.swift`

**Type:** `@Observable @MainActor final class CharacterStore`

**Contents:** Character CRUD, profile management, text fields, ordering.

**References:** `characters` array and `animateURL`.

**Parent relationship:** AnimateStore holds `private(set) var characterStore: CharacterStore`.

**AnimateStore facade:** `var characters: [CharacterRecord] { characterStore.characters }`

**Risk:** Medium. 694 call sites reference `store.characters`. However, `@Observable` tracks nested observable properties automatically, so view bindings like `store.characters` keep working without changes — this is the critical safety rule.

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -n "store.characters" Packages/Animate/Sources/AnimateUI/**/*.swift | head -5` (verify facade works)
**Commit:** `git commit -am "Phase 4B step 8: extract CharacterStore from AnimateStore"`

### 8.9 Step 4B.9: Extract CharacterReferenceWorkflowStore (~1,270 lines)

**Source MARK section:** `// MARK: - Look Development Board` (line 11337)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/CharacterReferenceWorkflowStore.swift`

**Type:** `@Observable @MainActor final class CharacterReferenceWorkflowStore`

**Contents:** 59 functions for master sheets, head turnaround, costume sets, background removal.

**References:** `characters`, `animateURL`, `fileOWPURL`, `allImagesContentRevision`.

**Risk:** Medium. Heavy function count but thematically coherent.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 9: extract CharacterReferenceWorkflowStore from AnimateStore"`

### 8.10 Step 4B.10: Extract InspirationImagesStore (~1,150 lines)

**Source:** MARK sections for inspiration, reference, shot reference, animated images (search AnimateStore for these).

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/InspirationImagesStore.swift`

**Type:** `@Observable @MainActor final class InspirationImagesStore`

**Contents:** Inspiration, reference, shot reference, and animated images.

**References:** `characters`, `animateURL`, `fileOWPURL`.

**Risk:** Medium. Similar pattern to Character Reference Workflow.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 10: extract InspirationImagesStore from AnimateStore"`

### 8.11 Step 4B.11: Extract PlaceGenerationEngine (~3,500 lines) — **HIGH RISK**

**Source MARK sections:**
- `// MARK: - Image Intelligence (Phase 1-6)` (line 1014)
- `// MARK: - AI Generation Activity Queue` (line 14449)
- `// MARK: - Per-activity cancellation` (line 14534)
- `// MARK: - Vertex image-generation attempt ledger` (line 14567)
- `// MARK: - Vertex AI free-trial credit tracking` (line 14669)
- `// MARK: - Loopback API: Place Image Generation` (line 15906)
- Related helpers in `// MARK: - Private Helpers` (line 16941)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/Places/PlaceGenerationEngine.swift`

**Type:** `@Observable @MainActor final class PlaceGenerationEngine`

**Contents:** AI generation activity queue, cancellation, vertex tracking, credit tracking, loopback API.

**References (TIGHT COUPLING):** `backgrounds`, `placesWorkflowLibrary`, `scriptPlaceRequirements`, dozens of private caches.

**Risk: HIGH.** This is the hardest extraction. Strategy:
1. First, separate the **generation queue** (pure state machine) from the **AI client calls** (external integration)
2. Extract in two pieces: `PlaceGenerationQueue` then `PlaceAIClient`
3. Use snapshots for any long-running async work; never pass weak references to background tasks
4. Add at least 2 smoke tests before extraction to catch regression

**Verification:** `/usr/bin/swift build -c release`
**Spot-check:** `grep -n "backgrounds\|placesWorkflowLibrary" Packages/Animate/Sources/AnimateUI/AnimateStore.swift | wc -l` (should decrease significantly)
**Commit:** `git commit -am "Phase 4B step 11: extract PlaceGenerationEngine from AnimateStore (HIGH RISK)"`

### 8.12 Step 4B.12: Extract BackgroundStore (~2,500 lines) — **HIGH RISK**

**Source MARK sections:** `// MARK: - Background Management` (line 11498), `// MARK: - Place Angle Images` (line 14992)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/Places/BackgroundStore.swift`

**Type:** `@Observable @MainActor final class BackgroundStore`

**Contents:** CRUD, approved images, filtering, indexing.

**Dependency:** Extracted after PlaceGenerationEngine to minimize shared state.

**Risk: HIGH.** Tight coupling with PlaceGenerationEngine.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 12: extract BackgroundStore from AnimateStore (HIGH RISK)"`

### 8.13 Step 4B.13: Dissolve Computed Section (~4,150 lines)

**Source MARK sections:** `// MARK: - Computed` (line 2632), `// MARK: - Track Resolution Cache Types & Helpers` (line 19793)

**Action:** **Not a single extraction.** This is a dissolution task spanning multiple commits. After all domain stores are extracted (Steps 4B.1-12), move each computed property to its owning store mechanically — no logic changes.

**Nature:** Mechanical relocation. Risk is low only because the domains are already extracted.

**Procedure:**
1. Read the "Computed" section line by line
2. For each property: identify which new store owns it
3. Move it to that store via `git mv` + edit
4. Build. Commit per 5-10 properties.

**Risk:** Low **after** domains are extracted. Mechanical relocation.

**Verification:** `/usr/bin/swift build -c release` after each batch of 5-10 properties
**Commit:** `git commit -am "Phase 4B step 13: dissolve Computed section batch N into domain stores"`

### 8.14 Step 4B.14: Extract OWPCoordinator (~650 lines)

**Source MARK sections:** `// MARK: - OWP Project` (line 190), `// MARK: - App Support Directory` (line 8758)

**New file:** `Packages/Animate/Sources/AnimateUI/Stores/OWPCoordinator.swift`

**Type:** `final class OWPCoordinator` (not `@Observable` — it's stateless orchestration)

**Contents:** `openOWP()`, save, persistence functions. Delegates to sub-stores.

**Risk:** Low at this point. All sub-stores already extracted. Becomes a thin orchestration layer, not a store.

**Verification:** `/usr/bin/swift build -c release`
**Commit:** `git commit -am "Phase 4B step 14: extract OWPCoordinator from AnimateStore"`

### 8.15 Step 4B.15: Verify + Deploy

After all 14 extractions:
- AnimateStore.swift reduced from 20,417 → ~650 lines (pure facade/coordinator with passthrough vars)
- 13 new stores in `Packages/Animate/Sources/AnimateUI/Stores/` (including `Stores/Places/` subdirectory)
- Deploy via `Scripts/build-app.sh`
- **Commit:** `git commit -am "Phase 4B: AnimateStore split complete"`

### 8.16 Phase 4 spot-checks (4A and 4B combined)

```bash
# ScoreUI stores
ls Packages/Score/Sources/ScoreUI/Stores/

# AnimateUI stores
ls Packages/Animate/Sources/AnimateUI/Stores/

# AnimateUI Places subdomain
ls Packages/Animate/Sources/AnimateUI/Stores/Places/
# Should list: PlaceGenerationEngine.swift, BackgroundStore.swift, PlaceAngleManager.swift, PlacesWorldbuildingCoordinator.swift

# Final line counts
wc -l Packages/Animate/Sources/AnimateUI/AnimateStore.swift
# Should be ~650 lines (down from 20,417)

wc -l Packages/Score/Sources/ScoreUI/ScoreStore.swift
# Should be ~4,000 lines (down from 8,819)

wc -l Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift
# Should be ~1,700 lines (down from 4,851)

# Verify facade properties work
grep -n "var characters:" Packages/Animate/Sources/AnimateUI/AnimateStore.swift
# Should show passthrough to characterStore
```

---

## 9. Phase 5 — Consolidation Sweep (LOW RISK, ~1 day)

### 9.1 Add `.swiftlint.yml` at repo root

```yaml
disabled_rules:
  - trailing_comma
  - todo
opt_in_rules:
  - empty_count
  - first_where
  - force_unwrapping
  - implicitly_unwrapped_optional
  - missing_docs
  - operator_usage_whitespace
  - overridden_super_call
  - private_action
  - private_outlet
  - prohibited_super_call
  - sorted_first_last
  - vertical_whitespace
  - weak_delegate
excluded:
  - .build
  - build
  - .claude
  - Packages/Score/.build
  - Packages/ProjectKit/.build
file_length:
  warning: 500
  error: 1000
function_body_length:
  warning: 60
  error: 120
type_body_length:
  warning: 300
  error: 600
cyclomatic_complexity:
  warning: 15
  error: 25
identifier_name:
  excluded:
    - id
    - x
    - y
    - z
    - r
    - g
    - b
    - a
```

Add to `Scripts/lint.sh` and document in AGENTS.md.

### 9.2 ProjectDatabaseBridge consolidation

Rename each domain bridge (per locked decision D0.2):
- `Sources/WriteUI/Services/ProjectDatabaseBridge.swift` → `WriteProjectBridge.swift`
- `Packages/Score/Sources/ScoreUI/Services/ProjectDatabaseBridge.swift` → `ScoreProjectBridge.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift` → `AnimateProjectBridge.swift`

Update ~30 call sites (found via grep).

### 9.3 Dead-code audit

By Phase 5, monolith splits expose dead code. Flag each candidate and ask Gary before removing. Never auto-delete.

### 9.4 Tests for new stores

Every new `XxxStore.swift` extracted in Phases 1 and 4 gets a companion smoke test:
```swift
@Test func store_initializes_with_defaults() {
    let store = XxxStore()
    #expect(store.initialState == .expectedValue)
}
```

### 9.5 MARK convention

- Every file > 200 lines: `// MARK: - Public API` at top listing public surface
- Every file > 500 lines: top-level `// MARK: - Section Name` per logical domain
- No `// MARK:` without `-` separator when a name follows
- Nested `// MARK:` within large types is fine

### 9.6 Phase 5 spot-checks
```bash
[ -f .swiftlint.yml ] && swiftlint lint 2>&1 | tail -20

# Verify bridges renamed
find . -name "ProjectDatabaseBridge.swift" -not -path "*/.build/*"
# Should be empty (all renamed)

find . -name "*ProjectBridge.swift" -not -path "*/.build/*"
# Should list: WriteProjectBridge.swift, ScoreProjectBridge.swift, AnimateProjectBridge.swift
```

---

## 10. Execution Order, Risk, and Duration (consolidated)

| # | Phase | Risk | Lines Affected | Files | Duration |
|---|-------|------|----------------|-------|----------|
| 0 | ProjectKit utilities | Low | ~280 migrations | 4 new + migrations | 1-2 days |
| 1 | MIDIPlaybackEngine split (4 steps) | Very Low | ~3,000 | 4 new | 1 day |
| 2 | Directory modernization | Low | 0 (filesystem) | 0 new (moves only) | 1 day |
| 3 | View decomposition (15 files) | Medium | 15 files decomposed | ~50 new subviews | 3 days |
| 4A | ScoreStore split (6 steps) | Low-Medium | ~5,070 | 5 stores + 1 view | 2 days |
| 4B | AnimateStore split (14 steps) | Low-High | ~19,747 | 13 stores | 4 days |
| 5 | Consolidation sweep | Low | Cleanup | ~6 new tests + lint config | 1 day |

**Total: ~14 days of focused work for an execution agent.**

---

## 11. Non-Negotiable Rules

1. Use `/usr/bin/swift build -c release`, NOT `rtk swift build`.
2. Build after EVERY extraction step.
3. Deploy after any successful batch that produces the app, via `Scripts/build-app.sh` to `!Applications/`.
4. Never mass-regex move functions between stores.
5. Preserve parent facades while moving internals.
6. One view or domain per commit.
7. Never extract more than one panel per commit in Phase 3.
8. Every commit message names the phase: e.g. `Phase 0 step 3: migrate WriteUI to ProjectKit utilities`.
9. **AnimateStore facade rule:** keep `store.characters`, `store.backgrounds`, etc. as passthroughs until all consumers migrated.
10. **Places rule:** do NOT attempt a single 8,700-line Backgrounds/Places extraction in one step. Split internally first.
11. **Export rule:** long-running export functions should receive explicit snapshots of notes, mappings, selected asset, tempo, output paths where practical. Prefer snapshots over weak refs inside async work.
12. **High-risk rule:** Phase 4B steps 11-12 (PlaceGenerationEngine, BackgroundStore) each get at least 2 smoke tests added BEFORE extraction to catch regression.

---

## 12. Stop Conditions

Stop and **ask Gary** if:

| Condition | Response |
|-----------|----------|
| Build failure spans unrelated changed files | Fix current step only, do not continue |
| Move requires broad access-level changes across many files | Switch to facade wrappers or smaller extraction |
| View loses editing capability or changes behavior | Revert that step only |
| Deleted retired-feature type seems needed by active workflow | Stop and identify active behavior |
| Animate Places extraction touches generation, CRUD, credits, and persistence in one edit | Split smaller |
| Uncertain whether a decision was already made | Grep the existing specs before asking; ask anyway if uncertain |
| Phase 4B steps 11-12 fail build 3+ times in a row | Stop and ask Gary — this is the failure-prone region |

---

## 13. Locked-in Decision Points

| ID | Decision | Locked Choice |
|----|----------|---------------|
| D0.1 | Logging strategy | **(c) both** — `os.Logger` primary + `/tmp/` mirror for grep |
| D0.2 | Bridge consolidation | **(a) rename** to `WriteProjectBridge` / `ScoreProjectBridge` / `AnimateProjectBridge` |
| D3.1 | View decomposition order | **(b) WriteUI first** as warm-up, then AnimateUI |
| D4.1 | AnimateStore timing | **(a) views first** — easier to verify visually |
| D5.1 | SwiftLint deployment | **(c) on-demand `Scripts/lint.sh`** initially |
| D5.2 | Dead-code aggressiveness | **(c) human review per candidate** |

If Gary wants to override any of these, update this section before executing the relevant phase.

---

## 14. What NOT to Do

1. ❌ Create a separate `SharedUtilities` package — ProjectKit IS the shared layer.
2. ❌ Auto-convert `DisclosureGroup` to `OperaChromeCollapsibleSection` via regex.
3. ❌ Replace full-feature views with summary views (`ScoreInstrumentSummaryPanel` regression).
4. ❌ Touch `Packages/*/.build/` or run index-build operations — tool-generated.
5. ❌ Add new targets/products to Package.swift during Phase 0 — keep graph stable.
6. ❌ Move files across package boundaries as part of Phase 2 — within-target only.
7. ❌ Try to fix tests during Phase 1 or 4 unless the split specifically broke them.
8. ❌ Refactor `ProjectKit/OWPModels.swift` or `ProjectModels.swift` — out of scope.
9. ❌ Touch `Packages/Animate/Sources/AnimateUI/_archived_3d/` — intentionally archived.
10. ❌ Edit `Info.plist`, `Opera.entitlements`, or `Package.resolved` unless the refactor requires it.
11. ❌ Pass weak parent store references into long-running async export/generate tasks — use snapshots.
12. ❌ Extract the "Computed" section (~4,150 lines) in AnimateStore as a single file — dissolve it into domain stores instead.

---

## 15. Expected Outcomes

| Metric | Before | After Phase 5 |
|--------|--------|---------------|
| Files > 200K | ~15 | 0 |
| Files > 100K | ~22 | ~3 (legitimate orchestrators) |
| Max store file size | 875K / 20,417 lines (AnimateStore) | ~30K / ~650 lines (facade coordinator) |
| ScoreStore | 383K / 8,819 lines | ~170K / ~4,000 lines (irreducible core) |
| MIDIPlaybackEngine | 209K / 4,851 lines | ~75K / ~1,700 lines (core) |
| Max view file size | 257K (PlacesWorldbuildingViews) | ~60K |
| Duplicated utilities | 58+ ISO8601, 271 emptiness checks, 6 nilIfEmpty, 2 amiraDebugLog, 3 ColorHex | 0 |
| Flat directories >50 files | 2 (AnimateUI/Services, AnimateUI/Views) | 0 |
| SwiftLint config | None | Present with file-size/complexity caps |
| New files created | 0 | ~75 (4 Audio + 5 Score stores + 13 Animate stores + ~50 view subviews + utilities) |

---

## Appendix A — Day 1 Checklist

Before ANY code changes:

1. **Read prerequisite docs:**
   - `AGENTS.md`
   - `README.md`
   - `history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md`
   - `history/HANDOFF-2026-03-21.md`
   - `history/OPERA-CONSOLIDATION-2026-03-21.md`
   - `history/OPERA-DEVELOPMENT-HISTORY-2026-03-21.md`
   - `docs/API.md`
   - This spec (the one you're reading)

2. **Establish a clean baseline:**
   ```bash
   cd "/Volumes/Storage VIII/Programming/Amira Writer"
   git status --short
   git log --oneline -5
   ```
   If the worktree is dirty: STOP. Ask Gary.

3. **Verify build is green:**
   ```bash
   /usr/bin/swift build -c release --product Opera
   ```
   If fails: STOP. Inform Gary.

4. **Capture test baseline:**
   ```bash
   /usr/bin/swift test -c release 2>&1 | tee /tmp/amira-test-baseline.log
   ```

5. **Create branch:**
   ```bash
   git checkout -b refactor/professionalization-2026-05-25
   ```

6. **Begin Phase 0.**

---

## Appendix B — Reference Architecture Patterns (COPY THESE)

| Reference | Why it's good |
|-----------|---------------|
| `Packages/Score/Sources/ScoreUI/Services/MusicEngine/` | 15 files, 8-30K each. Each analyzer is a single responsibility. |
| `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/` | 10 files + README. Clear separation: Store (coordination), DiscoveryService, SearchService, Client (external), Coordinator. |
| `Packages/Animate/Sources/AnimateUI/Services/Animate3D/` | Single file for narrow scope. |
| `Views/Motion`, `Views/Unified`, `Views/Capture` | Feature-aligned view grouping without over-engineering. |

**Rule of thumb:**
- 1 file → flatten
- 2-4 files → optional directory
- 5+ files → directory required
- 3+ file directory → README.md (3-10 lines)

---

## Appendix C — Pre-Existing Test State

Save baseline on Day 1 (checklist step 4).

| Target | Location | Known State |
|--------|----------|-------------|
| WriteTests | `Tests/WriteTests/` | `MixStoreTests` (29.9K), `ScriptStoreTests` (43.2K). Some pre-existing skips. |
| MixTests | `Tests/MixTests/` | Recently re-enabled (per 2026-05-25 handoff). |
| ScoreTests | `Packages/Score/Tests/ScoreTests/` | ~21 files; some broken from retired cloud-music removal. `RetiredCloudMusicFeatureGuardTests.swift` is a GUARD test — preserve it. |
| AnimateTests | `Packages/Animate/Tests/AnimateTests/` | 15 files. `LLMAnimationPlanCompilerTests` (76.7K), `PackagePipelineTests` (64.9K) dominate. |
| ProjectKitTests | `Packages/ProjectKit/Tests/ProjectKitTests/` | 3 files. Should be GREEN. |

**Test discipline:**
- Refactor breaks previously-passing test → fix it or revert.
- Test was broken before refactor → do not fix. Log and tell Gary.
- Never add tests for code you didn't change (except §9.4 smoke tests for new stores).

---

## Appendix D — Per-Phase Spot-Check Commands

### Phase 0
```bash
# No ISO8601DateFormatter() outside DateFormatters.swift/tests
rg "ISO8601DateFormatter\(\)" \
  --glob "*.swift" --glob "!*.build/**" --glob "!build/**" --glob "!**/*Tests.swift" \
  | grep -v "DateFormatters.swift"

rg "var nilIfEmpty: String\?" \
  --glob "*.swift" --glob "!*.build/**" --glob "!StringExtensions.swift"

rg "private func amiraDebugLog" \
  --glob "*.swift" --glob "!*.build/**"
```

### Phase 1
```bash
ls -la Packages/Score/Sources/ScoreUI/Stores/Audio/

wc -l Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift
# Should be ~1,700
```

### Phase 2
```bash
find . -path '*/Sources/*/Services/*.swift' \
  -not -path '*/.build/*' -not -path '*/build/*' \
  -printf '%h\n' | sort -u | while read d; do
    count=$(ls -1 "$d"/*.swift 2>/dev/null | wc -l)
    echo "$count $d"
done | sort -rn | head

find . -path '*/Sources/*/Services/*/' -type d \
  -not -path '*/.build/*' -not -path '*/build/*' \
  | while read d; do
    [ -f "$d/README.md" ] || echo "MISSING README: $d"
done
```

### Phase 3
```bash
find . -path '*/Sources/*/Views/*.swift' \
  -not -path '*/.build/*' -not -path '*/build/*' \
  -exec wc -c {} + | sort -rn | head -10
```

### Phase 4A
```bash
ls Packages/Score/Sources/ScoreUI/Stores/

wc -l Packages/Score/Sources/ScoreUI/ScoreStore.swift
# Should be ~4,000
```

### Phase 4B
```bash
ls Packages/Animate/Sources/AnimateUI/Stores/

ls Packages/Animate/Sources/AnimateUI/Stores/Places/
# Should list: PlaceGenerationEngine.swift, BackgroundStore.swift, PlaceAngleManager.swift, PlacesWorldbuildingCoordinator.swift

wc -l Packages/Animate/Sources/AnimateUI/AnimateStore.swift
# Should be ~650
```

### Phase 5
```bash
[ -f .swiftlint.yml ] && swiftlint lint 2>&1 | tail -20

find . -name "ProjectDatabaseBridge.swift" -not -path "*/.build/*"
# Should be empty

find . -name "*ProjectBridge.swift" -not -path "*/.build/*"
# Should list 3 renamed bridges
```

---

## Appendix E — Post-Completion Archival

After Phase 5 completes:

1. Move `2026-05-24-monolith-splitting-plan.md` to `docs/specs/archive/`. Add top-of-file note: `**STATUS:** Completed as part of 2026-05-25-codebase-professionalization-plan.md`.
2. Same for `2026-05-24-refactor-execution-game-plan.md`.
3. This spec becomes the active reference.
4. Update `AGENTS.md` to reference the new spec.
5. Create `history/HANDOFF-2026-05-25-CODEBASE-PROFESSIONALIZATION.md`.

---

## Appendix F — MARK Section Inventory for View Files

(See §6.3 for the full list of 15 target files with proposed MARK boundaries.)

---

## Appendix G — Per-File Execution Scripts

**Phase 0.1 — Verify clean baseline:**
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" \
  && git status --short \
  && /usr/bin/swift build -c release --product Opera 2>&1 | tail -5
```

**Phase 0.2 — Create DateFormatters.swift:**
1. Read §3.1 for exact file contents
2. Write to `Packages/ProjectKit/Sources/ProjectKit/DateFormatters.swift`
3. Run: `/usr/bin/swift build -c release --product ProjectKit`
4. Commit: `Phase 0 step 2: add AmiraDateFormatter`

**Phase 0.3 — Migrate ProjectKit's own ISO formatter sites:**
```bash
rtk grep "ISO8601DateFormatter" \
  Packages/ProjectKit/Sources/ProjectKit/ \
  --glob "*.swift"
```
For each file: open, replace with `AmiraDateFormatter` variant, build, commit.

Repeat pattern for §3.2 StringExtensions, §3.3 AmiraLogger, §3.4 ColorHex, §3.5 stub deletion.

---

## Appendix H — MARK Section Inventories for Three Stores

Source of truth for the exact locations of logical blocks in the three main stores. Use these line numbers to guide extractions in Phases 1, 4A, and 4B.

### H.1 MIDIPlaybackEngine (4,851 lines, 14 MARK sections)

```
Line 145:   // MARK: - Metronome                 → Step 1.1
Line 158:   // MARK: - Silent Export             → Remains in core
Line 167:   // MARK: - Recording                 → Step 1.2
Line 195:   // MARK: - Loop Recording            → Step 1.2
Line 1160:  // MARK: - Metering API              → Step 1.3
Line 1175:  // MARK: - Metronome API             → Step 1.1
Line 1203:  // MARK: - Recording API             → Step 1.2
Line 1251:  // MARK: - Recording Implementation  → Step 1.2
Line 1397:  // MARK: - Loop Recording            → Step 1.2
Line 1624:  // MARK: - Send Routing              → Remains in core
Line 1689:  // MARK: - Metronome Implementation  → Step 1.1
Line 3788:  // MARK: - AU MIDI Helpers           → Remains in core
Line 4195:  // MARK: - Metering                  → Step 1.3
Line 4567:  // MARK: - Export Buffer Mode        → Step 1.4
```

### H.2 ScoreStore (8,819 lines, 72 MARK sections — selected)

```
Line 13:    // MARK: - Debug Logging                      → Replace with AmiraLogger
Line 31:    // MARK: - Supporting Enums                   → Remains in core
Line 128:   // MARK: - Types Not in OPWModels             → Consider moving to Models/
Line 195:   // MARK: - OWS Playback Snapshot              → Remains in core
Line 295:   // MARK: - OWS Song Document                  → Remains in core
Line 535:   // MARK: - OWP Project I/O                    → Remains in core (coordination)
Line 1046:  // MARK: - ScoreStore                          → Top of class
Line 1053:  // MARK: - Project State                      → Remains in core
Line 1067:  // MARK: - Selection                          → Remains in core
Line 1075:  // MARK: - Note Selection                     → Remains in core
Line 1110:  // MARK: - Piano Roll Data                    → Remains in core
Line 1135:  // MARK: - Instrument Mappings                → Remains in core
Line 1163:  // MARK: - Playback                           → Remains in core
Line 1205:  // MARK: - Undo / Redo                        → Remains in core
Line 1244:  // MARK: - Freeze / Bounce                    → Step 4A.1 (ExportStore)
Line 1248:  // MARK: - Audio Devices                      → Remains in core
Line 1255:  // MARK: - Music Intelligence Engine          → Step 4A.3
Line 1265:  // MARK: - Full Mix Export                    → Step 4A.1
Line 1274:  // MARK: - Batch / Send-to-Mix Export         → Step 4A.1
Line 1283:  // MARK: - API Server                         → Step 4A.4
Line 1310:  // MARK: - LLM                                → Step 4A.5
Line 1331:  // MARK: - Style & Composition                → Step 4A.5
Line 1337:  // MARK: - MidiAI                             → Step 4A.5
Line 1346:  // MARK: - MIDI Input                         → Remains in core
Line 1357:  // MARK: - Track Reordering                   → Remains in core
Line 1379:  // MARK: - Per-channel Pan                    → Remains in core
Line 1393:  // MARK: - Metering                           → Remains in core
Line 1398:  // MARK: - Automation Recording               → Remains in core
Line 1423:  // MARK: - SoundFont Cache                    → Remains in core
Line 1427:  // MARK: - Sample Browser                     → Remains in core
Line 1433:  // MARK: - Audio Unit Discovery               → Remains in core
Line 1437:  // MARK: - Status & Dirty                     → Remains in core
...plus 40 more sections in body (mostly note editing, project I/O, misc)
```

**Irreducible Core (remains in ScoreStore after Phase 4A):**
Four properties form the entanglement core, accessed by 60%+ of sections:
- `pianoRollNotes: [PianoRollNote]` — 110+ accesses
- `instrumentMappings: [String: InstrumentMapping]` — 101 accesses
- `selectedMidiID / selectedMidiAsset` — 75 accesses
- `isDirty: Bool` — 64 accesses

These stay in ScoreStore core (~4,000 lines).

### H.3 AnimateStore (20,417 lines, 74 MARK sections — selected)

```
Line 190:   // MARK: - OWP Project                             → Step 4B.14
Line 275:   // MARK: - Characters                              → Step 4B.8
Line 302:   // MARK: - Motion Capture State                    → Step 4B.1
Line 317:   // MARK: - Canvas Generation                       → Step 4B.4
Line 364:   // MARK: - Imagine State                           → Step 4B.7
Line 1014:  // MARK: - Image Intelligence (Phase 1-6)          → Step 4B.11
Line 2571:  // MARK: - NLA Evaluation                          → Step 4B.2
Line 2617:  // MARK: - Status                                   → Remains in facade
Line 2632:  // MARK: - Computed                                → Step 4B.13 (dissolve)
Line 8669:  // MARK: - Track Freeze / Bounce                   → (ScoreStore territory? verify)
Line 8758:  // MARK: - App Support Directory                   → Step 4B.14
Line 10982: // MARK: - Background Removal (Re-mask transparent PNGs) → Step 4B.5
Line 11337: // MARK: - Look Development Board                  → Step 4B.9
Line 11498: // MARK: - Background Management                   → Step 4B.12
Line 14449: // MARK: - AI Generation Activity Queue            → Step 4B.11
Line 14534: // MARK: - Per-activity cancellation               → Step 4B.11
Line 14567: // MARK: - Vertex image-generation attempt ledger  → Step 4B.11
Line 14669: // MARK: - Vertex AI free-trial credit tracking    → Step 4B.11
Line 14992: // MARK: - Place Angle Images                      → Step 4B.12
Line 15906: // MARK: - Loopback API: Place Image Generation    → Step 4B.11
Line 16941: // MARK: - Private Helpers                          → Step 4B.13 (dissolve)
Line 19050-19989: Various scene/shot automation sections       → Verify per-domain
Line 19378: // MARK: - Scene Direction Integration              → Step 4B.10
Line 19480: // MARK: - Video Export                            → Step 4B.6
Line 19541: // MARK: - Lip Sync Generation                     → Step 4B.6
Line 19630: // MARK: - Audio Playback                           → Remains in core
Line 19646: // MARK: - Camera Choreography                     → Step 4B.6
Line 19674: // MARK: - Lipsync Direction Tag Processing        → Step 4B.6
Line 19733: // MARK: - LLM Animation Plan Generation           → Step 4B.6
Line 19793: // MARK: - Track Resolution Cache Types & Helpers  → Step 4B.13 (dissolve)
Line 19857: // MARK: - Animate Scene Macro (Item 16)           → Step 4B.6 candidate
Line 19950: // MARK: - Batch Scene Processing (Item 17)        → Step 4B.6
Line 19989: // MARK: - Motion Clip Management (Phase 3)        → Step 4B.2
Line 19995: // MARK: - NLA Motion Clip Placement               → Step 4B.2
Line 20088: // MARK: - Playback Helpers (Phase 6 additions)    → Remains in core
Line 20097: // MARK: - BVH Export                              → Step 4B.2
Line 20118: // MARK: - Clip Speed                              → Step 4B.2
Line 20131: // MARK: - Video Import                            → Step 4B.6 candidate
Line 20190: // MARK: - Audio Lip Sync Recording                → Step 4B.1
Line 20212: // MARK: - Enhanced Tracking Mode (Phase 7)        → Step 4B.1
Line 20243: // MARK: - Imagine Gallery Management              → Step 4B.7
...plus 34 more sections in body
```

**Nested Monolith: Backgrounds/Places (~8,700 lines, 170+ functions across 8 MARK sections)**

This is the single biggest obstacle. Sub-split plan:

| New Store | Lines | Scope | Step |
|-----------|-------|-------|------|
| `PlaceGenerationEngine` | ~3,500 | AI queue, cancellation, vertex tracking, credit tracking, loopback API | 4B.11 |
| `BackgroundStore` | ~2,500 | CRUD, approved images, filtering, indexing | 4B.12 |
| `PlaceAngleManager` | ~900 | Angle image management | 4B.12 (co-extract) |
| `PlacesWorldbuildingCoordinator` | ~200 | Places-worldbuilding bridge | 4B.12 (co-extract) |

**Strategy:** First internally split within AnimateStore (e.g., separate generation queue from CRUD in place), THEN extract.

---

## End of Spec

When the executing agent completes Phases 0-5 and all verification gates, the codebase will look like it was written by a world-class professional developer — consistent structure, shared utilities, no monoliths, observable logging, enforced style, clear decomposition, and agent-navigable layout.

**Rollback at any point:** `git checkout pre-refactor-checkpoint-20260524`
