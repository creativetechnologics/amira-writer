# 53 — Package Diff Report Bundle

Date: 2026-03-31
Updated: 2026-03-31 (expanded)

## Purpose
Define what a complete, reviewable package diff bundle must contain.

## Bundle directory structure

```
{character}-{date}/
├── manifest.json                  # Top-level bundle descriptor
├── old/
│   └── package.json                # Baseline package manifest
├── new/
│   └── package.json                # Revised package manifest
├── diff/
│   ├── diff_report.json            # Machine-readable diff
│   └── diff_summary.md             # Human-readable summary
├── regressions/
│   └── regression_acknowledgements.json  # Signed-off regressions
└── logs/
    └── bundle_generation_log.json  # Who generated, when, tool versions
```

## manifest.json schema

```json
{
  "bundleId": "luke-hart-diff-2026-03-31",
  "generatedAt": "2026-03-31T12:00:00Z",
  "generatorTool": "generate_package_diff_bundle.py",
  "generatorVersion": "1.0.0",
  "oldPackage": {
    "file": "old/package.json",
    "packageId": "luke-hart-vnext-hero-ready",
    "qaStatus": "performance-ready",
    "schemaVersion": 1
  },
  "newPackage": {
    "file": "new/package.json",
    "packageId": "luke-hart-vnext-hero-ready",
    "qaStatus": "dialogue-ready",
    "schemaVersion": 1
  },
  "diffFile": "diff/diff_report.json",
  "markdownSummary": "diff/diff_summary.md",
  "requiresHumanAcknowledgement": true,
  "blockRegressionCount": 4,
  "warnRegressionCount": 1,
  "infoChangeCount": 2
}
```

## diff_report.json schema

```json
{
  "summary": {
    "removedMouthProfiles": ["mouth_profile_right_luke", "mouth_profile_left_luke"],
    "addedMouthProfiles": [],
    "removedCostumePacks": ["costume_plain_clothes"],
    "addedCostumePacks": [],
    "removedMotionPrimitives": [
      "idle_concerned", "walk_rl", "reach_satchel",
      "sit_clinic", "stand_from_seat", "look_down", "look_up"
    ],
    "addedMotionPrimitives": [],
    "removedAccessorySets": ["acc_scarf_default"],
    "addedAccessorySets": [],
    "qaStatusChange": {
      "from": "performance-ready",
      "to": "dialogue-ready",
      "severity": "BLOCK"
    }
  },
  "regressions": [
    {
      "id": "REG-001",
      "severity": "BLOCK",
      "category": "coverage",
      "description": "Mouth profile coverage dropped from 5 to 2",
      "details": {
        "removed": ["mouth_profile_right_luke", "mouth_profile_left_luke", "mouth_profile_luke"],
        "countBefore": 5,
        "countAfter": 2
      },
      "impact": "Characters will lack mouth animation at profile and remaining angles",
      "requiresAcknowledgement": true,
      "acknowledged": false
    },
    {
      "id": "REG-002",
      "severity": "BLOCK",
      "category": "coverage",
      "description": "Motion primitive coverage dropped from 12 to 4",
      "details": {
        "removed": ["idle_concerned", "walk_rl", "reach_satchel", "sit_clinic", "stand_from_seat", "look_down", "look_up"],
        "countBefore": 12,
        "countAfter": 4
      },
      "impact": "Reduced character behavior repertoire; some scenes cannot be staged",
      "requiresAcknowledgement": true,
      "acknowledged": false
    },
    {
      "id": "REG-003",
      "severity": "BLOCK",
      "category": "coverage",
      "description": "Costume pack 'costume_plain_clothes' removed",
      "details": {
        "removed": ["costume_plain_clothes"],
        "reason": null
      },
      "impact": "Plain Clothes costume unavailable for staging",
      "requiresAcknowledgement": true,
      "acknowledged": false
    },
    {
      "id": "REG-004",
      "severity": "BLOCK",
      "category": "accessory",
      "description": "Accessory set 'acc_scarf_default' removed from costume_medic_desert",
      "details": {
        "costume": "costume_medic_desert",
        "removed": ["acc_scarf_default"]
      },
      "impact": "Scarf accessory no longer available with Medic Desert costume",
      "requiresAcknowledgement": true,
      "acknowledged": false
    },
    {
      "id": "REG-005",
      "severity": "BLOCK",
      "category": "readiness",
      "description": "QA status downgraded from 'performance-ready' to 'dialogue-ready'",
      "details": {
        "from": "performance-ready",
        "to": "dialogue-ready"
      },
      "impact": "Package no longer approved for performance-tier shots",
      "requiresAcknowledgement": true,
      "acknowledged": false
    }
  ],
  "warnings": [
    {
      "id": "WARN-001",
      "severity": "WARN",
      "category": "semantic",
      "description": "Motion primitive 'walk_lr' behavior alias changed (check if semantic intent preserved)"
    }
  ],
  "infoChanges": [
    {
      "id": "INFO-001",
      "category": "semantic",
      "description": "Costume label 'Medic Desert' unchanged but accessory set count changed"
    },
    {
      "id": "INFO-002",
      "category": "semantic", 
      "description": "Package ID suffix changed from 'ready' to 'ready-regressed' (test artifact)"
    }
  ],
  "hasBlockRegressions": true,
  "hasWarnRegressions": false,
  "blockRegressionCount": 5,
  "warnRegressionCount": 0,
  "infoChangeCount": 2
}
```

