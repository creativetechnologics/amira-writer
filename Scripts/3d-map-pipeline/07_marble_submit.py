#!/usr/bin/env python3
"""Phase H — Submit the expanded map to the World Labs Marble API.

API: https://api.worldlabs.ai/marble/v1
Auth header: WLT-Api-Key

Flow:
  1. prepare_upload -> signed URL for our image
  2. PUT image to signed URL
  3. POST /worlds:generate with the uploaded asset
  4. poll /operations/{id} every 10s until done (~5 min)
  5. download SPZ splat + GLB collider into viewer/public/marble/

Reads the API key from (in priority order):
  $WLT_API_KEY
  ~/.config/worldlabs/api_key
"""
from __future__ import annotations
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


IMAGE_PATH = C.EXPANDED_MAP
PROMPT = (
    "A remote Himalayan-style valley with a central village beside a glacial river, "
    "ancient stone houses clustered on the north bank, a stone bridge crossing the river, "
    "rugged rocky mountains with snow patches to the east, bright midday sunlight. "
    "Top-down aerial scene for explorable 3D reconstruction."
)
OUT_DIR = C.VIEWER_PUBLIC / "marble"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def load_key() -> str | None:
    k = os.environ.get("WLT_API_KEY")
    if k:
        return k.strip()
    if C.WLT_KEY_FILE.exists():
        return C.WLT_KEY_FILE.read_text().strip()
    return None


def req(method: str, url: str, key: str, body: bytes | dict | None = None,
        content_type: str = "application/json") -> tuple[int, dict]:
    headers = {"WLT-Api-Key": key}
    data: bytes | None
    if isinstance(body, dict):
        data = json.dumps(body).encode()
        headers["Content-Type"] = content_type
    elif isinstance(body, (bytes, bytearray)):
        data = bytes(body)
        headers["Content-Type"] = content_type
    else:
        data = None
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw.decode())
            except Exception:
                return resp.status, {"_raw": raw[:200].decode(errors="replace")}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        print(f"[H] HTTP {e.code} {e.reason}: {raw[:400]}")
        return e.code, {"error": raw}


def upload_via_signed(signed_url: str, path: Path) -> None:
    # Signed PUT to the media server. No API key on this request.
    with path.open("rb") as f:
        data = f.read()
    r = urllib.request.Request(signed_url, data=data, method="PUT",
                               headers={"Content-Type": "image/jpeg"})
    with urllib.request.urlopen(r, timeout=600) as resp:
        print(f"[H] upload status {resp.status}")


def main() -> None:
    key = load_key()
    if not key:
        print("[H] no WLT API key found.")
        print("    set $WLT_API_KEY or put the key in ~/.config/worldlabs/api_key")
        print("    (create it from https://platform.worldlabs.ai )")
        return

    if not IMAGE_PATH.exists():
        print(f"[H] image missing: {IMAGE_PATH}")
        return

    print(f"[H] requesting signed upload for {IMAGE_PATH.name}")
    code, body = req("POST", f"{C.MARBLE_BASE}/media-assets:prepare_upload",
                     key,
                     {"filename": IMAGE_PATH.name, "content_type": "image/jpeg"})
    if code >= 400:
        print(f"[H] prepare_upload failed ({code}). Aborting.")
        return
    signed_url = body.get("upload_url") or body.get("signed_url") or body.get("url")
    asset_ref = body.get("asset_id") or body.get("asset_ref") or body.get("id") or body.get("asset")
    print(f"[H] upload_url ok, asset_ref={asset_ref}")
    upload_via_signed(signed_url, IMAGE_PATH)

    print("[H] submitting generation job")
    gen_body = {
        "model": C.MARBLE_MODEL,
        "input": {"image_asset_id": asset_ref, "text_prompt": PROMPT},
    }
    code, body = req("POST", f"{C.MARBLE_BASE}/worlds:generate", key, gen_body)
    if code >= 400:
        print(f"[H] worlds:generate failed ({code}).")
        print(json.dumps(body, indent=2)[:500])
        return
    op_id = body.get("operation_id") or body.get("name") or body.get("id")
    print(f"[H] operation={op_id}")

    print("[H] polling…")
    deadline = time.time() + 30 * 60
    while time.time() < deadline:
        time.sleep(10)
        code, op = req("GET", f"{C.MARBLE_BASE}/operations/{op_id}", key)
        if code >= 400:
            print(f"[H] poll failed ({code})")
            continue
        state_s = op.get("state") or op.get("status")
        print(f"    state={state_s}")
        if state_s in {"SUCCEEDED", "DONE", "COMPLETED"}:
            break
        if state_s in {"FAILED", "CANCELLED", "ERROR"}:
            print(f"[H] generation failed: {op}")
            return
    else:
        print("[H] timed out waiting for operation")
        return

    result = op.get("result") or op
    (OUT_DIR / "marble_result.json").write_text(json.dumps(result, indent=2))
    print("[H] saved marble_result.json. Asset download links (if any):")
    assets = result.get("assets") or []
    for a in assets:
        url = a.get("url") or a.get("download_url")
        kind = a.get("kind") or a.get("type")
        if not url:
            continue
        fn = OUT_DIR / (a.get("filename") or f"{kind}.bin")
        print(f"    {kind}  {fn.name}  <-  {url}")
        try:
            urllib.request.urlretrieve(url, fn)
        except Exception as e:
            print(f"    download failed: {e}")


if __name__ == "__main__":
    main()
