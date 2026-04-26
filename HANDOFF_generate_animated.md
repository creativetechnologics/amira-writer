# Handoff: "Generate Animated" Right-Click Feature

## What we're building
Right-clicking any image thumbnail anywhere in the app shows a "Generate Animated" context menu item. When tapped, it opens the Gemini preflight sheet with:
- The right-clicked image pre-attached as a reference
- The "Animated Look" toggle pre-checked
- An empty prompt

## Key implementation details
- `UnifiedImageActions.onGenerateAnimated: (() -> Void)?` — already added to the struct and menu button
- Before presenting the preflight sheet, set `UserDefaults.standard.set(true, forKey: AnimatedLookPromptSettings.preflightToggleDefaultsKey)` so the sheet's `.onAppear` sync reads it correctly
- Build a `GeminiGenerationDraft` with `usesMasterAnimatedLookPrompt: true`, `prompt: ""`, and one `GeminiGenerationReferenceDraft` for the tapped image path

## Status by file

### ✅ DONE
- `UnifiedImageContextMenu.swift` — `onGenerateAnimated` added to struct + button in geminiSection
- `AllProjectImagesPageView.swift` — `beginGenerateAnimated(for:)` helper + wired at both filmstrip and grid call sites
- `PlacesPageView.swift` — wired at `PlaceAllImagesGallerySection` and `ImageGallerySection` call sites; two `beginGenerateAnimated` helpers added
- `CharactersPageView.swift` — inspiration gallery `galleryThumbnail` wired (~line 2639), `beginGenerateAnimated(imagePath:)` helper added (~line 2503)
- `CharactersPageView.swift` — `ReferenceImagesSheet` struct: `onGenerateAnimated: ((String) -> Void)? = nil` added to struct definition (~line 2670); main-reference context menu wired (~line 2786)

### 🔴 INTERRUPTED MID-EDIT — finish these first
- `CharactersPageView.swift` — `ReferenceImagesSheet.referenceGalleryThumbnail(path:index:)` at ~line 2970:
  Currently reads:
  ```swift
  onGenerateWithGemini: (geminiEnabled && onGenerateWithGemini != nil) ? { count in
      onGenerateWithGemini?(path, count)
  } : nil,
  onRemoveFromCollection: {
  ```
  Add after the `onGenerateWithGemini` block:
  ```swift
  onGenerateAnimated: (geminiEnabled && onGenerateAnimated != nil) ? {
      onGenerateAnimated?(path)
  } : nil,
  ```

- `CharactersPageView.swift` — find where `ReferenceImagesSheet(...)` is instantiated (grep for `ReferenceImagesSheet(`). It currently passes `onGenerateWithGemini`. Add a parallel `onGenerateAnimated` argument that calls `beginGenerateAnimated(imagePath:)`.

### 🔴 NOT STARTED YET
- `ImagineScenesPageView.swift` — `galleryThumbnail(path:)` at ~line 669 builds `UnifiedImageActions`. Add `onGenerateAnimated`. The preflight logic for scenes should mirror the existing scenes Gemini preflight (set UserDefaults key + build GeminiGenerationDraft with `usesMasterAnimatedLookPrompt: true`).
- `ImagineCanvasPageView.swift` — check if `galleryCell` or equivalent uses `UnifiedImageActions`; if so wire the same way.

## After all wiring is done
```bash
bash "Scripts/build-app.sh"
# Then deploy to /Volumes/Storage VIII/Programming/!Applications/
# Then commit
```

## Key types / constants
- `AnimatedLookPromptSettings.preflightToggleDefaultsKey` — UserDefaults key to pre-check the toggle
- `GeminiGenerationDraft(usesMasterAnimatedLookPrompt: true)` — signals animated-look mode
- `GeminiGenerationReferenceDraft(label:path:isIncluded:)` — wraps a single reference image
- The preflight sheet is presented via `state.edit.pendingPreflight = draft` (AllImages/Places pattern) or `generatePendingPlan` (Characters pattern) — match whatever the page already uses for its existing Gemini generate flow
