# LORA Gemini Asset Generation Workflow
## Amira Writer - NanoBanana Pro Integration

**Document Version:** 1.0  
**Created:** March 22, 2026  
**Purpose:** Specification for implementing automated character asset generation using NanoBanana Pro

---

## Overview

This document describes the workflow for generating high-quality character assets using NanoBanana Pro (formerly referred to as "Gemini Pro" in early iterations). This workflow was successfully tested on March 20, 2026, generating 28 variant poses of the character "Luke" for the opera "Amira - A Modern Opera."

### Key Specifications
- **Model:** NanoBanana Pro (NOT NanoBanana Flash)
- **Aspect Ratio:** 2:19 (vertical/portrait orientation)
- **Quality:** 4K resolution
- **Batch Size:** 28 unique poses per generation run
- **Source:** Single reference image + style prompt from Amira opera context

---

## The March 20, 2026 Reference Workflow

### What Was Generated
On March 20, 2026, we generated a batch of 28 high-quality character images for Luke using the following process:

1. **Source Material:**
   - Primary reference image: `luke-reference-main.png`
   - Style direction: "Approved Amira painterly 2D feature style"
   - Character identity preservation: Qwen-based identity preservation workflow

2. **Prompt Structure:**
   - Base prompt: "Luke as a painterly 2D animated feature character, [pose description], readable silhouette, natural mountain valley background, soft overcast daylight, preserve Luke likeness, clean costume edges, grounded film-art direction."
   - Negative prompt: "cartoon exaggeration, distorted anatomy, extra fingers, glossy 3D, noisy painterly texture, text watermark"
   - All 28 variations used this base with pose-specific modifications

3. **Generated Assets:**
   - 28 unique poses (variants v1-v28 + main anchor)
   - Located in: `Character Builder (Gemini)/luke/outputs/`
   - File naming: `luke-soldier-YYYYMMDD-HHMMSS-v##.png`
   - Average file size: 1.2-1.8MB per image
   - Total batch: ~45MB

### The 28 Pose Categories
The batch included variations of:
- Frontal base poses
- Three-quarter views (left/right)
- Profile views
- Walking/action poses
- Emotional states (determined, grieving, hopeful, etc.)
- Hand/arm positions
- Head angles
- Full-body and medium shots

---

## UI/UX Specification for Amira Writer

### Section Location
**Navigation:** Characters → [Select Character] → "Generate Assets" tab

### Interface Components

#### 1. Source Image Upload Area
```
┌─────────────────────────────────────────┐
│  📤 DROP REFERENCE IMAGE HERE           │
│                                         │
│  Or click to select file                │
│                                         │
│  [Preview thumbnail appears here]       │
└─────────────────────────────────────────┘
```

**Requirements:**
- Drag-and-drop support
- File picker fallback
- Accepts: PNG, JPG, JPEG
- Max file size: 10MB
- Preview thumbnail generation (200x200px)

#### 2. Pre-filled Prompt Text Box
```
┌─────────────────────────────────────────┐
│ Character Style Prompt                  │
│ ┌─────────────────────────────────────┐ │
│ │Luke as a painterly 2D animated      │ │
│ │feature character, [POSE_NAME],       │ │
│ │readable silhouette, natural mountain │ │
│ │valley background, soft overcast      │ │
│ │daylight, preserve Luke likeness,     │ │
│ │clean costume edges, grounded         │ │
│ │film-art direction.                   │ │
│ └─────────────────────────────────────┘ │
│ [✏️ Edit] [🔄 Reset to Default]         │
└─────────────────────────────────────────┘
```

**Requirements:**
- Pulls default prompt from Amira opera metadata
- Auto-fills character name from selected character
- Text area: 5 rows, expandable
- Placeholder `[POSE_NAME]` gets replaced per-pose during generation
- Edit button allows customization
- Reset button restores default from Amira context

