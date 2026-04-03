# 25 — Package Promotion and Approval Workflow

Date: 2026-03-31

## Purpose
Define how assets move from raw generations into an approved character package.

## Core rule
No generated image becomes a long-term reference automatically.
Everything must move through explicit states.

## Asset lifecycle
1. generated candidate
2. reviewed candidate
3. corrected candidate or regenerated candidate
4. approved asset
5. promoted reference asset
6. packaged runtime asset

## State definitions
### Generated candidate
Fresh output from the image system. May be plausible but not trusted.

### Reviewed candidate
A structured review exists for identity, angle, costume, pose, and technical quality.

### Corrected / regenerated candidate
A derivative candidate created because the review found local or structural problems.

### Approved asset
A human or trusted gate has decided the asset is good enough for its slot.

### Promoted reference asset
An approved asset that is allowed to guide future generations.
Only a small number should be promoted.

### Packaged runtime asset
An approved asset that is inserted into a character package for runtime use.

## Promotion rules
Promote to reference only when:
- the asset is stable enough to guide future generations
- identity is highly reliable
- angle/costume/pose are correct
- it reduces ambiguity for later generations

Do not promote when:
- the asset is merely acceptable for runtime but visually noisy
- the asset contains unresolved drift
- the asset is too specific to one shot

## Recommended promotion quotas
### Per character
- 1 master sheet
- 1 head turnaround sheet
- 1 body turnaround sheet per costume
- 1 accessory/detail sheet per important accessory family

Everything else should generally remain package/runtime material, not reference-driving material.

## QA gates
### Gate 1 — candidate gate
Passes basic technical sanity:
- no broken anatomy
- no wrong identity family
- no unusable angle

### Gate 2 — slot gate
Fits the intended slot:
- correct costume
- correct pose/angle
- usable framing
- acceptable lighting response behavior for the slot's expected scene conditions

### Gate 3 — promotion gate
Strong enough to become a future generation reference:
- extremely stable
- low ambiguity
- easy to compare against later candidates
- remains readable under representative relight profiles if it is a promotion-critical sheet

## Human approval policy
AI can recommend approval, but a human should promote reference-driving assets.
This keeps the package bible from drifting.

## Practical takeaway
The package should be built from many approved assets, but only a disciplined subset should become future reference images.
