# 28 — Singing Mouth Timing Heuristics

Date: 2026-03-31

## Purpose
Move the mouth engine from generic speech timing toward a more production-grade singing model.

## Core rule
In singing, **vowels carry the shot**.
Consonants are accents unless intelligibility or emotion requires emphasis.

## Timing layers
The mouth engine should treat singing as a stack of layers:
1. lyric text / syllables
2. vowel family selection
3. note duration / sustain
4. emotional modifier
5. angle-family adjustment
6. cleanup / smoothing

## Recommended heuristic rules

### 1. Phrase attack
At phrase starts:
- enter the first vowel slightly slower than speech
- avoid instant hyper-wide opening unless the phrase begins with a belt
- preserve a readable approach to the vowel shape

### 2. Sustained vowels
When a syllable sustains:
- hold the vowel family
- add subtle variation rather than rapid viseme swaps
- use small oscillation or openness drift only if emotional intensity justifies it

### 3. Consonant compression
For most sung consonants:
- shorten closure timing
- return quickly to the dominant vowel family
- do not let consonants dominate long notes

### 4. Phrase release
At phrase ends:
- soften the release
- avoid snapping instantly to rest unless the phrase is clipped
- allow breath/rest recovery on the following beat if available

### 5. Emotional overrides
#### Soft / intimate
- smaller openings
- more oo/oh bias
- slower transitions

#### Strong / heroic
- wider aa/eh shapes
- stronger attack on vowel onset
- more stable held openness

#### Strained / crying
- add strain variant
- compress corners or raise upper-lip tension
- allow asymmetry only if it fits the art style

### 6. Angle adjustments
#### Front
- use the full shape inventory
- symmetric shape transitions

#### Quarter-turn
- preserve readability with mild side compression
- avoid overly wide horizontal shapes that break the perspective

#### Profile
- heavily simplify to silhouette-readable openings
- keep tongue/teeth details minimal unless the asset family supports them

## Suggested event model
For each lyric event:
- frame
- canonical shape
- optional variant
- emphasis level
- sustain duration
- openness bias
- emotional modifier

## Human-quality goal
The target is not phonetic perfection.
The target is **anime-caliber credibility**:
- readable singing
- emotionally appropriate shapes
- stable timing
- minimal chatter

## Later implementation hint
A future singing engine should probably take:
- lyric text
- optional syllable timings
- optional melody/note lengths
- mouth profile id
- emotion flag
and return a dense mouth event plan with smoothing metadata.