#### 3. Generation Settings Panel
```
┌─────────────────────────────────────────┐
│ Generation Settings                     │
│                                         │
│ Model:        NanoBanana Pro ▼          │
│ Aspect Ratio: 2:19 (Portrait) ▼         │
│ Quality:      4K ▼                      │
│                                         │
│ Batch Name:   [Luke Batch March 20  ]   │
│                                         │
│ [ ] Use negative prompt (recommended)   │
└─────────────────────────────────────────┘
```

**Fixed Settings (Non-Configurable by User):**
- Model: Always NanoBanana Pro
- Aspect Ratio: Always 2:19
- Quality: Always 4K
- Mode: Always Batch (never single)

**User-Configurable:**
- Batch name (auto-generated with timestamp, editable)
- Negative prompt toggle (on by default)

#### 4. The Big Red Button
```
┌─────────────────────────────────────────┐
│                                         │
│     [ 🚀 GENERATE ASSETS ]              │
│                                         │
│     28 poses • ~15 minutes • 4K         │
│                                         │
└─────────────────────────────────────────┘
```

**Button States:**
1. **Ready:** "Generate Assets" - Blue, enabled
2. **Generating:** "Generating... (3/28)" - Animated, disabled
3. **Complete:** "Generation Complete ✓" - Green, enabled
4. **Error:** "Retry Failed Poses (2 errors)" - Red, enabled

---

## The 28 Poses List Interface

### Real-Time Progress Tracking
```
┌─────────────────────────────────────────┐
│ Batch Progress: 12 of 28 complete       │
│ ████████░░░░░░░░░░░░░░░░ 43%           │
│                                         │
│ Current: Generating "Walking Left"...   │
│ ETA: ~8 minutes remaining               │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ Generated Poses                         │
├─────────────────────────────────────────┤
│ ✅ Frontal Base         [👁️] [🔄]      │
│ ✅ Three-Quarter Left   [👁️] [🔄]      │
│ ✅ Three-Quarter Right  [👁️] [🔄]      │
│ ✅ Profile Left         [👁️] [🔄]      │
│ ⏳ Walking Left         [···]          │
│ ⏳ Walking Right        [···]          │
│ ⏳ Action Pose          [···]          │
│ ... (20 more)                           │
└─────────────────────────────────────────┘
```

### Pose List Features

Each pose row contains:
1. **Status Icon:**
   - ⏳ Pending (gray)
   - 🔄 Generating (animated)
   - ✅ Complete (green)
   - ❌ Failed (red)
   - 👁️ Preview available

2. **Pose Name:** Descriptive name (e.g., "Frontal Base", "Walking Left", "Determined Close-up")

3. **Thumbnail:** 80x80px preview (once generated)

4. **Actions:**
   - 👁️ **View** - Open full-size preview
   - 🔄 **Regenerate** - Re-run just this pose
   - 🗑️ **Delete** - Remove from batch
   - ⬇️ **Download** - Save individual image

