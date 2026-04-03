
# 05 — LLM Motion Planning and Runtime for Semi-Autonomous 2D Animation

## Bottom line

For this project, the LLM should **not** be responsible for generating every frame.
Instead, it should produce a **motion plan**: a sparse, structured description of what the character does, when it happens, where the character is in the frame, and what overlay systems need to be applied on top.

That means the downstream engine should operate in layers:

1. **Scene blocking / shot intent** — what happens in the scene.
2. **Motion primitives** — reusable actions such as idle, walk, turn, reach, react, sing, and stop.
3. **Keyframe anchors** — sparse poses and timing checkpoints.
4. **Overlay systems** — lip sync, blinks, gaze, breathing, clothing follow-through, and prop offsets.
5. **Runtime composition** — the actual 2D engine combines the above into a shot.
6. **AI video fallback** — use generative video only when the internal system cannot reasonably cover the shot.

The research below points strongly toward a keyframe-first system: generate the meaningful anchors, then interpolate/infill the gaps.

---

## 1) What the research says

### 1.1 Sparse keyframes are the right abstraction
Recent motion-generation research repeatedly converges on the same idea: **keyframes matter more than dense frame-by-frame generation**.

- **KeyMotion** generates motion by first producing keyframes, then infilling the rest.
- **PlanMoGPT** uses progressive planning: sparse global plans first, then refinement into full motion tokens.
- **Less is More: Improving Motion Diffusion Models with Sparse Keyframes** explicitly frames professional animation as a sparse-keyframe workflow and shows that keyframe-centric generation improves quality and efficiency.
- **MoMADiff** emphasizes sparse user-provided keyframes as controllable motion prompts.

**Practical takeaway:** our LLM should emit sparse, meaningful anchors and timing metadata, not a long dense list of per-frame instructions.

### 1.2 Long sequences need anchors to prevent drift
Audio- and motion-driven facial animation papers keep hitting the same failure mode: identity drift and temporal error accumulation over long sequences.

- **KeyFace** uses low-frame-rate facial keyframes plus interpolation to keep long sequences coherent.
- **KSDiff** separates speech features and predicts salient motion frames.
- **Lookahead Anchoring** treats future keyframes as directional beacons that preserve identity over time.
- **KeyframeFace** builds an interpretable text-to-facial-keyframe system around LLM-produced semantic structure.

**Practical takeaway:** the runtime should allow periodic re-anchoring. For long shots, the system should refresh the body pose, facial pose, or mouth anchor every few seconds rather than trusting a single open-ended plan.

### 1.3 Facial animation benefits from controller-level keys, not just baked video
**Audio2Rig** is especially relevant because it generates keys on rig controllers, making output easy to retake, tune, and reuse. It also notes that different facial regions can be controlled separately (lips, tongue, eyes, emotion intensity).

**Practical takeaway:** mouth, eyes, brows, head, and body should be separable tracks. The mouth engine should not be fused into the body motion engine.

### 1.4 Lip sync is a standardized mapping problem
Animation software docs from Toon Boom and Adobe show the same pattern:

- lip sync is usually driven by a **mouth chart** or **viseme set**;
- the software maps audio/phonemes to the correct mouth shapes;
- the mouth layer already contains the necessary drawings or symbols;
- the system inserts the correct exposure/viseme at the correct frame rather than drawing a whole new face from scratch.

This is exactly the right mental model for our project.

### 1.5 Traditional animation principles still matter
Adobe’s animation principle guidance and Autodesk’s timing/keyframe documentation reinforce the classic blocking approach:

- pose-to-pose blocking
- anticipation
- follow-through / overlapping action
- arcs
- easing in and out
- secondary action
- strong timing and spacing

**Practical takeaway:** even with AI assistance, the engine should prefer strong poses, controlled timing, and readable motion arcs over “continuous realism everywhere.”

---

## 2) How much of a character package do we actually need?

The answer is **more than a toy rig, but less than an entire frame-for-frame redraw system**.

For a production-grade semi-autonomous 2D show, a character package should usually contain:

### Core identity assets
- one or more identity reference images
- a master reference sheet
- approved turnarounds
- approved expression sheet
- approved mouth/viseme sheet

### Base animation assets
- idle pose(s)
- walk / run cycle anchors
- stop / settle poses
- turn poses
- reach / point / react / sit / crouch / kneel primitives

