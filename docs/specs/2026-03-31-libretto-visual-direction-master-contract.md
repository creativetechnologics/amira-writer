# Amira Writer Libretto → Animate Master Visual Direction Contract

This is the **canonical libretto-side authoring contract** for any LLM or human author writing scene direction for **Animate**.

It is designed so a libretto-writing agent can work **scene by scene** and make real creative decisions as:
- a **director**
- a **cinematographer**
- a **blocking supervisor**
- a **prop / object staging planner**
- a **music-aware shot planner**

It is also designed so Animate can use the result **immediately** for:
- scene-local shot seeding
- scene-local timeline timing
- camera/shot anchoring
- object/prop runtime playback
- plan conversion into Animate JSON
- review / execution / viseme workflows

> Canonical rule: the **bracketed libretto DSL** is the primary authoring format.
> The JSON scene-plan schema is the downstream execution format.
> This file is the only canonical libretto-side authority. The scene-shot contract file is now only a quick companion/reference.

---

## 1. Contract status and integration target

This contract is written against the **current real Animate runtime**.

It now aligns with real Animate support for:
- scene-local shots
- shot names and shot IDs
- shot-aware plan anchoring
- character blocking
- camera shots and camera movement
- object / prop placement, motion, state, visibility, attachment
- scene-local audio timeline alignment
- downstream dialogue beat / viseme workflows
- downstream lighting packet generation

This means a libretto-author LLM can now write direction in a way that Animate can immediately use for:
- shot creation
- scene timing
- planning
- runtime playback preparation
- downstream execution review

---

## 2. What the libretto-writing LLM is responsible for

The libretto-writing LLM must:

1. work **scene by scene**
2. preserve lyrics / dialogue / dramatic meaning
3. add structured visual direction using the bracket DSL
4. create or refine a **scene-local shot list**
5. align shot timing to music using **bars / beats / frames**
6. direct:
   - camera
   - character blocking
   - object / prop presence
   - object interaction
   - pause / hold timing
   - lipsync markers
   - lighting phrases
7. make tasteful creative choices like a film/opera director, not like a random stage-note generator

The LLM must **not**:
- use show-global timestamps
- invent unsupported tags casually
- hide important visual logic in prose
- rely on vague references like “the bag,” “the soldier,” or “closeup again”
- rewrite the scene into a completely different dramatic event
- paraphrase or condense the libretto text unless fixing an obvious typo
- reorder, merge, or split scenes unless explicitly instructed by the operator

---

## 3. Hard rules

### 3.1 Scene-local timing only
All timing is local to the **current scene only**.

Use:
- `bars=...`
- `beats=...`
- `frames=...`

Do **not** use:
- show-global timecode
- total-show offsets
- references like “2 minutes after the previous scene”

### 3.2 One meaningful bracket block per instruction
Canonical syntax:

```text
[tag: primary_value | key=value | key=value]
```

Write one meaningful direction block per instruction.

### 3.3 Stable names always
Use stable names for:
- characters
- shots
- objects
- backgrounds / places
- recurring props

### 3.4 Music is the master timing source
Because this is an opera, there is always music.

Preferred timing order:
1. `bars`
2. `beats`
3. `frames`
4. timecode only as derived display metadata, never as primary authorship

### 3.5 Every meaningful shot needs a label
Every authored shot must include:
- `label=...`

Labels must be unique **inside the scene**.

### 3.6 Structured direction beats prose
If something matters visually, express it structurally.

Examples:
- camera choice → `camera`
- character move → `move`
- prop transfer → `object_move` / `object_state`
- hold → `pause`

Critical:
- do not convert important staging into loose narrative prose
- use prose only for the original libretto text and small descriptive fields like `description=` or `notes=`

### 3.7 Source-of-truth names only
For names that already exist in the project:
- character names must come from the **Characters** workspace
- place/background names must come from the **Places** workspace
- authored shot names must come from the scene’s current authored shot list once it exists

For objects/props introduced in the libretto:
- create a stable lower-kebab-case identity
- keep that exact name for the entire scene
- keep that exact name across later scenes if it is meant to be the same diegetic object

Examples:
- `amira`
- `luke`
- `district-clinic-exterior`
- `medical-satchel`
- `tea-tray`

Bad:
- `Amira again`
- `the clinic outside`
- `bag`
- `satchel maybe`

---

## 4. Exact bracket DSL grammar

## 4.1 Canonical syntax

```text
[tag: primary_value | key=value | key=value]
```

