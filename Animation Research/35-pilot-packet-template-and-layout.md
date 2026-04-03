# 35 — Pilot Packet Template and Layout

Date: 2026-03-31

## Purpose
Provide a literal on-disk template for the first pilot packet so future integration work has something concrete to mirror.

## Template folder
`Animation Research/pilot-packet-template/`

## Expected contents
- `packet.json`
- `character-package.json`
- `motion-plan.json`
- `readiness.json`
- `routing.json`
- `mouth-profiles/front.json`
- `reviews/review-01.json`
- `promotion-records/head-sheet.json`
- `refs/README.md`

## Packet assembly rule
Every file referenced by `packet.json` should be relative and portable.
That makes the packet safe to copy into test harnesses later.

## Why a real folder matters
Docs alone are not enough.
A physical template reduces ambiguity and helps future engineers see the exact shape of the first pilot bundle.
