# 15 — Package Readiness and Coverage Model

Date: 2026-03-31

## Purpose
A package can have many assets and still be unusable. This document defines how to score whether a character package is actually ready for production work.

## Readiness dimensions
1. **Identity coverage** — master sheet, head sheet, body sheet, style anchors
2. **Costume coverage** — required costume packs and sheet coverage
3. **Facial coverage** — expressions, blinks, mouth profiles by angle family
4. **Motion coverage** — idle, walk, turn, reach, react, seated/kneeling as needed
5. **Lighting coverage** — lighting response metadata, relight protection, and approved profile compatibility
6. **Accessory coverage** — props, attachment points, compatibility declarations
7. **Technical coverage** — placement metadata, pivots, QA state, required fields

## Suggested statuses
- **draft** — not usable for scene work
- **blocking-ready** — can stage shots but not finish them
- **dialogue-ready** — can handle close/medium dialogue scenes
- **performance-ready** — can handle acting, walking, props, and singing overlays
- **production-ready** — broad enough for general show use

## Recommended thresholds
### Dialogue-ready
- identity >= 0.90
- facial >= 0.75
- motion >= 0.50
- lighting >= 0.60
- technical >= 0.80

### Performance-ready
- identity >= 0.90
- facial >= 0.85
- motion >= 0.75
- costume >= 0.70
- lighting >= 0.75
- technical >= 0.90

### Production-ready
- identity >= 0.95
- facial >= 0.90
- motion >= 0.85
- costume >= 0.85
- lighting >= 0.85
- technical >= 0.95

## Blocking failures
Any of these should prevent production-ready status:
- no approved master sheet
- no approved mouth profile for required angle family
- no pose coverage for required costume
- no lighting response metadata for required asset families
- no placement metadata for runtime parts

## Sandbox code
Use `tools/package_readiness_model.py` to score a package-like JSON payload.