## 4.2 Formatting rules
- tag names: lowercase snake_case
- enum-like values: lowercase snake_case
- natural-language labels or names with spaces: quote them
- one bracket block per line when possible
- keep the raw libretto readable; direction blocks should organize, not overwhelm

Good:

```text
[camera: medium_close | label="Amira verse opening" | focus=amira | intent=dialogue | bars=9-12]
```

Bad:

```text
[Camera: MediumClose | Label=Opening | Focus=Amira | Timecode=00:18:42.12]
```

---

## 5. Supported tag families

### 5.1 Canonical tag families
Use these canonical tags:
- `scene`
- `camera`
- `enter`
- `exit`
- `move`
- `emotion`
- `action`
- `gesture`
- `object`
- `object_move`
- `object_state`
- `object_visibility`
- `lipsync`
- `pause`
- `sfx`
- `transition`

### 5.2 Legacy object aliases still parse, but do not author new work with them
Accepted aliases:
- `prop`
- `prop_move`
- `prop_state`
- `prop_visibility`

Use the canonical `object*` family for all new authoring.

---

## 6. Tag interpretation matrix

| Tag | Primary value | Required keys | Common optional keys | Immediate Animate use | Downstream use |
|---|---|---|---|---|---|
| `scene` | scene display name | none | `bg`, `background`, `lighting`, `time` | scene context | scene / lighting packet |
| `camera` | shot value **or** movement value | `label`, timing | `focus`, `intent`, `from`, `to`, `shot`, `easing`, `notes` | shot seeding + legacy camera parse | camera plan generation |
| `enter` | character name | timing + position | `facing`, `emotion`, `view`, `pose`, `z` | parser / setup context | character placement |
| `exit` | character name | timing | `direction`, `fade`, `notes` | parser / timing | exit behavior |
| `move` | character name | timing + destination | `from`, `to`, `easing`, `facing`, `view`, `pose`, `movement_style`, `z` | parser / timing | character motion |
| `emotion` | character name | timing + expression | `notes` | parser / timing | expression cues |
| `action` | character name | timing + description | `target`, `with_object`, `hand`, `intensity`, `notes` | parser / timing | action cue |
| `gesture` | character name | timing + `type` | `hand`, `target`, `with_object`, `notes` | parser / timing | drawing/action cue |
| `object` | object name | timing + position | `state`, `variant`, `layer`, `z`, `visible`, `opacity`, `attach_to`, `holder`, `notes` | parser + runtime catalog | object placement |
| `object_move` | object name | timing + destination | `from`, `to`, `easing`, `state`, `z`, `attach_to`, `holder`, `notes` | parser + runtime tracks | object motion |
| `object_state` | object name | timing | `state`, `variant`, `visible`, `opacity`, `attach_to`, `holder`, `notes` | parser + runtime tracks | object state cues |
| `object_visibility` | object name | timing | `visible`, `opacity`, `notes` | parser + runtime tracks | object visibility |
| `lipsync` | character name | timing | `mode`, `transcript`, `audio`, `action`, `expression` | marker / shot context | dialogue beat generation |
| `pause` | none | timing | `reason`, `notes` | timing spacing + shot seeding | hold / beat spacing |
| `sfx` | sound name | timing | `notes` | advisory | export / editorial |
| `transition` | type | timing or `duration` | `notes` | advisory | editorial / export |

---

## 7. Timing contract

### 7.1 Supported timing keys
Use one of:
- `bars=1-4`
- `beats=17-24`
- `frames=240-360`

Point cues may use:
- `bar=12`
- `beat=36`
- `frame=480`

### 7.2 Safest authoring subset
For best current integration:
- use `bars` for scene and shot rhythm
- use `beats` for tighter lyrical / emotional / reaction timing
- use `frames` only when exact fine placement matters

### 7.3 Timecode policy
Timecodes displayed in Animate are derived from:
- scene-local audio
- scene fps
- scene-local frame numbers

If a shot grows or shrinks, update only the **scene-local** shot timing in that scene.
Do **not** shift the whole show.

### 7.4 Pause semantics
`pause` does not create a new event by itself; it creates time / spacing.

Use it when you need:
- a dramatic hold
- orchestral breath
- reaction time
- an empty beat before a cut

### 7.5 Timing fallback rule
If the libretto does not already provide precise timing:
1. infer a best-fit shot timing from musical phrase boundaries
2. prefer bars first
3. tighten with beats only where the dramatic action truly needs it
4. use frames only for fine corrections or very short events

