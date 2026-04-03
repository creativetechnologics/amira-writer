# Lighting Fixture Diff Report

Regression detected: yes

## summary
- removedProfiles: ['night_practical_mix']
- removedLocationBindings: []
- removedPacketLocations: ['family-courtyard']
- oldProfileCount: 5
- newProfileCount: 4
- oldPacketCount: 5
- newPacketCount: 4

## regressions
- [BLOCK] Lighting profile family coverage dropped
- [BLOCK] Duet motion-lighting packet coverage dropped
- [BLOCK] Profile sunset_warm lost required lighting channels
- [BLOCK] family-courtyard lost amira character fixture binding
- [BLOCK] district-clinic-exterior lost packet fixture linkage
- [BLOCK] village-street-night dropped below minimum duet beat coverage

## warnings
- [WARN] village-street-night routing downgraded

