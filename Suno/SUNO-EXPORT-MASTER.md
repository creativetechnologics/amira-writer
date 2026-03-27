# Suno Export Master

Date: 2026-03-25
Workspace: `/Volumes/Storage VIII/Programming/Amira Writer`

This is the canonical export-only reference for headless WAV creation in the unified Opera repo.
For the full Suno workflow, current status, and batch behavior, follow `HANDOFF.md`.

If any older handoff conflicts with this file, follow this file.

## The Important Migration Fact

`Novotro Score` as a standalone repo is retired.

That does **not** mean the headless export capability is gone.

The code now lives inside the Opera repo here:

- `Packages/NovotroScore/Sources/NovotroScore/NovotroScoreBootstrap.swift`
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Packages/NovotroScore/Package.swift`

The headless export entrypoint still exists as:

```text
NovotroScore --headless-export-wav ...
```

The difference is that the executable now needs to be invoked from the vendored `Packages/NovotroScore` package inside `Amira Writer`, not from the retired standalone `Novotro Score.app` workflow.

One more important detail:

- The root Opera package builds the `NovotroOpera` shell.
- The headless export CLI lives in the vendored `Packages/NovotroScore` package.
- So an agent can miss the export path if it only inspects the root `Package.swift`.

## What The Migration Broke

The migration did not break the render engine itself.

What it broke was the surrounding assumptions:

1. Older notes still pointed at `/Volumes/Storage VIII/Programming/Novotro Score/...`
2. Older wrapper logic assumed `~/Applications/Novotro Score.app/Contents/MacOS/NovotroScore`
3. Agents could confuse `NovotroOpera` with `NovotroScore`
4. The repo-local wrapper script was missing from `Amira Writer`

So the export capability is still present, but the canonical path changed.

## Canonical Headless Export Path

Use this script:

- `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh`

This script:

1. Works directly from the unified Opera repo
2. Does not require opening `Amira Writer.app`
3. Runs the repo-local `NovotroScore` executable in headless mode
4. Reads the `.owp` directly
5. Writes a WAV directly
6. Preserves the Bluetooth/AirPods guard and cooldown guard

## Canonical Command

```bash
/Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/export-headless-wav.sh \
  --project "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera" \
  --song-path "Songs/1.02.0 - PROLOGUE - ARRIVAL - WITNESS.ows" \
  --output "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno/1.02.0 PROLOGUE - ARRIVAL - WITNESS/1.02.0 PROLOGUE - ARRIVAL - WITNESS v001-Upload.wav"
```

This is the preferred no-GUI export path moving forward.

## What Not To Do

- Do not assume the old standalone `Novotro Score` repo is canonical.
- Do not assume `NovotroOpera.app` is the headless export binary.
- Do not point agents at `/Volumes/Storage VIII/Programming/Novotro Score/Scripts/export-headless-wav.sh` as the primary path anymore.
- Do not open the UI just to export a WAV if the goal is a background Suno source render.

## Why This Still Works Without Opening Opera

The render path is in the vendored `NovotroScore` package, not in the windowed shell.

The executable target still exists in:

- `Packages/NovotroScore/Package.swift`

The CLI bootstrap still parses:

- `--headless-export-wav`
- `--project`
- `--output`
- `--song-path`
- `--song-index`
- `--start-tick`
- `--end-tick`
- `--override-sf2`

So the agent can export directly from the `.owp` package without launching the Opera GUI.

Do not assume older historical flags still exist unless they are visible in the current bootstrap.
In particular, older notes discussed flat-velocity experiments, but that is not part of the current documented Opera-local wrapper interface.

## BBC Audio Unit Behavior

For BBC / Audio Unit material, `renderChunkToWav(...)` still switches to the live playback-engine capture path when Audio Units are needed and no SF2 override is supplied.

That behavior lives in:

- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`

Important consequence:

- If BBC AUs are discoverable, the headless export can render the real orchestral instruments.
- If BBC AUs are not discoverable in the current Core Audio session, the export can fail, fall back incorrectly, or produce silence.

## Silent WAV Rule

If the WAV is silent, do **not** immediately conclude that BBC Symphony is "not installed."

Instead ask:

1. Is the BBC AU visible to `auval`?
2. Is the current export session able to discover the AU?
3. Is Core Audio wedged or stale?
4. Is the process environment different from the GUI playback session?

Installed on disk is not enough by itself.

Historical AU/debugging incident notes are archived under `archive/docs/`.

## Fast Troubleshooting

Useful checks:

```bash
auval -a | rg -i "bbc|spitfire|symphony"
auval -v aumu Sant SpFi
```

If `auval` does not see the BBC AU, the problem is discovery / registration, not missing notes.

## Suno Workflow After Export

### Canonical cover presets

Authoritative source:

- `/Volumes/Storage VIII/Programming/Amira Writer/Suno/CANONICAL-SUNO-COVER-PROMPTS.md`

Agents should treat that file as the single source of truth for cover prompt wording, negative prompt, and slider defaults.

Use these exact prompt families:

- `chamber cover`
  `chamber music, adagio for strings, lyrical woodwinds, <voice_mode>, same tempo, same structure, restrained dynamics`
- `orchestral cover`
  `orchestra, classical voice, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies`

Use this exact negative prompt:

- `-drums, -percussion, -cymbals, -snare, -kick`

Use these slider values:

- `0 / 30 / 95`

Voice mode rule:

- Use `classical voice` for vocal covers.
- Use `instrumental` only for instrumental-only results.

Workspace rule:

- Do not force a specific Suno workspace in this workflow.
- Let Suno use its normal current/default workspace state unless Gary asks for
  a workspace-specific run and that path is revalidated first.

Lyrics and gender rule:

- Always pass the real lyrics explicitly for vocal covers.
- Never leave lyrics blank on vocal covers.
- Default genders:
  `Johnny/Luke/Mark/Matt = male`
  `Amira/Yasmin = female`

1. Export the WAV headlessly with the Opera-local script.
2. Inspect the WAV in `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno`.
3. Upload one source song only using Suno's normal create flow.
4. Reuse that one source song for all related cover attempts.
5. Follow the canonical Suno prompt / lyric / gender rules.
6. Name the exported source WAVs as `Base Title v###-Upload.wav` and the
   generated Suno downloads as `Base Title v###-A.wav` / `Base Title v###-B.wav`.

## Short Version

The move to `Amira Writer` did not remove headless export.

It only changed where the authoritative export path lives.

Use the Opera-local wrapper script, target the vendored `Packages/NovotroScore` executable, and treat older `Novotro Score` script paths as historical rather than canonical.
