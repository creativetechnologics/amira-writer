#!/usr/bin/env python3
import base64
import io
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

import requests
from PIL import Image

PROJECT_ROOT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
ANIMATE_DIR = PROJECT_ROOT / "Animate"
SCENES_PATH = ANIMATE_DIR / "scenes.json"
PLACES_PATH = PROJECT_ROOT / "Places" / "places.json"
SONG_PATH = PROJECT_ROOT / "Songs" / "1.05.0 - Silver.ows"
BACKGROUND_DIR = ANIMATE_DIR / "backgrounds"
OBJECT_DIR = ANIMATE_DIR / "objects" / "silver"
BACKUP_DIR = PROJECT_ROOT / "Metadata" / "safety_backups" / f"{time.strftime('%Y%m%d_%H%M%S')}_silver_placeholder_generation"
SESSION_DIR = ANIMATE_DIR / "generated" / "silver" / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
MODEL = "gemini-3.1-flash-image-preview"
BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
API_TIMEOUT = 600

MARK_REF = PROJECT_ROOT / "Animate" / "characters" / "mark-price" / "reference-workflow" / "master-sheet" / "master-sheet-2026-03-31T163802Z.png"
JOHNNY_REF = PROJECT_ROOT / "Animate" / "characters" / "johnny-ward" / "reference-workflow" / "master-sheet" / "master-sheet-2026-03-31T080959Z.png"
MARK_RIG = PROJECT_ROOT / "Animate" / "characters" / "mark-price" / "rig.json"
JOHNNY_RIG = PROJECT_ROOT / "Animate" / "characters" / "johnny-ward" / "rig.json"


def load_api_key() -> str:
    for env_name in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_API_KEY"):
        env_value = (os.environ.get(env_name) or "").strip()
        if env_value:
            return env_value
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-w",
            "-s",
            "com.amira.writer.animate",
            "-a",
            "gemini-api-key",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    key = result.stdout.strip()
    if not key:
        raise RuntimeError("Gemini API key not found in macOS Keychain for com.amira.writer.animate/gemini-api-key")
    return key


def ref_image(path: Path) -> dict:
    data = path.read_bytes()
    ext = path.suffix.lower()
    mime = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
    }.get(ext, "image/png")
    return {
        "inlineData": {
            "mimeType": mime,
            "data": base64.b64encode(data).decode("utf-8"),
        }
    }


@dataclass
class AssetSpec:
    key: str
    filename: str
    prompt: str
    aspect_ratio: str
    refs: list
    chroma_key: bool