### Layerable body parts
- head
- hair front / hair back
- face / mouth / brows / eyes
- torso / chest / hips
- upper and lower arms
- hands
- upper and lower legs
- feet

### Costume and prop overlays
- uniform overlays
- civilian overlays
- scarf / coat / jacket / vest overlays
- satchel / bag / weapon / tool / medical kit props
- hand-held prop variants

### Facial systems
- expressions
- visemes
- blink variants
- gaze/look-direction variants
- optional jaw / cheek / brow sublayers

### Metadata
- angle tags
- view tags
- pose tags
- attachment points
- registration metadata
- blend priorities
- fallback rules

**Important:** the package should be organized around **reusable categories**, not around a separate asset for every possible frame. The point is to support controlled synthesis, not to pre-render the entire show.

---

## 3) Motion primitives: the reusable building blocks

The engine should treat motion as a library of **primitives**. A primitive is a reusable animation concept that can be parameterized by speed, direction, emotional intensity, and camera angle.

### Recommended primitive families

#### Locomotion
- idle breathing
- weight shift
- walk
- run
- stop / brake
- pivot turn
- look over shoulder
- start walking
- end walking

#### Acting / gesture
- reach
- point
- wave
- shrug
- nod
- shake head
- lean in
- lean back
- kneel
- sit
- stand up
- crouch

#### Reactive acting
- surprise
- recoil
- flinch
- laugh
- sigh
- blink reaction
- think / hesitate
- listen
- empathic pause

#### Singing / dialogue
- speak
- sing sustained vowel
- consonant closure
- breath intake
- emotional emphasis

### Each primitive should have:
- **entry pose**
- **exit pose**
- **timing hints**
- **world-space target(s)**
- **camera awareness**
- **overlay plan**
- **asset requirements**
- **fallback behavior**

This is important because a text instruction like “Luke walks across the frame” should not be passed straight through as a free-form sentence. It should become a structured primitive with a beginning, middle, and end.

---

## 4) Scene blocking from text: what the LLM should output

The LLM’s job should be to transform text into a **scene plan**:

1. **Extract beats**
   - opening
   - action
   - reaction
   - secondary motion
   - end state

2. **Choose motion primitives**
   - walk
   - turn
   - reach
   - speak
   - hold
   - react

3. **Assign keyframe anchors**
   - start pose
   - anticipation pose
   - action peak
   - settle pose
   - exit pose

4. **Assign overlays**
   - lip sync
   - blink
   - gaze shift
   - breathing
   - coat/hair follow-through

5. **Assign coordinates and timings**
   - normalized frame positions
   - normalized screen coordinates
   - durations in frames
   - hold lengths
   - transition curves

### Good representation style
The LLM should output something like:
- `startFrame`
- `endFrame`
- `characterId`
- `primitiveId`
- `anchorPoses`
- `screenPosition`
- `facing`
- `cameraDistance`
- `emotion`
- `overlayTracks`

### Bad representation style
The LLM should **not** emit:
- raw per-frame drawings
- unstructured prose only
- huge dense numeric streams without semantic labels

The runtime engine should do the interpolation and asset selection.

---

## 5) Heuristics for natural anime-like motion

Anime motion is not the same as photoreal motion. It typically benefits from:

- **clear silhouette**
- **strong posing**
- **controlled holds**
- **snappy transitions**
- **selective exaggeration**
- **asymmetric body offsets**
- **staggered overlap**
- **readable arcs**
- **deliberate eye and mouth timing**

### Practical heuristics

#### A. Pose-to-pose first
Block the shot with a few readable key poses before worrying about inbetweens.

#### B. Put emphasis on intent, not on continuity noise
If the beat is “he notices something,” the important part is:
- head turn starts first
- eyes lead the head
- torso follows
- clothing and hair settle last

#### C. Use holds aggressively
Anime often gets its power from a held pose followed by a quick reaction, not from constant motion.

#### D. Ease, overshoot, settle
Movement should usually:
- start with anticipation
- overshoot slightly
- settle back into a controlled finish

#### E. Separate body from face from mouth
A body turn, an eye blink, and a mouth vowel should not all be tied to the same exact timing curve.

#### F. Secondary motion should lag the primary motion
Hair, cloth, satchel straps, and loose accessories should trail the torso.