The LLM should never refuse to direct a scene just because the scene has imperfect musical timing metadata.

---

## 8. Scene contract

Use a `scene` block near the top of every scene whenever possible.

Example:

```text
[scene: "Clinic Exterior" | bg=district-clinic-exterior | lighting="late-afternoon dusty sun with cool clinic doorway fill" | time=late_afternoon]
```

Preferred keys:
- `bg`
- `background`
- `lighting`
- `time`

`lighting` should describe:
- time of day
- dominant practicals
- emotional light world
- readability priorities if obvious

Good:
- `lighting="gold sunset key with cool city fill and soft rim on both singers"`

Bad:
- `lighting=nice`
- `lighting=sad`

---

## 9. Camera / shot contract

## 9.1 Canonical camera shot values
Use exactly:
- `extreme_wide`
- `wide`
- `medium`
- `medium_close`
- `close`
- `extreme_close`

## 9.2 Canonical camera movement values
Use exactly:
- `zoom_in`
- `zoom_out`
- `pan_left`
- `pan_right`
- `pan_up`
- `pan_down`
- `track`
- `shake`
- `hold`

## 9.3 Canonical shot intent values
Use exactly:
- `establishing`
- `reveal`
- `reaction`
- `handoff`
- `dialogue`
- `movement`
- `confrontation`
- `insert`
- `transition`
- `emotional`

## 9.4 Two valid camera authoring forms

### A. Shot-definition form
Use when defining a shot block.

```text
[camera: medium_close | label="Amira verse opening" | focus=amira | intent=dialogue | bars=9-12]
```

### B. Camera-movement form
Use when the shot itself contains camera motion.

```text
[camera: zoom_in | label="Lantern reveal push" | from=medium | to=close | focus=lantern | intent=reveal | beats=41-48 | easing=ease_in_out]
```

Rule of thumb:
- use shot-definition form for most shots
- use movement form only when camera motion is truly meaningful

## 9.5 Required camera keys
Every meaningful camera block should include:
- `label`
- one timing field (`bars`, `beats`, or `frames`)

Common keys:
- `focus`
- `intent`
- `from`
- `to`
- `shot`
- `easing`
- `notes`

## 9.6 Focus values
`focus` should point to a stable subject:
- known character slug/name
- stable object name
- very rare named world target if necessary

Good:
- `focus=amira`
- `focus=luke`
- `focus=medical-satchel`

## 9.7 Shot authoring principles
The libretto-author LLM should behave like a real cinematographer:
- do not overcut
- cut on musical structure, not randomly
- use wider frames for spatial clarity
- use closer frames for emotional readability
- use inserts sparingly and deliberately
- if a prop handoff matters, give it a shot with readable intention
- do not swing wildly between extreme sizes without dramatic reason

## 9.8 Insert / object-focused shot rule
If an object materially changes the story state, the libretto may give it a dedicated shot.

Use:
- `intent=insert` when the shot exists mainly to clarify the object
- `intent=reveal` when the shot exists mainly to unveil a new object state or discovery

Object-focused shots must still:
- use a stable `label`
- use scene-local timing
- use `focus` pointing at the exact stable object name

Good:
```text
[camera: close | label="Satchel clasp insert" | focus=medical-satchel | intent=insert | beats=73-76]
```

---

## 10. Character blocking contract

## 10.1 Character identity
Use exact known project names/slugs.
Do not invent alternate names for the same character.

## 10.2 Canonical stage positions
Use these preferred stage positions whenever possible:
- `stage_left`
- `left`
- `center_left`
- `center`
- `center_right`
- `right`
- `stage_right`
- `offscreen_left`
- `offscreen_right`

## 10.3 Facing values
Use exactly:
- `left`
- `right`
- `camera`
- `away`

## 10.4 View-angle values
Use exactly:
- `front`
- `three_quarter_front`
- `side`
- `three_quarter_back`
- `back`

## 10.5 Pose values
Use exactly:
- `neutral`
- `frontal`
- `three_quarter`
- `profile`
- `seated`
- `walking`
- `pointing`
- `action`

## 10.6 Character tag patterns

### Enter
```text
[enter: "amira" | position=center_left | facing=right | emotion=guarded | view=three_quarter_front | bars=5-6]
```

### Exit
```text
[exit: "luke" | direction=offscreen_right | bars=37-40]
```

### Move
```text
[move: "luke" | from=right | to=center_right | bars=13-16 | easing=ease_in_out | movement_style=careful]
```

### Emotion
```text
[emotion: "amira" | expression=shaken | beat=36]
```