ASSETS = [
    AssetSpec(
        key="background_corridor",
        filename="silver-base-corridor-midday.png",
        aspect_ratio="21:9",
        refs=[],
        chroma_key=False,
        prompt=(
            "Create a 2D animated feature-film background plate for an original opera scene. "
            "Empty military base corridor outside a briefing room at midday. Cold fluorescent ceiling lights, "
            "cool silver-blue palette, brushed metal, institutional walls, subtle window spill, clean depth perspective, "
            "a communications desk in the left foreground, corridor continuing behind, cinematic but readable for blocking. "
            "Cel-shaded anime-inspired production background, no characters, no text, no watermark."
        ),
    ),
    AssetSpec(
        key="mark_seated",
        filename="mark-seated-logbook.png",
        aspect_ratio="3:4",
        refs=[MARK_REF],
        chroma_key=True,
        prompt=(
            "Using the provided reference sheet for the same character identity, create one clean 2D production placeholder cutout sprite. "
            "Mark Price seated at a military communications desk, turned slightly right, drained and controlled, hands near an open logbook. "
            "Full figure visible, mature cel-shaded animated-film style, clean silhouette, centered composition. "
            "Background must be a pure solid chroma green only with no props, no floor, no extra elements, no text."
        ),
    ),
    AssetSpec(
        key="mark_standing",
        filename="mark-standing-guarded.png",
        aspect_ratio="3:4",
        refs=[MARK_REF],
        chroma_key=True,
        prompt=(
            "Using the provided reference sheet for the same character identity, create one clean 2D production placeholder cutout sprite. "
            "Mark Price standing and clutching a logbook against his chest like a shield, guarded, emotionally closed, facing slightly right. "
            "Full figure visible, mature cel-shaded animated-film style, clean silhouette, centered composition. "
            "Background must be a pure solid chroma green only with no environment, no floor, no text."
        ),
    ),
    AssetSpec(
        key="johnny_guarded",
        filename="johnny-guarded-camera.png",
        aspect_ratio="3:4",
        refs=[JOHNNY_REF],
        chroma_key=True,
        prompt=(
            "Using the provided reference sheet for the same character identity, create one clean 2D production placeholder cutout sprite. "
            "Johnny Ward standing in a guarded pose with a camera in one hand and dog tags visible, facing slightly left. "
            "Full figure visible, restrained expression, mature cel-shaded animated-film style, clean silhouette, centered composition. "
            "Background must be a pure solid chroma green only with no environment, no text."
        ),
    ),
    AssetSpec(
        key="johnny_emotional",
        filename="johnny-emotional-window.png",
        aspect_ratio="3:4",
        refs=[JOHNNY_REF],
        chroma_key=True,
        prompt=(
            "Using the provided reference sheet for the same character identity, create one clean 2D production placeholder cutout sprite. "
            "Johnny Ward in an emotional witness pose, camera in hand, frustrated but controlled, left-facing three-quarter/profile feel as if near a window. "
            "Full figure visible, mature cel-shaded animated-film style, clean silhouette, centered composition. "
            "Background must be a pure solid chroma green only with no environment, no floor, no text."
        ),
    ),
    AssetSpec(
        key="comms_desk",
        filename="comms-desk.png",
        aspect_ratio="4:3",
        refs=[],
        chroma_key=True,
        prompt=(
            "Create an isolated 2D production placeholder prop sprite of a military communications desk. "
            "Front-facing three-quarter readable angle, compact field desk with radio paperwork surface, muted silver and olive military palette, cel-shaded animated-film style. "
            "Background must be pure solid chroma green only, no characters, no text."
        ),
    ),
    AssetSpec(
        key="mark_logbook",
        filename="mark-logbook-open.png",
        aspect_ratio="4:3",
        refs=[],
        chroma_key=True,
        prompt=(
            "Create an isolated 2D production placeholder prop sprite of an open military logbook. "
            "Readable from a medium front angle, slightly worn pages, utilitarian wartime notebook, cel-shaded animated-film style. "
            "Background must be pure solid chroma green only, no hands, no desk, no text."
        ),
    ),
]


def generate_asset(api_key: str, spec: AssetSpec) -> dict:
    parts = [{"text": spec.prompt}]
    for ref in spec.refs:
        parts.append(ref_image(ref))
    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "imageConfig": {
                "aspectRatio": spec.aspect_ratio,
                "imageSize": "1K",
            },
        },
    }
    url = f"{BASE_URL}/{MODEL}:generateContent"
    last_error = None
    for attempt in range(1, 4):
        response = requests.post(
            url,
            headers={
                "Content-Type": "application/json",
                "x-goog-api-key": api_key,
            },
            json=payload,
            timeout=API_TIMEOUT,
        )
        if response.status_code != 200:
            last_error = f"HTTP {response.status_code}: {response.text[:800]}"
            time.sleep(2 * attempt)
            continue
        data = response.json()
        candidates = data.get("candidates") or []
        if not candidates:
            last_error = f"No candidates in response: {data}"
            time.sleep(2 * attempt)
            continue
        parts = candidates[0].get("content", {}).get("parts", [])
        text_response = None
        image_bytes = None
        for part in parts:
            if "text" in part:
                text_response = part["text"]
            inline = part.get("inlineData")
            if inline and inline.get("data"):
                image_bytes = base64.b64decode(inline["data"])
        if image_bytes:
            return {
                "request": payload,
                "response_text": text_response,
                "image_bytes": image_bytes,
            }
        last_error = f"No image bytes in response: {data}"
        time.sleep(2 * attempt)
    raise RuntimeError(f"Failed to generate {spec.key}: {last_error}")


def remove_green(bytes_in: bytes) -> bytes:
    image = Image.open(io.BytesIO(bytes_in)).convert("RGBA")
    pixels = image.load()
    width, height = image.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            # chroma key for strong greens while preserving other tones
            green_strength = g - max(r, b)
            if g > 90 and green_strength > 35 and g > r * 1.18 and g > b * 1.18:
                distance = min(255, max(0, green_strength * 4))
                new_alpha = max(0, 255 - distance)
                pixels[x, y] = (r, g, b, new_alpha if new_alpha < 36 else 0)
    alpha = image.getchannel("A")
    bbox = alpha.point(lambda p: 255 if p > 12 else 0).getbbox()
    if bbox:
        pad = 16
        bbox = (
            max(0, bbox[0] - pad),
            max(0, bbox[1] - pad),
            min(width, bbox[2] + pad),
            min(height, bbox[3] + pad),
        )
        image = image.crop(bbox)
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()


