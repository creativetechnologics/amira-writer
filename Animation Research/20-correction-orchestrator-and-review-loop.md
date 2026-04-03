# 20 — Correction Orchestrator and Review Loop

Date: 2026-03-31

## Purpose
Turn the QA/correction strategy into a practical research-only orchestration design.

## Core loop
1. generate candidate asset
2. review against approved references
3. emit structured review JSON
4. choose approve / edit / regenerate / escalate
5. if edit, generate a targeted edit prompt
6. re-review the result
7. promote only if the asset passes

## Why an orchestrator is needed
Without orchestration, AI QA becomes just a note-taking step.
The system needs a deterministic controller that can:
- read the review JSON
- decide next action
- prevent endless bad edit loops
- preserve good facts while fixing bad ones

## Recommended state model
Each asset candidate should track:
- asset id
- source slot
- reference pack ids
- generation prompt
- review status
- edit attempt count
- regenerate attempt count
- promoted / rejected state

## Decision policy
### Approve immediately
- no critical issues
- no major issues
- overall confidence high
- asset fits the target slot

### Edit
Use edit when:
- identity is correct
- angle is correct
- structural pose is correct
- the issue is local to costume, mouth, pocket, scarf, cleanup, or styling drift

### Regenerate
Use regenerate when:
- identity drift is structural
- angle is wrong
- body construction is wrong
- silhouette is unusable
- pose intent is broken

### Escalate
Use human review when:
- the model is low-confidence
- repeated edit/regenerate loops disagree
- the candidate is aesthetically ambiguous but technically viable

## Hard safety rules
- maximum 2 edit attempts before forcing regenerate or escalate
- maximum 2 regenerate attempts before escalate
- never overwrite approved references automatically
- always preserve prompt, reference list, and review history

## Correction prompt recipe
A correction prompt should contain:
1. preserve facts
2. change facts
3. forbidden drift
4. target slot reminder

Example structure:
- Keep the same character identity, same front-neutral pose, same desert medic colors.
- Remove the oversized chest pockets and match the approved pocket placement.
- Do not alter face, body, silhouette, or angle.

## Best use of AI perception
Gemini image understanding can be used to:
- compare candidate vs approved sheets
- locate face / mouth / costume regions
- return JSON review
- optionally emit candidate mouth or garment bounding boxes for downstream cleanup

## Practical output contract
The orchestrator should output:
- action
- reason
- edit prompt if relevant
- whether to retry with same refs or stricter refs
- whether the result should be reviewed again automatically

## Research-only implementation suggestion
Start with a simple controller:
- read `asset_review_schema.json`
- convert to a next action
- produce a correction packet

Later, a real implementation could:
- queue edits automatically
- attach updated reference packs
- stop when readiness criteria are met
