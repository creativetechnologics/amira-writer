# Characters Queue Fix, Places Draw Things, Animation Pipeline, 3D Viewer, Audit Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the broken Characters page queue system, add Draw Things integration to Places, build a shot production pipeline with Vidu Q3, add inline 3D model viewer, implement smart cropping, and fix 47 audit bugs.

**Architecture:** Phase-based execution. Phase 0 fixes critical bugs and the cursor-jump issue (foundation). Phase 1 separates the queues. Phase 2 adds new services (MiniMax, Vidu, Draw Things, smart cropping). Phase 3 builds new UI (3D viewer, Draw Things pane, shot production strip). Phase 4 is Sonnet/Opus code review and fix pass.

**Tech Stack:** Swift, SwiftUI, macOS 26.0+, SceneKit, ModelIO, Core Image, Accelerate, @Observable pattern

**Delegation Model:**
- **MiniMax M2.7** — Tasks 1-15 (bulk implementation, one task per dispatch)
- **Sonnet** — Fix any build errors MiniMax introduces, Task 16 code review
- **Opus** — Task 17 final review, tough architectural issues

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `Services/MiniMaxPromptService.swift` | MiniMax M2.7 API client for SD prompt generation |
| `Services/MiniMaxCredentialStore.swift` | Keychain storage for MiniMax API key |
| `Services/ViduAPIService.swift` | Vidu Q3 API client (create task, poll, download) |
| `Services/ViduCredentialStore.swift` | Keychain storage for Vidu API key |
| `Services/ReferenceSheetCropService.swift` | Vision-based smart cropping for reference sheets |
| `Models/ShotProductionModels.swift` | ShotBackgroundPlate, ShotFrameGeneration, AnimationStylePreset, ViduBatchQueueItem |
| `Views/ShotFilmstripView.swift` | Horizontal scrollable shot filmstrip |
| `Views/ShotProductionStripView.swift` | Shot production detail strip (first/last frame, Vidu) |
| `Views/ShotFrameCard.swift` | First/last frame card component |
| `Views/DrawThingsGenerationPane.swift` | Draw Things pane for Places page |
| `Views/Character3DModelViewer.swift` | Inline SCNView wrapper for 3D model viewing |
| `Views/CharacterQueueControlsBar.swift` | Pinned Gemini+Meshy queue controls for Characters page |
| `Views/CostumeSectionView.swift` | Extracted costume section with local text state (cursor fix) |

### Modified Files
| File | Changes |
|------|---------|
| `AnimateStore.swift` | Replace batchQueue with geminiQueue/meshyQueue, add viduQueue, API keys, fix 11 bugs |
| `CharactersPageView.swift` | Restore characterHeader/lookDevSection, add queue bar, 3D viewer, fix 16 bugs |
| `CharacterReferenceWorkflowSheet.swift` | Extract CostumeSectionView, fix cursor jump, fix 11 bugs |
| `Meshy3DGenerationPane.swift` | Move batchQueue to store, fix 6 bugs |
| `InspectorView.swift` | Fix batch queue, remove redundant tab, fix 3 bugs |
| `PlacesPageView.swift` | Add Draw Things generation pane |
| `Animate3DWorkspace.swift` | Add filmstrip + production strip below 3D preview |
| `AnimateModels.swift` | Add animationStylePreset to AnimationScene, shot production fields to AnimationSceneShot |
| `DrawThingsPlaceGenerationService.swift` | Add img2img support, seed control |
| `PlacesIndexModels.swift` | Add resolution presets to DrawThingsPlaceConfig |

---

## Phase 0: Critical Bug Fixes (Foundation)

### Task 1: Fix Cursor-Jump Bug — Extract CostumeSectionView

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/CostumeSectionView.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`

**Context for MiniMax (include ALL of this in the prompt):**

This is a SwiftUI macOS app targeting macOS 26.0. The store uses `@Observable` pattern (NOT ObservableObject). The bug: every TextEditor/TextField with a `Binding(get:set:)` where `set` calls a store method causes cursor to jump to end on every keystroke because `@Observable` triggers re-render.

- [ ] **Step 1: Create CostumeSectionView.swift**

Extract the costume editing into its own view with local `@State` for all text fields:

```swift
import SwiftUI

@available(macOS 26.0, *)
struct CostumeSectionView: View {
    @Bindable var store: AnimateStore
    let characterID: UUID
    let costume: CharacterCostumeReferenceSet
    
    // Local state — prevents cursor jump
    @State private var localName: String = ""
    @State private var localNotes: String = ""
    @State private var localSheetPrompt: String = ""
    @State private var hasAppeared = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Costume Name", text: $localName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .onChange(of: localName) { _, newValue in
                            guard hasAppeared else { return }
                            store.updateCostumeReferenceSetName(newValue, costumeID: costume.id, for: characterID)
                        }
                    
                    TextEditor(text: $localNotes)
                        .font(.callout)
                        .frame(minHeight: 86)
                        .padding(8)
                        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.quaternary.opacity(0.4))
                        }
                        .onChange(of: localNotes) { _, newValue in
                            guard hasAppeared else { return }
                            store.updateCostumeReferenceSetNotes(newValue, costumeID: costume.id, for: characterID)
                        }
                }
                // ... rest of costume section buttons (copy from CharacterReferenceWorkflowSheet costumeSection)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("\(localName) Sheet Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $localSheetPrompt)
                    .font(.callout)
                    .frame(minHeight: 88)
                    .padding(8)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.quaternary.opacity(0.4))
                    }
                    .onChange(of: localSheetPrompt) { _, newValue in
                        guard hasAppeared else { return }
                        store.updateCostumeSheetPrompt(newValue, costumeID: costume.id, for: characterID)
                    }
            }
            // ... rest of costume section (variants, slots, etc — copy from CharacterReferenceWorkflowSheet)
        }
        .onAppear {
            localName = costume.name
            localNotes = costume.notes
            localSheetPrompt = costume.sheetPrompt
            hasAppeared = true
        }
        .onChange(of: costume.id) { _, _ in
            // Reset when costume identity changes (different costume selected)
            localName = costume.name
            localNotes = costume.notes
            localSheetPrompt = costume.sheetPrompt
        }
    }
}
```

- [ ] **Step 2: Update CharacterReferenceWorkflowSheet.swift**

Replace the `ForEach` + inline `costumeSection` at lines 642-644 with:

```swift
ForEach(character.costumeReferenceSets) { costume in
    CostumeSectionView(store: store, characterID: characterID, costume: costume)
}
```

Remove the old `costumeSection(character:costume:)` method entirely. Move all the non-text-field content (buttons, variant grid, slots) into `CostumeSectionView`.

Also fix the master reference prompt TextEditor (line 343) and head turnaround prompt TextEditor (line 499) with the same local `@State` pattern — add `@State private var localMasterPrompt: String = ""` and `@State private var localHeadPrompt: String = ""` with `.onAppear` + `.onChange`.

- [ ] **Step 3: Fix CharactersPageView.swift textEditorRow**

Replace the `textEditorRow` helper at line 856 with a new `DebouncedTextEditorRow` view struct:

```swift
@available(macOS 26.0, *)
private struct DebouncedTextEditorRow: View {
    let title: String
    let icon: String
    let storeValue: String
    let placeholder: String
    let onChange: (String) -> Void
    
    @State private var localText: String = ""
    @State private var hasAppeared = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            ZStack(alignment: .topLeading) {
                TextEditor(text: $localText)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: localText) { _, newValue in
                        guard hasAppeared else { return }
                        onChange(newValue)
                    }
                
                if localText.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            localText = storeValue
            hasAppeared = true
        }
        .onChange(of: storeValue) { _, newValue in
            // External change — only update if different (prevents cursor jump)
            if !hasAppeared || localText != newValue {
                localText = newValue
            }
        }
    }
}
```

Update callers at lines 830-852:
```swift
DebouncedTextEditorRow(
    title: "Backstory", icon: "book.fill",
    storeValue: character.backstory,
    placeholder: "Enter character backstory...",
    onChange: { store.updateCharacterBackstory($0, for: character.id) }
)
```

Same pattern for Personality and Notes.

- [ ] **Step 4: Fix AnimateStore debounce for backstory/personality**

In `AnimateStore.swift`, change `updateCharacterBackstory` (line 4897) and `updateCharacterPersonality` (line 5058) to match the `updateCharacterNotes` pattern:

```swift
func updateCharacterBackstory(_ text: String, for characterID: UUID) {
    guard let index = characters.firstIndex(where: { $0.id == characterID }),
          characters[index].backstory != text else { return }
    characters[index].backstory = text
    scheduleDebouncedSave()
}

