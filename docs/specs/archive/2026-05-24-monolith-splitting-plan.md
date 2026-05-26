# Monolith Splitting Plan — AnimateStore, ScoreStore, MIDIPlaybackEngine

**Date:** 2026-05-24
**Prepared by:** OpenCode investigation of 35,700 lines across 3 files
**Checkpoint:** `pre-refactor-checkpoint-20260524`

---

## Overview

Three files dominate the Amira Writer codebase:

| File | Lines | Type | Domain |
|------|-------|------|--------|
| `AnimateStore.swift` | **20,490** | `@Observable @MainActor` class | Animation / Characters / Places / Generation |
| `ScoreStore.swift` | **10,293** | `@Observable @MainActor` class | Score / Playback / Export |
| `MIDIPlaybackEngine.swift` | **4,913** | `@unchecked Sendable` class | Audio engine / Metronome / Recording |

These three files account for 35,696 lines — roughly 25% of the project's total Swift code. All three compile successfully today. The goal is to split them into focused, testable units without breaking anything.

---

## Part 1: MIDIPlaybackEngine (4,913 lines) — First, Easiest

### Why First

MIDIPlaybackEngine is the smallest of the three and has NO SwiftUI or Observation dependencies. It's pure GCD-based audio engine code. It can be split independently — changes here can't break views.

### Current Structure

```
MIDIPlaybackEngine (4,913 lines)
├── Core Engine (~1,200 lines)      — init, play(), stop(), AU loading, audio graph
├── Metronome (~1,500 lines, 53 funcs) — Metronome engine
├── Recording (~900 lines, 20 funcs)   — Recording + loop recording
├── Metering (~350 lines, 10 funcs)    — Meter tap infrastructure
├── Send Routing (~80 lines, 4 funcs)  — Track sends
├── AU MIDI Helpers (~300 lines, 9 funcs) — MIDI event dispatch
├── Silent Export (~60 lines, 3 funcs)  — Mute/unmute for export
└── Export Buffer Mode (~250 lines, 7 funcs) — Export configuration
```

### Splitting Plan

**Step 1: Extract MetronomeEngine (~1,500 lines)**

Create `MetronomeEngine.swift` — a new `final class` with:
- `metronomeNode`, `metronomeDownbeatBuffer`, `metronomeUpbeatBuffer`
- `metronomeEnabled`, `metronomeTimeSignatures`, `metronomeGain`, `metronomeGate`
- All 53 metronome functions
- Reference back to parent `MIDIPlaybackEngine` for the `AVAudioEngine` node attachment

Risk: **Very Low.** Metronome is a self-contained subsystem. It only touches the engine to attach/detach nodes. ScoreStore sets `metronomeTimeSignatures` before playback but never accesses metronome internals.

**Step 2: Extract RecordingEngine (~900 lines)**

Create `RecordingEngine.swift` — a new `final class` with:
- `recordingLock`, `recordingFile`, `isRecordingAudio`
- `mixdownWriteGroup`, mixdown recording state
- `loopRecordingTimer`, `loopStartTick`, `loopEndTick`
- All 20 recording/loop-recording functions
- Callbacks: `onRecordingComplete`, `onMainMixRecordingComplete`, `onLoopPassComplete`

Risk: **Low.** Recording is self-contained. ScoreStore triggers recording start/stop but never touches recording internals.

**Step 3: Extract MeterManager (~350 lines)**

Create `MeterManager.swift` — with:
- `meterTapLevels`, `masterMeterRaw`, `meterPublishTimer`
- All 10 metering functions
- Callback: `onMeterUpdate`

Risk: **Very Low.** ScoreStore reads `leftPeakDB`/`rightPeakDB` computed properties — these would become passthroughs on the parent engine.

**Step 4: Extract ExportBufferConfig (~250 lines)**

Risk: **Very Low.** Self-contained export configuration. Used only by the Offline WAV Renderer path.

**After splitting, MIDIPlaybackEngine core will be ~1,700 lines** — just the audio graph, AU loading, sampler management, and `play()`/`stop()` orchestration.

### ScoreStore Impact

After splitting, ScoreStore's `playbackEngine` becomes a facade that owns three sub-engines:

```swift
private(set) var playbackEngine = MIDIPlaybackEngine()
// playbackEngine.metronome is a MetronomeEngine
// playbackEngine.recorder is a RecordingEngine  
// playbackEngine.meters is a MeterManager
```

ScoreStore's 7 `@ObservationIgnored` properties are unaffected. No view code changes.

