# 07 — QA and Repair

## Principle

QA should compare generated outputs against the shot spec and reference contract, not just ask whether an image looks good.

## Frame QA checks

| Check | Example failure |
|---|---|
| Place identity | Ridge shelf becomes permanent concrete base. |
| Character identity | Johnny face drifts into Luke. |
| Wardrobe | Soldier loses desert camouflage/field gear. |
| Time period | Modern smartphones, drones, LED screens. |
| Geography | Village appears on wrong side of river. |
| Landmark | Bridge disappears or becomes modern steel. |
| Camera | Close-up generated when shot requires wide geography. |
| Action | End frame does not reflect described change. |
| Style | CGI smoothness, HDR punch, wrong animation look. |

## Video QA checks

| Check | Example failure |
|---|---|
| Start/end adherence | Video ignores end frame. |
| Identity preservation | Face morphs mid-shot. |
| Motion prompt | Character walks wrong direction. |
| Geography continuity | Bridge or river moves. |
| Temporal continuity | Lighting jumps. |
| Artifacts | Warping, extra limbs, unstable props. |

## QA result behavior

| Result | Action |
|---|---|
| `pass` | Eligible for approval or next stage. |
| `warning` | User can accept or regenerate. |
| `fail` | Generate targeted correction prompt. |
| `needs_review` | Stop automation and show user the issue. |

## Retry policy

Recommended default:

```text
automatic retries per artifact: 2
after retry cap: needs_manual_review
manual approval can override warning
manual approval should not hide QA result
```

## Correction prompt generation

A correction prompt should be targeted. It should not rewrite the whole prompt unless the error is broad.

Examples:

### Wrong place

```text
Keep the approved Mountain Valley Approach Road geography: river low in the valley, village on the north bank only, old stone bridge as the only crossing, temporary base on the opposite ridge. Do not invent a modern highway, permanent concrete base, or city skyline.
```

### Wrong character

```text
Preserve Johnny Ward's identity from the character reference: white American male, early 30s, short dark brown cropped hair, light stubble, weathered fair-to-medium skin, brown eyes, squared jaw. Keep desert camouflage and military photographer gear.
```

### Wrong period

```text
Remove all modern/future details. The world is early 2000s: period-appropriate vehicles, paper records, analog signage, sparse early-mobile-era details only. No drones, LED walls, modern smartphones, or futuristic military technology.
```

### Wrong style

```text
Return to grounded cinematic photorealism with documentary framing, natural light, subtle film grain, muted satellite-style palette, no glossy CGI smoothness, no HDR punch.
```

## QA sidecar

```json
{
  "version": 1,
  "sceneID": "...",
  "shotID": "...",
  "artifactKind": "frame",
  "artifactPath": "/absolute/path.png",
  "status": "fail",
  "checks": [
    {
      "name": "place_identity",
      "status": "fail",
      "evidence": "The generated image shows a paved highway and city skyline.",
      "correctionHint": "Use the approved place image and map reference."
    }
  ],
  "retryRecommendation": {
    "action": "regenerate",
    "reason": "Wrong place identity and time period.",
    "correctionPrompt": "Keep the approved valley geography..."
  },
  "attempt": 1,
  "createdAt": "ISO-8601"
}
```

## Manual escalation

Escalate when:

- missing required reference role
- ambiguous place/character
- repeated QA failure
- wrong geography after correction
- provider error repeats
- generated frame is usable but requires human creative judgment
- user has rejected all automatic variants
