# 2026-04-18 Fast AU Export Qualification Checkpoint

## Problem

WAV export for hosted Audio Unit / BBC instrument sessions currently falls back to realtime capture because the manual-rendering path can be faster but was not yet trustworthy enough to guarantee audio parity.

## Architectural direction

Instead of blindly switching all AU exports to offline mode, the export stack should move toward a DAW-style capability model:

1. **Try a faster offline path only when it proves trustworthy**
2. **Keep a safe realtime fallback for mapping sets that do not qualify**
3. **Reduce divergence between offline and realtime AU rendering by sharing more of the host behavior**

## Changes implemented in this checkpoint

1. Added an **AU export mode** concept:
   - `auto` (default)
   - `realtime`
   - `offline`
2. Added **persisted qualification caching** for hosted-AU mapping sets so launch-to-launch exports can reuse a prior verdict.
3. In `auto` mode, the exporter now:
   - renders a short **offline qualification excerpt**
   - renders the same excerpt via the trusted **realtime playback-engine path**
   - compares them using **MFCC similarity**, **RMS-envelope similarity**, and duration delta
   - tries both a **standard** and a more conservative hosted-AU offline render profile before deciding
   - only promotes offline rendering when the result passes conservative thresholds
4. Improved the hosted-AU offline path with:
   - **profiled manual-rendering block sizes**
   - a longer **silent warm-up / priming pass** before scheduling notes
   - **silence-aware hosted-AU tail stopping** instead of a fixed 1-second offline tail
   - qualification-time comparison of **active audible duration**, not just raw file duration
   - **measured leading-latency alignment** when offline hosted-AU renders start earlier or later than the trusted realtime excerpt
   - cached qualification details now record **onset delta** and **tail delta** so remaining mismatches are diagnosable without reproducing the same render blindly
   - audible-bound detection now uses a quieter analysis threshold so low-velocity orchestral excerpts still produce usable onset/tail diagnostics
   - when qualification still fails badly, preserve the qualification excerpt WAVs + metadata in Application Support so the mismatch can be inspected directly
   - qualification-time analysis now retries AVAudioFile opening/reading, waits up to a few seconds for freshly rendered excerpts, and falls back to analyzing a copied clone of the excerpt when the original just-written file still refuses to yield audible bounds

## Why this matters

This shifts the system from a binary “offline is experimental” stance to a more robust host architecture:
- fast export is attempted only when there is evidence it is safe
- incompatible AU setups remain on the proven realtime path
- successful qualification results can be reused within the session and across launches

## Current limitations

- Qualification still incurs a one-time realtime comparison cost for previously unseen AU mapping sets.
- More work is still needed if we want FL-Studio-style “fast by default” export for all plugin chains.

## Likely next steps

1. Move AU offline rendering setup into a more shared host abstraction with `MIDIPlaybackEngine`
2. Add better diagnostics/UI so qualification verdicts and chosen offline profiles are inspectable without digging through logs
3. Expand qualification to mixed MIDI+audio-clip exports
