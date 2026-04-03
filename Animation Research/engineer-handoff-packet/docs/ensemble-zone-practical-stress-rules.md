# 96 — Ensemble Zone/Practical Stress Rules

Date: 2026-03-31

## Purpose
Define when zone/practical complexity inside an ensemble lighting plan should automatically push routing upward from `internal` to `hybrid`, or from `hybrid` to `ai-video-fallback`.

## Engine-level requirement
This stress layer must remain generic. It should reason from:
- participant density
- active zone count
- active practical count
- moving practical count
- occlusion risk
- world-key stability

It should not depend on hero names or one-off scene assumptions.

## Stress factors
- **zone spread** — how many active lighting zones need meaningful separation on the same beat
- **practical density** — how many practicals are active at once
- **practical motion** — whether practical pools or sources move across performers
- **occlusion risk** — whether performers cross in front of each other or practical pools
- **world-key stability** — whether the shared key direction/value remains stable
- **participant density** — larger ensembles amplify all other stress factors

## Automatic routing pressure
- low stress can remain `internal`
- medium stress should push to at least `hybrid`
- high stress should push to `ai-video-fallback` only when combined with weak world-key stability or severe occlusion

## Minimum policy
- 4+ participants with 3+ active zones and 2+ practicals on the same beat should default to at least `hybrid`
- any beat with unstable world-key direction should block `internal`
- 5+ participants with moving practicals and high occlusion risk should strongly consider `ai-video-fallback`