### Action
```text
[action: "luke" | description="offers the satchel carefully" | with_object=medical-satchel | bars=13-16]
```

### Gesture
```text
[gesture: "amira" | type=hesitate_reach | hand=right | target=medical-satchel | bars=17-18]
```

## 10.7 Character-blocking rules
- if a character moves, give it timing
- if a character changes emotional readability, add `emotion`
- if a character does a meaningful thing, add `action` or `gesture`
- do not collapse an entire performance into one vague action note

---

## 11. Object / prop contract

Objects and props are now fully first-class in the authoring contract and Animate runtime.

Use them for:
- carried props
- handoff items
- doors / curtains / containers
- lamps / lanterns / switches
- trays / bowls / satchels / books
- chairs / furniture that changes state or position
- important set dressing that appears, disappears, or moves

## 11.1 Stable object naming
Use one stable `objectName` per object identity.

Good:
- `medical-satchel`
- `doorway-lantern`
- `tea-tray`
- `curtain-panel`
- `clinic-stool`

Bad:
- `the bag`
- `prop1`
- `tray maybe`

If the same diegetic object persists across several shots in the scene, reuse the same name.
If two similar objects exist, disambiguate them:
- `tea-bowl-left`
- `tea-bowl-right`

## 11.1A Object lifecycle / persistence rule
Objects persist through the scene until one of the following happens:
- the scene ends
- the object is explicitly hidden
- the object is explicitly removed/replaced
- the object changes state
- the object moves to a new position
- the object is attached to or detached from a character, another object, or a world anchor

Do **not** rename the object when its state changes.

Good:
- `medical-satchel` stays `medical-satchel` whether it is closed, open, held, or resting

Bad:
- `medical-satchel` becoming `open-bag`

## 11.2 Object placement

```text
[object: "medical-satchel" | position=center_right | y=0.66 | state=closed | layer=foreground | z=3 | attach_to=character:luke:hand_right | bars=5-6]
```

Preferred keys:
- `position`
- `x`
- `y`
- `state`
- `variant`
- `layer`
- `z`
- `visible`
- `opacity`
- `attach_to`
- `holder`
- timing keys
- `notes`

## 11.3 Object motion

```text
[object_move: "medical-satchel" | from=center_right | to=center | bars=13-16 | easing=ease_in_out | attach_to=character:luke:hand_right]
```

Preferred keys:
- `from`
- `to`
- `from_x`
- `from_y`
- `to_x`
- `to_y`
- timing keys
- `easing`
- `state`
- `z`
- `attach_to`
- `holder`
- `notes`

## 11.4 Object state

```text
[object_state: "doorway-lantern" | state=lit | beats=33-36]
[object_state: "curtain-panel" | state=parted | beats=49-56]
```

Preferred keys:
- `state`
- `variant`
- `description`
- `visible`
- `opacity`
- `attach_to`
- `holder`
- timing keys
- `notes`

## 11.5 Object visibility

```text
[object_visibility: "doorway-lantern" | visible=false | frames=300-324]
```

Preferred keys:
- `visible`
- `opacity`
- timing keys
- `notes`

## 11.6 Character ↔ object interaction grammar
The authoring contract must make interaction explicit.

### Pickup
```text
[action: "amira" | description="picks up the lantern" | with_object=doorway-lantern | beats=41-44]
[object_state: "doorway-lantern" | state=held | attach_to=character:amira:hand_right | beats=41-44]
```

### Put down
```text
[action: "luke" | description="sets the satchel on the stool" | with_object=medical-satchel | beats=49-52]
[object_move: "medical-satchel" | to=center | beats=49-52]
[object_state: "medical-satchel" | state=resting_on_stool | beats=49-52]
```

### Handoff
```text
[action: "luke" | description="offers the satchel" | with_object=medical-satchel | bars=13-16]
[gesture: "amira" | type=hesitate_reach | target=medical-satchel | bars=17-18]
[object_state: "medical-satchel" | state=transferred | attach_to=character:amira:hand_left | beats=65-72]
```

### Wear / remove
```text
[object_state: "headscarf" | state=worn_securely | attach_to=character:amira:head | bars=1-8]
[object_state: "headscarf" | state=loosened | beats=57-60]
```

### Open / close / reveal / conceal
```text
[object_state: "medical-satchel" | state=open | beats=73-80]
[object_state: "curtain-panel" | state=parted | bars=19-20]
[object_state: "curtain-panel" | state=closed | bars=21-22]
```