### Default 28 Poses Configuration
```json
{
  "poses": [
    {"id": "frontal-base", "name": "Frontal Base", "prompt": "front-facing, neutral expression"},
    {"id": "three-quarter-left", "name": "Three-Quarter Left", "prompt": "three-quarter view facing left"},
    {"id": "three-quarter-right", "name": "Three-Quarter Right", "prompt": "three-quarter view facing right"},
    {"id": "profile-left", "name": "Profile Left", "prompt": "side profile facing left"},
    {"id": "profile-right", "name": "Profile Right", "prompt": "side profile facing right"},
    {"id": "walking-left", "name": "Walking Left", "prompt": "walking stride, facing left"},
    {"id": "walking-right", "name": "Walking Right", "prompt": "walking stride, facing right"},
    {"id": "action-stance", "name": "Action Stance", "prompt": "dynamic action pose, mid-movement"},
    {"id": "pointing", "name": "Pointing", "prompt": "pointing gesture, directing attention"},
    {"id": "arms-crossed", "name": "Arms Crossed", "prompt": "arms crossed, confident stance"},
    {"id": "hand-on-hip", "name": "Hand on Hip", "prompt": "hand on hip, assertive posture"},
    {"id": "grieving", "name": "Grieving", "prompt": "grieving expression, solemn mood"},
    {"id": "determined", "name": "Determined", "prompt": "determined expression, resolute"},
    {"id": "hopeful", "name": "Hopeful", "prompt": "hopeful expression, looking upward"},
    {"id": "concerned", "name": "Concerned", "prompt": "concerned expression, worried"},
    {"id": "confident", "name": "Confident", "prompt": "confident smile, relaxed posture"},
    {"id": "close-up-neutral", "name": "Close-Up Neutral", "prompt": "close-up portrait, neutral expression"},
    {"id": "close-up-emotional", "name": "Close-Up Emotional", "prompt": "close-up portrait, emotional intensity"},
    {"id": "medium-shot", "name": "Medium Shot", "prompt": "medium shot, waist up"},
    {"id": "full-body", "name": "Full Body", "prompt": "full body standing pose"},
    {"id": "sitting", "name": "Sitting", "prompt": "seated pose, relaxed"},
    {"id": "kneeling", "name": "Kneeling", "prompt": "kneeling pose, respectful"},
    {"id": "reaching-out", "name": "Reaching Out", "prompt": "arm extended, reaching toward viewer"},
    {"id": "looking-back", "name": "Looking Back", "prompt": "looking back over shoulder"},
    {"id": "head-bowed", "name": "Head Bowed", "prompt": "head bowed, humble posture"},
    {"id": "looking-up", "name": "Looking Up", "prompt": "looking upward, aspirational"},
    {"id": "turning", "name": "Turning", "prompt": "mid-turn, dynamic movement"},
    {"id": "at-ease", "name": "At Ease", "prompt": "relaxed at-ease military stance"}
  ]
}
```

**Note:** These can be customized per-character or per-project.

---

## Background Watcher System

### Architecture
The watcher runs as a background service within Amira Writer:

```
┌─────────────────────────────────────────┐
│         Amira Writer Main App          │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │   Gemini Batch Watcher Service  │   │
│  │                                 │   │
│  │  • Monitors generation queue    │   │
│  │  • Polls NanoBanana Pro API     │   │
│  │  • Downloads completed images   │   │
│  │  • Updates UI in real-time      │   │
│  │  • Handles errors & retries     │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │     App Lifecycle Monitor       │   │
│  │                                 │   │
│  │  • Prevents accidental close    │   │
│  │  • Shows warning dialog         │   │
│  │  • Allows force-quit option     │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Watcher Behavior

1. **Queue Management:**
   - Maintains queue of 28 generation requests
   - Sends requests to NanoBanana Pro API with rate limiting
   - Tracks request IDs for each pose

2. **Polling Strategy:**
   - Polls every 30 seconds for status updates
   - Exponential backoff on API rate limits
   - Timeout: 5 minutes per pose (with retry)

3. **File Management:**
   - Downloads to: `Animate/characters/{slug}/generated/{batch-name}/`
   - Naming: `{character}-{pose-id}-{timestamp}.png`
   - Organizes by batch for easy management

4. **Error Handling:**
   - Auto-retry: 3 attempts per failed pose
   - Manual retry button in UI for persistent failures
   - Error log with full API responses

---

## Application Exit Protection

### Warning Dialog
When user attempts to close Amira Writer while a batch is running:

```
┌─────────────────────────────────────────┐
│  ⚠️ Active Generation in Progress       │
│                                         │
│  You have 16 of 28 poses still          │
│  generating for "Luke Batch March 20".  │
│                                         │
│  If you quit now:                       │
│  • 12 completed poses will be saved     │
│  • 16 pending poses will be cancelled   │
│  • Progress will be lost                │
│                                         │
│  [ Continue Generating ]  [ Quit Now ]  │
│                                         │
│  ☐ Don't ask again for this batch       │
└─────────────────────────────────────────┘
```

### Exit States

**1. Batch Running:**
- Show warning dialog
- Block quit until user confirms
- Offer "Continue in Background" option (if supported by OS)

**2. Batch Complete (Unreviewed):**
- No warning needed
- Allow normal quit
- Save state automatically

**3. Batch Paused/Failed:**
- Show summary dialog
- Offer to resume or quit

---

## Technical Implementation Notes

### API Integration

**NanoBanana Pro Endpoint:**
```
POST /v1/generate/batch
Content-Type: application/json
Authorization: Bearer {API_KEY}

