#!/usr/bin/env python3
"""
Drive the Amira Writer loopback API to generate one 16:9 2K Nano Banana 2 image
per place via the running app on Garys-Laptop. Reference mode is "curated" —
only the master map + the place's own 5★-rated images are attached.

Usage:
    python3 places_api_generate_all.py            # run from Garys-Server, SSHes to laptop
    python3 places_api_generate_all.py --dry-run  # just list the places, no generation

The API is loopback-only on the laptop, so every call is proxied via ssh.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path

API_HOST = "gary@Garys-Laptop.local"
API_BASE = "http://127.0.0.1:19849"

GEN_BODY = {
    "workflow": "photorealistic",
    # model is set per-request from --models (default: flash + pro)
    "aspectRatio": "16:9",
    "imageSize": "2K",
    "referenceMode": "curated",      # master map + 5★ images only
    "count": 1,
}

MODEL_ALIASES = {
    "flash": "flash",                # Nano Banana 2  (gemini-3.1-flash-image-preview)
    "nb2":   "flash",
    "pro":   "pro",                  # Nano Banana Pro (gemini-3-pro-image-preview)
    "nbpro": "pro",
}


def ssh_curl(method: str, path: str, body: dict | None = None) -> dict:
    """Run a curl request inside the laptop via ssh and return parsed JSON."""
    url = f"{API_BASE}{path}"
    if method == "GET":
        remote = f"curl -sS --max-time 600 {shlex.quote(url)}"
    elif method == "POST":
        payload = json.dumps(body or {})
        remote = (
            f"curl -sS --max-time 600 -X POST "
            f"-H 'Content-Type: application/json' "
            f"-d {shlex.quote(payload)} {shlex.quote(url)}"
        )
    else:
        raise ValueError(f"Unsupported method: {method}")

    proc = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=10", API_HOST, remote],
        capture_output=True, text=True, timeout=700,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ssh failure ({proc.returncode}): {proc.stderr.strip()}")
    out = proc.stdout.strip()
    if not out:
        raise RuntimeError(f"empty response from {method} {path}: {proc.stderr.strip()}")
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-JSON response from {method} {path}: {out[:300]}") from exc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="List places and exit; do not generate anything.")
    ap.add_argument("--start-at", type=int, default=0,
                    help="Resume at this 0-based index (useful after interruption).")
    ap.add_argument("--limit", type=int, default=None,
                    help="Only process this many places (for testing).")
    ap.add_argument("--pause", type=float, default=2.5,
                    help="Seconds to pause between successful generations.")
    ap.add_argument("--models", type=str, default="flash,pro",
                    help="Comma-separated model list. Default generates one "
                         "image per place per model (NB2 'flash' and NB Pro "
                         "'pro'). Aliases: nb2=flash, nbpro=pro.")
    ap.add_argument("--log", type=Path,
                    default=Path("/tmp/amira_places_api_generate.log"),
                    help="Path to write a JSONL progress log.")
    args = ap.parse_args()

    # Resolve + validate the model list.
    requested = [m.strip().lower() for m in args.models.split(",") if m.strip()]
    if not requested:
        print("[FATAL] --models must contain at least one entry", file=sys.stderr)
        return 1
    resolved_models: list[str] = []
    for m in requested:
        if m not in MODEL_ALIASES:
            print(f"[FATAL] unknown model '{m}'. "
                  f"Known: {sorted(MODEL_ALIASES.keys())}", file=sys.stderr)
            return 1
        canon = MODEL_ALIASES[m]
        if canon not in resolved_models:
            resolved_models.append(canon)
    print(f"[models] will run: {resolved_models}", flush=True)

    print(f"[health] probing {API_BASE}/health via {API_HOST}…", flush=True)
    health = ssh_curl("GET", "/health")
    print(json.dumps(health, indent=2))
    if not health.get("ok"):
        print("[FATAL] /health did not return ok", file=sys.stderr)
        return 1
    if health.get("backend") != "vertex":
        print(f"[WARN] backend is '{health.get('backend')}', expected 'vertex'. "
              f"Flip it in Inspector → Gemini → Backend before running.")
    if not health.get("geminiAllowed"):
        print("[FATAL] geminiAllowed is false — enable Gemini in Inspector → Tools.",
              file=sys.stderr)
        return 1

    print(f"[places] fetching list…", flush=True)
    places_resp = ssh_curl("GET", "/places")
    places = places_resp.get("places", [])
    if not places:
        print("[FATAL] no places returned", file=sys.stderr)
        return 1

    if args.limit is not None:
        places = places[args.start_at : args.start_at + args.limit]
    else:
        places = places[args.start_at:]
    print(f"[places] {len(places)} place(s) queued (start_at={args.start_at}).", flush=True)

    if args.dry_run:
        for i, p in enumerate(places):
            print(f"  {i:3d}. {p['name']}  hasBrief={p['hasVisualBrief']}")
        return 0

    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("a", encoding="utf-8") as logf:
        started = time.time()
        ok_count = 0
        fail_count = 0
        total_steps = len(places) * len(resolved_models)
        step = 0
        for i, p in enumerate(places):
            idx = i + args.start_at
            name = p["name"]
            place_id = p["id"]
            for model in resolved_models:
                step += 1
                print(f"[{step:3d}/{total_steps}] place #{idx} {name} [{model}] …",
                      flush=True, end=" ")
                t0 = time.time()
                body = dict(GEN_BODY, place=place_id, model=model)
                try:
                    resp = ssh_curl("POST", "/places/generate", body)
                except Exception as exc:
                    fail_count += 1
                    err = f"request failed: {exc}"
                    print(f"FAIL ({err})", flush=True)
                    logf.write(json.dumps({
                        "idx": idx, "name": name, "id": place_id,
                        "model": model, "ok": False, "error": err,
                        "elapsed": round(time.time() - t0, 2),
                    }) + "\n")
                    logf.flush()
                    if args.pause > 0 and step < total_steps:
                        time.sleep(args.pause)
                    continue
                elapsed = round(time.time() - t0, 2)
                if resp.get("ok"):
                    ok_count += 1
                    stored = resp.get("storedPaths", [])
                    refs = resp.get("referenceCount", 0)
                    print(f"ok ({elapsed}s, refs={refs}, {Path(stored[0]).name if stored else '-'})",
                          flush=True)
                else:
                    fail_count += 1
                    print(f"FAIL ({elapsed}s: {resp.get('error', '?')})", flush=True)
                logf.write(json.dumps({
                    "idx": idx, "name": name, "id": place_id,
                    "model": model, "elapsed": elapsed, **resp,
                }) + "\n")
                logf.flush()
                if args.pause > 0 and step < total_steps:
                    time.sleep(args.pause)

    total = round(time.time() - started, 1)
    print(f"\n[done] {ok_count} ok, {fail_count} failed in {total}s. "
          f"Log: {args.log}")
    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
