# Handoff — Inspector unification + cross-page UI refactor (2026-04-15)

## Read this first — restart instructions for Claude

**You are resuming this session after a restart. Do NOT ask clarifying questions, do NOT re-explore the codebase from scratch.** Gary has told you:

1. **Two tasks remain and must NOT be dropped: Task A (Unified Details Inspector) and Task B (Right-Click Gemini Generate menu).** Full specs for both are in the "Pending work" section below.
2. **You MUST use Spark (`gpt-5.3-codex-spark`).** Gary's usage limit on every other Codex model does not reset until tomorrow. Do not propose `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.4`, or "just do it with Opus" as alternatives until tomorrow.
3. **Try `--resume` first.** The prior Spark dispatch stalled partway through exploration. Pass `--resume` via codex-rescue so Codex continues the prior thread instead of re-reading everything. If resume fails, fall back to splitting Task A + Task B into smaller, tighter dispatches with inline context (file paths, line numbers, exact struct field names) so Spark doesn't burn tokens on exploration.

Invocation reminder — use the Agent tool with subagent_type `codex:codex-rescue`, and start the prompt with:

```
--model gpt-5.3-codex-spark --effort high --write --resume <task text>
```

If `--resume` returns nothing useful, drop it and re-dispatch with a tightened prompt (examples in "Restart strategy" below).

---

## Project context

- Repo: `/Volumes/Storage VIII/Programming/Amira Writer`
- Swift 6 / SwiftUI macOS 26.0+ app
- Build command: `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh` — builds scheme `Opera`, deploys to `/Volumes/Storage VIII/Programming/!Applications/`
- Central store: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` — `@Observable @MainActor final class AnimateStore` (internal, NOT public — do not make it public)
- Workspace controller: `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift` — `public final class AnimateWorkspaceController`

---

## Original user ask (from start of session)

Gary requested a multi-part UI refactor:

1. **Inspector unification**: Remove sticky preview window from middle area. Copy the Places "Details" inspector tab structure to Imagine, Characters, and Props as the first inspector item. Preview image at the top of Details should be vertically resizable via click-and-drag.
2. **Clear obsolete Characters details pane content** (rig, active package, canvas render, actions) — replace with the new unified Details pane.
3. **Gemini toggle persistence**: Make the "Gemini API calls" toggle persistent across app restarts. Alternative was to remove it entirely if other safeguards prevent unprompted Gemini calls.
4. **Move Gemini badge + settings gear** to the very top title bar of the entire application, to the LEFT of the toggle sidebar and toggle inspector buttons. They are system-wide, not Imagine-only.
5. **Right-click context menu on character images**: Trigger Gemini generation (one image, 27 batch) — load the selected image into the Gemini generation window preloaded.
6. **Fix 3D map black screen**: Loads black both in the Places page large view AND inside the Gemini generation camera picker.

---

## Completed and deployed

All of the following built successfully and were deployed to `!Applications`:

### 1. Gemini badge + settings gear moved to top title bar (#4)

- Added two public factory methods on `AnimateWorkspaceController` so the top shell can instantiate the views without needing access to the internal `AnimateStore` type:
  - `AnimateWorkspace.swift:61–72`: `geminiStatusBadgeView()` / `globalSettingsGearView()` — both return `some View`.
- Wired into the global title bar: `Sources/Opera/OperaShellView.swift:561–575` — the badge and gear now sit inside the same trailing `HStack` that holds the sidebar / inspector toggle buttons, positioned to their LEFT as Gary requested.
- Removed the old per-workspace instances:
  - `ImagineWorkspace.swift` — stripped `GeminiStatusBadge` + `GlobalSettingsGear` from the top HStack (used to be lines 108–109).
  - `PlacesWorkspace.swift` — stripped from the center pane header (used to be lines 100–101).
  - `AnimateWorkspace.swift` — stripped from title area (used to be lines 311–312).
- `GeminiStatusBadge` and `GlobalSettingsGear` are correctly internal structs. Do NOT make them public — the factory method pattern avoids that.

### 2. Gemini API-calls toggle now persistent (#3)

- `AnimateStore.swift` around line 163:

```swift
static let geminiMasterSwitchDefaultsKey = "animate.geminiMasterSwitch"
var geminiMasterSwitch: Bool = (UserDefaults.standard.object(forKey: "animate.geminiMasterSwitch") as? Bool) ?? true {
    didSet {
        UserDefaults.standard.set(geminiMasterSwitch, forKey: Self.geminiMasterSwitchDefaultsKey)
    }
}
```

- Default is `true`.
- Removed the prior project-scoped load/save (around lines 4759 and 4961 — see comments in place).

### 3. 3D map black screen fix (#6)

Root cause: two compounding problems.

- `PlacesMap3DView.swift` and `Map3DCameraPickerSheet.swift` both had `web.setValue(false, forKey: "drawsBackground")` — removed. Also added `config.preferences.setValue(true, forKey: "developerExtrasEnabled")` for diagnostics.
- The viewer's three.js import was pinned to `unpkg.com` CDN in `Scripts/3d-map-pipeline/viewer/index.html`. That fails in WKWebView's `file://` context. Switched the importmap to local vendored paths:

```html
"three": "./vendor/three/three.module.js",
"three/addons/": "./vendor/three/addons/"
```

New vendored files:
- `Scripts/3d-map-pipeline/viewer/vendor/three/three.module.js` (three@0.168.0, ~1.3 MB)
- `Scripts/3d-map-pipeline/viewer/vendor/three/addons/controls/OrbitControls.js` (~32 KB)

The build script already embeds the viewer into `Amira Writer.app/Contents/Resources/map3d-viewer/`, so the vendored files ship with the app.

---

## Pending work — DO NOT LOSE

### Task A — Unified "Details" inspector (#2)

**Design decided by Gary: Option A — protocol-based shared SwiftUI view.**

Goal: one `Details` tab that appears FIRST across Imagine, Characters, Places, Props. Renders a vertically-resizable preview image, title, rating, notes editor, and metadata rows. Each page feeds it via an adapter.

#### Files to touch

Primary:
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift` — has an `InspectorTab` enum, `@AppStorage("animate.inspector.selectedTab.v3")`, `detailsContent` routing at line 76. `PlaceGeneratedImageDetailsInspectorSection` struct starts at line 2246 — canonical "good" Details view to mirror.
- `Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift` — separate inspector. Currently tabs: Tools, Bulk, LORA, Props. Add Details as FIRST tab, becoming the new default.
- `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift` — remove the rig / active package / canvas render / actions "details" section from the middle pane. Leave characters list and grid intact.
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` — may need to add a few selection-tracking and per-inspiration-image metadata fields.

Relevant store state already present:
- `selectedCharacterID: UUID?` (line 123)
- `selectedCharacter: AnimationCharacter?` (computed, line 913)
- `selectedImaginePage: ImaginePage = .characters` (line 159)
- `imaginePreviewImagePath: String? = nil` (line 171) — already exists! Reuse this for Imagine's current-image selection instead of adding a new field.
- `selectedGeneratedBackgroundRecordID: UUID?` (line 315)
- `selectedGeneratedBackgroundRecord: GeneratedBackgroundLibraryRecord?` (computed, line 322)
- `AnimationCharacter.inspirationImagePaths: [String]` (relative, resolve with `store.resolvedCharacterAssetURL(for:)`)

Place library methods used by the existing Details view: `setGeneratedBackgroundRating`, `toggleGeneratedBackgroundRejected`, `updateGeneratedBackgroundEditNotes`, `pendingGeneratedBackgroundEditQueueItem`.

#### What to build

Create a new file `Packages/Animate/Sources/AnimateUI/Views/UnifiedDetailsInspector.swift` with:

1. **Protocol**:
```swift
@available(macOS 26.0, *)
@MainActor
protocol DetailedImageSelection {
    var imageURL: URL? { get }
    var title: String { get }
    var subtitle: String? { get }
    var rating: Int? { get }
    var isRejected: Bool { get }
    var notes: String { get }
    var metadataRows: [(label: String, value: String)] { get }
    var emptyStateMessage: String { get }

    func setRating(_ newValue: Int?)
    func toggleRejected()
    func setNotes(_ newValue: String)
}
```

2. **Shared view** `UnifiedDetailsInspectorSection<Selection: DetailedImageSelection>: View`:
- Title, vertically-resizable preview image, rating stars + reject button, notes `TextEditor` (min 120pt), metadata rows.
- Preview resize: `@State private var previewHeight: CGFloat = 240`, drag handle bar (4pt RoundedRectangle, `Color.secondary.opacity(0.3)`, `.resizeUpDown` cursor), clamp `[140, 520]`. Persist via `@AppStorage("animate.details.previewHeight")`.
- Empty state when `imageURL == nil`: dashed placeholder with `emptyStateMessage`.
- Optionally expose an `@ViewBuilder extraActions` slot so Places can keep its "Edit with Gemini / Add to Batch" buttons and queue state.

3. **Adapters** (internal structs conforming to `DetailedImageSelection`):
- `PlaceImageSelection(store: AnimateStore)` — wraps `selectedGeneratedBackgroundRecord`. Round-trip through existing store methods listed above.
- `CharacterImageSelection(store: AnimateStore)` — wraps the currently focused inspiration image of `store.selectedCharacter`. Reuse `imaginePreviewImagePath` if that's what characters use, otherwise add a `selectedImagineGalleryPath: String?` property near `showGenerationSheet` (line 490).
- `ImagineImageSelection(store: AnimateStore)` — mirror CharacterImageSelection.
- `PropImageSelection(store: AnimateStore)` — stub with empty state if there's no prop image selection concept.
- Per-inspiration rating/notes: add optional `inspirationRatings: [String: Int]?` and `inspirationNotes: [String: String]?` to `AnimationCharacter` (`Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift:601`). Use `decodeIfPresent` for the new fields.