{
  "model": "nanobanana-pro-4k",
  "aspect_ratio": "2:19",
  "reference_image": "base64_encoded_image",
  "prompts": [
    {
      "id": "frontal-base",
      "prompt": "Luke as a painterly 2D... frontal base...",
      "negative_prompt": "cartoon exaggeration..."
    },
    // ... 27 more poses
  ],
  "batch_id": "luke-march20-202603221430",
  "callback_url": "http://localhost:8765/gemini-webhook"
}
```

**Response:**
```json
{
  "batch_id": "luke-march20-202603221430",
  "status": "queued",
  "estimated_time": "900",
  "request_ids": [
    "req-001",
    "req-002",
    // ...
  ]
}
```

### Local Storage Schema

**Batch State:**
```json
{
  "batch_id": "luke-march20-202603221430",
  "character_slug": "luke",
  "character_id": "char-uuid",
  "status": "generating",
  "model": "nanobanana-pro-4k",
  "aspect_ratio": "2:19",
  "created_at": "2026-03-22T14:30:00Z",
  "completed_at": null,
  "progress": {
    "total": 28,
    "completed": 12,
    "failed": 0,
    "pending": 16
  },
  "poses": [
    {
      "id": "frontal-base",
      "name": "Frontal Base",
      "status": "completed",
      "request_id": "req-001",
      "file_path": "Animate/characters/luke/generated/luke-march20/frontal-base.png",
      "file_size": 1543200,
      "generated_at": "2026-03-22T14:32:15Z",
      "retry_count": 0
    },
    // ... more poses
  ],
  "settings": {
    "base_prompt": "Luke as a painterly 2D...",
    "negative_prompt": "cartoon exaggeration...",
    "reference_image_path": "Characters/luke/reference.png"
  }
}
```

### File System Structure

After generation completes:
```
Amira.owp/
├── Animate/
│   └── characters/
│       └── luke/
│           └── generated/
│               └── luke-march20-202603221430/
│                   ├── frontal-base.png
│                   ├── three-quarter-left.png
│                   ├── ... (26 more)
│                   └── batch-manifest.json
```

---

## Integration with Character Packages

### Post-Generation Workflow

1. **Review:** User reviews all 28 generated images
2. **Select:** User selects best variants (can be all 28 or subset)
3. **Import to Package:** 
   - Creates new Character Package
   - Or adds to existing package
   - Auto-tags with pose names
   - Sets appropriate asset roles

4. **Sync to Rig:**
   - Optional: Auto-sync to character rig
   - Creates drawing set variants
   - Sets up for animation

---

## UI Mockup Reference

### Full Interface Layout
```
┌──────────────────────────────────────────────────────────────┐
│ Amira Writer - Characters > Luke > Generate Assets          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────┐  ┌───────────────────────────────────┐  │
│  │ 📤 Drop Image   │  │ Character Style Prompt            │  │
│  │                 │  │ ┌───────────────────────────────┐ │  │
│  │ [Thumbnail]     │  │ │Luke as a painterly 2D...      │ │  │
│  │                 │  │ │[POSE_NAME] placeholder...     │ │  │
│  └─────────────────┘  │ └───────────────────────────────┘ │  │
│                       │ [✏️ Edit] [🔄 Reset]              │  │
│                       └───────────────────────────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Generation Settings                                     │ │
│  │ Model: NanoBanana Pro • Aspect: 2:19 • Quality: 4K    │ │
│  │ Batch Name: [Luke Batch March 22              ]       │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│              [ 🚀 GENERATE 28 ASSETS ]                       │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ Batch Progress: 12 of 28 complete (43%)                      │
│ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░                        │
│ Current: "Walking Left" • ETA: 8 minutes                     │
├──────────────────────────────────────────────────────────────┤
│ Generated Poses                                              │
│ ┌────────┬──────────────────────┬────────┬────────┐        │
│ │ Status │ Pose Name            │ Thumb  │ Action │        │
│ ├────────┼──────────────────────┼────────┼────────┤        │
│ │   ✅   │ Frontal Base         │ [img]  │👁️🔄🗑️ │        │
│ │   ✅   │ Three-Quarter Left   │ [img]  │👁️🔄🗑️ │        │
│ │   ✅   │ Three-Quarter Right  │ [img]  │👁️🔄🗑️ │        │
│ │   🔄   │ Walking Left         │ [···]  │   ⏸️   │        │
│ │   ⏳   │ Walking Right        │        │        │        │
│ │   ⏳   │ Action Pose          │        │        │        │
│ │  ...   │ ...                  │        │        │        │
│ └────────┴──────────────────────┴────────┴────────┘        │
│                                                              │
│  [📦 Create Package from Selected]  [🔄 Retry Failed]       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Success Metrics