def backup_file(path: Path):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, BACKUP_DIR / path.name)


def load_json(path: Path):
    return json.loads(path.read_text()) if path.exists() else None


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")


def load_character_meta(path: Path) -> dict:
    data = json.loads(path.read_text())
    return {
        "id": data["id"],
        "name": data["name"],
        "owpSlug": data["owpSlug"],
        "storageSlug": data.get("storageSlug") or data["owpSlug"],
    }


def kf_transform(frame, x, y, scale_x=1.0, scale_y=1.0, rotation=0.0, opacity=1.0, z=10, easing="linear"):
    return {
        "id": str(uuid.uuid4()).upper(),
        "frame": frame,
        "kind": "transform",
        "easing": {easing: {}},
        "value": {
            "transform": {
                "_0": {
                    "x": x,
                    "y": y,
                    "rotation": rotation,
                    "scaleX": scale_x,
                    "scaleY": scale_y,
                    "opacity": opacity,
                    "zOrder": z,
                }
            }
        },
    }


def kf_visibility(frame, visible, opacity=1.0):
    return {
        "id": str(uuid.uuid4()).upper(),
        "frame": frame,
        "kind": "visibility",
        "easing": {"stepped": {}},
        "value": {
            "visibility": {
                "opacity": opacity,
                "visible": visible,
            }
        },
    }


def kf_expression(frame, name):
    return {
        "id": str(uuid.uuid4()).upper(),
        "frame": frame,
        "kind": "expression",
        "easing": {"stepped": {}},
        "value": {
            "expression": {
                "name": name,
            }
        },
    }


def track(name, keyframes):
    return {
        "name": name,
        "keyframes": keyframes,
    }


def ensure_place(background_rel_path: str) -> str:
    places = load_json(PLACES_PATH) or []
    for place in places:
        if place.get("name") == "corridor" and place.get("approvedImagePath") == background_rel_path:
            return place["id"]
    place = {
        "id": str(uuid.uuid4()).upper(),
        "name": "corridor",
        "filename": Path(background_rel_path).name,
        "notes": "Generated automatically for 1.05.0 - Silver placeholder scene.",
        "imagePaths": [background_rel_path],
        "approvedImagePath": background_rel_path,
    }
    places.append(place)
    save_json(PLACES_PATH, places)
    return place["id"]


def object_setup(name, x, y, z, rel_path, enter=0, exit_frame=None, state="default", notes=""):
    return {
        "id": str(uuid.uuid4()).upper(),
        "objectName": name,
        "initialX": x,
        "initialY": y,
        "initialState": state,
        "enterFrame": enter,
        "exitFrame": exit_frame,
        "zOrder": z,
        "opacity": 1,
        "visible": True,
        "attachmentTarget": None,
        "imagePaths": [rel_path],
        "approvedImagePath": rel_path,
        "stateImagePaths": {},
        "notes": notes,
    }


