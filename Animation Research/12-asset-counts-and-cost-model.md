# 12 — Asset Counts and Cost Model for Character Packages

Date: 2026-03-31

## Purpose
Estimate how many reusable assets a character package will likely need, and what those assets will cost to generate with **Nano Banana 2 / Gemini 3.1 Flash Image Preview**.

## Short answer

### Hero character
- **Base character package:** about **90–140 assets**
- **Each additional costume:** about **18–28 assets**

### Supporting character
- **Base character package:** about **45–80 assets**
- **Each additional costume:** about **10–16 assets**

### Background character
- **Base character package:** about **18–35 assets**
- **Each additional costume:** about **6–10 assets**

These ranges assume the package includes:
- identity/master sheets
- head/body turnarounds
- pose families
- expressions
- mouth/viseme coverage
- costume overlays
- accessory/prop states
- a small number of corrective assets

## Example package recipes

### Hero with 2 costumes
A practical first-pass hero package usually lands around:
- 12–18 identity/sheet assets
- 20–35 pose/motion assets
- 20–30 facial and mouth assets
- 20–35 rig/corrective assets
- 2 costume packs at 18–28 assets each

**Planning total:** about **110–130 assets**

### Supporting with 1 costume
**Planning total:** about **50–65 assets**

### Background with 1 costume
**Planning total:** about **25–30 assets**

## Official Nano Banana 2 pricing used here
Verified from Google’s official Gemini Developer API pricing page for `gemini-3.1-flash-image-preview`:
- **Standard:** `$0.067 per 1K`, `$0.101 per 2K`, `$0.151 per 4K`
- **Batch:** `$0.034 per 1K`, `$0.050 per 2K`, `$0.076 per 4K`

Sources:
- https://ai.google.dev/gemini-api/docs/pricing
- https://ai.google.dev/gemini-api/docs/image-generation

## Model note
Google's current image docs explicitly describe **Nano Banana 2** as **Gemini 3.1 Flash Image Preview** (`gemini-3.1-flash-image-preview`). They also describe a cheaper, lower-resolution sibling model, **Gemini 2.5 Flash Image** (`gemini-2.5-flash-image`), which is useful for very cheap previz but tops out at 1K outputs.

Current official cost for `gemini-2.5-flash-image` (optional previz path):
- **Standard:** `$0.039 per image`
- **Batch:** `$0.0195 per image`

## Cost scenarios

### Hero package (~120 assets)
- **Standard 1K:** `120 × $0.067 = $8.04`
- **Standard 2K:** `120 × $0.101 = $12.12`
- **Standard 4K:** `120 × $0.151 = $18.12`
- **Batch 1K:** `120 × $0.034 = $4.08`
- **Batch 2K:** `120 × $0.050 = $6.00`
- **Batch 4K:** `120 × $0.076 = $9.12`

### Supporting package (~60 assets)
- **Standard 1K:** `$4.02`
- **Standard 2K:** `$6.06`
- **Standard 4K:** `$9.06`
- **Batch 1K:** `$2.04`
- **Batch 2K:** `$3.00`
- **Batch 4K:** `$4.56`

### Background package (~28 assets)
- **Standard 1K:** `$1.88`
- **Standard 2K:** `$2.83`
- **Standard 4K:** `$4.23`
- **Batch 1K:** `$0.95`
- **Batch 2K:** `$1.40`
- **Batch 4K:** `$2.13`

## Best practical cost rule
- use **2K** for master sheets, turnarounds, and most reusable package assets
- use **4K** only for a few canonical anchors or close-up-critical assets
- use **batch** whenever possible for large generation runs
- keep retries/regenerations budgeted at **+25% to +50%** on top of raw asset cost

## Planning takeaway
A lead character is probably not a $100+ problem in raw generation cost.
It is more like a **single-digit to low-double-digit dollar** problem per package if we keep most assets at 1K/2K and batch what we can.