---

## Part 2: ScoreStore (10,293 lines) — Second, Moderate Difficulty

### Current Structure

ScoreStore has **83 MARK sections** grouped into these logical domains:

| Domain | Sections | Lines | Functions | Extractable? |
|--------|----------|-------|-----------|-------------|
| **Export Pipelines** | 5 | ~3,800 | 36 | ✅ YES |
| **Note/Piano Roll Core** | 18 | ~3,500 | ~80 | ❌ ENTANGLED |
| **Instrument Mappings** | 3 | ~490 | 33 | ⚠️ PARTIALLY |
| **Version Management** | 1 | ~220 | 13 | ✅ YES |
| **Music Intelligence Engine** | 1 | ~250 | 15 | ✅ YES |
| **API Server/Diagnostics** | 2 | ~300 | 22 | ✅ YES |
| **LLM / Style / MidiAI** | 4 | ~500 | 18 | ✅ YES |
| **Audio Unit Assignment** | 1 | ~170 | 11 | ⚠️ PARTIALLY |
| **Playback** | 3 | ~200 | 5 | ❌ ENTANGLED |

### The Irreducible Core

Four properties form the **entanglement core** — accessed by 60%+ of all sections:

| Property | Access Count | Why Entangled |
|----------|-------------|---------------|
| `pianoRollNotes: [PianoRollNote]` | 110+ | Every editing, playback, and export section reads/writes this |
| `instrumentMappings: [String: InstrumentMapping]` | 101 | Playback, export, and editing all depend on it |
| `selectedMidiID / selectedMidiAsset` | 75 | Gating condition for most operations |
| `isDirty: Bool` | 64 | Set by every mutating section |

### Splitting Plan

**Phase 1: Extract ExportStore (~3,800 lines)**

Create `ExportStore.swift` — a new `@Observable @MainActor` class containing:
- Full Mix Export, Rehearsal Track Export, Stem Export
- Batch Export (Send-to-Mix)
- Offline WAV Renderer
- All export properties and 36 functions

Each export creates its own `MIDIPlaybackEngine` instance (already the pattern). The export store reads `pianoRollNotes`, `instrumentMappings`, and `selectedMidiAsset` from the parent ScoreStore — these are passed as parameters or accessed via a `weak var` reference.

Risk: **Low-Medium.** Exports are read-only consumers of score data. They create their own playback engine instances already.

**Phase 2: Extract VersionManager (~220 lines)**

Risk: **Very Low.** Pure CRUD on `songAssets[...].document.versions`. Self-contained.

**Phase 3: Extract MusicIntelligenceStore (~250 lines)**

Risk: **Low.** Read-only analysis that produces independent results.

**Phase 4: Extract APIStore (~300 lines)**

Create `APIStore.swift` containing:
- `APIServer` lifecycle
- 20 API diagnostic endpoints (read-only introspection)
- Separate from ScoreStore's main logic

Risk: **Low.** Already running on its own port; read-only diagnostics.

**Phase 5: Extract CompositionStore (~500 lines)**

Contains: LLM Methods, Style & Composition, MidiAI stubs. All use external services (`LLMClient`, `MidiAI`) with read-only access to `pianoRollNotes`.

Risk: **Low.** Read-only analysis + external API calls.

**After these phases, ScoreStore core will be substantially smaller** — just the note editing, playback orchestration, instrument mapping CRUD, and project I/O.

---

## Part 3: AnimateStore (20,490 lines) — Last, Most Difficult

### Current Structure

AnimateStore has **75 MARK sections** grouped into logical domains:

| Domain | Sections | Lines | Extractable? |
|--------|----------|-------|-------------|
| **Motion Capture + NLA** | 10 | ~500 | ✅ YES |
| **Playback/Timeline/Tracks** | 4 | ~100 | ✅ YES |
| **Gemini/API Settings** | 5 | ~250 | ✅ YES |
| **Canvas Generation** | 2 | ~120 | ✅ YES |
| **Image Eraser/Crop** | 3 | ~135 | ✅ YES |
| **Song Data** | 2 | ~35 | ✅ YES |
| **Lip Sync** | 3 | ~170 | ✅ YES |
| **Video Export** | 1 | ~60 | ✅ YES |
| **Camera Choreography** | 1 | ~28 | ✅ YES |
| **Batch Scene Processing** | 1 | ~45 | ✅ YES |
| **LLM Animation Plan** | 1 | ~60 | ✅ YES |
| **Video Import** | 1 | ~60 | ✅ YES |
| **Characters + Text Fields + Profile** | 3 | ~1,750 | ⚠️ PARTIALLY |
| **Character Reference Workflow** | 1 | ~1,270 | ⚠️ PARTIALLY |
| **Inspiration/Reference/Shot Images** | 5 | ~1,150 | ⚠️ PARTIALLY |
| **Rig Editing / Look Dev / BG Removal** | 4 | ~800 | ⚠️ PARTIALLY |
| **Imagine State + Gallery** | 2 | ~200 | ✅ YES |
| **Backgrounds/Places** | 9 | **~8,700** | ❌ MONOLITH |
| **Image Intelligence** | 1 | ~1,560 | ❌ MONOLITH |
| **Computed (grab-bag)** | 1 | **~4,150** | ❌ DISSOLVE |
| **OWP Open / Save / Persistence** | 5 | ~650 | ❌ COORDINATOR |

### The Two Nested Monoliths

**1. Backgrounds/Places — 8,700 lines, 170+ functions, 8 MARK sections**

This is the single biggest obstacle. It spans `Backgrounds`, `Background Management`, `Place Angle Images`, `Loopback API`, `AI Activity Queue`, `Per-activity Cancellation`, `Vertex Ledger`, `Vertex Credit Tracking`, and `Private Helpers`. All access `backgrounds`, `placesWorkflowLibrary`, `scriptPlaceRequirements`, and dozens of private caches.

This must be split internally FIRST before extraction. Sub-split into:
- `PlaceGenerationEngine` — AI generation activity, queue, cancellation, vertex tracking (~3,500 lines)
- `BackgroundStore` — CRUD, approved images, filtering, indexing (~2,500 lines)
- `PlaceAngleManager` — angle image management (~900 lines)
- `PlacesWorldbuildingCoordinator` — places-worldbuilding bridge (~200 lines)

**2. "Computed" section — 4,150 lines**

This catch-all contains timeline track resolvers, asset path resolvers, search/filter helpers, places index computation, and dozens of small computed properties bridging domains. This must be **dissolved**, not extracted — each helper moved to its respective domain store.

### Splitting Plan

**Phase 1: Motion Capture Store (~500 lines)**

Create `MotionCaptureStore.swift` — contains `mocapCaptureSession`, `mocapBodyTracker`, `mocapLatestPoseFrame`, `mocapIsRunning`. All NLA/bone/pose state. Already has `nonisolated(unsafe)` on the capture session.

Risk: **Low.** Motion capture is nearly self-contained.

**Phase 2: NLA Timeline Store (~190 lines)**

Create `NLATimelineStore.swift` — contains `nlaTimeline`, `motionClips`, NLA evaluation, clip management, BVH export, clip speed.

Risk: **Low.** Only references `currentFrame` for evaluation.

**Phase 3: Generation Settings Store (~250 lines)**

Create `GenerationSettingsStore.swift` — contains Gemini/MiniMax/Vidu settings, API keys, credential stores, image analysis settings.

Risk: **Very Low.** Pure credential/settings management.

**Phase 4: Canvas Store (~120 lines) + Image Eraser/Crop (~135 lines)**

Risk: **Very Low.** Self-contained state machines.

**Phase 5: Lip Sync + Video Export + Camera + Batch + LLM (~420 lines)**

Combine 5 small domains into `AnimationPipelineStore.swift`. These are small, self-contained pipelines that consume scene/character data without mutating shared state.

Risk: **Very Low.** All read-only consumers.

**Phase 6: Character Store (~1,750 lines)**

Create `CharacterStore.swift` — contains character CRUD, profile management, text fields, ordering. References `characters` array and `animateURL`. The parent AnimateStore holds a reference and delegates character operations.

Risk: **Medium.** Characters are referenced by 694 call sites. Every view references `store.characters` — this would become `store.characterStore.characters`. However, `@Observable` tracks nested observable properties automatically, so view bindings don't change.

**Phase 7: Character Reference Workflow Store (~1,270 lines)**

Create `CharacterReferenceWorkflowStore.swift` — 59 functions for master sheets, head turnaround, costume sets, background removal. References `characters`, `animateURL`, `fileOWPURL`, `allImagesContentRevision`.

Risk: **Medium.** Heavy function count but thematically coherent.

**Phase 8: Inspiration Images Store (~1,150 lines)**