def apply_scene(background_place_id: str, asset_map: dict):
    scenes = load_json(SCENES_PATH)
    if not scenes:
        raise RuntimeError(f"Could not load scenes from {SCENES_PATH}")

    mark = load_character_meta(MARK_RIG)
    johnny = load_character_meta(JOHNNY_RIG)

    silver = None
    for scene in scenes:
        if scene.get("owsSongPath") == "Songs/1.05.0 - Silver.ows":
            silver = scene
            break
    if silver is None:
        raise RuntimeError("Silver scene not found in Animate/scenes.json")

    silver["backgroundID"] = background_place_id
    silver["characterIDs"] = [mark["id"], johnny["id"]]
    silver["characterSlugs"] = [mark["storageSlug"], johnny["storageSlug"]]
    silver.setdefault("shots", [])
    silver.setdefault("keyframes", [])
    silver.setdefault("tracks", {})

    silver["objectSetups"] = [
        object_setup("comms-desk", 0.35, 0.73, 15, asset_map["comms_desk"], notes="Generated Silver placeholder prop"),
        object_setup("mark-logbook", 0.36, 0.62, 45, asset_map["mark_logbook"], notes="Generated Silver placeholder prop"),
        object_setup("mark-cutout-seated", 0.35, 0.66, 35, asset_map["mark_seated"], exit_frame=1727, notes="Generated Silver placeholder character cutout"),
        object_setup("mark-cutout-standing", 0.39, 0.60, 36, asset_map["mark_standing"], enter=1728, notes="Generated Silver placeholder character cutout"),
        object_setup("johnny-cutout-guarded", 0.80, 0.62, 34, asset_map["johnny_guarded"], exit_frame=1343, notes="Generated Silver placeholder character cutout"),
        object_setup("johnny-cutout-emotional", 0.74, 0.61, 34, asset_map["johnny_emotional"], enter=1344, notes="Generated Silver placeholder character cutout"),
    ]

    silver["tracks"] = {
        "camera": track("camera", [
            kf_transform(0, 0.0, 0.0, scale_x=1.0, scale_y=1.0, z=0),
            kf_transform(384, -0.01, -0.005, scale_x=1.08, scale_y=1.08, z=0),
            kf_transform(768, 0.01, -0.003, scale_x=1.03, scale_y=1.03, z=0),
            kf_transform(1344, 0.03, -0.02, scale_x=1.16, scale_y=1.16, z=0),
            kf_transform(1728, 0.015, -0.01, scale_x=1.08, scale_y=1.08, z=0),
        ]),
        "Mark Price:transform": track("Mark Price:transform", [
            kf_transform(0, 0.35, 0.66, rotation=0, z=20),
            kf_transform(384, 0.36, 0.66, rotation=-1.5, z=20),
            kf_transform(768, 0.35, 0.655, rotation=0.8, z=20),
            kf_transform(1344, 0.34, 0.655, rotation=0, z=20),
            kf_transform(1728, 0.39, 0.60, rotation=0, z=20),
            kf_transform(2112, 0.40, 0.595, rotation=0, z=20),
        ]),
        "Mark Price:visibility": track("Mark Price:visibility", [
            kf_visibility(0, False, 0),
        ]),
        "Mark Price:facing": track("Mark Price:facing", [
            kf_expression(0, "right"),
        ]),
        "Johnny Ward:transform": track("Johnny Ward:transform", [
            kf_transform(0, 0.80, 0.62, rotation=0, z=20),
            kf_transform(768, 0.77, 0.615, rotation=-1, z=20),
            kf_transform(1344, 0.74, 0.61, rotation=0, z=20),
            kf_transform(1536, 0.82, 0.605, rotation=2, z=20),
            kf_transform(1728, 0.78, 0.605, rotation=1, z=20),
            kf_transform(2112, 0.74, 0.61, rotation=0, z=20),
        ]),
        "Johnny Ward:visibility": track("Johnny Ward:visibility", [
            kf_visibility(0, False, 0),
        ]),
        "Johnny Ward:facing": track("Johnny Ward:facing", [
            kf_expression(0, "left"),
        ]),
        "object:mark-cutout-seated:transform": track("object:mark-cutout-seated:transform", [
            kf_transform(0, 0.35, 0.66, scale_x=2.7, scale_y=2.7, rotation=0, z=35),
            kf_transform(384, 0.36, 0.66, scale_x=2.72, scale_y=2.72, rotation=-1.5, z=35),
            kf_transform(768, 0.35, 0.655, scale_x=2.69, scale_y=2.69, rotation=0.8, z=35),
            kf_transform(1344, 0.34, 0.655, scale_x=2.68, scale_y=2.68, rotation=0, z=35),
            kf_transform(1727, 0.35, 0.655, scale_x=2.68, scale_y=2.68, rotation=0, z=35),
        ]),
        "object:mark-cutout-standing:transform": track("object:mark-cutout-standing:transform", [
            kf_transform(1728, 0.39, 0.60, scale_x=2.8, scale_y=2.8, rotation=0, z=36),
            kf_transform(1920, 0.395, 0.598, scale_x=2.82, scale_y=2.82, rotation=-1, z=36),
            kf_transform(2112, 0.40, 0.595, scale_x=2.8, scale_y=2.8, rotation=0, z=36),
        ]),
        "object:johnny-cutout-guarded:transform": track("object:johnny-cutout-guarded:transform", [
            kf_transform(0, 0.80, 0.62, scale_x=2.65, scale_y=2.65, rotation=0, z=34),
            kf_transform(768, 0.77, 0.615, scale_x=2.68, scale_y=2.68, rotation=-1, z=34),
            kf_transform(1343, 0.74, 0.61, scale_x=2.7, scale_y=2.7, rotation=0, z=34),
        ]),
        "object:johnny-cutout-emotional:transform": track("object:johnny-cutout-emotional:transform", [
            kf_transform(1344, 0.74, 0.61, scale_x=2.76, scale_y=2.76, rotation=0, z=34),
            kf_transform(1536, 0.82, 0.605, scale_x=2.82, scale_y=2.82, rotation=2, z=34),
            kf_transform(1728, 0.78, 0.605, scale_x=2.8, scale_y=2.8, rotation=1, z=34),
            kf_transform(2112, 0.74, 0.61, scale_x=2.78, scale_y=2.78, rotation=0, z=34),
        ]),
        "object:comms-desk:transform": track("object:comms-desk:transform", [
            kf_transform(0, 0.35, 0.73, scale_x=1.8, scale_y=1.8, rotation=0, z=15),
            kf_transform(2112, 0.35, 0.73, scale_x=1.8, scale_y=1.8, rotation=0, z=15),
        ]),
        "object:mark-logbook:transform": track("object:mark-logbook:transform", [
            kf_transform(0, 0.36, 0.62, scale_x=1.05, scale_y=1.05, rotation=0, z=45),
            kf_transform(384, 0.365, 0.61, scale_x=1.08, scale_y=1.08, rotation=-10, z=45),
            kf_transform(768, 0.36, 0.62, scale_x=1.05, scale_y=1.05, rotation=0, z=45),
            kf_transform(1728, 0.39, 0.59, scale_x=1.1, scale_y=1.1, rotation=6, z=46),
            kf_transform(2112, 0.40, 0.585, scale_x=1.1, scale_y=1.1, rotation=4, z=46),
        ]),
        "camera:shot": track("camera:shot", [
            kf_expression(0, "medium"),
            kf_expression(384, "medium_close"),
            kf_expression(768, "medium"),
            kf_expression(1344, "close"),
            kf_expression(1728, "medium_close"),
        ]),
        "camera:intent": track("camera:intent", [
            kf_expression(0, "establishing"),
            kf_expression(384, "emotional"),
            kf_expression(768, "dialogue"),
            kf_expression(1344, "emotional"),
            kf_expression(1728, "confrontation"),
        ]),
        "camera:focus": track("camera:focus", [
            kf_expression(0, "mark"),
            kf_expression(768, "johnny"),
            kf_expression(1728, "mark"),
        ]),
    }

    save_json(SCENES_PATH, scenes)


