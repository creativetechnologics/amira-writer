# Amira Writer Libretto → Scene-Local Shot Contract

> Status: quick companion only. The canonical libretto-side authority is:
> `docs/specs/2026-03-31-libretto-visual-direction-master-contract.md`

> Supersession note: for the full current libretto-side contract, use `docs/specs/2026-03-31-libretto-visual-direction-master-contract.md`. This file remains the narrower shot-focused companion.

This document is a **quick scene-shot companion reference** for any coding agent that edits or generates libretto/script content intended for the **Animate** page.

Its purpose is simple:

- let a libretto-side agent write shot directions in a format that **Animate can interpret immediately**
- keep shot timing **local to each scene**
- make those shot definitions useful later for:
  - shot seeding
  - shot editing
  - shot-aware plan generation
  - camera / motion / lipsync / lighting planning

---

## 1. Core rule: shots are scene-local, not show-global

Every shot belongs to **one scene**.

Do **not** author shots using show-global timing assumptions.

Instead:

- treat each scene as its own timing container
- define shot timing using:
  - `bars=...`
  - `beats=...`
  - or `frames=...`
- let Animate derive:
  - scene-local frame numbers
  - scene-local timecodes
  - waveform alignment

### Preferred timing hierarchy

For libretto authoring:

1. **bars / beats** when working from musical structure
2. **frames** when exact animation timing is already known
3. **minutes / seconds are display/output only**, not the primary source format for libretto directions

Animate currently interprets **bars / beats / frames** directly.  
Human-readable timecodes can be derived later inside Animate.

---

## 2. The only format Animate directly parses from libretto text

Animate parses **bracketed scene-direction markup**.

Each direction must be written like this:

```text
[tag: primary_value | key=value | key=value]
```

Examples:

```text
[scene: "Clinic Exterior" | bg=district-clinic-exterior | lighting=late-afternoon]
[camera: wide | label=Establish clinic | intent=establishing | bars=1-4]
[camera: medium_close | label=Amira first phrase | focus=amira | bars=5-8]
[pause: beats=2]
[camera: close | label=Luke reaction | focus=luke | intent=reaction | beats=33-36]
```

Plain libretto text can appear between these lines.  
Animate ignores plain lyric/dialogue text for parsing, but uses it as surrounding context.

---

## 3. What creates a shot in Animate

For shot seeding, the most important tag is:

```text
[camera: ...]
```

In practice:

- **one camera direction = one authored shot candidate**
- the libretto agent should write a new `[camera: ...]` line whenever the shot changes

Animate’s shot seeding currently uses:

- `camera`
- `pause`
- lyric alignment data
- scene-local musical timing

So if you want clean shot generation, the libretto should provide clean camera directions.

---

## 4. Required conventions for libretto-authored shots

### 4.1 Every shot must have a stable label

Always include:

```text
label=...
```

Example:

```text
[camera: medium | label=Amira verse opening | focus=amira | intent=dialogue | bars=9-12]
```

Why:

- Animate can seed readable authored shot names
- later LLM scene plans can target:
  - `shotName`
  - and eventually `shotID`

### 4.2 Shot labels must be unique inside a scene

Good:

- `label=Clinic establish`
- `label=Amira verse opening`
- `label=Luke silent reaction`

Bad:

- using `label=Closeup` three times in the same scene

### 4.3 Every shot should include timing

Use one of:

- `bars=17-20`
- `beats=65-72`
- `frames=480-575`

For single-point pauses:

- `beats=2`
- `frames=24`

### 4.4 Prefer musical timing over guessed wall-clock timing

Because this is an opera and music is always running:

- shots should usually be described against the music
- bars / beats are the best libretto-side source of truth

### 4.5 Use scene-local character references

When possible, use character slugs/names already known to the project:

```text
focus=amira
focus=luke
```

Do not invent alternate names for the same character.

---

## 5. Supported direction tags

These tags are part of the current bracket DSL:

- `scene`
- `enter`
- `exit`
- `move`
- `emotion`
- `action`
- `gesture`
- `camera`
- `lipsync`
- `pause`
- `sfx`
- `transition`

For shot building, the most important are:

- `scene`
- `camera`
- `pause`
- `move`
- `emotion`
- `action`
- `lipsync`

---

## 6. Camera shot contract

### 6.1 Allowed camera shot values

Use these raw values:

- `extreme_wide`
- `wide`
- `medium`
- `medium_close`
- `close`
- `extreme_close`

Example:

```text
[camera: medium_close | label=Amira verse opening | focus=amira | intent=dialogue | bars=9-12]
```

### 6.2 Recommended camera parameters

Supported / preferred keys:

- `label`
- `focus`
- `intent`
- `bars`
- `beats`
- `frames`
- `from`
- `to`
- `shot`
- `easing`

### 6.3 Recommended shot intents

Use readable, normalized intent terms already aligned with Animate’s camera intent system:

- `establishing`
- `reveal`
- `reaction`
- `dialogue`
- `movement`
- `confrontation`
- `insert`
- `transition`
- `emotional`

Example:

```text
[camera: close | label=Luke sees Amira | focus=luke | intent=reaction | bars=21-24]
```

---

## 7. Scene tag contract

Use a scene tag near the start of the scene when possible:

```text
[scene: "Clinic Exterior" | bg=district-clinic-exterior | lighting=late-afternoon]
```

Preferred keys:

- `bg`
- `background`
- `lighting`

This gives Animate stronger context for:

- place resolution
- lighting packet generation
- execution planning

---

## 8. How to think about pauses

Use `[pause: ...]` when the scene holds without a shot change or when you need to advance the seeding cursor.

Examples:

```text
[pause: beats=2]
[pause: bars=1]
[pause: frames=18]
```

