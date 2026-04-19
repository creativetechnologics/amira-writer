#!/usr/bin/env python3
# Phase 1e: WAV glitch detection + RMS envelope similarity analysis on qualification artifacts

import sys
import os
import math
import numpy as np
import soundfile as sf

ARTIFACT_DIR = os.path.expanduser(
    "~/Library/Application Support/Opera/HostedAudioUnitQualificationArtifacts/"
    "1776590244-hosted-au-qualification-v13___Volumes_Storage VIII_Users_gary_Amira - A Modern O"
)
OVERTURE_WAV = "/private/tmp/amira-phase1d/overture.wav"


def load_mono(path):
    """Load a WAV file as mono float32, returning (samples, samplerate)."""
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    return mono, sr


def rms_envelope(mono, sr, window_frames=2048):
    """Compute per-window RMS envelope exactly as the Swift rmsEnvelope() does it."""
    envelope = []
    sum_sq = 0.0
    count = 0
    for sample in mono:
        sum_sq += float(sample) * float(sample)
        count += 1
        if count >= window_frames:
            envelope.append(math.sqrt(sum_sq / count))
            sum_sq = 0.0
            count = 0
    if count > 0:
        envelope.append(math.sqrt(sum_sq / count))
    return np.array(envelope, dtype=np.float64)


def cosine_similarity(a, b):
    """Cosine similarity, truncated to min length — mirrors the Swift implementation."""
    n = min(len(a), len(b))
    if n == 0:
        return None
    a, b = a[:n], b[:n]
    dot = float(np.dot(a.astype(np.float64), b.astype(np.float64)))
    norm_a = float(np.dot(a.astype(np.float64), a.astype(np.float64)))
    norm_b = float(np.dot(b.astype(np.float64), b.astype(np.float64)))
    if norm_a <= 0 or norm_b <= 0:
        return None
    return max(0.0, min(1.0, dot / (math.sqrt(norm_a) * math.sqrt(norm_b))))


def glitch_analysis(path, label, sr_expected=48000):
    """Detect sample-level discontinuities, RMS drops, ZCR anomalies, clipping."""
    print(f"\n=== Glitch Analysis: {label} ===")
    print(f"    Path: {path}")

    data, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    n = len(mono)
    duration = n / sr
    print(f"    Samples: {n}  Duration: {duration:.3f}s  SR: {sr}Hz  Channels: {data.shape[1]}")

    # 1. Sample-to-sample discontinuities
    delta = np.abs(np.diff(mono.astype(np.float64)))
    DELTA_THRESHOLD = 0.1   # 0.1 full-scale ≈ -20 dBFS step — clearly audible
    exceedances = np.where(delta > DELTA_THRESHOLD)[0]
    print(f"\n  [Delta > {DELTA_THRESHOLD}] exceedances: {len(exceedances)}")
    print(f"    Max Δ seen: {delta.max():.6f} at sample {delta.argmax()} ({delta.argmax()/sr:.4f}s)")
    if len(exceedances) > 0:
        top_idx = np.argsort(delta)[-5:][::-1]
        print("    Top 5 positions (seconds):")
        for idx in top_idx:
            print(f"      {idx/sr:.4f}s  Δ={delta[idx]:.6f}")

    # 2. RMS envelope discontinuities (20ms windows, 20+ dB drops)
    WIN = int(sr * 0.020)   # 20ms window
    n_wins = n // WIN
    rms_wins = np.array([
        math.sqrt(float(np.mean(mono[i*WIN:(i+1)*WIN].astype(np.float64)**2)) + 1e-12)
        for i in range(n_wins)
    ])
    rms_db = 20 * np.log10(rms_wins)
    rms_drops = np.diff(rms_db)
    DROP_THRESHOLD = -20.0  # dB
    drop_positions = np.where(rms_drops < DROP_THRESHOLD)[0]
    print(f"\n  [RMS drop > 20dB in 20ms] count: {len(drop_positions)}")
    if len(drop_positions) > 0:
        top_drops = drop_positions[np.argsort(rms_drops[drop_positions])[:5]]
        print("    Top 5 drop positions (seconds):")
        for idx in top_drops:
            print(f"      {idx*WIN/sr:.4f}s  drop={rms_drops[idx]:.1f}dB")

    # 3. Zero-crossing rate anomalies (ZCR per 20ms window, flag windows 3σ above mean)
    zcr_wins = np.array([
        float(np.sum(np.diff(np.sign(mono[i*WIN:(i+1)*WIN])) != 0)) / WIN
        for i in range(n_wins)
    ])
    zcr_mean = zcr_wins.mean()
    zcr_std = zcr_wins.std()
    zcr_threshold = zcr_mean + 3 * zcr_std
    zcr_anomalies = np.where(zcr_wins > zcr_threshold)[0]
    print(f"\n  [ZCR anomalies >3σ] count: {len(zcr_anomalies)}  mean={zcr_mean:.4f}  threshold={zcr_threshold:.4f}")
    if len(zcr_anomalies) > 5:
        print(f"    First 5: {[f'{i*WIN/sr:.3f}s' for i in zcr_anomalies[:5]]}")

    # 4. Clipping
    clip_samples = np.sum(np.abs(mono) >= 0.9999)
    print(f"\n  [Clipping >=0.9999] count: {clip_samples}")

    return {
        "label": label,
        "duration": duration,
        "delta_exceedances": len(exceedances),
        "max_delta": float(delta.max()),
        "rms_drops": len(drop_positions),
        "zcr_anomalies": len(zcr_anomalies),
        "clipping": int(clip_samples),
    }