func updateCharacterPersonality(_ text: String, for characterID: UUID) {
    guard let index = characters.firstIndex(where: { $0.id == characterID }),
          characters[index].personality != text else { return }
    characters[index].personality = text
    scheduleDebouncedSave()
}
```

- [ ] **Step 5: Build and verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme Opera -destination 'platform=macOS' build 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add Packages/Animate/Sources/AnimateUI/Views/CostumeSectionView.swift \
  Packages/Animate/Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift \
  Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift \
  Packages/Animate/Sources/AnimateUI/AnimateStore.swift
git commit -m "fix: cursor-jump bug — extract CostumeSectionView, debounced text editors"
```

---

### Task 2: Fix Critical CharactersPageView Bugs (6.1.1, 6.1.2, 6.1.3, 6.1.4)

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`

**Context for MiniMax:**

Four critical bugs in CharactersPageView.swift. DO NOT EXPLORE THE CODEBASE — all context is inline.

- [ ] **Step 1: Restore characterHeader call**

In the `characterDetail` computed property (around line 430), find where the ScrollView content starts and add `characterHeader(character)` as the FIRST item inside the ScrollView's VStack:

```swift
// Inside characterDetail, find the ScrollView { VStack { ... } } 
// Add at the very top of the VStack, before any collapsible panes:
characterHeader(character)
```

The `characterHeader(_:)` method already exists at line 620 — it just needs to be called.

- [ ] **Step 2: Restore lookDevelopmentSection call**

Add `lookDevelopmentSection` as a collapsible pane in `characterDetail`, between Notes and Inspiration panes. Add a new `@AppStorage` toggle:

```swift
@AppStorage("charactersPage.showLookDevelopmentPane") private var showLookDevelopmentPane: Bool = true
```

Then in the body, after the Notes pane and before the Inspiration pane:

```swift
collapsiblePane(
    title: "Look Development",
    icon: "paintpalette",
    isExpanded: $showLookDevelopmentPane,
    counterText: nil
) {
    lookDevelopmentSection(character)
}
```

- [ ] **Step 3: Fix submitInspirationBatch routing**

In the GeminiGenerationPreflightSheet `onConfirm` handler (around line 155-171), change the `.batch` case to call `submitInspirationBatch` instead of `store.addToBatchQueue`:

```swift
case .batch:
    if let character = store.selectedCharacter {
        // Thread wardrobe through — add it as state captured from prepareInspirationGenerationPlan
        submitInspirationBatch(drafts, wardrobe: inspirationActiveWardrobe ?? .soldier)
    }
```

Add a `@State private var inspirationActiveWardrobe: CharacterInspirationWardrobe?` and set it in `prepareInspirationGenerationPlan`.

- [ ] **Step 4: Fix ImageCropper square crop math**

Replace `makeSquareCrop(for:)` (around line 2878):

```swift
private func makeSquareCrop(for imageAspectRatio: CGFloat) {
    let maxWidth: CGFloat = 1.0
    let maxHeight: CGFloat = 1.0
    let squareSize = min(maxWidth, maxHeight)
    let centerX = maxWidth / 2
    let centerY = maxHeight / 2
    cropRect = CGRect(
        x: centerX - squareSize / 2,
        y: centerY - squareSize / 2,
        width: squareSize,
        height: squareSize
    )
}
```

Note: In normalized coordinates (0-1), both maxWidth and maxHeight are 1.0, so `squareSize = 1.0`. The crop covers the full image. If the intent is a square region within a non-square image, use:

```swift
let squareSize: CGFloat
if imageAspectRatio > 1 {
    // Landscape: height-limited
    squareSize = 1.0 / imageAspectRatio  // width in normalized coords
} else {
    // Portrait: width-limited
    squareSize = imageAspectRatio  // height in normalized coords
}
// Actually for normalized 0-1 coords where width and height are both 0-1:
let side = min(1.0, 1.0)  // always 1.0
// The real fix: squareWidth must equal squareHeight in PIXEL space
// In normalized space with different aspect ratios, equal pixel sides means:
let normalizedSide = min(1.0, 1.0 / imageAspectRatio)
cropRect = CGRect(
    x: (1.0 - normalizedSide) / 2,
    y: (1.0 - normalizedSide * imageAspectRatio) / 2,
    width: normalizedSide,
    height: normalizedSide * imageAspectRatio
)
```

Wait — the crop rect is in normalized 0-1 space where width and height BOTH span 0-1 regardless of image aspect ratio. To get a square in pixel space:
```swift
private func makeSquareCrop(for imageAspectRatio: CGFloat) {
    // imageAspectRatio = width / height
    if imageAspectRatio > 1 {
        // Landscape — constrain by height (full height, centered width)
        let w = 1.0 / imageAspectRatio  // normalized width for square pixels
        cropRect = CGRect(x: (1.0 - w) / 2, y: 0, width: w, height: 1.0)
    } else {
        // Portrait — constrain by width (full width, centered height)
        let h = imageAspectRatio  // normalized height for square pixels
        cropRect = CGRect(x: 0, y: (1.0 - h) / 2, width: 1.0, height: h)
    }
}
```

- [ ] **Step 5: Build and verify**
- [ ] **Step 6: Commit**

```bash
git commit -m "fix: restore characterHeader, lookDev section, batch routing, square crop math"
```

---

### Task 3: Fix Critical AnimateStore Bugs (6.1.8-6.1.11, 6.3.8-6.3.10)

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

**Context for MiniMax:**

Fix these specific methods in AnimateStore.swift. DO NOT EXPLORE — all line numbers and fixes are below.

- [ ] **Step 1: Fix addModel3D — add save()**

At line 8671-8674, add `save()`:
```swift
private func addModel3D(_ model: Character3DModel, to characterID: UUID) {
    guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
    characters[index].models3D.append(model)
    save()
}
```

- [ ] **Step 2: Fix generateMeshy3DModel — guard empty imageURLs, clear characterID**

At line ~8546, add guard after existing guards:
```swift
guard !imageURLs.isEmpty else {
    meshyGenerationError = "No reference images available for 3D generation."
    isGeneratingMeshy3D = false
    return
}
```

At the end of generateMeshy3DModel (both success and error paths), add:
```swift
meshyGeneratingCharacterID = nil
```

- [ ] **Step 3: Fix downloadMeshyAssets — correct path**

At line 8628-8632, change:
```swift
// BEFORE:
let slug = character.owpSlug.isEmpty ? character.id.uuidString : character.owpSlug
let assetDir = animateURL
    .appendingPathComponent("Characters")

// AFTER:
let slug = character.assetFolderSlug
let assetDir = animateURL
    .appendingPathComponent("characters")
```

Also change the costume name at line 8644:
```swift
// BEFORE:
costumeName: "meshy-\(taskID.prefix(8))",

// AFTER:  
costumeName: config.costumeName ?? "meshy-\(taskID.prefix(8))",
```

(This requires adding `costumeName: String?` to the caller's context — or threading it through `MeshyMultiImageRequest`.)

- [ ] **Step 4: Fix stale index in import methods**

For `importInspirationImages(for:)` (line 5147), `importReferenceImages(for:)` (line 5412), `import3DModel(for:costumeName:)` (line 5572):

In each method's async Task block, re-resolve the index:
```swift
Task { @MainActor in
    // Re-resolve index — may have changed while panel was open
    guard let index = self.characters.firstIndex(where: { $0.id == characterID }) else { return }
    let slug = self.characters[index].assetFolderSlug
    // ... rest of logic using fresh `index` and `slug`
}
```

- [ ] **Step 5: Fix handleBatchItemCompletion — add guard**

At line 8680, add:
```swift
func handleBatchItemCompletion(...) {
    guard !isGeneratingMeshy3D else {
        statusMessage = "Meshy generation already in progress — queued for later."
        return
    }
    // ... existing code
}
```

- [ ] **Step 6: Fix seedCharacterReferenceWorkflowIfNeeded — conditional save**

At line 5657, add mutation tracking:
```swift
func seedCharacterReferenceWorkflowIfNeeded(for characterID: UUID) {
    guard let index = characters.firstIndex(where: { $0.id == characterID }) else { return }
    var didMutate = false
    
    // Before each mutation block, set didMutate = true
    // ... existing seeding logic, wrapping each mutation with didMutate = true
    
    if didMutate { save() }
}
```

- [ ] **Step 7: Fix accessory key corruption in updateCostumeReferenceSetName**

At line ~6037, change key reconstruction:
```swift
// BEFORE:
let suffix = slot.key.split(separator: "-").last.map(String.init) ?? slot.id.uuidString.prefix(8).lowercased()