## 11.7 Attachment naming rule
Use `attach_to` (preferred) or `holder`.

Examples:
- `attach_to=character:luke`
- `attach_to=character:amira:hand_right`
- `attach_to=object:clinic-stool:top`
- `attach_to=world:center_floor`
- `attach_to=none`

Important:
- bare character names still work as legacy shorthand for `character:<name>`
- use `character:<name>[:anchor]` for held or worn props
- use `object:<name>[:anchor]` when one object attaches to another object
- use `world:<anchor>` when an object should stay locked to a stable world point
- use `none`, `clear`, `detach`, or `detached` to explicitly remove an attachment

Recommended character anchors:
- `hand_right`
- `hand_left`
- `head`
- `belt`
- `shoulder_right`
- `shoulder_left`

Recommended object anchors:
- `top`
- `bottom`
- `left`
- `right`
- `top_left`
- `top_right`
- `bottom_left`
- `bottom_right`

Recommended world anchors:
- `center_floor`
- `left_floor`
- `right_floor`
- `center_air`
- `top_center`
- `top_left`
- `top_right`
- `bottom_left`
- `bottom_right`

Good:
```text
[action: "luke" | description="holds the satchel low in his right hand" | with_object=medical-satchel | bars=13-16]
[object_state: "medical-satchel" | state=held | attach_to=character:luke:hand_right | bars=13-16]
```

Detach example:
```text
[object_state: "medical-satchel" | state=resting_on_stool | attach_to=none | beats=81-84]
[object_move: "medical-satchel" | to=center | beats=81-84]
```

## 11.8 Object state naming rule
Object states should be stable, readable, and reusable.

Good:
- `closed`
- `open`
- `lit`
- `dim`
- `parted`
- `held`
- `transferred`
- `resting_on_stool`

Bad:
- `different bag look`
- `kind of open`
- `special thing now`

---

## 12. Singing / dialogue / lipsync contract

Because this is an opera, every scene sits on top of music.

The libretto-author LLM should explicitly mark singing / speaking passages when useful for downstream mouth generation.

## 12.1 Lipsync tag

```text
[lipsync: "amira" | mode=singing | transcript="How far can mercy travel" | bars=9-24]
```

Preferred keys:
- `mode`
- `transcript`
- `audio`
- `action`
- `expression`
- timing keys

## 12.2 Allowed lipsync modes
Use:
- `singing`
- `spoken`
- `spoken_over_music`

## 12.3 Lipsync rules
- mark major sung or spoken passages
- include transcript when possible
- do not try to author viseme frames directly in the libretto DSL
- Animate will later derive dialogue beats / viseme generation from this material

---

## 13. Lighting / atmosphere contract

Lighting is part of direction.

The libretto-author LLM should think like a cinematographer and clearly describe the light world.

## 13.1 Where lighting belongs
Primary location:
- `scene.lighting`

Optional shot-local metadata may appear on `camera` blocks when useful for downstream migration only:
- `lighting_emphasis`
- `practical_focus`
- `atmosphere`

These shot-local lighting keys are **migration metadata**, not guaranteed immediate direct parser semantics.

## 13.2 Good lighting phrases
Good lighting phrases mention:
- time of day
- key/fill relationship
- practicals
- atmosphere
- readability priorities

Good:
- `lighting="gold sunset key with cool blue fill, soft rim on both singers, dusty air"`
- `lighting="night street practicals with window lamp accents and fire-basket warmth against deep blue ambience"`

Bad:
- `lighting=nice`
- `lighting=dramatic`
- `lighting=beautiful`

## 13.3 Lighting principles for the author LLM
- preserve face readability during singing
- preserve prop readability when props matter dramatically
- keep one unified light world per shot
- only shift lighting emphasis when the story or staging clearly demands it

---

## 14. Pause / transition / sfx contract

## 14.1 Pause
```text
[pause: beats=2 | reason=reaction_hold]
```

## 14.2 Transition
```text
[transition: cut | duration=frames:12]
```

Use transition sparingly; it is mostly editorial metadata.

## 14.3 SFX
```text
[sfx: lantern_clink | beat=36]
```

Use SFX only as advisory staging metadata, not as a replacement for visual direction.

---

## 15. Immediate vs forwarded semantics

### 15.1 Immediate and structural now
These are immediately meaningful to current Animate authoring, parsing, shot seeding, plan conversion, or runtime preparation:
- `scene`
- `camera`
- `pause`
- character blocking tags
- object tags
- shot labels
- scene-local timing
- object attachment
- shot anchor bridge into JSON