#### G. Let emotional beats drive pose selection
A sad pause, a hesitant step, and an angry reaction should each choose a different pose library even if the locomotion is similar.

### Rule of thumb
For this project, “anime-like” should mean **clean, readable, stylized, and timed with intention**, not “constantly moving.”

---

## 6) Base animation vs overlays

This should be a **layered system**.

### Base animation layer
The base engine should own:
- body position
- body orientation
- walk/turn/reach cycles
- camera/framing
- major pose changes
- prop placement
- scene blocking

### Overlay layers
Overlay systems should own:
- lip sync
- eye blinks
- gaze direction
- brow motion
- subtle breathing
- cloth/hair secondary motion
- hand/finger accents
- line/cel shading effects if needed

### Why this separation matters
If the mouth system is baked into the body engine:
- retakes become harder
- view-angle changes become harder
- lip sync becomes brittle
- AI fallback replacement becomes harder
- reuse across characters becomes weaker

The better architecture is:
- base body motion can be swapped or retimed
- overlays can be re-generated independently
- the mouth engine can be upgraded without breaking body motion

This is exactly the type of separation seen in professional tools: the lip-sync system is its own subsystem, not just a few mouth images manually pasted into the main animation.

---

## 7) Mouth movement engine: separate subsystem, same character package

This should be a **separate engine** on top of the base animation engine.

### Inputs
- transcript text
- audio waveform or source audio
- language
- speaking style
- singing vs speaking mode
- emotion / intensity
- character identity
- current head angle / facing direction
- camera distance

### Outputs
- viseme timeline
- mouth asset selection
- jaw offset values
- mouth openness/closure timing
- mouth intensities
- fallback silent-mouth states

### Why it must be orientation-aware
A front-facing mouth is not the same as a profile mouth.

The mouth engine should know:
- front
- three-quarter left
- three-quarter right
- side left
- side right
- back (usually no mouth visibility)

That means the character package should contain **angle-specific mouth atlases** or angle-aware mouth drawings, with registration metadata for each view.

### Suggested mouth behavior rules
- **Consonants**: short, sharp closures/transitions
- **Vowels**: longer sustained holds
- **Singing**: favor vowel sustain and smoother transitions, with consonants compressed
- **Emphasis**: widen or intensify the mouth shape while preserving the phoneme class
- **Back-facing shots**: no mouth or only minimal implied jaw/cheek motion if useful
- **Three-quarter shots**: reduced mouth aperture and offset registration to match perspective

### Recommended viseme strategy
Use a small but expressive mouth set rather than trying to invent dozens of shapes.
A practical set is roughly:
- rest/neutral
- wide vowel
- open vowel
- rounded vowel
- closed lips
- teeth/fricative
- narrow smile mouth
- open consonant mouth
- corner pull / side mouth
- surprised / emphasis mouth

Professional tools usually fall into one of two families:

- **Compact mouth charts** like Toon Boom Harmony’s standard A/B/C/D/E/F/G/X set.
- **Richer viseme libraries** like Adobe Character Animator’s larger mouth group, which includes silent mouths and multiple audio-driven visemes.

For this project, the safest path is a **hybrid**:
- keep a compact chart for reliability and retakes,
- but allow richer alternate shapes for singers, closeups, and emotional emphasis.

The exact count can vary, but the engine should support both **phoneme mapping** and **style-specific retargeting**.

### Singing-specific layer
Because the user specifically wants musical performance, the mouth engine should have a **singing mode** distinct from dialogue mode.

Singing mode should:
- sustain vowels longer
- reduce fast mouth churn between every consonant
- preserve musical phrasing and note length
- allow phrase-level mouth shapes rather than only syllable-level changes
- optionally blend into eyebrow and head motion for emotional phrasing

---

## 8) Proposed architecture for the runtime

### Core modules

#### A. Motion Planner
Converts text into scene beats and motion primitives.

#### B. Package Resolver
Chooses the correct character package, costume variant, and overlays.

#### C. Pose Synthesizer
Chooses the right anchor poses and transition timing.

#### D. Mouth Engine
Generates viseme tracks and angle-aware mouth placement.

#### E. Overlay Composer
Combines blinks, gaze, breathing, and secondary motion.

#### F. Render Composer
Builds the final shot from base animation + overlays + camera.

#### G. AI Video Router
Decides when to keep the shot internal vs hand off to AI video fallback.