// AFTER — use stable slot ID:
let suffix = String(slot.id.uuidString.prefix(8)).lowercased()
```

- [ ] **Step 8: Build and verify**
- [ ] **Step 9: Commit**

```bash
git commit -m "fix: 11 critical AnimateStore bugs — Meshy downloads, stale indices, save/persist"
```

---

### Task 4: Fix CharacterReferenceWorkflowSheet Bugs (6.1.5-6.1.7, 6.2.6-6.2.7, 6.3.4-6.3.7)

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharacterReferenceWorkflowSheet.swift`

- [ ] **Step 1: Fix "Generate 1" missing disabled**

At line ~321, add:
```swift
.disabled(store.geminiAPIKey.isEmpty)
```

- [ ] **Step 2: Fix "Generate Missing" regenerating all when none missing**

At lines 1243-1244 and 1342-1343, change the fallback:
```swift
// BEFORE:
let targetSlots = slots.isEmpty ? character.headTurnaroundSlots : slots

// AFTER:
guard !slots.isEmpty else {
    generationStatus = "All slots already have approved variants — nothing to generate."
    return
}
let targetSlots = slots
```

Same fix for the costume version at line 1342.

- [ ] **Step 3: Remove phantom approval auto-selection**

At lines 410, 522, 749, remove the fallback:
```swift
// BEFORE:
isApproved: character.approvedMasterReferenceSheetVariantID == variant.id
    || (character.approvedMasterReferenceSheetVariantID == nil && character.masterReferenceSheetVariants.last?.id == variant.id)

// AFTER:
isApproved: character.approvedMasterReferenceSheetVariantID == variant.id
```

Same for head and costume variants.

- [ ] **Step 4: Fix try? crop errors**

At lines 486 and 704, replace:
```swift
// BEFORE:
try? store.cropApprovedHeadTurnaroundSheet(for: characterID)

// AFTER:
do {
    try store.cropApprovedHeadTurnaroundSheet(for: characterID)
} catch {
    generationError = "Crop failed: \(error.localizedDescription)"
}
```

Same for costume crop at line 704.

- [ ] **Step 5: Clear generationStatus on error**

At line ~1647, add in catch block:
```swift
} catch {
    generationError = error.localizedDescription
    generationStatus = nil  // Clear stale "Generating N of M" text
}
```

- [ ] **Step 6: Fix hardcoded /6 in head poses pill**

At line 278:
```swift
// BEFORE:
workflowPill(title: "Head Poses", value: "\(approvedHeadCount)/6", ...)

// AFTER:
workflowPill(title: "Head Poses", value: "\(approvedHeadCount)/\(character.headTurnaroundSlots.count)", ...)
```

- [ ] **Step 7: Fix ReferenceVariantCard store observation**

At line 2017 and 2123, change `let store: AnimateStore` to `@Bindable var store: AnimateStore`.

- [ ] **Step 8: Wire accessory crop callbacks**

At lines 867-912, add the missing callbacks:
```swift
onAdjustCrop: {
    store.openVariantCropTool(for: characterID, slotID: slot.id)
},
onAdjustCropVariant: { variantID in
    store.openVariantCropTool(for: characterID, slotID: slot.id, variantID: variantID)
}
```

- [ ] **Step 9: Build and verify**
- [ ] **Step 10: Commit**

```bash
git commit -m "fix: 11 CharacterReferenceWorkflowSheet bugs — disabled states, phantom approval, crop errors"
```

---

### Task 5: Fix Meshy3DGenerationPane and InspectorView Bugs

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/Meshy3DGenerationPane.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

- [ ] **Step 1: Fix encodeImages — make async**

```swift
private func encodeImages(_ images: [PoseImage]) async -> [String] {
    await withTaskGroup(of: String?.self) { group in
        for img in images {
            group.addTask {
                guard let animateURL = await self.store.animateURL else { return nil }
                let fullURL = animateURL.appendingPathComponent(img.imagePath)
                guard let data = try? Data(contentsOf: fullURL) else { return nil }
                return "data:image/png;base64,\(data.base64EncodedString())"
            }
        }
        var results: [String] = []
        for await result in group {
            if let r = result { results.append(r) }
        }
        return results
    }
}
```

Update callers to `await encodeImages(images)`.

- [ ] **Step 2: Fix batch success reporting**

Add status tracking to BatchItem:
```swift
private struct BatchItem {
    let costumeName: String
    let images: [PoseImage]
    var status: BatchItemStatus = .pending
}

private enum BatchItemStatus {
    case pending, inProgress, succeeded, failed(String)
}
```

Update `runBatchGeneration` to set status per-item and only show green "complete" if all succeeded.

- [ ] **Step 3: Fix textureImageURL — find frontNeutral explicitly**

At line 242:
```swift
let frontIndex = images.firstIndex(where: { $0.pose == .frontNeutral }) ?? 0
let textureURL = imageDataURLs.indices.contains(frontIndex) ? imageDataURLs[frontIndex] : imageDataURLs.first
```

- [ ] **Step 4: Clear stale batchQueue at start of new run**

At top of `runBatchGeneration()`:
```swift
batchQueue = []
currentBatchIndex = 0
```

- [ ] **Step 5: Fix InspectorView — remove items individually on success**

In `submitBatchQueue`, instead of clearing all at once:
```swift
// Remove items individually as each group succeeds
for item in items {
    store.removeBatchQueueItem(item.id)
}
```

- [ ] **Step 6: Build and verify**
- [ ] **Step 7: Commit**

```bash
git commit -m "fix: Meshy batch reporting, async encodeImages, InspectorView queue safety"
```

---

### Task 6: Fix Remaining CharactersPageView High/Important Bugs

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`

- [ ] **Step 1: Separate gallery selection state**

Replace shared state at lines 12-14:
```swift
@State private var inspirationSelectedPaths: Set<String> = []
@State private var inspirationLastClicked: String?
@State private var animatedSelectedPaths: Set<String> = []
@State private var animatedLastClicked: String?
```

Update each gallery section to use its own selection state.

- [ ] **Step 2: Clear selection on character switch**

Add:
```swift
.onChange(of: store.selectedCharacterID) { _, _ in
    inspirationSelectedPaths = []
    inspirationLastClicked = nil
    animatedSelectedPaths = []
    animatedLastClicked = nil
    previewImageIndex = nil
}
```

- [ ] **Step 3: Fix InspirationGallerySheet/ReferenceImagesSheet — use AsyncThumbnailView**

Replace `NSImage(contentsOf:)` calls with the `AsyncThumbnailView` pattern already used in `ImageGallerySection`.

- [ ] **Step 4: Fix double-tap detection**

Replace `TapGesture` + `NSApp.currentEvent?.clickCount` at line 2321 with:
```swift
.onTapGesture(count: 2) {
    openQuickLook(paths: paths, at: index)
}
.onTapGesture(count: 1) {
    handleGalleryClick(path: path)
}
```

- [ ] **Step 5: Fix ForEach identity — use path instead of offset**

At lines 2168, 2967, 3251, change:
```swift
// BEFORE:
ForEach(Array(paths.enumerated()), id: \.offset)

