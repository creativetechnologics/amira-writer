# 11 — Current Code Gap Analysis

Date: 2026-03-30

## Purpose
Compare the current Animate implementation with the research-backed target architecture.

---

## 1. What already exists in the codebase

### Character package foundations
Current `CharacterPackageManifest` already supports:
- package metadata
- defaults
- a flat asset list
- per-asset role / angle / pose / placement
- generation blueprints

### Current supported asset roles
Current roles include:
- turnaround
- reference
- basePose
- expression
- viseme
- handPose
- costumeOverlay
- propOverlay
- heroPose
- backgroundPlate

### Current placement metadata
Current assets can already carry:
- normalized center
- normalized size
- normalized pivot
- z-order override
- full-canvas vs framed placement

### Current mouth / lip-sync hooks
Current Animate code already has:
- Preston Blair viseme enum
- Rhubarb wrapper
- mouth timeline track role
- lip-sync-from-audio / lip-sync-from-alignment pathways
- LLM animation plan application with generated dialogue support

### Current character workflow improvements
Current UI/data work already supports:
- master reference sheets
- head turnaround workflow
- costume reference sets
- accessory slots
- inspiration/reference image curation
- Gemini preflight preview

---

## 2. What is still missing

### Missing package structure
The manifest is still too flat.
It does not yet explicitly model:
- mouth profiles
- costume packs as first-class runtime units
- accessory packs as first-class runtime units
- motion primitives
- approval coverage metrics
- compatibility relationships

### Missing runtime separation
The code has lip-sync features, but not yet a fully separate mouth engine with:
- angle-aware mouth profiles
- singing-vs-speech timing modes
- mouth registration metadata
- fallback angle logic

### Missing motion planner contract
There is LLM plan support, but the system still needs a clearer stable contract for:
- motion primitives
- sparse anchors
- overlay requests
- routing confidence

### Missing package completeness rules
The validator checks path safety and some package basics, but it does not yet know whether a package is complete enough for:
- dialogue
- walking
- singing
- costume switching
- prop acting

### Missing production tiers
The system does not yet formally distinguish:
- hero package
- supporting package
- background package

---

## 3. Most important implementation gaps

### Gap A — mouth engine data model
Needs:
- mouth profiles
- angle families
- viseme maps
- anchor/registration points
- fallback ordering

### Gap B — motion primitive library
Needs:
- reusable locomotion and acting primitives
- timing defaults
- compatibility declarations
- primitive-to-asset requirements

### Gap C — package QA coverage
Needs:
- coverage metrics
- missing-angle detection
- missing-viseme detection
- missing-costume detection
- readiness status per package

### Gap D — shot router
Needs:
- shot complexity scoring
- internal vs AI-video route decision
- export contract for start/end frame handoff

---

## 4. Recommended order for implementation later

1. extend package schema
2. extend validator with package completeness rules
3. add mouth profile model
4. add motion primitive model
5. add package readiness scoring
6. add shot router

---

## 5. Practical takeaway

The good news is that Amira Writer is **not starting from zero**.
The current code already contains meaningful package, placement, and lip-sync foundations.

But the project still needs a stronger formal contract before it can support feature-scale semi-autonomous animation.

The biggest jump is not inventing new image generation.
It is turning the current promising parts into a cleaner, richer, more explicit animation-runtime data model.
