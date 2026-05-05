# Synopsis Performance Fix Handoff

Date: 2026-03-23
Workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`

## What This Session Did

Fixed severe performance regression (spinning beach balls) when scrolling the libretto in Novotro Write. The root cause was bidirectional scroll synchronization between the center libretto pane and the synopsis inspector pane — each scroll event triggered expensive O(n*m) path resolution, computed property re-evaluation, regex parsing, and cascading animations.

## Root Cause

The synopsis pane had three compounding performance problems:

1. **`onPreferenceChange(SectionVisibilityKey)`** fires on every scroll frame, running `updateActiveSection(from:)` which computes geometry-based active section and writes to `store.activeSongPath`.

2. **`activeSectionIndex` computed property** in `SynopsisSectionView` was evaluated on every view body render. It called `parsedSections` (regex parsing of entire synopsis), and for each section ran `SynopsisScenePathResolver.resolve()` which does O(n*m) path normalization + case-insensitive search through all libretto paths.

3. **`onChange(of: store.activeSongPath)`** triggered synopsis auto-scroll with animation whenever the active section changed during scrolling, cascading animations on every section row.

## What Was Changed

### `Sources/NovotroWrite/Views/SynopsisSectionView.swift`

**Removed:**
- `lastScrolledToIndex: Int?` state variable
- `activeSectionIndex` computed property entirely (expensive O(n*m) path resolution per render)
- `ScrollViewReader` wrapper and `.onChange(of: store.activeSongPath)` that auto-scrolled synopsis to active section
- Yellow/active highlighting from `sectionView` (`.foregroundStyle(isActive ? ...)`, yellow `.background()`, yellow left-accent overlay, `.scaleEffect`, `.animation(...)`)
- `isActive: Bool` parameter from `sectionView` function signature

**Kept:**
- Clickable scene links (button sets `store.scrollTarget`)
- Subtle accent-color left bar indicator on linked sections (accentColor at 15% opacity, 2pt wide)
- Synopsis text parsing via `parsedSections` (still called once per view body render, but no longer called twice per section per render)
- Edit mode (pencil icon → TextEditor)

**After change:** Synopsis is now a read-only scrollable list of clickable scene links with no active-tracking or scroll-sync overhead.

### `Sources/NovotroWrite/ScriptStore.swift`

**Earlier in session (before performance fix):**
- Added `refreshSynopsisFromProjectFile()` method (lines ~1389-1417) — reads `Synopsis/synopsis.txt` from disk, updates `synopsisText` only if content changed, keeps file-snapshot bookkeeping in sync
- Modified `loadSynopsis(from:)` to update `lastKnownModDates["__synopsis__"]` and `lastKnownFileSnapshots` after loading (lines ~1380-1383)
- Changed `loadProject(...)` to always call `loadSynopsis(from:)` after DB load, ensuring disk reconciliation even when DB has data (lines ~949-960)
- Added `novotroDebugLog(...)` debug logger writing to `/tmp/novotro-debug.log`
- Added `suspendBackgroundWork()` method
- Added `guard !Task.isCancelled else { return }` checks to background index refresh task

### `Sources/NovotroWrite/Views/ScriptInspectorView.swift`

**Added (earlier session):**
- `@Environment(\.scenePhase)` injection
- `.onAppear { if activeTab == synopsis { store.refreshSynopsisFromProjectFile() } }`
- `.onChange(of: activeTab) { if synopsis { refresh } }`
- `.onChange(of: scenePhase) { if .active { refresh } }`

These force a synopsis disk-refresh when the synopsis tab becomes visible or the app returns to foreground.

### `Sources/NovotroWrite/Views/ScriptCenterView.swift`

**Current state (simplified `updateActiveSection`):**
- Uses `scrollOffset: CGFloat = 100` (fixed reference point, not viewport-based)
- Guards against empty sections and sections not yet visible
- Uses `guard section.maxY > scrollOffset` to skip sections above the reference line
- Keeps `best != store.activeSongPath` guard to prevent redundant state updates

**Note:** `updateActiveSection` still fires on every scroll frame via `onPreferenceChange`. This is now less harmful since synopsis sync was removed, but could benefit from debouncing if further issues arise.

## Build + Test Status

- `swift build -c release` — **passes**
- `swift test -c release` — **18 tests, 0 failures**

## What Was NOT Changed (Still Functional)

- Click-to-navigate from synopsis to libretto (`store.scrollTarget` path) — still works
- `store.activeSongPath` still updates as user scrolls through libretto (used by sidebar to show active scene)
- External change highlighting (yellow text highlighting on externally modified libretto sections) — still present in `ScriptSectionView`
- Syllable annotation stripping in `ScriptTextEditor` — still present
- `ScriptStore.refreshSynopsisFromProjectFile()` force-refresh mechanism — still wired to inspector lifecycle

## Current Repo Status

The workspace has many uncommitted modified files from this session and earlier work:

**Modified in this session (related to this fix):**
- `Sources/NovotroWrite/ScriptStore.swift`
- `Sources/NovotroWrite/Views/ScriptInspectorView.swift`
- `Sources/NovotroWrite/Views/SynopsisSectionView.swift`
- `Sources/NovotroWrite/Views/ScriptCenterView.swift` (minor cleanup)

**Modified in this session (external-change highlighting — related but separate):**
- `Sources/NovotroWrite/Views/ScriptCenterView.swift` (external change yellow highlighting in ScriptSectionView/ScriptTextEditor)

**Other modified files (unrelated prior work):**
- `Packages/NovotroAnimate/*` (many files)
- `Packages/NovotroScore/*` (many files)
- `Packages/NovotroProjectKit/*`
- `Sources/Opera/*`
- `Sources/NovotroWrite/NovotroWriteWorkspace.swift`
- `Sources/NovotroWrite/Views/ContentView.swift`

## Key Files for Reference

| File | What it does |
|------|-------------|
| `Sources/NovotroWrite/Views/SynopsisSectionView.swift` | Synopsis inspector pane — clickable scene links, no auto-scroll |
| `Sources/NovotroWrite/Views/ScriptCenterView.swift` | Libretto scroll + `updateActiveSection` (fires on scroll) |
| `Sources/NovotroWrite/ScriptStore.swift` | Synopsis load/refresh/save, `activeSongPath`, `scrollTarget` |
| `Sources/NovotroWrite/Views/ScriptInspectorView.swift` | Inspector tabs + synopsis refresh triggers |
| `Sources/NovotroWrite/Views/ScriptSectionView.swift` | Per-scene editor + external-change yellow highlighting |
| `Sources/NovotroWrite/Views/ScriptTextEditor.swift` | NSTextView wrapper + external change highlighting |

## Open / Next Steps

1. **Manual testing**: Open a real project, scroll libretto up/down — confirm no beach balls, confirm synopsis click-to-navigate still works.

2. **Optional further optimization**: If `updateActiveSection` still causes issues, add debouncing (e.g., 100ms delay before writing `activeSongPath`).

3. **Optional synopsis improvement**: If synopsis content is large, `parsedSections` (regex parse) is still called on every body render. Could cache with `@State var cachedSections` + `onChange(of: synopsisText)`.

4. **Debug log**: `novotroDebugLog(...)` writes to `/tmp/novotro-debug.log`. Can be searched for `loadProject`, `refreshSynopsisFromProjectFile` to trace synopsis lifecycle.

5. **Repo cleanup**: Many unrelated files are modified. Consider `git stash` or selective commits to isolate this work.