def main():
    if not SONG_PATH.exists():
        raise RuntimeError(f"Missing song file: {SONG_PATH}")
    api_key = load_api_key()
    SESSION_DIR.mkdir(parents=True, exist_ok=True)
    BACKGROUND_DIR.mkdir(parents=True, exist_ok=True)
    OBJECT_DIR.mkdir(parents=True, exist_ok=True)

    manifest = {
        "approved_model": MODEL,
        "approved_size": "1K",
        "song": str(SONG_PATH),
        "assets": [],
    }

    backup_file(SCENES_PATH)
    backup_file(PLACES_PATH)

    asset_rel_paths = {}
    for spec in ASSETS:
        print(f"Generating {spec.key}...", flush=True)
        result = generate_asset(api_key, spec)
        raw_path = SESSION_DIR / f"raw-{spec.filename}"
        raw_path.write_bytes(result["image_bytes"])
        final_bytes = remove_green(result["image_bytes"]) if spec.chroma_key else result["image_bytes"]
        if spec.key == "background_corridor":
            final_path = BACKGROUND_DIR / spec.filename
            final_rel = f"Animate/backgrounds/{spec.filename}"
        else:
            final_path = OBJECT_DIR / spec.filename
            final_rel = f"Animate/objects/silver/{spec.filename}"
        final_path.parent.mkdir(parents=True, exist_ok=True)
        final_path.write_bytes(final_bytes)
        asset_rel_paths[spec.key] = final_rel
        manifest["assets"].append({
            "key": spec.key,
            "filename": spec.filename,
            "finalPath": str(final_path),
            "relativePath": final_rel,
            "aspectRatio": spec.aspect_ratio,
            "prompt": spec.prompt,
            "responseText": result.get("response_text"),
            "refs": [str(p) for p in spec.refs],
            "chromaKeyed": spec.chroma_key,
        })
        time.sleep(1.5)

    place_id = ensure_place(asset_rel_paths["background_corridor"])
    apply_scene(place_id, asset_rel_paths)
    (SESSION_DIR / "prompt_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({
        "status": "ok",
        "sessionDir": str(SESSION_DIR),
        "backgroundPlaceID": place_id,
        "scenePath": str(SCENES_PATH),
        "placesPath": str(PLACES_PATH),
        "assets": asset_rel_paths,
    }, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
