# 43 — Package Diff and Regression Strategy

Date: 2026-03-31
Updated: 2026-03-31 (expanded)

## Purpose
Define how to compare character package revisions and detect regressions before they slip into runtime or reference packs.

## Why this matters
A package can look improved overall while silently losing critical coverage:
- a mouth profile disappears
- a costume pack vanishes
- a motion primitive is removed
- QA status downgrades
- default ids stop resolving
- an accessory set is silently dropped
- an asset reference becomes dangling

These are package regressions even if the artwork itself looks prettier.

## Diff categories

### Structural regressions (always block)
| Category | Detection |
|----------|-----------|
| schema version changed | compare top-level `schemaVersion` |
| required top-level sections removed | compare section key sets |
| `required` field removed from a section | compare field manifests |

### Coverage regressions (always block)
| Category | Detection |
|----------|-----------|
| mouth profile count dropped | compare `mouthProfiles[].id` sets |
| costume pack count dropped | compare `costumePacks[].id` sets |
| motion primitive count dropped | compare `motionPrimitives[].id` sets |
| accessory set count dropped | compare nested `accessorySetIDs[]` across all costume packs |
| angle family count dropped | compare angle families in mouth profiles |
| costume-to-angle coverage gap | detect mouth profiles whose angle families have no matching costume |

### Readiness / QA regressions (always block)
| Category | Detection |
|----------|-----------|
| QA status downgraded | ordered comparison: `draft → blocking-ready → dialogue-ready → performance-ready → production-ready` |
| readiness score dropped | compare numeric `readiness.score` if present |
| promoted references removed | compare `promotedReferences[].id` sets |

### Default resolution regressions (always block)
| Category | Detection |
|----------|-----------|
| default costume id no longer exists | `package.defaults.costumeId` must be in `costumePacks[].id` |
| default mouth profile id no longer exists | `package.defaults.mouthProfileId` must be in `mouthProfiles[].id` |
| master sheet asset reference dangling | `masterSheetAssetID` must reference an existing asset |
| head sheet asset reference dangling | `headSheetAssetID` must reference an existing asset |

### Semantic regressions (warn, not block)
| Category | Detection |
|----------|-----------|
| motion primitive renamed | same behavior under a different `id` (alias mapping missing) |
| mouth profile angle family shifted | `mouthProfiles[].angleFamily` changed for same `id` |
| costume label changed | informational for consumer tooling |

## Regression severity levels

| Severity | Meaning | Policy |
|----------|---------|--------|
| **BLOCK** | Package is unusable or dangerous | Must be acknowledged before baseline replacement |
| **WARN** | Package works but coverage intent changed | Should be acknowledged; no hard block |
| **INFO** | Cosmetic or metadata only | No acknowledgement required |

## Regression rule matrix

| Condition | Severity | Category |
|-----------|----------|----------|
| Any coverage count drops | BLOCK | Coverage |
| QA status order decreases | BLOCK | Readiness |
| Any default id becomes unresolved | BLOCK | Default resolution |
| Schema version incremented | BLOCK | Structural |
| Required section missing | BLOCK | Structural |
| Accessory set silently dropped | BLOCK | Coverage |
| Angle family count drops | BLOCK | Coverage |
| Readiness score drops | WARN | Readiness |
| Promoted reference removed | WARN | Readiness |
| Asset label changed | INFO | Semantic |

## Recommended workflow

```
1. generate diff
   └─ run package_diff_report.py old.json new.json
   
2. classify regressions
   └─ severity matrix applied automatically by tooling
   
3. emit diff bundle
   ├─ machine-readable JSON report
   ├─ human-readable markdown summary
   └─ regression flags with severity labels
   
4. require human acknowledgement
   └─ BLOCK regressions must be acknowledged before baseline update
   
5. do not replace approved baselines automatically
   └─ diff bundle must be reviewed and signed off
   
6. log promotion record
   └─ record who acknowledged, when, and why
```

## Tooling requirements

| Tool | Purpose |
|------|---------|
| `package_diff_report.py` | Core diff engine; emits JSON report |
| `generate_package_diff_bundle.py` | Combines old, new, and diff into a shareable bundle |
| `package_tier_audit.py` | Validates tier minimums after diff |

## Exception handling

When a regression is intentional (e.g., removing a broken costume pack):
1. Document the reason in the diff bundle under `intentionalChanges`
2. Require the same acknowledgement flow
3. Log the justification for future audit trail

The intent is to ensure regressions are **known**, not **forbidden**. A broken costume pack removed intentionally is fine; a silent removal is not.

## Priority
Coverage regressions matter more than cosmetic improvements.
A package that is prettier but less usable is a downgrade.
