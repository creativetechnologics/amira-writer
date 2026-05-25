# Refactor Execution Game Plan

**Date:** 2026-05-24
**Workspace:** `/Volumes/Storage VIII/Programming/Amira Writer`
**Checkpoint:** `pre-refactor-checkpoint-20260524`
**Primary verification:** `/usr/bin/swift build -c release`

This plan is the execution order for the remaining cleanup and monolith-splitting work. It supersedes the raw order in `2026-05-24-monolith-splitting-plan.md` where current worktree risk changes the priority.

## Current Reality

The worktree already contains a large uncommitted refactor batch:

| Area | State |
| --- | --- |
| Shared ProjectKit models | In progress, uncommitted |
| CharactersPageView extraction | Mostly complete, uncommitted |
| PlacesPageView extraction | Several cards extracted, uncommitted |
| Animate ProjectDatabaseBridge JSON coders | Complete, uncommitted |
| Retired cloud-music integration | Archived outside the repo and removed from live app code |
| CharacterReferenceWorkflowSheet section conversion | Should be treated as reverted/high-risk unless rechecked |

The first execution objective is not another large extraction. It is to make the current batch compile cleanly and establish a reliable baseline.

## Non-Negotiable Execution Rules

| Rule | Reason |
| --- | --- |
| Use `/usr/bin/swift build -c release`, not `rtk swift build` | `rtk` has reported misleading status/cache behavior in this repo |
| Build after every extraction step | The refactor changes Swift type visibility and view bindings |
| Deploy after any successful code-change batch that produces the app | Global project requirement: deploy to `/Volumes/Storage VIII/Programming/!Applications/` |
| Do not mass-regex move functions between stores | Previous broad store-move attempts produced invalid declarations and mixed ownership |
| Preserve parent facades while moving internals | Avoid breaking existing views/API call sites during extraction |
| Prefer one self-contained view or domain per edit | Keeps failures small and reversible |

## Phase 0: Stabilize The Existing Worktree

Goal: prove the current dirty state is buildable before adding risk.

| Step | Action | Gate |
| --- | --- | --- |
| 0.1 | Check `git status --short` and note all untracked Swift files | No unexpected generated/secrets files |
| 0.2 | Run `/usr/bin/swift build -c release` | Must compile |
| 0.3 | If the build fails on stale package state, run `swift package clean`, then rebuild | Must compile after clean |
| 0.4 | If the build fails on deleted retired-feature symbols/resources, remove the stale call site instead of restoring the integration | Build passes |
| 0.5 | Reindex/register edited Swift files with jCodemunch after stabilization | Navigation reflects current files |

Decision point: if Phase 0 cannot be made green quickly, stop and fix the baseline only. Do not start a new extraction on a failing baseline.

## Phase 1: Finish Low-Risk View Cleanup

Goal: complete the safe decomposition work before touching store ownership.

| Priority | Task | Approach | Gate |
| --- | --- | --- | --- |
| 1 | `InstrumentMappingPanel.swift` extraction | Extract self-contained subviews only. Do not replace the full panel with a summary panel. Keep full editing behavior. | Build passes |
| 2 | `nilIfEmpty` access fix | Do not expose the existing `private extension String` globally unless necessary. Prefer a local helper or move the exact helper with the extracted code. | Build passes |
| 3 | Remaining small `DisclosureGroup` conversions | Convert only small, brace-simple groups to `OperaChromeCollapsibleSection`. Skip `CharacterReferenceWorkflowSheet` unless manually reworked. | Build passes |
| 4 | `PlacesPageView` remaining subviews | Continue one brace-balanced component at a time: world map panel, landmarks panel, modal/card helpers. | Build passes |

Important guardrails:

| Guardrail | Detail |
| --- | --- |
| `ScoreInstrumentSummaryPanel` | Do not reintroduce the prior summary-only replacement. It caused a behavioral regression by bypassing full track editing. |
| `CharacterReferenceWorkflowSheet` | Treat conversion as optional/high-risk. Earlier automation failed due to deep nested return/brace structure. |
| `DisclosureGroup` conversion | Wrapper-only conversions are safe only when the content body is structurally simple. |

Deploy after Phase 1 if any code changed and the release build succeeds.

## Phase 2: Post-Removal Score Cleanup

Goal: use the smaller post-removal `ScoreStore` as the new baseline, then extract low-risk domains without reintroducing retired cloud-music integration.

| Step | Action | Gate |
| --- | --- | --- |
| 2.1 | Run a non-`.build` audit for retired cloud-music strings and delete stale docs/scripts, keeping only intentional guard tests | Audit returns only guard strings |
| 2.2 | Re-enable focused test targets that already have tests, starting with `MixTests` | Targeted tests run instead of reporting 0 tests |
| 2.3 | Extract tiny ScoreStore extension domains first: audio buffer/device setters, version CRUD, read-only analysis helpers | Build passes after each move |
| 2.4 | Extract API lifecycle/diagnostics once the small extension pattern is proven | Build passes |
| 2.5 | Extract export orchestration last; pass explicit snapshots into long-running async export work | Build passes |