### Routing guidance
Use the internal engine when the shot is:
- dialogue-heavy
- repetitive / reusable
- continuity-sensitive
- mostly character acting
- simple to medium motion
- editable / retakable

Use AI video when the shot is:
- extremely complex in motion or camera
- hard to fake with 2D rigs
- effect-heavy
- crowd-heavy
- visually exceptional enough to justify the cost

The best system is hybrid: **internal engine for most shots, AI video for the outliers**.

---

## 9) Proposed JSON schema for motion planning

This is a practical first-pass schema for the project.

```json
{
  "schemaVersion": 1,
  "scene": {
    "id": "scene_012",
    "title": "Luke crosses the clinic yard",
    "fps": 24,
    "frameRange": { "start": 0, "end": 192 },
    "camera": {
      "shotType": "mediumWide",
      "aspectRatio": "16:9",
      "path": [
        { "frame": 0, "x": 0.5, "y": 0.5, "zoom": 1.0 },
        { "frame": 96, "x": 0.48, "y": 0.5, "zoom": 1.05 }
      ]
    },
    "backgroundRef": "Animate/backgrounds/clinic-yard/approved.png"
  },
  "characters": [
    {
      "characterId": "uuid",
      "name": "Luke Hart",
      "packageId": "luke-hart-v1",
      "storageSlug": "luke-hart",
      "role": "lead",
      "facing": "right",
      "position": { "x": 0.18, "y": 0.82 },
      "scale": 1.0,
      "overlayPriority": ["mouth", "blink", "gaze", "breath", "cloth"]
    }
  ],
  "beats": [
    {
      "id": "beat_1",
      "startFrame": 0,
      "endFrame": 24,
      "kind": "anticipation",
      "primitiveId": "look_then_step",
      "emotion": "focused",
      "characterId": "uuid",
      "keyframes": [
        { "frame": 0, "pose": "stand", "x": 0.18, "y": 0.82, "facing": "right" },
        { "frame": 12, "pose": "lean_forward", "x": 0.18, "y": 0.82, "facing": "right" },
        { "frame": 24, "pose": "step_start", "x": 0.20, "y": 0.82, "facing": "right" }
      ],
      "overlays": {
        "blink": [{ "frame": 6, "type": "single" }],
        "breath": [{ "frame": 0, "amplitude": 0.2 }]
      }
    }
  ],
  "motionPrimitives": [
    {
      "id": "walk_cross_frame",
      "kind": "locomotion",
      "entryPose": "stand",
      "exitPose": "stand",
      "durationFrames": 72,
      "constraints": {
        "path": "leftToRight",
        "speed": "medium",
        "feet": "grounded",
        "hands": "neutral"
      },
      "overlayPlan": {
        "secondaryMotion": ["cloth", "satchel", "hair"],
        "blinkCadence": "natural",
        "mouthMode": "idle"
      }
    }
  ],
  "mouthTrack": {
    "mode": "singing",
    "language": "en",
    "sourceText": "...",
    "sourceAudio": "Audio/dialogue/scene_012.wav",
    "headAngle": "threeQuarterFrontRight",
    "mouthSet": "luke_hart_v1",
    "phonemeToViseme": {
      "AA": "open_vowel",
      "EE": "wide_vowel",
      "OO": "rounded_vowel",
      "MBP": "closed_lips"
    },
    "keyframes": [
      { "frame": 30, "viseme": "open_vowel", "confidence": 0.94 },
      { "frame": 36, "viseme": "closed_lips", "confidence": 0.88 }
    ]
  },
  "fallbackRouting": {
    "route": "internal",
    "reason": "simple dialogue and walk cycle covered by package assets"
  }
}
```

### Notes on the schema
- **`motionPrimitives`** are reusable across scenes.
- **`beats`** are scene-specific.
- **`mouthTrack`** is separate from the base body plan.
- **`overlayPlan`** keeps mouth/blink/gaze/cloth independent.
- **`fallbackRouting`** determines if a shot should remain in-house or go to AI video.

---

## 10) What the character package should store

For this project, the package manifest should probably track at least:

- character identity refs
- approved style refs
- approved master sheets
- head turnarounds
- full-body turnarounds
- expression sheet
- viseme sheet
- body-part overlays
- costume sets
- accessory sets
- hand/prop attachments
- motion primitive references
- anchor points per angle
- registration data per overlay
- fallback routing hints