### 15.2 Forwarded / migration metadata
These are safe to author, but may primarily exist for downstream plan conversion:
- shot-local lighting emphasis metadata
- transcript on lipsync tags
- detailed object interaction notes beyond core state/motion
- nuanced camera notes beyond the immediate keys

### 15.3 Never hide core logic in prose
If the event matters to the image, structure it.

Bad:
```text
[action: "luke" | description="hands over the satchel, the lantern brightens, the curtain parts, and the camera pushes in"]
```

Correct:
- Luke’s handoff → `action`
- satchel transfer → `object_state` / `object_move`
- lantern brightens → `object_state`
- curtain parts → `object_state`
- push-in → `camera`

---

## 16. Downstream Animate JSON scene-plan contract

The downstream JSON plan is what Animate actually applies.

Current top-level keys:

```json
{
  "schemaVersion": 8,
  "sceneName": "Scene Name",
  "backgroundName": "Approved place name",
  "lighting": "short lighting phrase",
  "sceneAudioPath": "optional path",
  "characterPlacements": [],
  "objectPlacements": [],
  "motions": [],
  "objectMotions": [],
  "expressions": [],
  "dialogueBeats": [],
  "shadowCues": [],
  "objectStateCues": [],
  "cameraMoves": [],
  "shotPresetApplications": [],
  "notes": []
}
```

### 16.1 Shot anchoring bridge
Frame-based commands may target authored shots using:
- `shotName`
- `shotID`
- `frameOffset`

Range-based commands may target authored shots using:
- `shotName`
- `shotID`
- `startFrameOffset`
- `endFrameOffset`

### 16.2 Character placement shape
```json
{
  "characterName": "amira",
  "frame": 0,
  "shotName": "Amira verse opening",
  "frameOffset": 0,
  "position": { "x": 0.32, "y": 0.58 },
  "facing": "right",
  "viewAngle": "threeQuarterFront",
  "pose": "threeQuarter",
  "emotion": "guarded",
  "zOrder": 2
}
```

### 16.3 Character motion shape
```json
{
  "characterName": "luke",
  "startFrame": 0,
  "shotName": "Satchel offer",
  "startFrameOffset": 0,
  "endFrameOffset": 36,
  "from": { "x": 0.78, "y": 0.60 },
  "to": { "x": 0.62, "y": 0.60 },
  "easing": "ease_in_out",
  "facing": "left",
  "viewAngle": "front",
  "pose": "walking",
  "movementStyle": "careful",
  "zOrder": 3
}
```

### 16.4 Object placement shape
```json
{
  "objectName": "medical-satchel",
  "frame": 0,
  "shotName": "Satchel offer",
  "frameOffset": 0,
  "position": { "x": 0.72, "y": 0.66 },
  "state": "closed",
  "zOrder": 3,
  "opacity": 1,
  "visible": true,
  "attachmentTarget": "character:luke:hand_right"
}
```

### 16.5 Object motion shape
```json
{
  "objectName": "medical-satchel",
  "startFrame": 0,
  "shotName": "Satchel offer",
  "startFrameOffset": 0,
  "endFrameOffset": 24,
  "to": { "x": 0.54, "y": 0.65 },
  "easing": "ease_in_out",
  "state": "transferred",
  "zOrder": 4,
  "attachmentTarget": "character:amira:hand_left"
}
```

### 16.6 Object state cue shape
```json
{
  "objectName": "doorway-lantern",
  "frame": 0,
  "shotName": "Lantern reveal push",
  "frameOffset": 0,
  "state": "lit",
  "opacity": 1,
  "visible": true,
  "attachmentTarget": "none"
}
```

Use `"none"` when JSON needs to explicitly clear/detach an attachment. Omit the field only when no attachment change is intended.

### 16.7 Expression cue shape
```json
{
  "characterName": "amira",
  "frame": 0,
  "shotName": "Amira verse opening",
  "frameOffset": 0,
  "expression": "shaken"
}
```

### 16.8 Dialogue beat shape
```json
{
  "characterName": "amira",
  "startFrame": 0,
  "shotName": "Amira verse opening",
  "frameOffset": 0,
  "audioPath": "Mix/SceneAudio/scene-03.wav",
  "transcript": "How far can mercy travel",
  "expression": "pleading",
  "action": "sing"
}
```

### 16.9 Shadow cue shape
```json
{
  "characterName": "luke",
  "frame": 0,
  "shotName": "Luke reaction",
  "frameOffset": 0,
  "style": "soft_ground",
  "opacity": 0.72
}
```