// AFTER:
ForEach(paths, id: \.self) { path in
```

- [ ] **Step 6: Disable drag reorder affordance during search**

At the character list, add `.moveDisabled(!characterSearchText.isEmpty)` to each row.

- [ ] **Step 7: Fix sanitizedFilenameStem**

```swift
private func sanitizedFilenameStem(_ input: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return input
        .components(separatedBy: allowed.inverted)
        .joined(separator: "-")
        .replacingOccurrences(of: "--", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .lowercased()
}
```

Run the replacement in a while loop for multi-dashes.

- [ ] **Step 8: Build and verify**
- [ ] **Step 9: Commit**

```bash
git commit -m "fix: gallery selection isolation, async thumbnails, tap detection, ForEach identity"
```

---

## Phase 1: Queue Separation

### Task 7: Split batchQueue into geminiQueue + meshyQueue

**Dispatch to:** MiniMax M2.7  
**Files:**
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- Create: `Packages/Animate/Sources/AnimateUI/Views/CharacterQueueControlsBar.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/Meshy3DGenerationPane.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

- [ ] **Step 1: Add typed queue structs and properties to AnimateStore**

```swift
// MARK: - Gemini Generation Queue (separate from Meshy)
struct GeminiBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var characterID: UUID?
    var characterName: String
    var characterSlug: String?
    var draftTitle: String
    var draft: GeminiGenerationDraft
    var outputRootRelativePath: String?
    var dateQueued: Date = Date()
    
    var groupingKey: String {
        if let characterID { return "character:\(characterID.uuidString)" }
        if let outputRootRelativePath,
           !outputRootRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "pipeline:\(outputRootRelativePath)"
        }
        return "pipeline:\(characterName)"
    }
}

struct MeshyBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var characterID: UUID
    var characterName: String
    var costumeName: String
    var poseImages: [(pose: CharacterReferencePose, imagePath: String)]
    var config: MeshyMultiImageRequest
    var dateQueued: Date = Date()
}

var geminiQueue: [GeminiBatchQueueItem] = []
var meshyQueue: [MeshyBatchQueueItem] = []

func addToGeminiQueue(characterID: UUID?, characterName: String, draftTitle: String, draft: GeminiGenerationDraft, characterSlug: String? = nil, outputRootRelativePath: String? = nil) {
    geminiQueue.append(GeminiBatchQueueItem(characterID: characterID, characterName: characterName, characterSlug: characterSlug, draftTitle: draftTitle, draft: draft, outputRootRelativePath: outputRootRelativePath))
}

func addToMeshyQueue(characterID: UUID, characterName: String, costumeName: String, poseImages: [(CharacterReferencePose, String)], config: MeshyMultiImageRequest) {
    meshyQueue.append(MeshyBatchQueueItem(characterID: characterID, characterName: characterName, costumeName: costumeName, poseImages: poseImages, config: config))
}

func removeGeminiQueueItem(_ id: UUID) { geminiQueue.removeAll { $0.id == id } }
func removeMeshyQueueItem(_ id: UUID) { meshyQueue.removeAll { $0.id == id } }
func clearGeminiQueue() { geminiQueue.removeAll() }
func clearMeshyQueue() { meshyQueue.removeAll() }
```

Remove old `batchQueue`, `addToBatchQueue`, `removeBatchQueueItem`, `clearBatchQueue`.

- [ ] **Step 2: Create CharacterQueueControlsBar.swift**

```swift
import SwiftUI

@available(macOS 26.0, *)
struct CharacterQueueControlsBar: View {
    @Bindable var store: AnimateStore
    @State private var showGeminiItems = false
    @State private var showMeshyItems = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Gemini queue
            queueCard(
                icon: "sparkles",
                label: "Gemini",
                count: store.geminiQueue.count,
                isExpanded: $showGeminiItems,
                onSubmit: { submitGeminiQueue() },
                onClear: { store.clearGeminiQueue() }
            )
            
            // Meshy queue
            queueCard(
                icon: "cube.fill",
                label: "Meshy 3D",
                count: store.meshyQueue.count,
                isExpanded: $showMeshyItems,
                onSubmit: { submitMeshyQueue() },
                onClear: { store.clearMeshyQueue() }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        
        // Expanded item lists
        if showGeminiItems && !store.geminiQueue.isEmpty {
            geminiItemList
        }
        if showMeshyItems && !store.meshyQueue.isEmpty {
            meshyItemList
        }
    }
    
    private func queueCard(icon: String, label: String, count: Int, isExpanded: Binding<Bool>, onSubmit: @escaping () -> Void, onClear: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button { isExpanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(label)
                        .fontWeight(.medium)
                    Text("\(count)")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(count > 0 ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            
            if count > 0 {
                HStack(spacing: 6) {
                    Button("Submit", action: onSubmit)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button("Clear", action: onClear)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    
    // ... geminiItemList, meshyItemList, submitGeminiQueue, submitMeshyQueue
    // submitGeminiQueue: move logic from InspectorView.submitBatchQueue, using store.geminiQueue
    // submitMeshyQueue: iterate store.meshyQueue, call store.generateMeshy3DModel for each
}
```

- [ ] **Step 3: Add queue bar to CharactersPageView**

In `characterDetail`, add above the ScrollView:
```swift
CharacterQueueControlsBar(store: store)
Divider()
```

- [ ] **Step 4: Update Meshy3DGenerationPane — use store.meshyQueue**

Remove `@State private var batchQueue`, `currentBatchIndex`, `isBatchGenerating`. Replace with store references.

- [ ] **Step 5: Update InspectorView — remove batch tab when on Characters page**

In the tab picker, conditionally hide the batch tab:
```swift
if currentPage != .characters {
    Picker.Option(InspectorTab.batch.rawValue)
}
```

- [ ] **Step 6: Update CharacterReferenceWorkflowSheet — route to addToGeminiQueue**

Replace all `store.addToBatchQueue(...)` calls with `store.addToGeminiQueue(...)`.

- [ ] **Step 7: Build and verify**
- [ ] **Step 8: Commit**

```bash
git commit -m "feat: separate Gemini and Meshy queues with pinned controls bar"
```

---

## Phase 2: New Services

### Task 8: MiniMax Prompt Service + Credential Store

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/MiniMaxPromptService.swift`
- Create: `Packages/Animate/Sources/AnimateUI/Services/MiniMaxCredentialStore.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

- [ ] **Step 1: Create MiniMaxCredentialStore.swift**

Follow the exact pattern from `GeminiCredentialStore.swift` — Keychain-based, service = `"com.amira.writer.animate"`, account = `"minimax-api-key"`.

- [ ] **Step 2: Create MiniMaxPromptService.swift**

```swift
import Foundation

@available(macOS 26.0, *)
final class MiniMaxPromptService: Sendable {
    let apiKey: String
    private let baseURL = "https://api.minimaxi.chat/v1/text/chatcompletion_v2"
    private let model = "MiniMax-Text-01"
    
    // Rate limiting
    private static let maxCallsPerMinute = 10
    private static var callTimestamps: [Date] = []
    private static var consecutiveFailures = 0
    private static let circuitBreakerThreshold = 5
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func generateSDPrompt(
        placeName: String,
        category: String,
        notes: String,
        sceneContext: String? = nil
    ) async throws -> String {
        // Rate limit check
        // Circuit breaker check
        // Build system prompt for SD prompt generation
        // Call MiniMax chat completion API
        // Parse response
        // Return prompt string
        
        let systemPrompt = """
        You are an expert at writing Stable Diffusion prompts. Generate a detailed, comma-separated prompt for generating a background plate image. Focus on: composition, lighting, atmosphere, materials, color palette. Do NOT include character descriptions. Output ONLY the prompt text, nothing else.
        """
        
        let userPrompt = """
        Location: \(placeName)
        Category: \(category)
        Notes: \(notes)
        \(sceneContext.map { "Scene context: \($0)" } ?? "")
        
        Generate a detailed Stable Diffusion prompt for this location as a background plate.
        """
        
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 500,
            "temperature": 0.7
        ]
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            MiniMaxPromptService.consecutiveFailures += 1
            throw MiniMaxError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        MiniMaxPromptService.consecutiveFailures = 0
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MiniMaxError.invalidResponse
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func generateFramePrompt(
        background: String,
        characters: [(name: String, position: String, expression: String)],
        cameraShot: String,
        isFirstFrame: Bool,
        motionDirection: String,
        animationStyle: String
    ) async throws -> String {
        // Similar pattern — builds a frame-description prompt
        // for first frame or last frame of a shot
        let systemPrompt = """
        You are an expert at writing image generation prompts for animation keyframes. Generate a detailed prompt describing a single frame. Include: character positions, expressions, camera angle, background, lighting, and animation style. Output ONLY the prompt, nothing else.
        """
        // ... implementation follows same HTTP pattern
        fatalError("Implement with same HTTP pattern as generateSDPrompt")
    }
    
    enum MiniMaxError: LocalizedError {
        case rateLimited
        case circuitBreakerOpen
        case requestFailed(statusCode: Int)
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .rateLimited: return "MiniMax rate limit reached. Please wait."
            case .circuitBreakerOpen: return "MiniMax service temporarily unavailable after repeated failures."
            case .requestFailed(let code): return "MiniMax request failed with status \(code)."
            case .invalidResponse: return "Invalid response from MiniMax API."
            }
        }
    }
}
```

- [ ] **Step 3: Add miniMaxAPIKey to AnimateStore**

```swift
// MARK: - MiniMax Settings
private let miniMaxCredentialStore = MiniMaxCredentialStore()
private var isHydratingMiniMaxSettings = false

var miniMaxAPIKey: String = "" {
    didSet {
        guard !isHydratingMiniMaxSettings else { return }
        miniMaxCredentialStore.saveAPIKey(miniMaxAPIKey)
    }
}
```

Add hydration in the existing `hydrateSettings` method:
```swift
isHydratingMiniMaxSettings = true
miniMaxAPIKey = miniMaxCredentialStore.loadAPIKey()
isHydratingMiniMaxSettings = false
```

- [ ] **Step 4: Build and verify**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: MiniMax M2.7 prompt service + credential store"
```

---

### Task 9: Vidu Q3 API Service

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/ViduAPIService.swift`
- Create: `Packages/Animate/Sources/AnimateUI/Services/ViduCredentialStore.swift`
- Create: `Packages/Animate/Sources/AnimateUI/Models/ShotProductionModels.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

**Context:** IMPORTANT: Before implementing, search online for "Vidu Q3 API documentation" and "Vidu API reference keyframe generation". The service struct below uses placeholder endpoints — replace with actual API URLs, auth headers, and request/response shapes from the docs. The general pattern (create task → poll → download) is correct but the exact JSON fields WILL differ.

- [ ] **Step 1: Create ShotProductionModels.swift**

```swift
import Foundation

@available(macOS 26.0, *)
struct ShotBackgroundPlate: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sourceBackgroundID: UUID
    var cameraShot: String?
    var prompt: String = ""
    var generatedImagePath: String?
    var approvedImagePath: String?
    var variants: [String] = []
}

@available(macOS 26.0, *)
struct ShotFrameGeneration: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    
    var firstFramePrompt: String = ""
    var firstFrameImagePath: String?
    var firstFrameVariants: [String] = []
    var firstFrameApproved: Bool = false
    
    var lastFramePrompt: String = ""
    var lastFrameImagePath: String?
    var lastFrameVariants: [String] = []
    var lastFrameApproved: Bool = false
    
    var motionDirection: String = ""
    var animationStyleNotes: String = ""
    
    var durationSeconds: Double = 4.0
    var aspectRatio: String = "16:9"
    
    var viduTaskID: String?
    var viduStatus: ViduTaskStatus = .idle
    var viduOutputPath: String?
}