Retired-feature rule: if a build error references removed cloud-music types, resources, paths, API endpoints, or CLI helpers, remove the stale reference. Do not restore compatibility shims.

Deploy after Phase 2.

## Phase 3: Split MIDIPlaybackEngine Before Bigger Stores

Goal: reduce the smallest monolith first using a facade pattern, with no Score UI changes.

| Step | New File | Move | External API Strategy | Gate |
| --- | --- | --- | --- | --- |
| 3.1 | `MetronomeEngine.swift` | Metronome buffers, node state, enable/gain/time-signature functions | Keep `MIDIPlaybackEngine` wrapper properties/methods | Build passes |
| 3.2 | `RecordingEngine.swift` | Recording files, mixdown state, loop recording, callbacks | Keep `MIDIPlaybackEngine` start/stop wrappers | Build passes |
| 3.3 | `MeterManager.swift` | Meter tap levels, publish timer, peak calculations | Keep `leftPeakDB`/`rightPeakDB` wrappers | Build passes |
| 3.4 | `ExportBufferConfig.swift` | Offline/export buffer flags and helpers | Keep parent export configuration API | Build passes |

Preferred dependency style: start with sub-engines owned by `MIDIPlaybackEngine` and parent wrappers. Do not make ScoreStore talk to sub-engines directly in this phase.

Deploy after Phase 3.

## Phase 4: Split ScoreStore After Removal

Goal: keep ScoreStore as a facade/coordinator while extracting read-heavy domains.

| Order | New Store | Why This Order | Gate |
| --- | --- | --- | --- |
| 4.1 | `VersionManager` | Small, low-risk CRUD over song versions | Build passes |
| 4.2 | `MusicIntelligenceStore` | Mostly analysis/read-only | Build passes |
| 4.3 | `APIStore` | API lifecycle/diagnostics can delegate through parent | Build passes |
| 4.4 | `CompositionStore` | LLM/MidiAI/style logic is separable and mostly read-only | Build passes |
| 4.5 | `ExportStore` | Largest Score extraction; do after smaller patterns are proven | Build passes |

Export rule: long-running export functions should receive explicit snapshots of notes, mappings, selected asset, tempo, and output paths where practical. Prefer snapshots over a weak parent reference inside long async work.

Do not extract the piano-roll editing core, playback orchestration, or instrument mapping data ownership yet. Those remain ScoreStore core until all low-risk domains are out.

Deploy after Phase 4.

## Phase 5: Split AnimateStore In Risk Layers

Goal: shrink AnimateStore without destabilizing Characters/Places workflows.

| Layer | Domains | Strategy | Gate |
| --- | --- | --- | --- |
| 5A | Settings, canvas, eraser/crop, lip sync, video export, camera, batch, LLM plan | Extract first. These are small and mostly self-contained. | Build passes after each store |
| 5B | Motion capture and NLA timeline | Extract after small settings stores. Keep timeline/current-frame access explicit. | Build passes after each store |
| 5C | Character CRUD/profile/reference/inspiration images | Use facade wrappers and avoid changing all views at once. | Build passes after each store |
| 5D | Backgrounds/Places nested monolith | Split internally before true extraction. Start with `PlaceGenerationEngine`, then `BackgroundStore`, then `PlaceAngleManager`. | Build passes after each internal split |
| 5E | Computed section and OWP coordinator | Dissolve computed helpers into owning domains only after domains exist. | Build passes |

AnimateStore facade rule: keep existing `store.characters`, `store.backgrounds`, and other heavily used entry points alive as wrappers until the relevant views are migrated deliberately.

Places rule: do not attempt a single 8,700-line Backgrounds/Places extraction. First separate generation queue/cancellation/credits from CRUD/filtering/indexing.

Deploy after each completed Animate layer.

## Verification Cadence

| Scope | Command |
| --- | --- |
| After every small extraction | `/usr/bin/swift build -c release` |
| If SwiftPM reports stale/missing generated inputs | `swift package clean`, then `/usr/bin/swift build -c release` |
| After each phase that changes app code | `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh` |
| After deployment | Confirm `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app` was updated |

Tests are useful where they already pass, but this repo has known pre-existing test issues. The release app build is the required gate for these refactors.

## Stop Conditions

Stop and reassess if any of these happen:

| Stop Condition | Response |
| --- | --- |
| A build failure spans unrelated changed files | Fix the current step only; do not continue extracting |
| A move requires broad access-level changes across many files | Switch to facade wrappers or smaller extraction |
| A view loses editing capability or changes behavior | Revert that extraction step only |
| A deleted retired-feature type seems needed by an active workflow | stop and identify the active behavior before adding replacement code |
| Animate Places extraction touches generation, CRUD, credits, and persistence in one edit | split the edit smaller |

## Recommended Next Execution Step

Start with the final retired-feature audit, then re-enable focused tests and proceed to either small Places view extractions or the first `MIDIPlaybackEngine` support extraction. Build immediately after each slice.
