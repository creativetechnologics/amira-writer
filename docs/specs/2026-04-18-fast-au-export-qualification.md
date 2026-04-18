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
2. Added **session-local qualification caching** for hosted-AU mapping sets.
3. In `auto` mode, the exporter now:
   - renders a short **offline qualification excerpt**
   - renders the same excerpt via the trusted **realtime playback-engine path**
   - compares them using **MFCC similarity** plus duration delta
   - only promotes offline rendering when the result passes conservative thresholds
4. Improved the hosted-AU offline path with:
   - **smaller manual-rendering block sizes**
   - a short **silent warm-up / priming pass** before scheduling notes

## Why this matters

This shifts the system from a binary “offline is experimental” stance to a more robust host architecture:
- fast export is attempted only when there is evidence it is safe
- incompatible AU setups remain on the proven realtime path
- successful qualification results can be reused within the session

## Current limitations

- Qualification is currently **session-local**, not persisted across launches.
- Qualification still incurs a one-time realtime comparison cost for previously unseen AU mapping sets.
- More work is still needed if we want FL-Studio-style “fast by default” export for all plugin chains.

## Likely next steps

1. Move AU offline rendering setup into a more shared host abstraction with `MIDIPlaybackEngine`
2. Persist qualification results per project / mapping signature
3. Add richer audio-comparison metrics beyond MFCC + duration
4. Expand qualification to mixed MIDI+audio-clip exports