enum ViduTaskStatus: String, Codable, Sendable {
    case idle, queued, generating, succeeded, failed
}

@available(macOS 26.0, *)
struct AnimationStylePreset: Codable, Sendable {
    var name: String = "Slightly Anime"
    var frameRateStyle: String = "variable"
    var holdFrames: Bool = true
    var impactFrames: Bool = true
    var motionBlurStyle: String = "speed lines"
    var aestheticNotes: String = ""
}

@available(macOS 26.0, *)
struct ViduBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sceneName: String
    var shotIndex: Int
    var firstFramePath: String
    var lastFramePath: String
    var motionPrompt: String
    var durationSeconds: Double
    var aspectRatio: String
    var animationStyle: AnimationStylePreset
    var dateQueued: Date = Date()
}
```

- [ ] **Step 2: Create ViduCredentialStore.swift**

Same Keychain pattern, account = `"vidu-api-key"`.

- [ ] **Step 3: Create ViduAPIService.swift**

```swift
import Foundation

@available(macOS 26.0, *)
final class ViduAPIService: Sendable {
    let apiKey: String
    private let baseURL = "https://api.vidu.com/ent/v2"  // Verify from docs
    
    private static var consecutiveFailures = 0
    private static let circuitBreakerThreshold = 5
    
    init(apiKey: String) { self.apiKey = apiKey }
    
    struct ViduTask: Codable, Sendable {
        var id: String
        var state: String          // "pending", "processing", "success", "failed"
        var progress: Int?
        var resultURL: String?
        var errorMessage: String?
    }
    
    func createKeyFrameTask(
        firstFrameImageData: Data,
        lastFrameImageData: Data,
        prompt: String,
        durationSeconds: Double,
        aspectRatio: String
    ) async throws -> ViduTask {
        // POST to create task endpoint
        // Upload images as base64 or multipart
        // Return task with ID for polling
        fatalError("Implement after verifying Vidu API docs")
    }
    
    func getTaskStatus(taskID: String) async throws -> ViduTask {
        // GET task status
        fatalError("Implement after verifying Vidu API docs")
    }
    
    func downloadResult(taskID: String, to destination: URL) async throws {
        // Download result video
        fatalError("Implement after verifying Vidu API docs")
    }
    
    func pollUntilComplete(taskID: String, progressHandler: @Sendable (Int) -> Void) async throws -> ViduTask {
        var task = try await getTaskStatus(taskID: taskID)
        while task.state == "pending" || task.state == "processing" {
            try await Task.sleep(for: .seconds(5))
            task = try await getTaskStatus(taskID: taskID)
            if let progress = task.progress {
                progressHandler(progress)
            }
        }
        guard task.state == "success" else {
            throw ViduError.taskFailed(task.errorMessage ?? "Unknown error")
        }
        return task
    }
    
    enum ViduError: LocalizedError {
        case taskFailed(String)
        case rateLimited
        case circuitBreakerOpen
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .taskFailed(let msg): return "Vidu generation failed: \(msg)"
            case .rateLimited: return "Vidu rate limit reached."
            case .circuitBreakerOpen: return "Vidu service temporarily unavailable."
            case .invalidResponse: return "Invalid response from Vidu API."
            }
        }
    }
}
```

- [ ] **Step 4: Add viduQueue and viduAPIKey to AnimateStore**

```swift
// MARK: - Vidu Settings
private let viduCredentialStore = ViduCredentialStore()
private var isHydratingViduSettings = false

var viduAPIKey: String = "" {
    didSet {
        guard !isHydratingViduSettings else { return }
        viduCredentialStore.saveAPIKey(viduAPIKey)
    }
}

var viduQueue: [ViduBatchQueueItem] = []

func addToViduQueue(_ item: ViduBatchQueueItem) { viduQueue.append(item) }
func removeViduQueueItem(_ id: UUID) { viduQueue.removeAll { $0.id == id } }
func clearViduQueue() { viduQueue.removeAll() }
```

Add to AnimationScene model:
```swift
var animationStylePreset: AnimationStylePreset?
```

Add to AnimationSceneShot model:
```swift
var shotBackgroundPlate: ShotBackgroundPlate?
var shotFrameGeneration: ShotFrameGeneration?
```

- [ ] **Step 5: Build and verify**
- [ ] **Step 6: Commit**

```bash
git commit -m "feat: Vidu Q3 API service, shot production models, credential store"
```

---

### Task 10: Smart Reference Sheet Cropping Service

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Services/ReferenceSheetCropService.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

- [ ] **Step 1: Create ReferenceSheetCropService.swift**

```swift
import AppKit
import CoreImage
import Accelerate

@available(macOS 26.0, *)
final class ReferenceSheetCropService {
    struct CropResult {
        let pose: CharacterReferencePose
        let imageData: Data
        let cropRect: CropRect
        let confidence: Double
    }
    
    enum CropKind {
        case head       // 3x2 grid, tighter crops
        case fullBody   // 3x2 grid, more vertical space
    }
    
