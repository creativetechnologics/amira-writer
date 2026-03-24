# BBC AU Silent WAV Troubleshooting

Date: 2026-03-23
Workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`

This note is for the case where an agent says it can only export a silent WAV because the BBC Symphony Audio Unit is "not installed," even though Gary confirms the Audio Unit is present on the machine.

The key lesson is simple:

**Installed on disk is not the same thing as discoverable by Core Audio / `auval` in the export session.**

## Symptom Pattern

The failure usually looks like this:

- The WAV file is created and has a normal-looking size.
- The PCM payload is all zeroes, or the export is effectively silent.
- Export logs show BBC AU load failures for every instrument.
- The exporter then falls back to SF2 / muted sampler behavior because no usable instrument loaded.

Typical log line:

```text
[Engine] AU load timeout/failed for violins-i: OSStatus error -3000
```

When this happens across the full orchestra, the result is a silent output file rather than a broken-but-audible arrangement.

## What This Usually Means

The problem is usually one of these:

1. The BBC component exists on disk, but Core Audio is not discovering it in the current session.
2. The component is visible in GUI playback, but not to the headless export process.
3. The AU registry / cache is stale.
4. The process environment differs between the app session and the headless exporter.

The important distinction is that **GUI playback working does not prove headless export will see the same AU**.

## Evidence From This Project

We have already seen this exact pattern on Storage VIII:

- The BBC component bundle exists on disk.
- `/Library/Audio` is symlinked into the Storage VIII relocated system data tree.
- `auval -a` still showed only Apple system Audio Units in the failing session.
- The export log reported all 27 BBC instruments timing out or failing to load.
- The resulting WAV was large but silent.

That means the agent should not stop at "the files are installed." It needs to ask:

- Is the AU registered?
- Is the AU visible to `auval`?
- Is the headless exporter running in the same discoverable environment as the GUI app?

## Quick Decision Tree

If the answer to the first question is "yes, installed":

1. Run `auval -a`.
2. Search for `BBC`, `Spitfire`, or `Symphony`.
3. If nothing appears, this is a discovery / registration problem, not a song problem.
4. If the GUI still works but headless export does not, treat it as a session / registry mismatch.

If `auval` does list the BBC component but the export is still silent:

1. Inspect the export log for AU load timeouts.
2. Confirm the exporter is not falling back to muted sampler behavior.
3. Verify the project path and song path are correct.
4. Check whether the current process has permission to access the Audio Unit bundle.

## Commands Worth Trying

```bash
auval -a | rg -i "bbc|spitfire|symphony"
auval -v aumu Sant SpFi
```

If Core Audio looks wedged, a restart of the audio daemon may help:

```bash
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

Use that carefully. If the machine is already healthy, the better fix is to correct AU discovery rather than bouncing audio services repeatedly.

## What Not To Assume

- Do not assume the AU is missing just because the export is silent.
- Do not assume the song data is empty just because the WAV is silent.
- Do not assume GUI playback and headless export use identical Core Audio discovery paths.
- Do not "fix" the issue by replacing the render with generic tones or staccato placeholders.

## Reference Files

- [Suno Generation Handoff](/Volumes/Storage%20VIII/Programming/Novotro%20Opera/Suno/HANDOFF-2026-03-23-SUNO-GENERATION.md)
- [Suno Cover Handoff — 1.01.0 OVERTURE](/Volumes/Storage%20VIII/Programming/Novotro%20Opera/Suno/HANDOFF-2026-03-23-SUNO-COVER-1.01.0-OVERTURE-FAILURE.md)
- [WAV Export Guardrails](/Volumes/Storage%20VIII/Programming/Novotro%20Score/docs/superpowers/WAV-EXPORT-GUARDRAILS.md)
- [Suno Cover Preset Master](/Volumes/Storage%20VIII/Programming/Novotro%20Score/docs/superpowers/SUNO-COVER-PRESET-MASTER.md)

## Bottom Line

If the agent claims "BBC Symphony is not installed" but Gary can see it on disk, the next question is not installation. The next question is:

**Why is the BBC Audio Unit not visible to `auval` / Core Audio in the export session?**

That is the actual failure to solve.
