#!/usr/bin/env python3
"""Targeted retry for THE CONFESSION cover (job 3).

Re-exports a fresh WAV and retries the Suno cover with the 120s upload-polling fix.
Run after the main test_cover_variants.py has completed, when only job 3 needs a redo.
"""

from __future__ import annotations

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Re-use everything from the main test module
from test_cover_variants import (
    ORCHESTRAL_VOCAL,
    CONFESSION_LYRICS,
    NEGATIVE,
    PREVIEWS,
    LOG,
    export_song,
    run_job,
    log_event,
)

CONFESSION_JOB = {
    "name": "3. THE CONFESSION (orchestral vocal, male)",
    "base_title": "2.09.0 THE CONFESSION",
    "style": ORCHESTRAL_VOCAL,
    "lyrics": CONFESSION_LYRICS,
    "gender": "male",
}

SONG_FILE = "2.09.0 - THE CONFESSION.ows"


def main():
    print("\n" + "=" * 70)
    print("  CONFESSION RETRY — fresh WAV export + Suno cover")
    print("=" * 70 + "\n")

    log_event("retry_start", job=CONFESSION_JOB["name"])

    # Phase 1: Fresh WAV export
    print("PHASE 1: Exporting fresh WAV for THE CONFESSION...")
    try:
        upload_path = export_song(CONFESSION_JOB["base_title"], SONG_FILE)
        print(f"  ✅ Exported: {upload_path.name} ({upload_path.stat().st_size / 1048576:.1f} MB)")
    except Exception as exc:
        print(f"  ❌ Export failed: {exc}")
        log_event("retry_export_error", job=CONFESSION_JOB["name"], error=str(exc))
        sys.exit(1)

    # Phase 2: Create cover
    print("\nPHASE 2: Creating Suno cover...")
    result = run_job(CONFESSION_JOB, upload_path)

    print("\n" + "=" * 70)
    print("  RESULT")
    print("=" * 70)
    status = result["status"]
    icon = "✅" if status == "done" else "⚠️" if status == "captcha" else "❌"
    print(f"  {icon} {result['job']}: {status}")
    if "song_ids" in result:
        for sid in result["song_ids"]:
            print(f"      ID: {sid}")
    if "error" in result:
        print(f"      Error: {result['error']}")
    print("=" * 70)

    log_event("retry_complete", result=result)
    sys.exit(0 if status == "done" else 1)


if __name__ == "__main__":
    main()
