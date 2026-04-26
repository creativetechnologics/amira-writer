# 09 — Acceptance Tests

## Minimal acceptance test suite

```text
1. Project summary reads:
   - 52 scenes
   - 367 shots
   - 27 places
   - 6 character rig folders

2. World context:
   - uses Places/places-world-context.json
   - resolves period to early 2000s
   - ignores stale mid-2020s duplicate

3. Dry-run:
   - one scene dry-run produces EffectiveShotSpec, ReferenceContract, ShotFrameGenerationPlan
   - zero paid jobs are created

4. References:
   - known place includes approved place image
   - outdoor shot includes map
   - bridge shot includes bridge refs
   - focus character includes correct character package refs
   - pinned refs survive rerun
   - rejected refs do not reappear

5. Frame planning:
   - beginning defaults to generate
   - end uses edit when continuity applies
   - hard cut/new location forces generate
   - missing edit source blocks visibly

6. Frame generation:
   - every paid job writes prompt.txt, response.txt, plan.json
   - variants are recorded
   - approved start/end frame paths are saved

7. Video:
   - cannot queue without approved start/end
   - task record includes provider/model/URLs/prompt/duration/status/output
   - polling/download can resume

8. QA:
   - flags missing character
   - flags wrong place
   - flags wrong period/time-of-day
   - flags style drift
   - retry cap escalates to manual review

9. Manual review:
   - transcript edits are preserved
   - shot spec overrides are preserved
   - reference pins/rejections are preserved
   - frame approvals are preserved
   - QA accept/reject decisions are preserved
```

## Unit test ideas

### Canonical source resolver

```text
testProjectSummaryCounts()
testWorldContextUsesPlacesPath()
testNoNovotroProjectServerDependency()
testStaleAnimateWorldContextIgnored()
```

### Data contracts

```text
testTranscriptShotSpecRoundTrip()
testEffectiveShotSpecRoundTrip()
testReferenceContractRoundTrip()
testShotFrameGenerationPlanRoundTrip()
testGeneratedFrameRecordRoundTrip()
testVideoTaskRecordRoundTrip()
testQAResultRoundTrip()
testRequiredIDsValidate()
```

### Effective shot spec builder

```text
testSceneBackgroundIDResolvesToKnownPlace()
testFocusCharacterSlugResolvesToCharacterRig()
testMissingBackgroundProducesNeedsReview()
testWorldContextInjected()
testAnimatedLookPromptInjectedOrReferenced()
```

### Reference contract resolver

```text
testKnownPlaceIncludesApprovedImage()
testOutdoorShotIncludesMapReference()
testBridgeShotIncludesMapAndBridgeReferences()
testFocusCharacterIncludesIdentityAndCostume()
testMaxReferencesRespectsQuota()
testPinnedReferenceSurvivesRerun()
testRejectedReferenceDoesNotReappear()
```

### Frame plan builder

```text
testBeginningDefaultsToGenerate()
testEndUsesEditWhenBeginningApproved()
testHardCutForcesGenerate()
testNewLocationForcesGenerate()
testMissingEditSourceBlocksVisibly()
testPromptSpellsOutWorldPeriodRegionMaterialsLightingTone()
```

### Frame generation

```text
testGenerateRequiresExecuteMode()
testDryRunCreatesNoPaidJob()
testGeneratedFrameWritesSidecars()
testVariantApprovalStored()
testVideoBlockedUntilStartAndEndApproved()
```

### Video handoff

```text
testVideoQueueRequiresApprovedFrames()
testUploadFailureBlocksQueue()
testVideoTaskRecordWrittenBeforeProviderCall()
testPollingUpdatesStatus()
testDownloadStoresOutputInsideProject()
testFailedTaskRetryCreatesNewAttempt()
```

### QA

```text
testFrameQAFlagsWrongPlace()
testFrameQAFlagsMissingCharacter()
testFrameQAFlagsWrongTimePeriod()
testFrameQAFlagsStyleDrift()
testCorrectionPromptTargetsFailure()
testRetryCapEscalatesToManualReview()
```

## Smoke test: one-scene dry-run

Expected sequence:

```text
1. Open Animate workspace.
2. GET /automation/project/summary.
3. Select scene with backgroundID.
4. GET /automation/scenes/{sceneID}/effective-shot-specs.
5. POST /automation/references/resolve with mode=dry_run.
6. POST /automation/frame-plans/dry-run.
7. Verify report includes blockers, cost estimate, refs, planned moments.
8. Verify no generated images or video tasks are created.
```

## Smoke test: one-shot frame generation

Expected sequence:

```text
1. Resolve effective shot spec.
2. Resolve and save reference contract.
3. Build frame plan.
4. Generate beginning frame with explicit execute mode.
5. Verify sidecars.
6. Approve one beginning variant.
7. Generate end frame.
8. Verify end uses edit mode when appropriate.
9. Approve one end variant.
10. Verify video queue becomes eligible.
```

## Smoke test: video handoff

Expected sequence:

```text
1. Use approved beginning/end frames.
2. Queue Vidu task.
3. Verify task record written before provider call.
4. Poll task.
5. Download output.
6. Store output under `Animate/video-tasks`.
7. Run video QA.
```