4. **Wire Details into `InspectorView.detailsContent`** — replace each switch branch with `inspectorScrollContainer { UnifiedDetailsInspectorSection(selection: XxxImageSelection(store: store)) }`. For `.places`, replace the `PlaceGeneratedImageDetailsInspectorSection(store: store)` call. If no other file references `PlaceGeneratedImageDetailsInspectorSection`, delete that struct — otherwise leave it and just stop calling it from `InspectorView`.

5. **Wire into `ImagineInspectorView`** — add `case details = "Details"` as first tab and make it the default. If `inspectorScrollContainer` is private to InspectorView.swift, extract it.

6. **Clear Characters page obsolete content** + **remove sticky preview window from middle area**. Search CharactersPageView for rig/active-package/canvas-render/actions views to delete. Search all four pages for anything that looks like a persistent middle-pane preview and remove it.

#### Non-negotiable constraints

- Do NOT make `AnimateStore` public.
- Do NOT auto-call Gemini.
- New Codable fields MUST use `decodeIfPresent` so existing project files still load.
- Preserve Places' existing "Edit with Gemini / Add to Batch" behavior via an extraActions slot.
- All new/edited files inside `Packages/Animate/Sources/AnimateUI/`.

---

### Task B — Right-click Gemini generate menu on character images (#5)

Goal: on character image grid cells (both Imagine Characters page and main Characters page), add context-menu items that open the Gemini generation sheet with the image preloaded.

#### Files

- `Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift` — existing grid cell contextMenu at line 1357. Already has `Edit with Gemini…` — see `beginEditWithGemini(characterID:imagePath:)` at line 1398 for the pattern that wires a single immediate generation with the image as reference.
- `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift` — second grid at line 2116+, contextMenu at line 2152. Needs new Gemini menu items added (currently has "Set as Profile Pic / Show in Finder / Quick Look" only).

#### What to add

To BOTH context menus, above any existing Gemini entries (optionally grouped under a `Menu("Generate with Gemini…", systemImage: "sparkles")`):

- **"Generate 1 with this as reference"** — behaves like `beginEditWithGemini` but requests a fresh generation (not an edit) with a blank prompt and this image as the included reference. In ImagineCharactersPageView, reuse the existing `inspirationPendingPlan` flow. In CharactersPageView, set `store.showGenerationSheet = true` after preloading the generation draft; if needed, add a helper on `AnimateStore`: `func presetGeminiGenerationWithReference(path: String, count: Int)`.
- **"Generate 27 batch variations"** — same thing but configure for a 27-image batch. Search for `inspirationBatchJobs` / `27` for an existing batch-generation path; reuse if present.

Disable both menu items if `store.geminiAPIKey.isEmpty` OR `store.geminiMasterSwitch == false`.

#### Non-negotiable constraints

- Do NOT auto-call Gemini. Menu items only OPEN the generation sheet preloaded — the user clicks Generate.
- Reuse existing generation paths. Prefer one helper on `AnimateStore` over duplicating setup in two context menus.

---

## Restart strategy

**Step 1 — Resume attempt** (do this first):

Dispatch via Agent tool with `subagent_type: codex:codex-rescue`, prompt begins:

```
--model gpt-5.3-codex-spark --effort high --write --resume

Resume the two-task refactor from earlier in this session: (1) Unified Details inspector across Imagine/Characters/Places/Props using the protocol-based approach, (2) right-click "Generate with Gemini" menu items on character image grid cells. Full specs are in docs/handoffs/2026-04-15-inspector-unification-handoff.md in the repo. Apply the changes with apply_patch. Build command is Scripts/build-app.sh but Claude will run it; you just need to apply patches.
```

**Step 2 — If resume fails or stalls again**, split into two smaller fresh dispatches:

Dispatch 1 (Task B, smaller, self-contained):

```
--model gpt-5.3-codex-spark --effort high --write

In /Volumes/Storage VIII/Programming/Amira Writer, add right-click menu items to TWO character-image grids:
- Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift (contextMenu at line 1357; existing helper beginEditWithGemini at line 1398 shows the wiring pattern)
- Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift (contextMenu at line 2152)

Add two items to BOTH, disabled when store.geminiAPIKey.isEmpty or !store.geminiMasterSwitch:
1. "Generate 1 with this as reference" — fresh generation (not edit) with blank prompt, image as reference. Reuse inspirationPendingPlan in ImagineCharactersPageView. For CharactersPageView, if needed add a helper on AnimateStore: presetGeminiGenerationWithReference(path:count:).
2. "Generate 27 batch variations" — same but batch count 27.

Do NOT auto-call Gemini. Only preload the sheet; the user clicks Generate. Do not make AnimateStore public.
```

Dispatch 2 (Task A, larger, with very tight context): use the full spec in "Task A" above. Inline all the line numbers, struct names, and existing store methods listed there so Spark does not need to re-read the codebase.

---

## Durable memory saved alongside this handoff

- Engram: `mem_session_summary` captured Goal / Accomplished / Next Steps / Relevant Files.
- agent-sync: `record_handoff` with source=claude-code, summary, files_changed, decisions, next_steps.

Both should surface this session's context automatically at session start.
