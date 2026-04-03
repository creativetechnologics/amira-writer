# 09 — Research Roadmap and Validation Plan

Date: 2026-03-30

## Purpose
Turn this research corpus into a concrete multi-phase build and validation program.

The goal is not just to keep writing ideas.
The goal is to prove that Amira Writer can animate a feature film with:
- structured character packages
- sparse motion planning
- a separate mouth engine
- AI image generation for package creation
- AI video fallback only where needed

---

## 1. Core hypotheses to test

### H1 — Internal 2D rigging can cover most dialogue and staging shots
Expected result:
- yes, if package completeness is high enough
- especially for anime-style blocking and moderate camera movement

### H2 — A separate mouth engine will materially improve quality and maintainability
Expected result:
- yes, because mouth timing, angle handling, and singing behavior differ too much from body motion

### H3 — AI image generation can build most package assets faster than manual authoring
Expected result:
- yes for exploration, sheets, and many variants
- but human QA and selective cleanup remain essential

### H4 — AI video should be routed only to hard shots
Expected result:
- yes, because it is less deterministic and less editable than internal animation

---

## 2. Immediate research-to-build phases

### Phase 0 — Lock vocabulary and contracts
Deliverables:
- approved package taxonomy
- approved mouth-engine vocabulary
- approved motion-plan schema
- approved shot-routing categories

Success criteria:
- all future implementation work uses the same language for parts, angles, mouth profiles, costumes, and shot types

### Phase 1 — Build one hero package end-to-end
Target character:
- Luke

Deliverables:
- master sheet
- head sheet
- one military costume sheet
- one civilian costume sheet
- core rig parts
- mouth profiles for key angles
- basic motion primitive set

Success criteria:
- Luke can perform a simple dialogue scene, a walking scene, and a singing shot internally

### Phase 2 — Build the separate mouth engine
Deliverables:
- viseme mapping rules
- speech mode
- singing mode
- angle-aware mouth registration
- manual override support

Success criteria:
- acceptable anime-grade mouth movement on at least three head-angle families

### Phase 3 — Build the LLM motion planner
Deliverables:
- sparse motion-plan JSON
- primitive selection logic
- timing heuristics
- runtime composition contract

Success criteria:
- script text can drive believable blocking without hand-keying every movement

### Phase 4 — Build the shot router
Deliverables:
- internal vs AI-video decision matrix
- start/end-frame export logic
- shot metadata package

Success criteria:
- hard shots can be externalized without losing style or continuity

---

## 3. Validation scenes we should use

### Test Scene A — Static dialogue
Purpose:
- prove base package + mouth engine

### Test Scene B — Walk and talk
Purpose:
- prove locomotion + mouth overlay + camera-relative movement

### Test Scene C — Emotional close-up
Purpose:
- prove face/expression quality

### Test Scene D — Singing medium shot
Purpose:
- prove lyrics-driven mouth behavior

### Test Scene E — Hard shot routed to AI video
Purpose:
- prove hybrid pipeline continuity

---

## 4. Metrics that actually matter

Do not validate only on whether the image is pretty.
Validate on:

### Package completeness
- angle coverage
- costume coverage
- mouth coverage
- hand/gesture coverage
- prop coverage

### Runtime quality
- identity stability
- costume consistency
- staging readability
- mouth timing credibility
- editability after generation

### Production usefulness
- time to generate usable package
- time to revise a shot
- time to regenerate a missing asset
- cost per usable approved asset
- percentage of shots that stay internal

---

## 5. The best overnight research-to-prototype order

1. package architecture
2. mouth engine
3. motion-plan contract
4. one hero package generator workflow
5. shot router

This ordering keeps the runtime contract stable before heavy implementation starts.

---

## 6. What should be avoided

Avoid:
- building everything around AI video first
- depending on one giant monolithic reference sheet forever
- conflating mouth logic with body logic
- generating assets without approval state
- allowing package folders to become loose image dumps
- overfitting the engine to one character before defining the universal contract

---

## 7. Final build recommendation

### Build first
- the package contract
- the package generator workflow
- the mouth engine contract
- the sparse motion-plan schema

### Build second
- actual runtime interpolation and overlays

### Build third
- AI-video bridging tools

That order gives the project the strongest chance of shipping something controllable instead of something impressive-but-fragile.