This is especially useful for:

- breaths
- sustained holds
- orchestral transitions
- emotional stillness between vocal phrases

---

## 9. How to write context-aware shots

The libretto agent should not blindly emit one shot per line of lyrics.

It should read:

1. the lyrics
2. the dramatic action
3. existing stage directions
4. the current cast in the scene
5. the musical phrasing

Then it should build shots that are:

- readable
- sparse
- motivated
- musically aligned

### Best-practice rules

- prefer **fewer, stronger shots**
- avoid needless shot churn
- let musical phrases define shot boundaries where possible
- use reaction shots only when dramatically justified
- use close shots for emotional emphasis, not by default
- if two characters are singing to each other, structure shots around:
  - establish
  - singer focus
  - reaction
  - duet/shared frame

---

## 10. Recommended authoring workflow for the libretto agent

For each scene:

1. identify the scene’s place / setting
2. identify the cast active in the scene
3. identify the musical sections / phrase changes
4. identify major dramatic beats
5. write:
   - one `[scene: ...]` block near the start
   - `[camera: ...]` lines for each shot
   - optional `[pause: ...]` lines where musical holds or transitions need them
   - other direction tags as needed

### Minimal acceptable output

A scene is shot-readable if it has:

- a scene tag
- labeled camera directions
- scene-local timing on each shot

---

## 11. Example: good scene-local shot formatting

```text
[scene: "District Clinic Exterior" | bg=district-clinic-exterior | lighting=late-afternoon dust]

The clinic courtyard is crowded and tense.

[camera: wide | label=Clinic establish | intent=establishing | bars=1-4]
Chorus and townspeople fill the courtyard.

[camera: medium_close | label=Amira verse opening | focus=amira | intent=dialogue | bars=5-8]
AMIRA:
If mercy still lives in this place—

[camera: close | label=Luke first reaction | focus=luke | intent=reaction | bars=9-10]

[camera: medium | label=Two-shot tension | focus=amira | intent=confrontation | bars=11-14]
LUKE:
I came to help, not to command.

[pause: beats=2]

[camera: close | label=Amira resolve | focus=amira | intent=emotional | bars=15-18]
AMIRA:
Then stand and hear what fear has made of us.
```

This is good because it is:

- scene-local
- musically timed
- label-stable
- character-aware
- directly useful for Animate shot seeding

---

## 12. Example: bad formatting

```text
[camera: close]
[camera: close]
[camera: medium]
```

Why it is bad:

- no labels
- no timing
- no focus
- no intent
- no dramatic context

Another bad example:

```text
[camera: close | label=Reaction | timecode=00:14.52-00:18.01]
```

Why it is bad:

- Animate does **not** currently treat wall-clock timecode as the authoritative parse format
- use `bars`, `beats`, or `frames` instead

---

## 13. What Animate expects downstream from these libretto shots

After the shots exist, external animation-plan JSON can target them using:

- `shotName`
- `shotID`
- `frameOffset`
- `startFrameOffset`
- `endFrameOffset`

Example downstream JSON:

```json
{
  "sceneName": "District Clinic Exterior",
  "characterPlacements": [
    {
      "characterName": "Amira Nazari",
      "shotName": "Amira verse opening",
      "frameOffset": 0,
      "position": { "x": 0.42, "y": 0.68 }
    }
  ],
  "cameraMoves": [
    {
      "shotName": "Two-shot tension",
      "startFrameOffset": 0,
      "endFrameOffset": 24,
      "movement": "hold"
    }
  ]
}
```

That means the libretto agent’s job is to create a **stable shot grammar** that later planning agents can target.

---

## 14. Non-negotiable rules for the libretto coding agent

1. **Do not use show-global timing**
2. **Do not rely on wall-clock timecodes as the authoritative authored format**
3. **Always label shots**
4. **Always give shot timing**
5. **Prefer bars/beats when musically available**
6. **Keep labels unique inside a scene**
7. **Use project-known character names/slugs**
8. **Write camera directions sparsely and intentionally**
9. **Assume Animate will seed authored shots from these lines**
10. **Assume later LLM animation plans will anchor to these shot labels**

---

## 15. Short instruction block you can paste to another coding agent

Use this if you want a compact handoff:

```text
You are editing libretto text for Amira Writer’s Animate engine.

Write scene-local bracketed direction markup in this exact style:
[tag: primary_value | key=value | key=value]

For shot creation, use [camera: ...] lines.
Every shot must include:
- label=unique_scene_local_shot_name
- bars=... or beats=... or frames=...
- focus=... when relevant
- intent=... when relevant

Use these camera values only:
extreme_wide, wide, medium, medium_close, close, extreme_close

Use scene-local timing only. Do NOT use show-global timing.
Prefer bars/beats as the source format; Animate derives frames/timecodes later.

Add a [scene: ...] line near the start when possible:
[scene: "Scene Name" | bg=place-slug | lighting=short-lighting-phrase]

Use [pause: ...] when musical holds or transitions need timing without a new shot.

Write shots contextually from the lyrics, dramatic beats, stage action, and musical structure.
Prefer fewer, stronger shots over excessive cutting.

The output must be immediately interpretable by Animate’s bracket-direction parser and usable for scene shot seeding.
```

---

## 16. Where this connects in the codebase

Relevant Animate seams:

- `Packages/Animate/Sources/AnimateUI/Services/SceneDirectionParser.swift`
- `Packages/Animate/Sources/AnimateUI/Models/SceneDirectionModels.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneShotSeedingService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateShotSegmentationService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimatePlanShotAnchorResolver.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneOrchestrationService.swift`

This document should be treated as the libretto-side contract for authored shots until superseded by a newer spec.