A good package should answer these questions:
- What does the character look like from each angle?
- What are the reusable body/face layers?
- What mouth drawings are valid per angle?
- What costume does this shot use?
- What props or accessories are available?
- What motion primitives does the engine already know how to build?

If the package cannot answer those questions, the runtime will have to guess too much.

---

## 11) Recommended development order

1. **Motion-plan schema + compiler**
   - parse text into beats and primitives
   - emit normalized coordinates and timing

2. **Package manifest expansion**
   - add motion primitives, overlays, and angle-aware mouth sets

3. **Overlay composer**
   - blink, gaze, breath, cloth, mouth as separate layers

4. **Mouth engine**
   - transcript/audio -> visemes -> angle-aware mouth drawings

5. **Retake tooling**
   - easy edits for timing, intensity, and local corrections

6. **AI video router**
   - only for impossible or expensive shots

7. **QA / heuristic scoring**
   - silhouette readability
   - continuity
   - mouth accuracy
   - pose clarity
   - shot cost vs benefit

---

## Sources and references

### Animation principles / keyframes / blocking
- Adobe — *12 Principles of Animation*  
  https://www.adobe.com/creativecloud/animation/discover/principles-of-animation
- Autodesk Maya — *Timing and Tempo*  
  https://help.autodesk.com/cloudhelp/2024/ENU/Maya-GettingStarted/files/GUID-0EABDA1B-D59E-4002-AAEC-75862DF6372B.htm
- Autodesk Softimage — *Animating with Keys*  
  https://download.autodesk.com/global/docs/softimage2014/en_us/userguide/files/ani_keys.htm
- Autodesk Maya — *Inbetweens*  
  https://download.autodesk.com/global/docs/maya2013/en_US/files/Keyframe_Animation_Inbetweens.htm

### Lip sync / mouth charts / overlay-style facial animation
- Toon Boom Harmony — *About Lip-sync*  
  https://docs.toonboom.com/help/harmony-24/advanced/sound/about-lip-sync.html
- Toon Boom Harmony — *Animating Lip-Sync*  
  https://docs.toonboom.com/help/harmony-21/premium/cut-out-animation/animate-lip-sync.html
- Toon Boom Harmony — *Mapping the Lip-Sync Detection*  
  https://docs.toonboom.com/help/harmony-24/premium/sound/map-lip-sync-detection.html
- Adobe Character Animator — *Creating mouth shapes*  
  https://www.adobe.com/learn/adobe-character-animator/web/lip-sync-mouth-shapes
- Adobe Animate — *Auto Lip-Sync*  
  https://helpx.adobe.com/lt/adobe/animate/how-to/auto-lip-sync-sensei.html
- Audio2Rig (SIGGRAPH Talks 2024) — artist-oriented facial animation with keyframe control  
  https://arxiv.org/pdf/2405.20412.pdf

### Keyframe-first motion research
- KeyMotion — keyframes first, then in-filling  
  https://arxiv.org/abs/2405.15439
- PlanMoGPT — progressive planning for text-to-motion  
  https://arxiv.org/abs/2506.17912
- Less is More — sparse keyframes for motion diffusion  
  https://arxiv.org/abs/2503.13859
- MoMADiff — controllable text-to-motion with sparse keyframes  
  https://arxiv.org/abs/2505.11013
- KeyFace — keyframe interpolation for long audio-driven facial animation  
  https://arxiv.org/abs/2503.01715
- KeyframeFace — text-to-expressive facial keyframes with LLM priors  
  https://arxiv.org/abs/2512.11321
- Lookahead Anchoring — future keyframes to preserve identity over time  
  https://arxiv.org/abs/2510.23581
- KSDiff — keyframe-augmented speech-aware facial animation  
  https://arxiv.org/abs/2509.20128

---

## Final recommendation

Build the engine as a **planner + layers + overlays** system.

- The **planner** converts text into a sparse, labeled motion plan.
- The **base engine** performs pose blocking, locomotion, and camera motion.
- The **overlay engine** handles mouth, blinks, gaze, and secondary motion.
- The **mouth engine** is its own subsystem.
- The **AI video router** is the fallback for hard shots, not the default.

That is the most realistic way to make semi-autonomous 2D animation feel controllable, retakable, and production-friendly.
