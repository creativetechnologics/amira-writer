# Ensemble Routing Diff Report

Regression detected: yes

## summary
- oldComparisonCount: 5
- newComparisonCount: 4
- removedLocations: ['family-courtyard']

## regressions
- [BLOCK] Ensemble routing location coverage dropped
- [BLOCK] clinic-interior-fluorescent lost required routing modes
- [BLOCK] district-clinic-exterior baseline collapsed to ai-video-fallback
- [BLOCK] village-street-night should not baseline internal at 5+ participants
- [BLOCK] village-street-night ensemble should remain hybrid-biased

## warnings
- [WARN] clinic-interior-fluorescent decision rationale shrank
- [WARN] district-clinic-exterior participant count dropped
- [WARN] district-clinic-exterior decision rationale shrank
- [WARN] rooftop-sunset decision rationale shrank
- [WARN] village-street-night decision rationale shrank