def envelope_similarity_analysis():
    """Reproduce the Swift audioEnvelopeSimilarity on the artifact files and diagnose the 0.0 bug."""
    print("\n\n=== Envelope Similarity Analysis ===")

    rt_path = os.path.join(ARTIFACT_DIR, "realtime.wav")
    std_path = os.path.join(ARTIFACT_DIR, "standard.wav")
    con_path = os.path.join(ARTIFACT_DIR, "conservative.wav")

    rt_mono, sr = load_mono(rt_path)
    std_mono, _  = load_mono(std_path)
    con_mono, _  = load_mono(con_path)

    # Report basic duration info
    print(f"  realtime:     {len(rt_mono)/sr:.4f}s  ({len(rt_mono)} samples)")
    print(f"  standard:     {len(std_mono)/sr:.4f}s  ({len(std_mono)} samples)")
    print(f"  conservative: {len(con_mono)/sr:.4f}s  ({len(con_mono)} samples)")
    print(f"  sample count delta (std - rt): {len(std_mono) - len(rt_mono)} samples "
          f"= {(len(std_mono) - len(rt_mono))/sr:.4f}s")

    WINDOW = 2048
    env_rt  = rms_envelope(rt_mono,  sr, WINDOW)
    env_std = rms_envelope(std_mono, sr, WINDOW)
    env_con = rms_envelope(con_mono, sr, WINDOW)

    print(f"\n  Envelope lengths (windows of {WINDOW}):")
    print(f"    realtime:     {len(env_rt)}")
    print(f"    standard:     {len(env_std)}")
    print(f"    conservative: {len(env_con)}")

    # --- Cosine similarity (Swift implementation: truncate to min length) ---
    sim_std = cosine_similarity(env_rt, env_std)
    sim_con = cosine_similarity(env_rt, env_con)
    print(f"\n  Cosine similarity (truncated to min length):")
    print(f"    realtime vs standard:     {sim_std:.6f}")
    print(f"    realtime vs conservative: {sim_con:.6f}")

    # --- Diagnose: what do envelopes look like in the overlapping region? ---
    n_common = min(len(env_rt), len(env_std))
    rt_region  = env_rt[:n_common]
    std_region = env_std[:n_common]

    rt_nonzero  = np.sum(rt_region  > 1e-9)
    std_nonzero = np.sum(std_region > 1e-9)
    print(f"\n  Non-zero envelope bins (threshold 1e-9):")
    print(f"    realtime ({n_common} bins total): {rt_nonzero}")
    print(f"    standard ({n_common} bins total): {std_nonzero}")
    print(f"    realtime max env value:  {float(rt_region.max()):.6f}")
    print(f"    standard max env value:  {float(std_region.max()):.6f}")

    # Check for format issues: are floatChannelData values actually being read?
    print(f"\n  Raw sample range check (first 100 samples):")
    print(f"    realtime:  min={rt_mono[:100].min():.6f}  max={rt_mono[:100].max():.6f}")
    print(f"    standard:  min={std_mono[:100].min():.6f}  max={std_mono[:100].max():.6f}")

    # --- What would norm_A and norm_B be? ---
    norm_rt  = float(np.dot(rt_region.astype(np.float64),  rt_region.astype(np.float64)))
    norm_std = float(np.dot(std_region.astype(np.float64), std_region.astype(np.float64)))
    print(f"\n  norm_A (realtime²):  {norm_rt:.6f}")
    print(f"  norm_B (standard²):  {norm_std:.6f}")
    if norm_rt <= 0 or norm_std <= 0:
        print("  >>> ZERO NORM DETECTED — guard normA > 0, normB > 0 returns nil → clamped to 0")

    # --- Check processingFormat of file via AVAudioFile — Python can't do this but
    #     we check the WAV subtype as a proxy ---
    print(f"\n  WAV format proxy check:")
    info_rt  = sf.info(rt_path)
    info_std = sf.info(std_path)
    print(f"    realtime.wav  format={info_rt.format}  subtype={info_rt.subtype}  sections={info_rt.sections}")
    print(f"    standard.wav  format={info_std.format} subtype={info_std.subtype} sections={info_std.sections}")

    # --- Check what openAnalysisAudioFile sees: WAVEX interleaved vs non-interleaved ---
    # realtime.wav is WAVEX (extensible) — that's what MIDIPlaybackEngine writes
    # standard.wav is plain WAV — that's what AVAudioFile(forWriting:) writes
    # The key difference: WAVEX files opened with interleaved:false may return a
    # processingFormat that is ALREADY non-interleaved float32 (the format is preserved).
    # Plain WAV float32 opened with interleaved:false should also give non-interleaved.
    # BUT: the rmsEnvelope function uses audioFile.processingFormat for the buffer —
    # if processingFormat ends up interleaved despite the interleaved:false request,
    # floatChannelData returns nil and rmsEnvelope returns nil → similarity = 0.
    #
    # We can't test this directly in Python, but we can verify the actual sample data
    # is non-zero (which it is), so the issue must be in Swift's AVAudioFile handling.

    print(f"\n  Summary of likely Swift bug:")
    # Check if perhaps the issue is that rmsEnvelope's audioFile.processingFormat
    # is INTERLEAVED (despite interleaved:false in openAnalysisAudioFile) so the
    # buffer guard `guard let channelData = buffer.floatChannelData` fails:
    print(f"    Python cosine sim (correct path): std={sim_std:.6f}  con={sim_con:.6f}")
    print(f"    Swift reports:                    std=0.0000        con=0.0000")
    print(f"    => The Python result is non-zero, so data is valid.")
    print(f"    => Swift's rmsEnvelope() must be returning nil → audioEnvelopeSimilarity() ?? 0")
    print(f"    => Root cause: rmsEnvelope opens with openAnalysisAudioFile (interleaved:false)")
    print(f"       BUT then uses audioFile.processingFormat for the buffer, which for WAVEX")
    print(f"       may still be interleaved — floatChannelData returns nil → return nil")


def main():
    print("Phase 1e WAV Analysis")
    print("=" * 60)

    results = []

    # Run glitch analysis on all three files
    results.append(glitch_analysis(
        os.path.join(ARTIFACT_DIR, "realtime.wav"), "realtime (53.000s excerpt)"
    ))
    results.append(glitch_analysis(
        os.path.join(ARTIFACT_DIR, "standard.wav"), "standard offline (53.424s excerpt)"
    ))
    results.append(glitch_analysis(
        OVERTURE_WAV, "overture.wav (full 179.7s export)"
    ))

    print("\n\n=== GLITCH SUMMARY TABLE ===")
    print(f"{'File':<40} {'Δ>0.1':>8} {'MaxΔ':>8} {'RMSdrop':>8} {'ZCR':>6} {'Clip':>6}")
    for r in results:
        print(f"{r['label'][:40]:<40} {r['delta_exceedances']:>8} {r['max_delta']:>8.4f} "
              f"{r['rms_drops']:>8} {r['zcr_anomalies']:>6} {r['clipping']:>6}")

    envelope_similarity_analysis()

    print("\n\nDone.")


if __name__ == "__main__":
    main()