    /// Smart crop: detect figures via connected components, assign to grid cells, crop with uniform padding.
    func cropSheet(
        image: NSImage,
        kind: CropKind,
        expectedPoses: [CharacterReferencePose] = CharacterReferencePose.allCases
    ) -> [CropResult] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let width = cgImage.width
        let height = cgImage.height
        
        // Step 1: Convert to grayscale and threshold
        let binaryMask = createBinaryMask(from: cgImage, threshold: 240)
        
        // Step 2: Find connected components (bounding boxes of figures)
        let components = findConnectedComponents(in: binaryMask, width: width, height: height)
        
        // Step 3: Filter noise — keep components larger than 2% of cell area
        let cellWidth = width / 3
        let cellHeight = height / 2
        let minArea = Int(Double(cellWidth * cellHeight) * 0.02)
        let significantComponents = components.filter { $0.area >= minArea }
        
        // Step 4: Grid-guided assignment
        let assignments = assignComponentsToGrid(
            components: significantComponents,
            gridCols: 3, gridRows: 2,
            imageWidth: width, imageHeight: height,
            poses: expectedPoses
        )
        
        // Step 5: Crop each assigned figure
        var results: [CropResult] = []
        let paddingFraction = kind == .head ? 0.08 : 0.05
        
        for (pose, component) in assignments {
            let padX = Int(Double(cellWidth) * paddingFraction)
            let padY = Int(Double(cellHeight) * paddingFraction)
            
            var cropX = max(0, component.minX - padX)
            var cropY = max(0, component.minY - padY)
            var cropW = min(width - cropX, component.width + padX * 2)
            var cropH = min(height - cropY, component.height + padY * 2)
            
            // Step 6: Mask adjacent figures — fill intruding pixels with white
            let cleanedImage = maskAdjacentFigures(
                in: cgImage,
                cropRect: CGRect(x: cropX, y: cropY, width: cropW, height: cropH),
                targetComponent: component,
                allComponents: significantComponents,
                binaryMask: binaryMask,
                imageWidth: width
            )
            
            guard let cropped = cleanedImage,
                  let pngData = pngData(from: cropped) else { continue }
            
            let normalizedRect = CropRect(
                x: Double(cropX) / Double(width),
                y: Double(cropY) / Double(height),
                width: Double(cropW) / Double(width),
                height: Double(cropH) / Double(height)
            )
            
            results.append(CropResult(
                pose: pose,
                imageData: pngData,
                cropRect: normalizedRect,
                confidence: component.confidence
            ))
        }
        
        return results
    }
    
    // MARK: - Private Helpers
    
    struct BoundingComponent {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var pixelCount: Int
        var confidence: Double = 1.0
        
        var width: Int { maxX - minX }
        var height: Int { maxY - minY }
        var area: Int { width * height }
        var centerX: Double { Double(minX + maxX) / 2.0 }
        var centerY: Double { Double(minY + maxY) / 2.0 }
    }
    
    private func createBinaryMask(from cgImage: CGImage, threshold: UInt8) -> [UInt8] {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width
        var pixelData = [UInt8](repeating: 0, count: width * height)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return pixelData }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Binary: 0 = content (dark), 1 = background (white)
        for i in 0..<pixelData.count {
            pixelData[i] = pixelData[i] >= threshold ? 1 : 0
        }
        return pixelData
    }
    
    private func findConnectedComponents(in mask: [UInt8], width: Int, height: Int) -> [BoundingComponent] {
        // Union-Find based connected component labeling on inverted mask (content pixels)
        var labels = [Int](repeating: 0, count: width * height)
        var nextLabel = 1
        var parent = [Int: Int]()
        
        func find(_ x: Int) -> Int {
            var r = x
            while let p = parent[r], p != r { r = p }
            // Path compression
            var c = x
            while let p = parent[c], p != c { parent[c] = r; c = p }
            return r
        }
        
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        
        // First pass
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard mask[idx] == 0 else { continue }  // Content pixel
                
                let above = y > 0 ? labels[(y-1) * width + x] : 0
                let left = x > 0 ? labels[y * width + (x-1)] : 0
                
                if above == 0 && left == 0 {
                    labels[idx] = nextLabel
                    parent[nextLabel] = nextLabel
                    nextLabel += 1
                } else if above != 0 && left == 0 {
                    labels[idx] = above
                } else if above == 0 && left != 0 {
                    labels[idx] = left
                } else {
                    labels[idx] = above
                    if above != left { union(above, left) }
                }
            }
        }
        
        // Second pass — resolve labels and compute bounding boxes
        var componentMap = [Int: BoundingComponent]()
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard labels[idx] > 0 else { continue }
                let root = find(labels[idx])
                labels[idx] = root
                
                if var comp = componentMap[root] {
                    comp.minX = min(comp.minX, x)
                    comp.minY = min(comp.minY, y)
                    comp.maxX = max(comp.maxX, x)
                    comp.maxY = max(comp.maxY, y)
                    comp.pixelCount += 1
                    componentMap[root] = comp
                } else {
                    componentMap[root] = BoundingComponent(
                        minX: x, minY: y, maxX: x, maxY: y, pixelCount: 1
                    )
                }
            }
        }
        
        return Array(componentMap.values)
    }
    
    private func assignComponentsToGrid(
        components: [BoundingComponent],
        gridCols: Int, gridRows: Int,
        imageWidth: Int, imageHeight: Int,
        poses: [CharacterReferencePose]
    ) -> [(CharacterReferencePose, BoundingComponent)] {
        let cellW = Double(imageWidth) / Double(gridCols)
        let cellH = Double(imageHeight) / Double(gridRows)
        
        let poseGrid: [(CharacterReferencePose, row: Int, col: Int)] = [
            (.frontNeutral, 0, 0), (.quarterLeft, 0, 1), (.quarterRight, 0, 2),
            (.back, 1, 0), (.leftProfile, 1, 1), (.rightProfile, 1, 2)
        ].filter { poses.contains($0.0) }
        
        var assignments: [(CharacterReferencePose, BoundingComponent)] = []
        var usedComponents = Set<Int>()
        
        for (pose, row, col) in poseGrid {
            let cellCenterX = (Double(col) + 0.5) * cellW
            let cellCenterY = (Double(row) + 0.5) * cellH
            
            // Find closest component by centroid distance
            var bestIndex = -1
            var bestDist = Double.greatestFiniteMagnitude
            
            for (i, comp) in components.enumerated() where !usedComponents.contains(i) {
                let dx = comp.centerX - cellCenterX
                let dy = comp.centerY - cellCenterY
                let dist = sqrt(dx*dx + dy*dy)
                if dist < bestDist {
                    bestDist = dist
                    bestIndex = i
                }
            }
            
            if bestIndex >= 0 {
                var comp = components[bestIndex]
                // Confidence based on distance from cell center
                let maxDist = sqrt(cellW*cellW + cellH*cellH) / 2
                comp.confidence = max(0, 1.0 - (bestDist / maxDist))
                assignments.append((pose, comp))
                usedComponents.insert(bestIndex)
            }
        }
        
        return assignments
    }
    
    private func maskAdjacentFigures(
        in cgImage: CGImage,
        cropRect: CGRect,
        targetComponent: BoundingComponent,
        allComponents: [BoundingComponent],
        binaryMask: [UInt8],
        imageWidth: Int
    ) -> CGImage? {
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        
        let cropW = Int(cropRect.width)
        let cropH = Int(cropRect.height)
        let cropX = Int(cropRect.minX)
        let cropY = Int(cropRect.minY)
        
        // Check if any OTHER component's pixels fall in crop region
        let otherComponents = allComponents.filter { comp in
            comp.minX != targetComponent.minX || comp.minY != targetComponent.minY
        }
        
        var hasIntrusion = false
        for comp in otherComponents {
            let overlapX = max(comp.minX, cropX) < min(comp.maxX, cropX + cropW)
            let overlapY = max(comp.minY, cropY) < min(comp.maxY, cropY + cropH)
            if overlapX && overlapY { hasIntrusion = true; break }
        }
        
        guard hasIntrusion else { return cropped }
        
        // Create mutable image and white-out intruding pixels
        guard let context = CGContext(
            data: nil,
            width: cropW, height: cropH,
            bitsPerComponent: 8, bytesPerRow: cropW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }
        
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))
        
        // White out pixels that belong to other components
        context.setFillColor(CGColor.white)
        for comp in otherComponents {
            let overlapMinX = max(comp.minX - cropX, 0)
            let overlapMinY = max(comp.minY - cropY, 0)
            let overlapMaxX = min(comp.maxX - cropX, cropW)
            let overlapMaxY = min(comp.maxY - cropY, cropH)
            if overlapMinX < overlapMaxX && overlapMinY < overlapMaxY {
                context.fill(CGRect(
                    x: overlapMinX, y: cropH - overlapMaxY,  // Flip Y for CG
                    width: overlapMaxX - overlapMinX,
                    height: overlapMaxY - overlapMinY
                ))
            }
        }
        
        return context.makeImage()
    }
    
    private func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