Allowed shadow styles:
- `none`
- `contact`
- `soft_ground`
- `dramatic_stage`

### 16.10 Camera move shape
```json
{
  "movement": "zoom_in",
  "startFrame": 0,
  "endFrame": 36,
  "shotName": "Lantern reveal push",
  "startFrameOffset": 0,
  "endFrameOffset": 36,
  "fromShot": "medium",
  "toShot": "close",
  "easing": "ease_in_out"
}
```

### 16.11 Shot preset application shape
```json
{
  "presetName": "Dialogue Two Shot",
  "frame": 0,
  "shotName": "Satchel offer",
  "frameOffset": 0,
  "cameraShot": "medium",
  "focusCharacterName": "amira",
  "shotIntent": "handoff",
  "beatLabel": "handoff beat",
  "beatNotes": "keep satchel readable",
  "characterOverrides": [
    {
      "characterName": "luke",
      "facing": "left",
      "viewAngle": "front",
      "pose": "three_quarter",
      "expression": "careful",
      "action": "offer"
    }
  ]
}
```

### 16.12 Allowed enum values for JSON

Important: these are the **exact runtime JSON spellings**. They may differ from the more human-friendly DSL examples above.

#### Facing
- `left`
- `right`
- `camera`
- `away`

#### View angle
- `front`
- `threeQuarterFront`
- `side`
- `threeQuarterBack`
- `back`

#### Pose
- `neutral`
- `frontal`
- `threeQuarter`
- `profile`
- `seated`
- `walking`
- `pointing`
- `action`

#### Easing
- `linear`
- `stepped`
- `ease_in`
- `ease_out`
- `ease_in_out`

---

## 17. Scene-by-scene authoring method for the libretto-writing LLM

When rewriting a scene, use this order:

0. gather the current scene inputs:
   - scene text
   - cast
   - place/background
   - known recurring objects
   - music phrase or timing context if available

Copy-paste operator scaffold:

```text
Scene name: {{SCENE_NAME}}
Song path: {{SONG_PATH}}
Audio path: {{AUDIO_PATH}}
Approved place/background: {{PLACE_BACKGROUND}}
Cast names: {{CAST_NAMES}}
Existing scene shots: {{EXISTING_SCENE_SHOTS}}
Recurring object names: {{RECURRING_OBJECTS}}
Timing notes: {{TIMING_NOTES}}
Additional directing guidance: {{DIRECTING_GUIDANCE}}
Operator notes: {{OPERATOR_NOTES}}

Scene text:
{{SCENE_TEXT}}
```

Prefer the dedicated operator template file when handing a scene to another LLM:
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-03-31-libretto-author-llm-operator-template.md`
1. identify the scene’s dramatic purpose
2. identify the musical structure in that scene
3. decide the minimum clean shot list needed
4. label every shot clearly
5. place characters in readable blocking
6. place the key objects/props in the world
7. mark object interaction explicitly
8. decide where the camera moves and where it does not
9. mark singing / lipsync passages when useful
10. add pauses / holds where the music or drama needs them
11. check that all timing remains scene-local
12. check that the scene reads like a directed film/opera moment, not random instructions

## 17.1 Minimal acceptable Animate-ready scene
At minimum, a scene rewrite should contain:
- one `scene` block
- at least one clearly labeled `camera` block
- at least one scene-local timing field on each meaningful shot
- explicit character blocking for the principal cast visible in the scene
- explicit object staging for any dramatically important carried or changing object

If the scene contains none of those, it is not ready for Animate.

---

## 18. Creative decision rules for the libretto-writing LLM

The LLM should behave like a tasteful director + cinematographer.

### 18.1 Prioritize readability
- preserve face readability during singing
- preserve hand/prop readability during handoffs
- preserve silhouette clarity during movement

### 18.2 Prefer motivated coverage
- do not create extra shots unless they improve meaning
- let music justify the cut rhythm
- use closeups for emotional pressure, not automatically

### 18.3 Treat props as dramatic subjects when needed
If a prop matters emotionally or narratively, give it:
- readable blocking
- a stable object name
- its own structured movement/state logic
- possibly its own shot or insert if dramatically warranted

### 18.4 Use scene-local continuity
Within a scene:
- object names remain stable
- shot labels remain stable
- light world remains coherent
- changes in timing update only that scene’s shot timing

---

## 19. Validation checklist for the libretto-writing LLM

Before finalizing any scene, verify all of the following.

### 19.1 Shots / camera
- every shot has a unique `label`
- shot timing is scene-local
- camera values use supported enums
- camera moves are only used when dramatically justified
- focus points to a known character or stable object when used

### 19.2 Characters
- names match the known cast
- movement has timing
- emotional turns are marked when visually important
- gestures/actions are not overloaded with unrelated events

### 19.3 Objects / props
- every recurring object has a stable name
- object events are structured, not buried in prose
- transfers / holds / attachments use `attach_to` or `holder`
- state names are stable and reusable
- object timing exists when object behavior matters to a shot

### 19.4 Singing / lipsync
- important sung/spoken passages have lipsync markers when helpful
- transcripts are included when practical
- no direct viseme-frame authoring appears in the libretto DSL

### 19.5 Timing
- bars / beats / frames only
- no show-global offsets
- no “this moves the rest of the opera” assumptions

### 19.6 Formatting
- lowercase snake_case enums
- one bracket block per meaningful instruction
- no unsupported tag invention unless the contract is updated intentionally

---

## 20. Good full-scene example

```text
[scene: "Clinic Exterior" | bg=district-clinic-exterior | lighting="late-afternoon dusty sun with cooler clinic doorway fill" | time=late_afternoon]

