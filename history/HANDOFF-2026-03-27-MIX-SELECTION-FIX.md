# Mix Page Selection Fix

**Date:** 2026-03-27
**Status:** Fixed

## Problem

Waveform clips on the Mix timeline could not be reliably selected or deselected by clicking. Clicking a clip sometimes didn't visually show it as selected. Clicking empty space to deselect didn't work. The behavior was erratic and unpredictable.

## Root Cause

Two issues were found and fixed:

### 1. `@ObservationIgnored` on `selectionOverrides` (primary fix)

In `Sources/NovotroMix/MixStore.swift`, line 588:

```swift
@ObservationIgnored private var selectionOverrides: [String: MixSceneSelectionOverride] = [:]
```

The `selectionOverrides` dictionary — which stores all clip and track selection state — was marked `@ObservationIgnored`. This told Swift's Observation framework to never track changes to this property. Every selection method (`selectClip`, `selectTrack`, `deselectClip`) writes to `selectionOverrides`, and every view reads selection state through computed properties (`currentSelectedClipID`, `currentSelectedTrackID`) that read `selectionOverrides`. With `@ObservationIgnored`, the writes happened internally but no view was ever invalidated — the UI was frozen on whatever selection state happened to be rendered when some other observed property last changed.

**Fix:** Removed `@ObservationIgnored` so `selectionOverrides` is a normal observed property.

### 2. NSView click surface bypassing SwiftUI hit-test chain (secondary fix)

In `Sources/NovotroMix/Views/MixTimelineView.swift`, the lane background click handler (`MixLaneClickSurface`) was an `NSViewRepresentable` wrapping a custom `MixLaneClickNSView`. This NSView handled mouse events through AppKit's responder chain, which operates independently from SwiftUI's gesture system. Both systems could process the same click, potentially causing the clip to be selected and immediately deselected in the same event cycle.

**Fix:** Replaced the NSView-based click surface with a pure SwiftUI `Color.clear` view using a `SpatialTapGesture`. Now both clip tap gestures and lane tap gestures participate in the same SwiftUI hit-test chain — only one fires per click.

## Files Changed

- `Sources/NovotroMix/MixStore.swift` — Removed `@ObservationIgnored` from `selectionOverrides`
- `Sources/NovotroMix/Views/MixTimelineView.swift` — Replaced `MixLaneClickSurface` (NSViewRepresentable) and `MixLaneClickNSView` with a SwiftUI `SpatialTapGesture` on `Color.clear`

## Also in this session

Renamed all references from "Novotro Opera" to "Amira Writer" across functional code and active documentation to match the renamed project directory. Historical documents in `history/` and `Suno/archive/` were left as-is.
