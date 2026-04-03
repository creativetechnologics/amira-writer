# 77 — Duet Motion Lighting Fixtures

Date: 2026-03-31

## Purpose
Tie the duet lighting packets to motion-plan beats so engineering can see where lighting continuity has to survive body movement, mouth overlays, and shot blocking.

## Required packet shape
Each duet motion-lighting packet should include:
- `packetId`
- `locationId`
- `lightingPlanFixture`
- `duetLightingPacketFixture`
- `routingMode`
- `motionBeats`
- `mouthOverlay`
- `channelContinuityRules`

## Beat design rules
- lighting should not re-invent the world on every beat; most beats only adjust channel intensity or emphasis
- movement across the frame should preserve the same `sharedLightWorld`
- character-specific protection channels can rebalance locally, but they cannot contradict `ch01`–`ch06`

## Key continuity constraints
- Luke crossing deeper into shadow should first receive `ch07_luke_protect`, not a brand-new key
- Amira turning away from key should first receive `ch08_amira_protect`, not a separate world fill
- mouth overlays should inherit the active angle and the active local protection channel for the beat

## Pilot recommendation
The first engineering pilot should wire one duet motion-lighting packet per top location, then validate:
- beat-to-beat channel continuity
- mouth readability continuity
- silhouette continuity during movement
