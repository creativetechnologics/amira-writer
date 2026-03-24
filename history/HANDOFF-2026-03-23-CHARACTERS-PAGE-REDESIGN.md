# Novotro Animate — Characters Page Redesign Handoff

**Date:** 2026-03-23  
**Session Title:** Characters Page Image Systems Separation & Gallery Improvements

---

## Goal

Redesign the Characters page in Novotro Animate with: profile picture cropping, inspiration reference thumbnail in the header, masonry thumbnail galleries for inspiration/animated images, persistence for all character page data, and drag-and-drop character reordering. Also fix cropper 1:1 square math, thumbnail layout spacing, and save/reopen persistence.

---

## Architecture: Two Separate Image Systems (CRITICAL)

The Characters page has **TWO completely separate image systems** that must NOT share data:

### 1. Inspiration Images (Middle Section)
- **Field:** `AnimationCharacter.inspirationImagePaths: [String]`
- **Sheet:** `InspirationGallerySheet`
- **Purpose:** Design inspiration — images that inspired the character's look
- **Storage path in bundle:** `Animate/characters/<slug>/inspiration/`

### 2. Reference Images (Header Thumbnail)
- **Fields:**
  - `AnimationCharacter.inspirationReferenceImagePath: String?` — single image shown in header thumbnail
  - `AnimationCharacter.referenceImagePaths: [String]` — multiple images for gallery (newly added)
- **Sheet:** `ReferenceImagesSheet`
- **Purpose:** Visual reference guides for the character's appearance, also used by Gemini prompts
- **Storage path in bundle:** `Animate/characters/<slug>/reference/`

**The header thumbnail opens `ReferenceImagesSheet` (NOT `InspirationGallerySheet`).**

---

## Key Files Modified

### `Packages/NovotroAnimate/Sources/NovotroAnimate/Models/AnimateModels.swift`
- **Lines ~298-334:** Added `referenceImagePaths: [String]` field to `AnimationCharacter`

### `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift`
- **Lines ~3524-3590:** New `// MARK: - Reference Images Gallery` section with:
  - `addReferenceImage(_ imagePath: String, for characterID: UUID)`
  - `removeReferenceImage(at indexToRemove: Int, for characterID: UUID)`
  - `importReferenceImages(for characterID: UUID)`
- **Line ~3710:** Updated `syncCharactersFromOWP()` to include `referenceImagePaths: persistedCharacter?.referenceImagePaths ?? []`

### `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/CharactersPageView.swift`
- **Line ~14:** Added `showReferenceImages: Bool` state
- **Lines ~65-72:** Added `.sheet(isPresented: $showReferenceImages)` for `ReferenceImagesSheet`
- **Lines ~305-350:** `inspirationReferenceView()` (renamed but still references inspiration) — opens `showReferenceImages`, label says "Reference Images"
- **Lines ~1318-1400:** `InspirationGallerySheet.galleryThumbnail()` — simplified thumbnail with context menu only (no ellipsis button overlay)
- **Lines ~1255-1295:** `InspirationGallerySheet` — header no longer shows reference image
- **Lines ~1354-1575:** `ReferenceImagesSheet` — expanded with main reference + gallery section
- **Lines ~756-866:** `ImageGalleryThumbnail` — removed hover buttons (`isHovering`, remove button, expand button, `.onHover`)

---

## Build Command

```bash
cd "/Volumes/Storage VIII/Programming/Novotro Opera" && rtk swift build -c release --product NovotroAnimateUI
```

---

## What Was Done

### Phase 1: Image Cropper Fix
- Rewrote `ImageCropperView` to use single source of truth for crop rect
- Fixed `makeSquareCrop()` to center square around current crop center
- Fixed drag math to use `value.translation` delta
- Fixed crop-save to use `CGImage.width/height` (not `NSImage.size`)
- Added `.contentShape(Rectangle())` for drag hit-testing

### Phase 2: Thumbnail Gallery Layout
- Replaced custom `MasonryLayout` with `LazyVGrid` with fixed adaptive columns
- Fixed `ImageGalleryThumbnail` to not use `GeometryReader`
- Fixed to use `tileWidth` from layout and `max(88, tileWidth * 0.68)` height

### Phase 3: Persistence Fixes
- All character page fields saved to `rig.json` for every character
- Images copied into project bundle: `Animate/characters/<slug>/profile/`, `/inspiration/`, `/reference/`, `/animated/`
- `AssetManager` extended with `importCharacterImageURL()` and `writeCharacterImageData()`
- `loadPersistedCharacterState()` returns full `AnimationCharacter`
- `syncCharactersFromOWP()` merges all persisted page fields
- Fixed cross-project stale character leak in `openOWP()`
- Added `sortOrder` field to `AnimationCharacter` for character ordering

### Phase 4: UI Updates
- Added `showInspirationGallery` and `showReferenceImages` sheet bindings
- `InspirationGallerySheet` for middle section inspiration images
- `ReferenceImagesSheet` for header reference images (with main image + gallery)
- Updated `characterHeader` to show profile + reference images side by side
- Added drag-and-drop reordering to character sidebar list
- Added right-click context menu for thumbnail removal
- Added double-click preview with left/right navigation

### Phase 5: Hover Button Removal
- Removed hover-reveal buttons from `ImageGalleryThumbnail`
- Removed ellipsis overlay button from `InspirationGallerySheet.galleryThumbnail()`
- Deletion: right-click context menu only
- Preview: double-click only

### Phase 6: Reference Images Sheet Expansion
- Added `referenceImagePaths` array to `AnimationCharacter`
- Expanded `ReferenceImagesSheet` with two sections:
  - **Main Reference Image:** The single image shown in header (existing `inspirationReferenceImagePath`)
  - **Reference Image Gallery:** Multiple reference images with import, zoom, preview
- Added store methods: `addReferenceImage`, `removeReferenceImage`, `importReferenceImages`

---

## Current State

All planned features implemented and building successfully. The two image systems are now completely separate.

---

## Next Steps / Remaining Work

If any, these would be logical extensions:
1. Consider renaming `inspirationReferenceImagePath` to `mainReferenceImagePath` for clarity (backward compat concern)
2. Consider whether the reference gallery should support setting one image as "main" automatically
3. Consider Gemini integration using `referenceImagePaths` for prompt context
4. The `inspirationReferenceView` function name still references "inspiration" — could rename to `referenceImageView` for consistency

---

## Relevant Reference Files (Read Only)
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/InspectorView.swift` — Inspector pane
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/CharactersSidebarView.swift` — Sidebar
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Services/CharacterPackageLibrary.swift` — Package library