Contains inspiration, reference, shot reference, and animated images. References `characters`, `animateURL`, `fileOWPURL`.

Risk: **Medium.** Similar pattern to Character Reference Workflow.

**Phase 9: Place Generation Engine (~3,500 lines)**

This is the first half of the Backgrounds/Places nested monolith. Extract AI activity queue, cancellation, vertex tracking, credit tracking, and loopback API into `PlaceGenerationEngine.swift`.

Risk: **High.** This is the hardest extraction. The Place Generation Engine references `backgrounds`, `placesWorkflowLibrary`, `scriptPlaceRequirements`, and dozens of private caches. Must be done carefully with tests.

**Phase 10: Background Store (~2,500 lines)**

Second half of the nested monolith. CRUD, approved images, filtering, indexing. Will be extracted after Place Generation Engine to minimize shared state.

Risk: **High.** Tight coupling with Place Generation Engine.

**Phase 11: Dissolve the "Computed" section (~4,150 lines)**

After all domain stores are extracted, move each computed property to its owning store. This is a mechanical task — no logic changes, just relocation.

Risk: **Low after domains are extracted.** Mechanical relocation.

**Phase 12: OWP Coordinator (~650 lines)**

The `openOWP()`, save, and persistence functions become a coordinator that delegates to sub-stores. After Phases 1-11, this becomes a thin orchestration layer.

Risk: **Low at this point.** All sub-stores are already extracted.

---

## Implementation Order & Risk Summary

| Order | File | Action | Lines Affected | Risk |
|-------|------|--------|----------------|------|
| 1 | MIDIPlaybackEngine | Extract MetronomeEngine | -1,500 | Very Low |
| 2 | MIDIPlaybackEngine | Extract RecordingEngine | -900 | Low |
| 3 | MIDIPlaybackEngine | Extract MeterManager | -350 | Very Low |
| 4 | MIDIPlaybackEngine | Extract ExportBufferConfig | -250 | Very Low |
| 5 | ScoreStore | Remove retired cloud-music integration | -1,500 | Complete |
| 6 | ScoreStore | Extract ExportStore | -3,800 | Low-Medium |
| 7 | ScoreStore | Extract VersionManager | -220 | Very Low |
| 8 | ScoreStore | Extract MusicIntelligenceStore | -250 | Low |
| 9 | ScoreStore | Extract APIStore | -300 | Low |
| 10 | ScoreStore | Extract CompositionStore | -500 | Low |
| 11 | AnimateStore | Extract MotionCaptureStore | -500 | Low |
| 12 | AnimateStore | Extract NLATimelineStore | -190 | Low |
| 13 | AnimateStore | Extract GenerationSettingsStore | -250 | Very Low |
| 14 | AnimateStore | Extract CanvasStore | -120 | Very Low |
| 15 | AnimateStore | Extract ImageEraserStore | -135 | Very Low |
| 16 | AnimateStore | Extract AnimationPipelineStore | -420 | Very Low |
| 17 | AnimateStore | Extract CharacterStore | -1,750 | Medium |
| 18 | AnimateStore | Extract CharacterReferenceWorkflowStore | -1,270 | Medium |
| 19 | AnimateStore | Extract InspirationImagesStore | -1,150 | Medium |
| 20 | AnimateStore | Extract PlaceGenerationEngine | -3,500 | **High** |
| 21 | AnimateStore | Extract BackgroundStore | -2,500 | **High** |
| 22 | AnimateStore | Dissolve Computed section | -4,150 | Low |
| 23 | AnimateStore | Refactor OWP Coordinator | -650 | Low |
| 24 | ScoreStore | InstrumentMappingPanel sub-structs | -370 | Very Low |

**Total: 24 steps across 3 files. Each step is independently verifiable. Build after each step. Deploy after each file is complete.**

---

## Expected Results

| File | Before | After | Reduction |
|------|--------|-------|-----------|
| AnimateStore.swift | 20,490 | ~650 (coordinator) | **97%** |
| ScoreStore.swift | 10,293 | ~4,000 (core) | **61%** |
| MIDIPlaybackEngine.swift | 4,913 | ~1,700 (core) | **65%** |
| **New files created** | 0 | **23** | — |
| **Lines moved to focused stores** | — | ~27,350 | — |

## Verification Strategy

After each step:
```bash
/usr/bin/swift build -c release  # Must succeed with zero errors
```

After each file is complete:
```bash
/Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh
```

Rollback at any step:
```bash
git checkout pre-refactor-checkpoint-20260524
```
