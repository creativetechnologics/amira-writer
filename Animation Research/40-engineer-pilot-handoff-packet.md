# 40 — Engineer Pilot Handoff Packet

Date: 2026-03-31

## Purpose
Give future implementation engineers a single packet of what to build first.

## Build targets
1. `PackageManifestAdapter`
2. `MotionPlanAdapter`
3. `MouthOverlayAdapter`
4. `AssetReviewAdapter`
5. `ReadinessAdapter`

## Required fixtures
- one hero-ready package fixture
- one pilot packet fixture
- one front mouth profile fixture
- one motion plan fixture
- one approved review fixture

## First test sequence
1. load package fixture
2. audit tier + readiness
3. load pilot packet
4. validate all required files exist
5. load motion plan and mouth profile
6. emit runtime instructions and overlay events
7. confirm routing remains internal for the pilot

## Success condition
One Luke pilot shot should load from research fixtures without ambiguity.

## Non-goals
- no multi-character runtime yet
- no AI-video execution yet
- no live migration of existing package storage yet
