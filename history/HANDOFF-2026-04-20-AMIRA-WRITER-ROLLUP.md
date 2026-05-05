# Handoff — 2026-04-20 — Amira Writer 4-Day Rollup

Audience: **Codex** (or any agent) picking up Amira Writer work after Claude's
session wound down. Covers every commit from **2026-04-17 22:15** through
**2026-04-20 16:38** (74 commits, `9f99321d` → `ffb4f50a` on `main`).

This is intentionally long so you don't have to re-explore the repo cold. If
you only read one thing, read [§0 "How to run and deploy"](#0-how-to-run-and-deploy)
and [§13 "Where things live now"](#13-where-things-live-now).

---

## 0. How to run and deploy

**Build + deploy** (one command, both Macs, do this after any code change):
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
bash Scripts/build-app.sh
```
- On Garys-Server: builds locally, deploys to
  `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`.
- Ad-hoc signed (Developer ID signing fails on SSH — this is **fine**, see
  `feedback_adhoc_signing_fine`). Gary only runs this app on his own Macs.
- **Never** deploy to `~/Applications/` or `/Applications/`. The
  `!Applications/` sync handles propagation between Gary's two Macs.

**Commit every meaningful change.** Gary's explicit rule:
`feedback_commit_after_every_prompt`.

**Repository state at handoff**: clean working tree. `main` is 275 commits
ahead of `origin/main` (not pushed).

---

## 1. Big picture — what shipped in this 4-day window

Roughly four threads ran in parallel. Rough chronology:

| Days | Thread | Outcome |
|------|--------|---------|
| Apr 17 evening | **Unified image grid + All Images workspace** | ✅ shipped |
| Apr 18 all day | **Startup performance (Places, Score, Characters)** | ✅ shipped |
| Apr 18–19 | **BBC SO WAV export — faster-than-realtime attempt** | ⚠️ offline path abandoned; **realtime path with 4096-frame export buffer is the shipping config** |
| Apr 20 morning | **Suno integration — suno-cli subprocess replaces suno-mcp server** | ✅ shipped + cross-machine fix |
| Apr 20 afternoon | **Project layout refactor — Waves A-F** (ProjectPaths type, disk migration, LoRA removal, Canvas/Scenes/Characters restructure) | ✅ shipped |
| Apr 20 late afternoon | **Doc cleanup** — retired broken headless-WAV doc | ✅ shipped |

Each thread is detailed in its own section below.

---

## 2. Unified image grid + All Images workspace (Apr 17 evening)

**Commits**: `9f99321d`, `47ecd4c4`, `de0f1b08`, `382e258f`, `0e26aa9f`,
`533c2c65`, `56b677b3`, `bf56c44e`, `f813ea2b`

**What**: Four-pass rollout to unify every image grid (Characters, All Images,
picker sheets, reference rows) on a single `UnifiedImageTile` component with a
shared context menu and keyboard nav (↑/↓).

- Pass 1 (`9f99321d`): unified context menu + up/down arrow navigation.
- Pass 2 (`47ecd4c4`): Characters + All Images context menus merged.
- Pass 3 (`de0f1b08`): single tile component for every grid.
- Pass 4 (`382e258f`): tile extended into picker sheets + reference rows.
- `0e26aa9f`: All Images rewritten as first-class workspace with shared chrome.
- `533c2c65`: 3D map zoom-in adjustment + debug info panel stripped.
- `56b677b3`: hide 3D map diagnostics by default; fix capture master-map
  fallback; restore All Images inspector split handle.
- `bf56c44e` + `f813ea2b`: fix right-click "Edit with Gemini" on All Images
  (shadow `@State` with `@Bindable` so the sheet actually presents).

**Relevant code**:
- `Packages/Animate/Sources/AnimateUI/Views/UnifiedImageTile.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AllImagesWorkspace*.swift`

**Gotcha (worth remembering)**: `@State` wrapped observables don't propagate to
`.sheet(item:)` presentations. Shadow with `@Bindable` at the call site. This
bit us twice on Apr 17 (`bf56c44e`, `f813ea2b`).

---

## 3. Startup performance sweep (Apr 18, ~20 commits)

**Commits**: `4abf15a0` → `a8938d93` (chronological block 03:03 → 11:33).

Gary's complaint: app showed beach balls on launch, Score and Places pages
were re-indexing on every load. Fixed in waves:

### 3a. Places workspace (`06d03c52` → `74c54828`)
- Staged Places page startup rendering (render-in-waves instead of all at once).
- Reduced derived-data + thumbnail cost on first load.
- Persisted launch caches for Places indexing (`a36794f5`).
- Deferred Places background refresh to library views (`fa9c9577`).
- Heavy Places detail sections staged (`b0a9f947`).
- Places Gemini Generation Studio staged (`9ec62b07`).
- Places notes staged + unified async image previews (`0eb1ee85`).

### 3b. Score + general (`94caebde`, `d9cc0434`, `e2884474`, `a8938d93`)
- Reduced Score and Places startup stalls (`94caebde`).
- Cached Animate backgrounds, async-loaded image editors (`e2884474`).
- Async-loaded props and Imagine gallery scans (`a8938d93`).

### 3c. AU export batching (`0da452c2`, `a55a807b`)
- Batched AU graph updates during WAV export so the graph isn't reconfigured
  per-event.
- Batched remaining AU startup paths for parity.

**Pattern to know**: many of these use a `StagedStartup` helper that does
`Task.yield()` between render phases. If you hit a beach ball regression,
check whether new code added a heavy synchronous chunk before the first frame.

---

## 4. BBC SO WAV export saga (Apr 18–19 — long, worth understanding before touching audio)

This was the marathon thread. Result: **the shipping config is the realtime
path with a 4096-frame export buffer** (commit `ca679fcf`). The offline path
is *present in the code* but not the active shipping path, and should not be
described as a fallback.

### 4a. What Gary wanted
Headless full-mix WAV export of Amira songs using BBC Symphony Orchestra AUs
with **no SF2 fallback and no realtime fallback** — offline only, faster than
realtime. Hard constraints, see `feedback_never_headless_export` memory.

### 4b. What we tried (in order, mostly Apr 18–19)

**Hosted-AU fast offline qualification pipeline** (`b1338f9f`, `01a5aec8`,
`5cb8648c`, `aa011968`, `9f7553d1`, `7369f1d0`, `2fcc83fc`, `25ac63b7`,
`a35fe83e`):
- Added an `auto` mode that renders a short qualification excerpt both offline
  and realtime, compares them with MFCC + RMS envelope similarity + audible
  duration, and promotes offline only if strict thresholds are met.
- Built-in profiles `standard` and `conservative`.
- Persisted qualification cache in Application Support.
- Phase 0 diagnostics showed `standard` profile produced `similarity=0.0000`
  on BBC SO while `conservative` got `0.9754/0.9826` — root cause was
  `renderBlockSize` mismatch with AU internal scheduler (see Engram:
  "Phase 2b standard-vs-conservative root cause").

**Headless Full-Mix launch hook** (`2ed583ac`, `754b7f11`, `2e97e525`,
`bfb68115`, `ba6a79f7`):
- Env-var-driven export mode: set `AMIRA_HEADLESS_FULLMIX_EXPORT=path` and
  `AMIRA_HEADLESS_FULLMIX_SONG=hint` and the app boots headless, renders,
  terminates. Dispatched from `Sources/Opera/OperaApp.swift ->
  applicationDidFinishLaunching` into `ScoreBootstrap.runHeadlessFullMixExport`.
- Use `open --env ...` NOT `launchctl setenv` (the latter doesn't propagate
  to LaunchServices-launched apps).
- dup2 stderr → `AMIRA_HEADLESS_LOG_FILE` for machine-readable markers.

**⚠️ Retired 2026-04-20** (see [§11 below](#11-doc-cleanup-apr-20-late-afternoon)): the env-var headless
path was documented in a canonical doc but **did not actually work
end-to-end from an agent context**. Gary tried it on Apr 19 night and had
to fall back to the HTTP API. The doc was removed on 2026-04-20.

**Offline render click/glitch debugging** (`5de1616f`, `5d2d9a3d`, `b690d900`,
`6150b303`, `bd4ec44f`, `3c0b4b3a`, `9b54e6e4`, `f3187ab0`, `8f691435`):
- Warmup strategies: 4-velocity-pass, 8-iter × vel-100 RR cycle, Round 3 dual-
  velocity, etc. (See Engram: "BBC SO RR-exhaustion warmup — outcome").
- Block-boundary stitch (Fix D): snap note-on frames to block boundaries.
- Post-render cosine deglitch (Fix F) — **reverted** per Gary.
- Block size raise to 4096 — **reverted** after silence.
- Legato retrigger gap (Fix C) — A/B tested, turned out to cause 11/23
  clicks, reverted then re-enabled with block-aligned note-offs (`8f691435`).
- Net result on offline path: clicks reduced but never fully eliminated.

**Realtime path with export-mode buffer** (`ca679fcf`, `def21697`):
- **This is what ships.** `MIDIPlaybackEngine.enterExportMode()` /
  `leaveExportMode()` raises `preferredBufferFrames` and
  `mainMixerNode.installTap` buffer from 1024 → **4096 frames** during WAV
  export. Click-free on BBC SO.
- Prevents macOS auto-termination during export with
  `ProcessInfo.beginActivity([.userInitiated, .latencyCritical,
  .idleSystemSleepDisabled])` + `disableSuddenTermination()`.
- See `ScoreStore.renderChunkToWavViaPlaybackEngine`.

**Audible bounds + envelope fixes** (`f1640262`, `075cc126`, `f2f4c58a`,
`33f2cbbb`):
- `audioAudibleBounds` was using `audioFile.processingFormat` and returning
  `nil`. Force non-interleaved Float32 read format. Now returns finite
  `first`/`last` reliably.
- `rmsEnvelope` had an interleaved-format bug and an EOF-as-error bug; both
  fixed.
- Phase 2a: trimmed offline qualification excerpt tail to realtime audible end.

**Diagnostic infrastructure** (`42c4a030`):
- `Scripts/phase1e-wav-analysis.py` — envelope / glitch / tail analysis.

### 4c. Offline throttle (`ce2c66e1`, Apr 19 evening)
- Added `AMIRA_EXPORT_THROTTLE_SPEED=5.0` env var for per-block sleep cap on
  the abandoned offline render path. Not part of shipping config. Documented
  as "do not set" since offline path is retired.

### 4d. Current state (2026-04-20)
- ✅ `POST /api/export/wav` on the running app works. This is the supported
  WAV-export path for agents (see `docs/API.md` and §11 below).
- ❌ Env-var headless export: code still present, not reliable from agents.
- ❌ Offline-only export: no working path that hits Gary's click-free bar
  with BBC SO.
- The export-buffer fix (`ca679fcf`) + auto-termination guard (`def21697`)
  together give you click-free full-mix WAV on BBC SO via the realtime path
  through the open app.

### 4e. If you resume this thread
- Don't re-propose realtime → offline fallback framing. Per `feedback_never_headless_export`, the offline path is the only acceptable target — but in practice realtime is what works today. Don't spend Opus cycles
  on offline unless Gary explicitly asks.
- **Do not ask Gary to listen to files** (`feedback: Gary is not the product
  tester — I am`).
- Test end-to-end yourself: `resolved song` matches request, WAV duration
  plausible, `done status=success`, spot-check via `afinfo`.

---

## 5. Suno integration — CLI subprocess migration (Apr 20 morning)

**Commits**: `1482127e`, `c7d82c2f`, `1e96c7d5`, `5fa3834f`, `920e4edf`

**What changed**: Replaced the old `suno-mcp` FastAPI HTTP server with a
direct subprocess integration against `suno` (the CLI at
`/Volumes/Storage VIII/Programming/SunoSkill/suno_cli/.venv/bin/suno`).

**Why**: The MCP server was a separate Python process that needed to be
running for Suno generation to work. Having the app shell out to `suno`
directly is simpler, has clearer error surfacing, and lets us parse JSON
responses per-call.

### 5a. Architecture
- `Packages/Score/Sources/ScoreUI/Services/SunoCLIRunner.swift` — spawns
  `suno --profile-dir ... --json <subcommand> ...`, parses last JSON line of
  stdout, maps exit codes (0=ok, 2=CAPTCHA, 3=auth, 4=UI drift, other=runtime).
- `Packages/Score/Sources/ScoreUI/Views/SunoInspectorView.swift` — UI.
- CLI path is overridable via `UserDefaults["sunoCLIPath"]`.
- Profile dir is `~/Library/Application Support/Novotro Score/suno-browser-data/`
  (overridable via `UserDefaults["sunoProfileDir"]`).

### 5b. Wave 1 UI overhaul (`c7d82c2f`)
- Source selector (Mix clip vs Scratch recording vs Upload).
- Prompt/lyrics overrides per song.
- Preset manager for style combinations.

### 5c. Wave 2 multi-song batch (`1e96c7d5`)
- Source = Mix WAV (use the per-song mixdown as the Suno cover input).
- Batch generation across multiple songs.
- Auto-route generated covers back into Mix on completion.

### 5d. Sundry (`5fa3834f`, `920e4edf`)
- Removed dead `resolvedSunoLyricsForCurrentPreset` helper.
- Fixed `sunoMixExportInfo`: use real `Mix/exports/` path + `displayName`
  sanitizer (not the legacy `Suno/renders` path).

### 5e. Cross-machine fix (`ffb4f50a`, Apr 20 16:38 — today)

**Problem** Gary reported: on the laptop, Suno generation failed with
`Suno CLI error: .venv/bin/suno: line 2: .venv/bin/python3: No such file or
directory`. Root cause: the venv's `python` symlink pointed to
`/opt/miniconda3/bin/python`, which exists only on Garys-Server. Storage VIII
is shared between the Macs, but `/opt/miniconda3` is per-machine.

**Fix (infrastructure, outside the repo)**:
- Installed Astral's python-build-standalone CPython 3.13.11 to
  `/Volumes/Storage VIII/Programming/SunoSkill/python-installs/` — truly
  relocatable CPython (stock CPython has `@executable_path` framework refs
  that break when moved; python-build-standalone doesn't).
- Rebuilt `SunoSkill/suno_cli/.venv` with `uv venv --relocatable --python
  <shared-python>`. Both Macs now resolve the symlink chain.
- Installed Chromium to `SunoSkill/.ms-playwright/` (shared, 527 MB) instead
  of per-machine `~/Library/Caches/ms-playwright/`.

**Fix (in-repo)**:
- `SunoCLIRunner.swift` sets `PLAYWRIGHT_BROWSERS_PATH` on subprocess env
  to `SunoCLIRunner.defaultPlaywrightBrowsersPath`
  (`/Volumes/Storage VIII/Programming/SunoSkill/.ms-playwright`). Respects
  pre-existing env-var value.
- `notInstalled` error message now points at the setup script.
- `Scripts/setup-suno-cli.sh` — idempotent recovery. Bootstraps `uv` if
  missing (via Astral's installer), installs Python (skipped if present),
  rebuilds venv from scratch (old one moved to `.venv.old-<ts>`), installs
  suno_cli + playwright, installs Chromium (skipped if present unless
  `--force`), smoke-tests `suno --json browser status`.

**Verified** on Garys-Server: `suno --json browser status` returns
`{"ok": true, ...}` via rebuilt venv + shared Chromium. Deployed binary
(`!Applications/Amira Writer.app`) contains the updated strings.

**Still TODO on this thread**: verify on the laptop. Gary will try when he
picks this back up. If it fails, the error message points him at
`bash Scripts/setup-suno-cli.sh`.

### 5f. Known gotchas
- Suno CAPTCHA: exit code 2 → `SunoCLIError.captcha`. Do not auto-retry (see
  global auth-failure rule). Surface to Gary.
- Suno auth failure: exit code 3 → `SunoCLIError.authFailure`. Same — do not
  retry.
- Playwright browser version is pinned via the installed `playwright` Python
  package (1.58.0 → chromium-1208). If you upgrade playwright, rerun `setup-suno-cli.sh --force` to redownload Chromium.

---

## 6. Project layout refactor — Waves A-F (Apr 20 afternoon)

**Commits**: `39cd8eec`, `7cf556a2`, `675e4d5c`, `ec2074ec`, `ce4cfc9d`,
`7113bbe2`, `7e5c6136`

This was a substantial rearrangement of both the code abstractions for URL
access **and** the on-disk layout of Amira projects.

### 6a. Wave A (`39cd8eec`) — `ProjectPaths` type

Introduced `Packages/ProjectKit/Sources/ProjectKit/ProjectPaths.swift` as
**the single source of truth for project URLs**. Value type with typed
accessors like `project.scenes`, `project.characters(slug: "amira")`,
`project.settings`, etc.

**Why**: string-path concatenation was scattered across ~30 files. Typed
accessors catch typos at compile time, let us repoint storage locations
without caller churn, and document canonical layout in one place.

**Key rule**: **name the accessor by its logical role, not its current
disk path**. When we migrated the disk layout in Wave D, we could repoint
accessor *bodies* without renaming the accessors — zero caller churn for
~25 call sites.

### 6b. Wave B (`7cf556a2`) — remove LoRA character-training code

Removed dead LoRA sheet + training flow. The LoRA UI was moved to being
read-only preview months ago; Wave B deletes the now-unused training code
path. See memory `project_lora_training_flow` for context on what remains
(read-only preview, gallery owns selection via L/K, trigger word = first
name lowercased).

### 6c. Waves C1-C4 — UI restructuring
- **C1** (`675e4d5c`): add Imagine/Reference tabs to Characters page.
- **C2** (`ec2074ec`): wire `ImagineCharactersPageView` into Characters >
  Imagine tab.
- **C3** (`ce4cfc9d`): promote Canvas to a top-level page (it used to be a
  sub-page of Imagine).
- **C4** (`7113bbe2`): rename Imagine workspace to Scenes.

After C1-C4, the top-level pages are now: Write, Characters, Places, Scenes,
Canvas, Score, Mix, Animate.

### 6d. Waves D+E+F (`7e5c6136`) — disk migration + accessor repoint + audit

**Wave D** — disk migration via `Scripts/wave-d-migration.py`:
- 36 `shutil.move` operations (atomic `os.rename` within volume, iCloud/
  Syncthing-safe).
- Dry-run by default, `--execute` to apply.
- Cross-volume checks via `st_dev` comparison.
- Old paths → new canonical paths:
  - `Animate/scenes.json` → `Scenes/scenes.json`
  - `Animate/characters/<slug>/` → `Characters/<slug>/`
  - `Animate/debug/canvas` → `Canvas/`
  - `config/api-credentials.json` → `Settings/api-credentials.json`
  - `Instruments.json` → `Settings/instruments.json`
  - `Suno/renders/` → `Suno/covers/` (rationalized naming)
  - Legacy places / maps JSON → `Places/`
  - Old Animate-3d tree → `_Archive/Animate-3d/`

**Wave E** — repointed ~12 accessors in `ProjectPaths.swift` to the new
canonical locations. Added ~10 new top-level accessors (scenes, places,
canvas, settings, archive, sunoCovers, sunoLogs, placesWorldContextJSON,
placesMasterMapLayersJSON, placesPeopleBriefsJSON, drawThingsPlacesJSON).
Deprecated `config` and `sunoRenders` with `@available(*, deprecated)`.

**Wave F** — code audit. Caught ~10 stray string literals that bypassed
accessors:
- `Packages/Animate/Sources/AnimateUI/Services/ProjectDatabaseBridge.swift`
  — static path constants.
- `Packages/ProjectKit/Sources/ProjectKit/ProjectDatabase.swift` — file
  exclusion + load fallback (dual-key pattern:
  `projectFile(at: "Scenes/scenes.json") ?? projectFile(at: "Animate/scenes.json")`
  keeps the code tolerant of either layout).
- `Packages/ProjectKit/Sources/ProjectKit/ProjectServiceHost.swift` — seeded
  files + `isClientVisibleProjectFile` + `shouldRebuildProjectIndex` prefix
  allowlists.
- `Packages/ProjectKit/Sources/ProjectKit/ProjectConnection.swift` — same
  allowlist.
- `Packages/ProjectKit/Sources/ProjectKit/ProjectMirrorSync.swift` — managed-
  prefix list for rebuild detection.
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` — character asset
  rename logic updated to handle both `Characters/<slug>/` (new) and
  `Animate/characters/<slug>/` (legacy) prefixes. Dual-prefix fallback so
  existing projects keep working.
- `Packages/Animate/Sources/AnimateUI/Views/ImagineCanvasPageView.swift` —
  fallback path `"Animate/debug/canvas"` → `"Canvas"`.
- `Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift` —
  user-facing text reference.
- Credential store docstrings (5 files).

### 6e. Gotchas from this refactor
- **SPM module cache**: after adding the `ProjectPaths` type to `ProjectKit`,
  consumers didn't see it until `swift package clean`. Documented in §28 of
  `SWIFT_UI_MASTER_GUIDE.md`. If you add new public types to `ProjectKit`
  and consumers fail to find them, `swift package clean` first, then rebuild.
- `rmdir Animate/characters/` failed on "Directory not empty" because of
  leftover `.DS_Store`. If you hit this on future migrations, `rm` the
  `.DS_Store` then `rmdir`.
- Accessor-name stability is the #1 reason this migration touched so few
  call sites. Follow that pattern if you rearrange more layout.

---

## 7. Score MiniVolumeKnob fix (Apr 20 16:02, `486ab9e3`)

**What**: Two bugs in one commit.

1. **Dot/value-arc 90° misalignment**: the knob's filled arc ended at one
   angle while the indicator dot drew at a different angle. Fix: one shared
   `indicatorAngle = 135° + n × 270°` used for both arc end and `cos/sin`
   dot position.

2. **Audio-vs-UI mismatch**: UI knob state moved independently of the actual
   audio gain. Fix: route knob changes through
   `MIDIPlaybackEngine.setMappingGain(..)` instead of only mutating UI state.

**Files**:
- `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift`
- `Packages/Score/Sources/ScoreUI/ScoreStore.swift`
- `Packages/Score/Sources/ScoreUI/Views/InstrumentMappingPanel.swift`
- `Packages/Score/Sources/ScoreUI/Views/MixerView.swift`
- `Packages/Score/Sources/ScoreUI/Views/IOSContentView.swift`
- UI lesson also updated in `/Volumes/Storage VIII/Programming/UI Lessons/SWIFT_UI_MASTER_GUIDE.md`.

---

## 8. Environment / build hygiene (Apr 20 16:06, `68d750bb`)

`.gitignore` additions:
- `build2/` — stale build artifact directory that kept re-appearing.
- `.claude/` — Claude Code per-machine session state (different paths on
  server vs laptop, polluting `git status`).

If you see these dirs in `git status`, they're now ignored. Don't commit them.

---

## 9. HTTP API reference doc (Apr 20 16:06, `5ff3db59`, partially reverted in `9eaa5b4e`)

Originally committed two canonical agent-facing reference docs:
- `docs/API.md` — HTTP JSON API on `localhost:19847` (~60 endpoints).
- `docs/HOW-TO-EXPORT-WAV.md` — env-var headless full-mix WAV export recipe.

AGENTS.md and README.md both got "programmatic interfaces" pointer sections.

**Current state after `9eaa5b4e` retirement** (see §11):
- ✅ `docs/API.md` still exists but section 2 (env-var headless interface)
  has been stripped. It now describes only the HTTP API.
- ❌ `docs/HOW-TO-EXPORT-WAV.md` deleted from the repo (copied to
  `~/Desktop/Amira File Removal/` outside the tree).

### 9a. HTTP API quick reference (from `docs/API.md`)
- Bind: `127.0.0.1:19847`, loopback only.
- Activation: **HTTP server only starts after the Score page loads in the
  app**. Polling the port before Score page navigation returns nothing. See
  memory `feedback_score_page_required`.
- Handlers run on `@MainActor` → requests serialize. No high concurrency.
- WAV export via HTTP: `POST /api/song/select` (first!) then
  `POST /api/export/wav`. Always re-read `/api/status` to confirm
  `selectedSongPath` matches. Skipping select exports whatever song is active.
- Source-of-truth Swift: `APIServer.swift`, `APIRouter.swift`,
  `APITypes.swift` (all in `Packages/Score/Sources/ScoreUI/Services/`).

---

## 10. Doc cleanup (Apr 20 late afternoon)

### 10a. Score MiniVolumeKnob (`486ab9e3`) — see §7.

### 10b. OperaApp NSLog debug hook — reverted (uncommitted previously).

### 10c. `build2/` + `.claude/` gitignore (`68d750bb`) — see §8.

---

## 11. Retired headless WAV export doc (Apr 20 16:26, `9eaa5b4e`) {#11-doc-cleanup-apr-20-late-afternoon}

**Why**: `docs/HOW-TO-EXPORT-WAV.md` was committed as canonical in `5ff3db59`,
but Gary's agent tried it on Apr 19 night and could not produce a WAV —
fell back to the HTTP API through the open app. Doc retired.

**What moved**:
- `docs/HOW-TO-EXPORT-WAV.md` → `~/Desktop/Amira File Removal/` (out of repo).
- `Scripts/export-all-songs-batch.py` → same place (was untracked).

**In-repo changes**:
- `AGENTS.md`: collapsed the two "Programmatic Interfaces" and "Headless Full-
  Mix WAV Export (BBC SO)" sections into one. Explicitly marks the env-var
  path as "not a supported agent workflow".
- `README.md`: dropped the HOW-TO-EXPORT-WAV link. Kept API.md link. Flagged
  `POST /api/export/wav` on the running app as the supported path.
- `docs/API.md`: stripped section 2 (env-var table, invocation template,
  verification checklist, song-hint guidance). Replaced with short "use
  POST /api/song/select then POST /api/export/wav" note. Removed headless
  entry points from source-of-truth list.

**Intentionally left intact**: the app-side code (`runHeadlessFullMixExport`,
`OperaApp applicationDidFinishLaunching` env dispatch, `AMIRA_HEADLESS_*` env
vars). This commit retires docs only. If you want to delete the code too,
that's a separate change — treat it as a latent hazard until resolved.

---

## 12. Suno CLI cross-machine fix (Apr 20 16:38, `ffb4f50a`) — see §5e

---

## 13. Where things live now

### 13a. On-disk project layout (post-Wave-D)

For an Amira project at `<project>/`:

```
<project>/
├── <project>.owp                    # project file
├── Characters/
│   └── <slug>/                      # NEW (was Animate/characters/<slug>/)
│       ├── character.json
│       ├── inspiration/
│       ├── generated/
│       ├── reference/
│       └── lora/                    # read-only preview
├── Places/                          # NEW (was scattered)
│   ├── master-map-layers.json
│   ├── world-context.json
│   ├── people-briefs.json
│   └── draw-things-places.json
├── Scenes/                          # NEW (was Animate/)
│   └── scenes.json
├── Canvas/                          # NEW (was Animate/debug/canvas)
│   └── ...
├── Settings/                        # NEW (was config/)
│   ├── api-credentials.json
│   └── instruments.json
├── Score/                           # unchanged
├── Mix/
│   └── exports/                     # Mix WAV per song
├── Suno/
│   ├── covers/                      # NEW (was Suno/renders/)
│   └── logs/
├── _Archive/
│   └── Animate-3d/                  # retired 3D SceneKit tree
└── Animate/                         # legacy fallback — some code still reads here
```

The fallback reads (`projectFile(at: "Scenes/scenes.json") ?? projectFile(at:
"Animate/scenes.json")`) exist so pre-Wave-D projects open without migration.
New data always writes to the canonical top-level location.

### 13b. Shared external resources

Anything that's too big or machine-specific to commit into the repo, stored
on Storage VIII (shared between Garys-Server and Garys-Laptop):

```
/Volumes/Storage VIII/Programming/
├── !Applications/
│   └── Amira Writer.app              # deployed app bundle
├── Amira Writer/                     # this repo
├── SunoSkill/
│   ├── suno_cli/
│   │   ├── src/suno_cli/
│   │   └── .venv/                    # relocatable, symlinks into python-installs
│   ├── python-installs/
│   │   └── cpython-3.13.11-macos-aarch64-none/
│   ├── .ms-playwright/               # 527 MB shared Chromium
│   └── amira-pipeline/               # legacy, unused
├── Novotro Score/                    # older code, not the current app
├── UI Lessons/
│   └── SWIFT_UI_MASTER_GUIDE.md      # READ BEFORE ANY UI WORK
└── Novotro Opera/                    # legacy, fully migrated into Amira Writer
```

### 13c. Swift package layout

```
Amira Writer/
├── Sources/Opera/OperaApp.swift       # app entry
├── Packages/
│   ├── ProjectKit/                    # URLs + project I/O
│   │   ├── ProjectPaths.swift         # SINGLE SOURCE OF TRUTH for paths
│   │   ├── ProjectDatabase.swift
│   │   ├── ProjectServiceHost.swift
│   │   ├── ProjectMirrorSync.swift
│   │   └── ProjectConnection.swift
│   ├── Score/                         # music / MIDI / AU / WAV export
│   │   └── ScoreUI/
│   │       ├── ScoreStore.swift       # @Observable main store
│   │       ├── ScoreBootstrap.swift   # startup + headless hooks
│   │       └── Services/
│   │           ├── APIServer.swift
│   │           ├── APIRouter.swift
│   │           ├── APITypes.swift
│   │           ├── MIDIPlaybackEngine.swift  # export-mode buffer
│   │           └── SunoCLIRunner.swift       # CLI subprocess
│   └── Animate/                       # visuals / characters / scenes / canvas
│       └── AnimateUI/
│           ├── AnimateStore.swift     # @Observable main store
│           ├── Views/
│           │   ├── UnifiedImageTile.swift
│           │   ├── AllImagesWorkspace*.swift
│           │   ├── ImagineCanvasPageView.swift
│           │   └── GeminiSettingsSheet.swift
│           └── Services/
│               ├── GeminiCredentialStore.swift
│               ├── MiniMaxCredentialStore.swift
│               ├── ViduCredentialStore.swift
│               ├── RunPodCredentialStore.swift
│               └── ProjectDatabaseBridge.swift
├── Scripts/
│   ├── build-app.sh                   # THE build+deploy script
│   ├── setup-suno-cli.sh              # new 2026-04-20
│   ├── wave-d-migration.py
│   ├── phase1e-wav-analysis.py
│   └── cleanup-opera-cache.sh
└── docs/
    └── API.md                         # HTTP API reference
```

---

## 14. Pending / known issues

### 14a. Suno CLI on laptop — verification pending
- The Apr 20 16:38 fix is green on Garys-Server. Gary will verify on the
  laptop when he picks this up.
- If it still fails, the error message points at `bash
  Scripts/setup-suno-cli.sh`. That script bootstraps `uv` via Astral's
  installer so it works even if `uv` isn't installed on the laptop.

### 14b. Env-var headless WAV export code still present
- `runHeadlessFullMixExport`, `AMIRA_HEADLESS_FULLMIX_*` env dispatch in
  `OperaApp.applicationDidFinishLaunching`. Doc says "retired" but code is
  still wired. If someone sets the env vars, it still fires. This is a
  latent hazard — either prove it works and bring the doc back, or delete
  the code path. Not urgent.

### 14c. BBC SO click-free export via offline — unsolved
- Gary's original goal (faster-than-realtime offline BBC SO export) did not
  ship. Realtime path with 4096-frame export buffer is what works. If he
  brings this up again, start from the Engram notes ("BBC SO RR-exhaustion
  warmup — outcome", "Fix C A/B click experiment result", "Phase 2b
  standard-vs-conservative root cause") rather than from scratch.

### 14d. Animate-3d archived, Vidu pipeline is new
- See `project_vidu_pipeline` memory. Vidu first/last frame → Q3 video is
  the replacement. Current Vidu integration status is outside this 4-day
  window — check earlier handoffs if you pick it up.

### 14e. `build2/` recovery
- `build2/` was deleted and `.gitignore`d. If your build fails with weird
  cache errors, check that SwiftPM isn't trying to use `build2/` as an
  alternate build dir somewhere.

---

## 15. Rules / conventions you must honor

These came up during this 4-day window and are worth repeating (they're
stored in Engram memory and Gary's CLAUDE.md):

### Gary's hard rules
- **Don't touch apps on Gary's laptop without permission** (`pkill`, `kill`,
  `osascript`, `open`, SSH restarts). Ask first.
- **Never head-screenshot-first** in desktop automation — use
  `desktop_read_ui` / `desktop_find` refs first. Screenshots are ~800 KB of
  tokens each.
- **Auth failures → halt at 2 consecutive failures**, same endpoint. One
  blacklist incident on 2026-04-15 took a site offline for hours.
- **Every Playwright/MCP browser session MUST be explicitly closed**,
  including in error paths. `try { … } finally { await browser.close(); }`.
- **Commit after every prompt** that produces changes.
- **Build + deploy after every code change** — never "verification build"
  without deploy. Only to `!Applications/`.
- **Ad-hoc signing is fine** on Gary's machines (`feedback_adhoc_signing_fine`).
- **Idempotency guards on all recurring ops** — cron, watchers, polling
  loops must check before side effects. Never `remove + recreate` files in
  iCloud/Syncthing folders (creates numbered conflict copies).
- **Don't maintain MEMORY.md or session-log.md by hand** — Engram + the
  cross-agent harness does this.

### Swift / build rules
- **Before any UI work**, read `/Volumes/Storage VIII/Programming/UI Lessons/
  SWIFT_UI_MASTER_GUIDE.md` and follow §27 checklist. Update afterward if
  new lessons learned.
- **macOS 26 minimum** for the app (`@available(macOS 26.0, *)` on stores
  and services).
- **`@Observable @MainActor`** pattern for stores. SwiftPM workspace.
- **`swift package clean`** required after adding public types to
  `ProjectKit` before consumers see them (§28 of guide).

### Code exploration
- **Use jCodemunch** for code navigation (not Read/Grep/Glob/Bash). Exception:
  `Read` required before `Edit`. `plan_turn { repo, query }` is the opening
  move.
- If `search_symbols` returns `verdict: no_implementation_found`, report
  the gap — don't keep searching with new terms.

### AI integrations
- **No auto-Gemini-API calls.** Circuit breaker + rate limit + logging
  mandatory (`feedback_no_auto_api_calls`).
- **No delegation to OpenCode/MiniMax from Amira Writer**. Claude writes the
  code directly. `ImagineScenePromptService` is the only GPT path
  (`project_codex_cli_canonical`).
- **Gemini character-inspiration**: 3-ref cap, identity-lock prompt structure
  (`project_gemini_ref_best_practices`).

### Cross-agent
- `agent_sync.get_project_context` at task start (before re-exploring).
- `agent_sync.record_handoff` after meaningful work.
- `ai-sessions` MCP lets you read raw transcripts from other agents if you
  need exact detail.

---

## 16. Immediate next steps for Codex

If you're picking this up cold:

1. **Verify Suno generation on the laptop** — Gary will try it. If it fails,
   run `bash Scripts/setup-suno-cli.sh` on the laptop first. The script is
   idempotent.
2. **If Gary brings up the headless WAV export again**: it's retired from
   docs but the code is still present. Either prove it works and restore the
   doc, or delete the code path. Don't leave both states.
3. **If Gary brings up beach balls / slow launch**: most of §3 is done but
   there may be stragglers. Profile with Instruments first — don't blindly
   stage more.
4. **If a UI change is requested**: read `SWIFT_UI_MASTER_GUIDE.md` §27
   checklist first. Non-negotiable.
5. **Repo is 275 commits ahead of origin**. If Gary wants to push, check
   with him first — there may be tokens/secrets in old history that should
   be squashed.

---

## 17. Files touched in this window (74 commits)

See `git log --since="2026-04-17 22:00" --name-only` for the full list. High-
churn files:

- `Packages/Score/Sources/ScoreUI/ScoreStore.swift` — BBC SO export saga.
- `Packages/Score/Sources/ScoreUI/ScoreBootstrap.swift` — headless hooks.
- `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` —
  export-mode buffer.
- `Packages/Score/Sources/ScoreUI/Services/SunoCLIRunner.swift` — CLI
  subprocess.
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` — huge file
  (can't fit in context; use jCodemunch).
- `Packages/ProjectKit/Sources/ProjectKit/ProjectPaths.swift` — new in Wave A.
- `Sources/Opera/OperaApp.swift` — headless hook dispatch.

---

## 18. Rehydration hints for Engram

Useful `mem_search` queries if you need more detail:
- `"BBC SO offline export"` — all the click/warmup/block-boundary work
- `"Phase 2b standard-vs-conservative root cause"` — renderBlockSize fix
- `"Fix C A/B click experiment"` — why Fix C was reverted then re-enabled
- `"Suno CLI"` — CLI migration + cross-machine fix
- `"Retired headless WAV export doc"` — today's doc retirement
- `"ProjectPaths"` / `"Waves A B C D E F"` — layout refactor

Use `mem_context project="amira-writer"` at session start.

---

## 19. Handoff close

As of **2026-04-20 16:40**:
- Working tree: clean.
- Branch: `main`, 275 commits ahead of `origin/main`.
- App deployed: `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
- App contains latest Suno PLAYWRIGHT_BROWSERS_PATH wiring (verified via
  `strings` grep of binary).
- All planned work from the 4-day window is committed.

Good luck, Codex. Ping Engram if you lose context.

— Claude (Opus 4.7)
