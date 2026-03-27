# Handoff: Mix Page Bug Fixes & Remaining Issues

**Date:** 2026-03-27
**Status:** Partial fixes deployed, critical issues remain
**Build:** Deployed to `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

---

## What Was Done This Session

### 1. Selection/Deselection Bug (FIXED - needs verification)

**Problem:** Clicking empty lane space did not deselect the currently-selected clip. The clip appeared permanently selected once clicked.

**Root Cause:** `MixTimelineLaneView` has a `laneBackground(width:)` method that returns a `ZStack` containing multiple filled `Rectangle()` views (lane fill, grid canvas, gradient overlay, accent stripe, top/bottom hairlines). These filled views intercepted all hit-testing before the parent's `.onTapGesture` could fire.

**Prior (failed) fix attempt:** Changed from `.simultaneousGesture(DragGesture(minimumDistance: 0))` to `.contentShape(Rectangle()).onTapGesture { location in ... }`. This was correct in principle (SwiftUI child-first gesture priority) but insufficient because `laneBackground`'s filled Rectangles still absorbed taps.

**Current fix:** Added `.allowsHitTesting(false)` to the entire `laneBackground` ZStack. This lets the parent's `.contentShape(Rectangle()).onTapGesture` fire reliably on empty lane space while still allowing child clip views (which have their own `.onTapGesture`) to receive taps first.

**File:** `Sources/NovotroMix/Views/MixTimelineView.swift`, line ~603 (end of `laneBackground` method)

**If this fix doesn't work:** The alternative approach is to place a `Color.clear.contentShape(Rectangle()).onTapGesture { ... }` as the FIRST child inside the lane ZStack (behind clips but above the background), with the deselect/seek logic. Remove the parent-level `.onTapGesture`. This ensures SwiftUI's child-first priority routes clip taps to clips and background taps to the clear layer.

### 2. Cross-Track Drag Disappearance (FIXED - needs verification)

**Problem:** Dragging a clip downward into another track caused it to visually disappear. The clip rendered behind the adjacent lane's content.

**Root Cause:** `.zIndex(isDragging ? 100 : ...)` on `MixClipView` only controls z-order within the clip's own lane ZStack. When the clip is offset vertically into an adjacent lane, that lane's ZStack renders on top in the parent VStack, hiding the dragged clip.

**Fix:**
1. Added `draggingClipTrackID: UUID?` property to `MixStore` (set on drag start, cleared on drag end)
2. `MixClipView.interactionGesture` sets `store.draggingClipTrackID = clip.trackID` at drag start and clears it at drag end
3. `MixArrangementView` checks `store.draggingClipTrackID == track.id` and applies `.zIndex(1000)` to that lane in the parent VStack, ensuring it renders above all siblings

**Files:**
- `Sources/NovotroMix/MixStore.swift` - added `draggingClipTrackID` property (~line 530)
- `Sources/NovotroMix/Views/MixClipView.swift` - sets/clears `draggingClipTrackID` in drag gesture (~lines 393, 407)
- `Sources/NovotroMix/Views/MixTimelineView.swift` - uses `draggingClipTrackID` for lane `.zIndex()` (~line 128)

**Known limitation:** The clip may still be visually clipped by the horizontal `ScrollView`'s `.clipped()` modifier (line ~164 of MixTimelineView). If the clip is dragged outside the scroll view's bounds entirely, it will be cut off. This is a deeper architectural issue that would require rendering the dragged clip in an overlay above the scroll view.

### 3. Blurry Waveforms (FIXED)

**Problem:** Waveform images looked blurry, especially after moving clips. Got worse on Retina displays.

**Root Cause:** `MixWaveformCache.renderWaveformImage()` created CGImages at 1x scale (128px height, up to 2048px width). Displayed via `Image(decorative: cgImage, scale: 1).resizable()` which made SwiftUI upscale by 2x on Retina displays, causing blur.

**Fix:**
1. `MixWaveformCache.renderWaveformImage()` now renders at 2x scale (`waveformImageHeight * 2` height, `logicalWidth * 2` width, `barWidth * 2`, `gap * 2`)
2. `MixClipView.waveformCanvas()` uses `Image(decorative: cgImage, scale: 2)` so SwiftUI knows each 2 pixels = 1 point

**Files:**
- `Sources/NovotroMix/MixWaveformCache.swift` - `renderWaveformImage()` (~line 121)
- `Sources/NovotroMix/Views/MixClipView.swift` - `waveformCanvas()` (~line 438)

**Note:** The waveform image cache now uses 4x the memory per entry (2x width * 2x height). With 50 max entries this should still be well under 100MB. If memory is a concern, reduce `maxCacheEntries` or `waveformImageHeight`.

### 4. Sidebar Rewrite (FIXED)

**Problem:** The Mix scene sidebar had a search/filter field ("Filter scenes") that Gary explicitly asked to be removed. It also didn't match the visual layout of the Write and Score page sidebars.

**Fix:** Rewrote `MixSceneSidebarView` to match the Score page sidebar pattern exactly:
- Removed the search field and all `filteredScenes`/`sceneSearchText` references
- Removed `sceneSearchText` property and `filteredScenes` computed property from `MixStore`
- Uses `store.scenes` directly (no filtering)
- Uses `OperaChromeSidebarList` + `OperaChromeSidebarRow` (same as Score and Write)
- Icon: `waveform` / `waveform.badge.plus` in `OperaChromeTheme.textSecondary` (matches the secondary icon color pattern from Score/Write)
- Title: `scene.displayTitle` in `OperaChromeTheme.textPrimary` at 12.5pt medium weight
- Summary line: `"3T . 5C"` format in `OperaChromeTheme.textSecondary` when session has content

**Files:**
- `Sources/NovotroMix/Views/MixSceneSidebarView.swift` - complete rewrite
- `Sources/NovotroMix/MixStore.swift` - removed `sceneSearchText` and `filteredScenes`

---

## Architecture Reference

### Gesture Hierarchy (critical for debugging selection issues)

SwiftUI processes gestures child-first. The current hierarchy:

```
MixTimelineLaneView (parent)
  .contentShape(Rectangle())           // Defines hit area for tap
  .onTapGesture { location in          // Fires ONLY if no child consumed the tap
      seekPlayhead + selectTrack(clearSelectedClip: true)
  }
  |
  +-- laneBackground(width:)           // ZStack of filled Rectangles
  |     .allowsHitTesting(false)       // CRITICAL: prevents background from eating taps
  |
  +-- ForEach(visibleClips) { clip in
  |     MixClipView(...)
  |       .onTapGesture { selectClip() }     // Child-first: fires before lane tap
  |       .gesture(interactionGesture)        // DragGesture(minimumDistance: 2)
  |
  +-- MixAutomationEnvelopeView(...)
        automation points have:
          .onTapGesture { }                   // Empty — prevents fall-through
          .gesture(DragGesture(minimumDistance: 1))
```

### Key SwiftUI Lessons Learned

1. **`.allowsHitTesting(false)` on decorative backgrounds** - Any filled Shape/Rectangle used purely for visual appearance must have `.allowsHitTesting(false)` if a parent-level gesture handler needs to receive taps through it.

2. **`.zIndex` scope** - `.zIndex` only affects ordering within the immediate parent container. To elevate a view above siblings in a VStack, the `.zIndex` must be on the VStack child, not on a nested descendant.

3. **CGImage scale for Retina** - `Image(decorative: cgImage, scale: 1)` tells SwiftUI the image is at 1x. On 2x Retina screens, SwiftUI upscales it, causing blur. Always render CGImages at 2x and use `scale: 2`.

4. **Never use `.simultaneousGesture(DragGesture(minimumDistance: 0))` on a parent** that has children with `.onTapGesture`. The simultaneous gesture fires on ALL interactions including child taps, racing with and undoing the child's state changes.

### File Map

| File | Purpose |
|------|---------|
| `Sources/NovotroMix/MixStore.swift` | Central `@Observable` state. Selection, clips, tracks, undo, transport. |
| `Sources/NovotroMix/MixWaveformCache.swift` | Background peak computation + CGImage pre-rendering. |
| `Sources/NovotroMix/Views/MixTimelineView.swift` | Arrangement layout, lane views, ruler, playhead, drop delegate. |
| `Sources/NovotroMix/Views/MixClipView.swift` | Individual clip: waveform display, drag/trim/split gestures, selection. |
| `Sources/NovotroMix/Views/MixSceneSidebarView.swift` | Scene list sidebar. |
| `Sources/NovotroMix/Views/MixWorkspaceContentView.swift` | Top-level workspace + keyboard shortcuts (30+ invisible Buttons). |
| `Sources/NovotroMix/Views/MixToolbarView.swift` | Toolbar: transport controls, tool selector, snap picker, LCD display. |
| `Sources/NovotroMix/Views/MixAutomationView.swift` | Automation envelope overlay with draggable points. |
| `Sources/NovotroMix/Views/MixInspectorView.swift` | Right-side inspector (clip, track, scene tabs). |
| `Sources/NovotroMix/Views/MixMixerDockView.swift` | Bottom mixer strip with per-track volume/pan/mute/solo. |
| `Sources/NovotroMix/MixPalette.swift` | All color constants for the Mix module. |

### MixStore Key Methods

| Method | Line (approx) | Purpose |
|--------|---------------|---------|
| `selectClip(_:)` | 814 | Sets `selectedClipID` + updates `selectedTrackID` |
| `selectTrack(_:clearSelectedClip:)` | 785 | Sets `selectedTrackID`, optionally clears clip selection |
| `deselectClip()` | 916 | Clears `selectedClipID` |
| `moveClip(_:to:startSeconds:)` | 1415 | Move clip to track at time, resolves overlaps |
| `targetTrackID(from:laneDelta:)` | 1722 | Maps vertical drag delta to target track ID |
| `snapToGrid(_:)` | ~1050 | Quantizes time to snap grid |
| `mutateCurrentSession(_:)` | 2306 | Updates session, calls `repairSelection`, saves |
| `repairSelection()` | 3016 | Validates selectedClipID/selectedTrackID, clears invalid |

---

## Known Remaining Issues

### Critical
1. **Selection fix needs user verification** - The `.allowsHitTesting(false)` fix is the correct approach but has not been tested in practice. If it still doesn't work, the issue may be deeper in SwiftUI's gesture system. See "If this fix doesn't work" section above.

2. **Cross-track drag may still clip at ScrollView boundary** - The outer horizontal ScrollView has `.clipped()` which may cut off clips dragged vertically outside the scroll view's frame. The `.zIndex` fix only addresses z-ordering between sibling lanes within the VStack.

### Medium
3. **Cross-lane drag height calculation imprecise** - `laneHeight` is used to compute `laneDelta` in `MixClipView.interactionGesture`, but each lane can have a different height. The calculation `Int((value.translation.height / laneHeight).rounded())` uses only the source lane's height. With very different lane heights, the target track prediction may be off by one.

4. **Waveform cache invalidation on move** - When a clip is moved, its `filePath` doesn't change, so the waveform cache is fine. But if the waveform CGImage was rendered at a different clip width, it may look slightly different at the new position since SwiftUI stretches it. This is cosmetic only.

### Low Priority
5. **CADisplayLink in AnimateStore** - Never invalidated after playback (no store leak, just wastes a tiny amount of CPU)
6. **`openProjectFromDisk` missing `@MainActor`** - Safe in practice but should be annotated
7. **No multi-clip selection** - No shift-click or Cmd-click range selection

---

## Build & Deploy

```bash
cd "/Volumes/Storage VIII/Programming/Novotro Opera"
swift build -c release                    # Verify compilation
bash Scripts/build-app.sh                 # Build + deploy to !Applications
bash Scripts/build-app.sh --debug         # Debug build
```

**Deploy target:** `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
**Do NOT deploy to remote machines** (Laptop/MacBook) via SSH/SCP per Gary's explicit instruction.

---

## Testing Checklist

1. Open the app, navigate to Mix page, select a scene
2. Add clips to a track (drag from browser or use existing)
3. **Click a clip** - should select it (white border, shadow)
4. **Click empty lane space** - should deselect the clip and seek playhead
5. **Click another clip** - should switch selection
6. **Drag a clip down into the next track** - clip should remain visible during drag
7. **Release drag in new lane** - clip should move to that track
8. **Check waveform sharpness** - should be crisp on Retina display, not blurry
9. **Check sidebar** - should show scene list without any search/filter field
10. **Verify sidebar matches Score page** - same icon style, font sizes, spacing