From the March 20, 2026 test:
- **Total Time:** ~12 minutes for 28 poses
- **Success Rate:** 100% (28/28 generated successfully)
- **Average Time per Pose:** ~26 seconds
- **Quality:** All images met production standards
- **User Intervention:** Minimal (one-click start)

---

## Future Enhancements (v2.0+)

1. **Style Transfer:** Apply generated style to existing sketches
2. **Expression Variations:** Generate same pose with different emotions
3. **Costume Variations:** Keep pose, change outfit
4. **Background Options:** Transparent, scenic, or custom
5. **Batch Templates:** Save/load pose configurations
6. **Collaborative Review:** Share batches with team for voting
7. **Auto-Rig Suggestions:** AI-powered rigging recommendations

---

## API Keys & Authentication

**Note:** Store API keys securely in macOS Keychain, never in code:
- Keychain item: `com.novotro.nanobanana.apikey`
- Fallback: Environment variable `NANOBANANA_API_KEY`
- Prompt user if not configured

---

## Error Handling & Edge Cases

1. **API Rate Limit:** Queue requests, show progress
2. **Network Failure:** Auto-retry with exponential backoff
3. **Invalid Reference Image:** Validate before sending (min 512px)
4. **NSFW Filter:** Handle rejected prompts gracefully
5. **Out of Credits:** Show warning, pause generation
6. **Duplicate Batch Names:** Auto-append timestamp

---

## Testing Checklist

- [ ] Upload reference image works (drag & click)
- [ ] Prompt pre-fills correctly from Amira context
- [ ] Edit prompt and reset works
- [ ] Generate button starts batch
- [ ] Progress updates in real-time
- [ ] All 28 poses generate successfully
- [ ] Thumbnails display correctly
- [ ] View full-size works
- [ ] Regenerate single pose works
- [ ] Exit warning shows during generation
- [ ] Force quit handles gracefully
- [ ] Batch saves correctly on disk
- [ ] Create package from batch works
- [ ] Error states handled properly

---

## Resources

**Reference Implementation:**
- March 20, 2026 batch files: `Character Builder (Gemini)/luke/outputs/`
- Sample package: `LukeGeminiBatchMarch20/` (in Amira project)

**Documentation:**
- NanoBanana Pro API docs: [Link TBD]
- Character Package format: `Amira Writer/Packages/NovotroAnimate/SampleData/CharacterPackages/`

**Contacts:**
- Gary (Product Owner)
- Claude Code (Implementation Support)

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-22 | Claude | Initial specification based on March 20 workflow |

---

**END OF DOCUMENT**

*This document serves as the complete specification for implementing the LORA Gemini Asset Generation feature in Amira Writer. All features described herein should be implemented as specified to maintain consistency with the March 20, 2026 reference workflow.*