## diff_summary.md template

```markdown
# Package Diff Report

**Bundle ID:** {bundleId}
**Generated:** {generatedAt}
**Generator:** {generatorTool} v{generatorVersion}

---

## Verdict

**STATUS: BLOCK** — {blockRegressionCount} regression(s) detected

This bundle contains {blockRegressionCount} BLOCK-level regression(s) that require human acknowledgement before the baseline can be updated.

---

## BLOCK Regressions

### REG-001 — Mouth Profile Coverage Dropped
- **Severity:** BLOCK
- **Impact:** Characters will lack mouth animation at profile and remaining angles
- **Before:** 5 mouth profiles
- **After:** 2 mouth profiles
- **Removed:** mouth_profile_right_luke, mouth_profile_left_luke, mouth_profile_luke
- **Recommended action:** Acknowledge loss or regenerate missing profiles

### REG-002 — Motion Primitive Coverage Dropped  
- **Severity:** BLOCK
- **Impact:** Reduced character behavior repertoire; some scenes cannot be staged
- **Before:** 12 motion primitives
- **After:** 4 motion primitives
- **Removed:** idle_concerned, walk_rl, reach_satchel, sit_clinic, stand_from_seat, look_down, look_up
- **Recommended action:** Acknowledge loss or regenerate missing primitives

### REG-003 — Costume Pack Removed
- **Severity:** BLOCK
- **Impact:** Plain Clothes costume unavailable for staging
- **Removed:** costume_plain_clothes
- **Recommended action:** Acknowledge removal or restore costume

### REG-004 — Accessory Set Removed
- **Severity:** BLOCK
- **Impact:** Scarf accessory no longer available with Medic Desert costume
- **Costume:** costume_medic_desert
- **Removed:** acc_scarf_default
- **Recommended action:** Acknowledge or restore accessory set

### REG-005 — QA Status Downgrade
- **Severity:** BLOCK
- **Impact:** Package no longer approved for performance-tier shots
- **Before:** performance-ready
- **After:** dialogue-ready
- **Recommended action:** Acknowledge downgrade or raise QA status through review

---

## Acknowledgement

I have reviewed the above regressions and acknowledge the following:

- [ ] REG-001 (mouth profiles) — acknowledged / intentional
- [ ] REG-002 (motion primitives) — acknowledged / intentional
- [ ] REG-003 (costume pack) — acknowledged / intentional
- [ ] REG-004 (accessory set) — acknowledged / intentional
- [ ] REG-005 (QA status) — acknowledged / intentional

**Reviewer:** ___________________
**Date:** ___________________
**Notes:** ___________________

---

## Policy Reminder

> A diff bundle must be produced and reviewed before replacing any approved package baseline.
> BLOCK regressions require explicit acknowledgement.
> The bundle must be logged for audit purposes.
```

## Why both JSON and Markdown

| Format | Purpose |
|--------|---------|
| JSON | Tooling consumption: CI gates, dashboards, automation pipelines |
| Markdown | Human review: signoff, handoff communication, audit trail |

## Review policy

1. Generate bundle before replacing any approved package baseline
2. Run tooling to identify BLOCK regressions automatically
3. Human reviewer must check WARN regressions manually
4. All BLOCK regressions require explicit acknowledgement
5. Bundle must be logged with reviewer name, date, and notes
6. Do not proceed with baseline update until all BLOCK regressions are acknowledged

## Tooling integration

The bundle should be consumed by:
- `handoff_bundle_audit.py` — validates bundle completeness
- `package_tier_audit.py` — validates tier minimums post-diff
- CI pipeline — gates baseline replacement on zero unacknowledged BLOCK regressions