[camera: wide | label="Clinic establish" | focus=amira | intent=establishing | bars=1-4]
[enter: "amira" | position=center_left | facing=right | emotion=guarded | view=three_quarter_front | bars=5-6]
[enter: "luke" | position=right | facing=left | emotion=concerned | view=front | bars=5-6]
[object: "medical-satchel" | position=center_right | y=0.66 | state=closed | layer=foreground | z=3 | attach_to=character:luke:hand_right | bars=5-6]
[object: "doorway-lantern" | position=stage_left | y=0.30 | state=dim | layer=foreground | bars=1-20]

[camera: medium_close | label="Amira verse opening" | focus=amira | intent=dialogue | bars=9-12]
[emotion: "amira" | expression=wary | bar=9]
[lipsync: "amira" | mode=singing | transcript="How far can mercy travel" | bars=9-24]

[camera: medium | label="Satchel offer" | focus=luke | intent=handoff | bars=13-16]
[action: "luke" | description="offers the satchel carefully" | with_object=medical-satchel | bars=13-16]
[object_move: "medical-satchel" | from=center_right | to=center | bars=13-16 | easing=ease_in_out | attach_to=character:luke:hand_right]

[camera: close | label="Amira takes the bag" | focus=amira | intent=reaction | beats=65-72]
[gesture: "amira" | type=hesitate_reach | hand=right | target=medical-satchel | bars=17-18]
[object_state: "medical-satchel" | state=transferred | attach_to=character:amira:hand_left | beats=65-72]
[pause: beats=2 | reason=reaction_hold]

[camera: zoom_in | label="Lantern reveal push" | from=medium | to=close | focus=doorway-lantern | intent=reveal | beats=73-80 | easing=ease_in_out]
[object_state: "doorway-lantern" | state=lit | beats=73-80]
```

---

## 21. Bad examples

### Bad: duplicate shot labels
```text
[camera: close | label="Closeup" | focus=amira | bars=1-2]
[camera: close | label="Closeup" | focus=luke | bars=3-4]
```

### Bad: vague object naming
```text
[object: "the bag" | position=center]
```

### Bad: unsupported global timecode authorship
```text
[camera: medium | label="Verse opening" | timecode=00:18:42.12]
```

### Bad: random unsupported tag invention
```text
[lighting_shift: sunset-ramp | bars=9-12]
```

### Bad: burying multiple visual events in one prose note
```text
[action: "luke" | description="hands Amira the satchel, the lantern brightens, the curtain parts, and the camera pushes in"]
```

### Bad: object identity drift
```text
[object: "bag" | position=center]
[object_state: "satchel" | state=open | beats=33-36]
```

---

## 22. Final authoring instruction

If a libretto-writing LLM is uncertain, it should prefer:
- fewer but clearer shots
- cleaner blocking
- stable object names
- explicit handoff / interaction structure
- music-aligned timing
- readable emotional staging

It should **not** prefer vague flourish over structured clarity.

---

## 23. Canonical status

This file is the **single canonical libretto-side master contract** for Animate visual direction.

It supersedes narrower shot-only guidance as the main authoring reference.

Quick companion only:
- `docs/specs/2026-03-31-libretto-scene-shot-contract.md`
