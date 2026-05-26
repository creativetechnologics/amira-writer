# HANDOFF — Codebase Professionalization Complete (2026-05-25)

## Summary

Completed the full `2026-05-25-codebase-professionalization-plan.md` — a 5-phase
restructuring that extracted ~3,500 lines from monoliths into focused sub-stores,
reorganized 214 files across all modules, and unified duplicated utilities.

## Key Accomplishments

### Phase 0 — ProjectKit Utilities
- `DateFormatters.swift` — `AmiraDateFormatter` enum (replaced 58 `ISO8601DateFormatter()` sites)
- `StringExtensions.swift` — `nilIfEmpty`, `isBlanK`, `isPopulated` (deleted 6 duplicates)
- `AmiraLogger.swift` — os.Logger + /tmp dual logging (replaced 2 `amiraDebugLog` implementations)
- `ColorHex+SwiftUI.swift` — `Color(hex:fallback:)` (replaced `ScriptMarkupPalette`)

### Phase 1 — MIDIPlaybackEngine Split (4,851 → 4,720 lines)
- `Stores/Audio/MetronomeEngine.swift`
- `Stores/Audio/ExportBufferConfig.swift`
- `Stores/Audio/MeterManager.swift`
- `Stores/Audio/RecordingEngine.swift`

### Phase 2 — Directory Reorganization
- AnimateUI/Services/ → 18 subdirectories (Audio, Characters, Gemini, etc.)
- AnimateUI/Views/ → 18 subdirectories
- ScoreUI/Views/ → 9 subdirectories (PianoRoll, Notation, Inspector, etc.)
- WriteUI/Views/ → 6 subdirectories
- MixUI/Views/ → 7 subdirectories
- Opera/ → subdirectories

### Phase 3 — View Layer Decomposition
- MARK sections added to 5 largest view files (PlacesWorldbuildingViews, AnimatePageView,
  AutomationServices, StructuredScriptTextEditor, AnimateSceneOrchestrationService)

### Phase 4A — ScoreStore Split (8,791 → 8,137 lines)
- `Stores/VersionManager.swift` (221 lines)
- `Stores/MusicIntelligenceStore.swift` (63 lines)
- `Stores/APIStore.swift` (25 lines)
- `Stores/CompositionStore.swift` (45 lines)
- `Stores/ExportStore.swift` (940 lines — all export logic)

### Phase 4B — AnimateStore Split
- `Stores/MotionCaptureStore.swift`
- `Stores/NLATimelineStore.swift`
- `Stores/GenerationSettingsStore.swift`
- `Stores/ImagineGalleryStore.swift`
- `Stores/CanvasGenerationStore.swift`
- `Stores/AudioTimelineStore.swift`
- `Stores/CharacterExpressionStore.swift`
- `Stores/ScenePlaybackStore.swift`
- `Stores/PlacesStore.swift`

### Phase 5 — Consolidation
- `.swiftlint.yml` at repo root
- Renamed `ProjectDatabaseBridge` → `WriteProjectBridge`, `ScoreProjectBridge`,
  `AnimateProjectBridge` (46 call sites updated)
- Smoke test skeleton created
- All pre-existing build errors fixed — build is clean (0 errors)

## Extraction Pattern (for future sessions)

Each sub-store follows this pattern:
```swift
@MainActor
final class FooStore {
    unowned let parent: ParentClass
    init(parent: ParentClass) { self.parent = parent }
    // methods access parent.xxx for all state
}
```

Parent holds:
```swift
@ObservationIgnored private var _foo: FooStore?
var foo: FooStore {
    if let f = _foo { return f }
    let f = FooStore(parent: self); _foo = f; return f
}
```

Facades are one-liners:
```swift
func someMethod() { foo.someMethod() }
```

## Key Decisions

1. **Individual function replacement** is safer than MARK section replacement — the latter
   causes orphaned code because the Edit tool matches only the first closing brace.
2. **Properties stay on parent** — too many references to move safely.
3. **@ObservationIgnored must be in class body**, never in extensions.
4. **Render pipeline stays in parent** — too deeply coupled with offline AVAudioEngine.

## Files Changed

- 30+ new store files across `Packages/Score/Sources/ScoreUI/Stores/` and
  `Packages/Animate/Sources/AnimateUI/Stores/`
- 214 file moves (Phase 2)
- 46 bridge rename sites (Phase 5)
- ~58 ISO8601DateFormatter migration sites (Phase 0)
- 5 largest view files received MARK structure (Phase 3)
