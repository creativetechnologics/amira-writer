# Amira Writer — Session Handoff
**Date:** 2026-04-03 09:15 PDT
**Performed by:** Claude Opus 4.6 (1M context) + Claude Sonnet 4.6 (subagents)
**Prior session:** Pipeline wave 2, crop tool, safety, quality pass

---

## Summary

12 commits across pipeline automation, crop tooling, layout, keyboard focus, API safety, quality improvements, code review, and circuit breaker.

---

## Commits This Session

| Hash | Description |
|------|-------------|
| `4f22b3c` | 20 pipeline automation items (wave 2) — video export, scrub slider, props sidebar, direction editor, etc. |
| `c0aacdc` | Master sheet reference ordering — first in headSheetReferencePaths |
| `cebc146` | Source-aware variant crop tool with 8 resize handles |
| `dc2164a` | Crop tool fixes — eoFill, pixel dimensions, 1:1 lock |
| `634147a` | Character page layout compaction for small screens |
| `15e22a5` | Spacebar-in-TextEditor fix — .focusable() scoped to gallery |
| `f3c0aaf` | Gemini API safeguards — rate limiting, logging, manual-only dispatch |
| `57ed27f` | 20 quality improvements — TTS, error surfacing, tests, performance |
| `f7d3cd6` | 5 code review bug fixes — main thread, timer, renderer, race, cut interval |
| `0931065` | Diagnostic logging for headSheetReferencePaths |
| `89ef14a` | Circuit breaker — 10 consecutive failures → block all API calls |

---

## Critical Open Issues

### 1. Gemini API spam — root cause unknown
The app made 1000+ unauthorized Gemini API image generation requests overnight. All were the head turnaround sheet prompt ("Use the supplied references..."), all returned 503. **The circuit breaker prevents this from happening again** (blocks after 10 consecutive failures), but the code path that triggered the loop was never identified. All explicit call sites require user confirmation through GeminiGenerationPreflightSheet.

### 2. Luke's master sheet missing from head turnaround preflight
User reports the approved master sheet is not appearing as a reference image when generating the head turnaround sheet for Luke Hart. Code analysis shows `headSheetReferencePaths` correctly includes `approvedMasterReferenceSheetVariant?.imagePath` in first position. Diagnostic logging has been added (commit `0931065`) — next step is to check Console.app output when clicking "Generate Sheet" on Luke's head turnaround section. The log lines are prefixed `[headSheetReferencePaths]`.

---

## Architecture Changes

### Circuit Breaker (GeminiImageService)
- `consecutiveFailures` counter increments on every HTTP error or network error
- After 10 consecutive failures → `circuitBreakerTripped = true` → ALL generate() calls immediately throw
- Counter resets to 0 on any successful response
- Only clears on app restart

### Source-Aware Crop Tool
- `CharacterLookDevelopmentVariant` now has `sourceSheetPath: String?` and `sourceCropRect: CropRect?`
- `cropApprovedHeadTurnaroundSheet` and `cropApprovedCostumeSheet` stamp these fields
- `CharacterVariantCropSheet` shows source sheet with 8 drag handles
- `AnimateStore.applyCropToVariant()` overwrites variant file in-place

### Keyboard Focus
- `.focusable()` + `.onKeyPress()` moved from page-level ScrollView to `ImageGallerySection.galleryGrid`
- Rule: NEVER scope keyboard handlers wider than the view that needs them

---

## Test Suite
- **263 tests, 0 failures, 4 skipped**
- New test files: `TTSServiceTests.swift`, `DepthEstimationTests.swift`, `CropRectTests.swift`
- `SilverSceneSmokeTests` now skip gracefully when test data is unavailable

---

## Deploy Process
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
xcodebuild -scheme "Opera" -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CONFIGURATION_BUILD_DIR="$(pwd)/build/app" build

cp build/app/Opera "/Volumes/Storage VIII/Programming/\!Applications/Amira Writer.app/Contents/MacOS/Opera"
for b in build/app/*.bundle; do
  cp -R "$b" "/Volumes/Storage VIII/Programming/\!Applications/Amira Writer.app/Contents/Resources/$(basename $b)"
done
codesign --force --sign - "/Volumes/Storage VIII/Programming/\!Applications/Amira Writer.app"
```

---

## Next Session Priorities
1. **Diagnose Luke's master sheet issue** — check Console output from diagnostic logging
2. **Remove diagnostic logging** once master sheet issue is resolved
3. **Find the Gemini API auto-trigger** — add more aggressive logging or a breakpoint to trace what calls `GeminiImageService.generate()` when no preflight sheet is open
4. **Test the crop tool** — verify source sheet display and resize handles work correctly
5. **Test the deployed app** — verify circuit breaker, rate limiting, keyboard focus fix all work in production
