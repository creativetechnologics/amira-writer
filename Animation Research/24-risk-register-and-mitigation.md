# 24 — Risk Register and Mitigation

Date: 2026-03-31

## 1. Package bloat
### Risk
Too many assets per character may create organizational and QA overhead.
### Mitigation
- tier characters explicitly
- gate expansion by scene need
- add readiness checkpoints before growing the package

## 2. Identity drift in generated assets
### Risk
Later generations drift from the approved look.
### Mitigation
- only generate from approved reference packs
- review every candidate with structured AI QA
- never promote unreviewed images into the reference set

## 3. Mouth-engine over-complexity
### Risk
Trying to model every phoneme precisely wastes effort.
### Mitigation
- use a canonical viseme family
- optimize for anime readability, not phonetic literalism
- separate singing timing from speech timing

## 4. Runtime contract mismatch
### Risk
Research schemas may not map cleanly onto current Animate structures.
### Mitigation
- use adapters first
- pilot on one narrow shot type
- keep manifests versioned and additive

## 5. AI correction loops waste time
### Risk
Bad assets may bounce between edit and regenerate forever.
### Mitigation
- hard cap edit/regenerate loops
- escalate uncertain cases to human review
- preserve candidate history for comparison

## 6. Cost creep from retries
### Risk
Raw model pricing may stay low while retries drive spend up.
### Mitigation
- milestone budgets
- promote only approved refs
- favor 2K batch for bulk package building
- reserve 4K for only a few canonical anchors