```

- [ ] **Step 2: Update AnimateStore — replace grid crop with smart crop**

In `cropApprovedHeadTurnaroundSheet` and `cropApprovedCostumeSheet`, replace the loop with:

```swift
let cropService = ReferenceSheetCropService()
let results = cropService.cropSheet(image: image, kind: .head)

for result in results {
    guard let slotIndex = characters[charIndex].headTurnaroundSlots.firstIndex(where: { $0.pose == result.pose }) else { continue }
    
    // Fall back to grid crop if confidence too low
    let pngData: Data
    let cropRect: CropRect
    if result.confidence < 0.3 {
        guard let gridData = cropReferenceSheetImageData(image: image, pose: result.pose, kind: .head) else { continue }
        pngData = gridData
        cropRect = normalizedCropRect(for: result.pose, kind: .head)
    } else {
        pngData = result.imageData
        cropRect = result.cropRect
    }
    
    // ... existing persist logic using pngData and cropRect
}
```

Keep the old `cropReferenceSheetImageData` and `normalizedCropRect` as private fallback methods.

- [ ] **Step 3: Build and verify**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: vision-based smart reference sheet cropping with fallback"
```

---

## Phase 3: New UI

### Task 11: Draw Things Generation Pane for Places

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/DrawThingsGenerationPane.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Services/DrawThingsPlaceGenerationService.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Models/PlacesIndexModels.swift`

- [ ] **Step 1: Add resolution presets to DrawThingsPlaceConfig**

In PlacesIndexModels.swift:
```swift
struct DrawThingsResolutionPreset: Codable, Sendable {
    let name: String
    let width: Int
    let height: Int
    
    static let presets: [DrawThingsResolutionPreset] = [
        .init(name: "1536×864 (16:9 HQ)", width: 1536, height: 864),
        .init(name: "1920×1080 (Full HD)", width: 1920, height: 1080),
        .init(name: "1024×576 (16:9 Fast)", width: 1024, height: 576),
    ]
}
```

- [ ] **Step 2: Add img2img support to DrawThingsPlaceGenerationService**

Add a method:
```swift
func generateImg2Img(
    prompt: String,
    negativePrompt: String,
    sourceImagePath: String,
    denoisingStrength: Double,
    config: DrawThingsPlaceConfig
) async throws -> Data {
    // POST to /sdapi/v1/img2img
    // Encode source image as base64
    // Return generated image data
}
```

- [ ] **Step 3: Create DrawThingsGenerationPane.swift**

Full collapsible pane with: prompt editor, negative prompt, auto-generate button (MiniMax), resolution picker, steps/CFG/seed controls, img2img section, generate buttons, results staging grid.

Follow the same SwiftUI patterns as existing panes in PlacesPageView — use `@Bindable var store`, local `@State` for form fields.

- [ ] **Step 4: Add pane to PlacesPageView detail view**

After existing sections in the place detail view, add the new collapsible pane.

- [ ] **Step 5: Build and verify**
- [ ] **Step 6: Commit**

```bash
git commit -m "feat: Draw Things generation pane on Places page with MiniMax prompts"
```

---

### Task 12: Inline 3D Model Viewer

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/Character3DModelViewer.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Views/CharactersPageView.swift`

- [ ] **Step 1: Create Character3DModelViewer.swift**

```swift
import SwiftUI
import SceneKit
import ModelIO

@available(macOS 26.0, *)
struct Character3DModelViewer: View {
    let modelURL: URL
    @State private var renderMode: RenderMode = .textured
    @State private var scene: SCNScene?
    @State private var loadError: String?
    @State private var polyCount: Int = 0
    @State private var vertexCount: Int = 0
    @State private var textureCount: Int = 0
    @State private var isFullscreen: Bool = false
    
    enum RenderMode: String, CaseIterable {
        case wireframe = "Wireframe"
        case textured = "Textured"
        case celShaded = "Cel-Shaded"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let error = loadError {
                Text("Failed to load: \(error)")
                    .font(.caption).foregroundStyle(.red)
                    .padding()
            } else if let scene {
                SceneViewWrapper(scene: scene, renderMode: renderMode)
                    .frame(minHeight: isFullscreen ? 500 : 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                HStack(spacing: 12) {
                    Picker("Mode", selection: $renderMode) {
                        ForEach(RenderMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    
                    Spacer()
                    
                    Button {
                        isFullscreen.toggle()
                    } label: {
                        Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 8)
                
                HStack(spacing: 16) {
                    Text("Polys: \(polyCount.formatted())")
                    Text("Verts: \(vertexCount.formatted())")
                    Text("Textures: \(textureCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            } else {
                ProgressView("Loading model...")
                    .frame(height: 200)
            }
        }
        .task { await loadModel() }
    }
    
    private func loadModel() async {
        do {
            let ext = modelURL.pathExtension.lowercased()
            let loadedScene: SCNScene
            
            if ext == "usdz" || ext == "scn" || ext == "dae" {
                loadedScene = try SCNScene(url: modelURL, options: [
                    .checkConsistency: true
                ])
            } else {
                // GLB, OBJ via ModelIO
                let asset = MDLAsset(url: modelURL)
                asset.loadTextures()
                loadedScene = SCNScene(mdlAsset: asset)
            }
            
            // Add lighting
            let keyLight = SCNLight()
            keyLight.type = .directional
            keyLight.intensity = 800
            keyLight.color = NSColor(white: 1.0, alpha: 1.0)
            let keyNode = SCNNode()
            keyNode.light = keyLight
            keyNode.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/4, 0)
            loadedScene.rootNode.addChildNode(keyNode)
            
            let fillLight = SCNLight()
            fillLight.type = .directional
            fillLight.intensity = 400
            fillLight.color = NSColor(calibratedRed: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
            let fillNode = SCNNode()
            fillNode.light = fillLight
            fillNode.eulerAngles = SCNVector3(-Float.pi/6, -Float.pi/3, 0)
            loadedScene.rootNode.addChildNode(fillNode)
            
            let rimLight = SCNLight()
            rimLight.type = .directional
            rimLight.intensity = 300
            let rimNode = SCNNode()
            rimNode.light = rimLight
            rimNode.eulerAngles = SCNVector3(Float.pi/8, Float.pi, 0)
            loadedScene.rootNode.addChildNode(rimNode)
            
            // Compute stats
            var polys = 0, verts = 0, textures = 0
            loadedScene.rootNode.enumerateChildNodes { node, _ in
                if let geo = node.geometry {
                    for element in geo.elements {
                        polys += element.primitiveCount
                    }
                    for source in geo.sources where source.semantic == .vertex {
                        verts += source.vectorCount
                    }
                    for mat in geo.materials {
                        if mat.diffuse.contents != nil { textures += 1 }
                        if mat.normal.contents != nil { textures += 1 }
                        if mat.roughness.contents != nil { textures += 1 }
                    }
                }
            }
            
            await MainActor.run {
                self.scene = loadedScene
                self.polyCount = polys
                self.vertexCount = verts
                self.textureCount = textures
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - NSViewRepresentable SCNView Wrapper

@available(macOS 26.0, *)
private struct SceneViewWrapper: NSViewRepresentable {
    let scene: SCNScene
    let renderMode: Character3DModelViewer.RenderMode
    
    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X
        return scnView
    }
    
    func updateNSView(_ scnView: SCNView, context: Context) {
        scnView.scene = scene
        applyRenderMode(to: scene, mode: renderMode)
    }
    
    private func applyRenderMode(to scene: SCNScene, mode: Character3DModelViewer.RenderMode) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geo = node.geometry else { return }
            for mat in geo.materials {
                switch mode {
                case .wireframe:
                    mat.fillMode = .lines
                case .textured:
                    mat.fillMode = .fill
                case .celShaded:
                    mat.fillMode = .fill
                    // Apply cel shading via SCNTechnique if available
                }
            }
        }
    }
}
```

