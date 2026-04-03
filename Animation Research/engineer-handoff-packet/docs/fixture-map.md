# 45 — Handoff Fixture Map

Date: 2026-03-31

## Purpose
Describe which research fixtures should be copied into the future engineer handoff bundle.

## Required fixtures
- `sample_hero_ready_package.json`
- `sample_pilot_packet.json`
- `sample_mouth_profile.json`
- `sample_walk_and_sing_motion_plan.json`
- `sample_asset_review.json`
- `sample_expanded_shot_library.json`
- `sample_schema_upgrade_manifest_v1.json`

## Why these fixtures
Together, they cover:
- package loading
- pilot packet loading
- mouth profile loading
- motion plan loading
- review/correction state
- routing examples
- upgrade-path testing

## Bundle principle
The engineer handoff should include both:
- human-readable docs
- machine-readable fixtures

That allows immediate adapter tests without hunting for sample data.