- [ ] **Step 2: Replace view3DModel in CharactersPageView**

Replace `view3DModel(character:model:)` with inline viewer toggle. Add `@State private var viewing3DModelID: UUID?`:

```swift
// In models3DCostumeRow, replace the "View" button:
Button {
    if viewing3DModelID == model.id {
        viewing3DModelID = nil
    } else {
        viewing3DModelID = model.id
    }
} label: {
    Label(viewing3DModelID == model.id ? "Close" : "View", systemImage: viewing3DModelID == model.id ? "xmark" : "eye")
}

// Below the model info row:
if viewing3DModelID == model.id {
    let modelURL = animateURL
        .appendingPathComponent("characters")
        .appendingPathComponent(character.assetFolderSlug)
        .appendingPathComponent("models")
        .appendingPathComponent(model.modelFileName)
    Character3DModelViewer(modelURL: modelURL)
        .transition(.move(edge: .top).combined(with: .opacity))
}
```

- [ ] **Step 3: Build and verify**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: inline 3D model viewer with wireframe/textured/cel-shaded modes"
```

---

### Task 13: Shot Filmstrip View

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ShotFilmstripView.swift`

- [ ] **Step 1: Create ShotFilmstripView.swift**

Horizontal scrollable strip of shot chips. Each shows: shot index, camera type, frame approval status (✓✓, ✓·, ··). Selected shot highlighted. Click to select. Prev/Next buttons at edges.

```swift
import SwiftUI

@available(macOS 26.0, *)
struct ShotFilmstripView: View {
    @Bindable var store: AnimateStore
    let shots: [AnimationSceneShot]
    @Binding var selectedShotIndex: Int?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if let idx = selectedShotIndex, idx > 0 { selectedShotIndex = idx - 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(selectedShotIndex == nil || selectedShotIndex == 0)
                
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                                shotChip(index: index, shot: shot)
                                    .id(index)
                                    .onTapGesture { selectedShotIndex = index }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .onChange(of: selectedShotIndex) { _, newIndex in
                        if let idx = newIndex {
                            withAnimation { proxy.scrollTo(idx, anchor: .center) }
                        }
                    }
                }
                
                Button {
                    if let idx = selectedShotIndex, idx < shots.count - 1 { selectedShotIndex = idx + 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(selectedShotIndex == nil || selectedShotIndex == shots.count - 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
    
    private func shotChip(index: Int, shot: AnimationSceneShot) -> some View {
        let isSelected = selectedShotIndex == index
        let frameGen = shot.shotFrameGeneration
        let firstApproved = frameGen?.firstFrameApproved ?? false
        let lastApproved = frameGen?.lastFrameApproved ?? false
        let statusText = (firstApproved ? "✓" : "·") + (lastApproved ? "✓" : "·")
        
        return VStack(spacing: 2) {
            Text("S\(index + 1)")
                .font(.caption.weight(.bold))
            Text(shot.cameraShot?.rawValue ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(firstApproved && lastApproved ? .green : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
```

- [ ] **Step 2: Build and verify**
- [ ] **Step 3: Commit**

```bash
git commit -m "feat: shot filmstrip view with approval status indicators"
```

---

### Task 14: Shot Production Strip + Frame Cards

**Dispatch to:** MiniMax M2.7  
**Files:**
- Create: `Packages/Animate/Sources/AnimateUI/Views/ShotFrameCard.swift`
- Create: `Packages/Animate/Sources/AnimateUI/Views/ShotProductionStripView.swift`
- Modify: `Packages/Animate/Sources/AnimateUI/Animate3DWorkspace.swift`

- [ ] **Step 1: Create ShotFrameCard.swift**

Reusable card showing: image preview (or placeholder), editable prompt, Generate button, Queue checkbox, variant count.

- [ ] **Step 2: Create ShotProductionStripView.swift**

Collapsible detail strip for selected shot. Contains: scene/BG info, shot background plate, characters row, two ShotFrameCards (first/last), motion direction editor, animation style picker, duration slider, aspect ratio picker, Vidu Q3 controls.

- [ ] **Step 3: Add filmstrip + production strip to Animate3DWorkspace**

In `Animate3DWorkspace.swift`, modify the middle pane content. After the 3D preview, add:

```swift
// In workspaceBody, inside the middle OperaChromeFlatPane content:
if usesProductionPreview {
    Animate3DProductionPreviewView(...)
} else {
    Animate3DTestHarnessView(...)
}

// NEW: Shot filmstrip + production strip
if let scene = store.selectedScene, !scene.shots.isEmpty {
    Divider()
    ShotFilmstripView(
        store: store,
        shots: scene.shots,
        selectedShotIndex: $selectedShotIndex
    )
    
    if let shotIndex = selectedShotIndex,
       shotIndex < scene.shots.count {
        Divider()
        ShotProductionStripView(
            store: store,
            scene: scene,
            shot: scene.shots[shotIndex],
            shotIndex: shotIndex
        )
    }
}
```

Add `@State private var selectedShotIndex: Int?` to `Animate3DWorkspaceContent`.

- [ ] **Step 4: Build and verify**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: shot production strip with first/last frame cards, Vidu Q3 controls"
```

---

### Task 15: API Key Settings UI

**Dispatch to:** Sonnet  
**Files:**
- Modify: Settings view (find the existing Gemini/Meshy key fields and add MiniMax + Vidu alongside)

- [ ] **Step 1: Find and update settings view**

Search for where `geminiAPIKey` and `meshyAPIKey` text fields are in the settings UI. Add `miniMaxAPIKey` and `viduAPIKey` fields with the same pattern.

- [ ] **Step 2: Build and verify**
- [ ] **Step 3: Commit**

```bash
git commit -m "feat: add MiniMax and Vidu API key fields to settings"
```

---

## Phase 4: Review & Fix

### Task 16: Sonnet Code Review Pass

**Dispatch to:** Sonnet (via Agent with model: "sonnet")  
**Files:** All files created/modified in Tasks 1-15

- [ ] **Step 1: Build the full project**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme Opera -destination 'platform=macOS' build 2>&1 | tail -40
```

- [ ] **Step 2: Fix all build errors**

Iterate until clean build.

- [ ] **Step 3: Review each new file for**
- Missing `@available(macOS 26.0, *)` annotations
- Type mismatches with existing code
- Missing imports
- Incorrect method signatures (compare against AnimateStore.swift)
- UI layout issues (missing `.frame`, wrong alignment)

- [ ] **Step 4: Verify cursor-jump fix works**
- Text fields in CostumeSectionView use local @State
- DebouncedTextEditorRow properly syncs
- No Binding(get:set:) patterns remain for text editing

- [ ] **Step 5: Verify queue separation works**
- geminiQueue and meshyQueue are independent
- No references to old `batchQueue` remain
- Submit buttons route to correct queue

- [ ] **Step 6: Commit all fixes**

```bash
git commit -m "fix: Sonnet review pass — build errors, type mismatches, missing annotations"
```

---

### Task 17: Opus Final Review

**Dispatch to:** Opus (main session)  
**Files:** All files from Tasks 1-16

- [ ] **Step 1: Review architectural consistency**
- Queue separation complete and clean
- No cursor-jump patterns remain anywhere
- Smart cropping integrated with fallback
- Shot production pipeline connects properly

- [ ] **Step 2: Review for security/safety**
- API keys stored in Keychain (not UserDefaults)
- Rate limiting on all external API calls
- Circuit breakers on all services
- No force-unwraps in new code

- [ ] **Step 3: Build, deploy, and verify**

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer" && xcodebuild -scheme Opera -destination 'platform=macOS' -configuration Release build 2>&1 | tail -20
# Deploy
cp -R "build/Build/Products/Release/Opera.app" "/Volumes/Storage VIII/Programming/!Applications/"
```

- [ ] **Step 4: Final commit**

```bash
git commit -m "feat: complete Characters queue fix, Places Draw Things, animation pipeline, 3D viewer, 47 bug fixes"
```
