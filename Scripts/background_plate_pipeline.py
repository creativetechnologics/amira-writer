#!/usr/bin/env python3
"""Catalog environment inspiration photos, build a background-plate matrix, and run immediate Gemini image tests.

This script is tailored for Amira's photoreal environment/background workflow.
It deliberately avoids Batch API generation for the review stage.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import time
import warnings
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
warnings.filterwarnings("ignore", message=r"urllib3 v2 only supports OpenSSL 1\.1\.1\+.*")
from html import escape
from io import BytesIO
from pathlib import Path
from typing import Any

import requests
from PIL import Image, ImageOps

Image.MAX_IMAGE_PIXELS = None


HOME = Path.home()
PROJECT_ROOT = HOME / "Amira - A Modern Opera"
INSPIRATION_ROOT = PROJECT_ROOT / "Animate" / "backgrounds" / "inspiration"
PIPELINE_ROOT = PROJECT_ROOT / "Animate" / "backgrounds" / "pipeline"
LOCATION_LIST_PATH = PROJECT_ROOT / "location_list.md"
DESKTOP_ROOT = HOME / "Desktop"

TEXT_MODEL = "gemini-2.5-flash-lite"
IMAGE_MODEL = "gemini-3.1-flash-image-preview"
BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
API_TIMEOUT = 600

SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".tif", ".tiff"}


CATALOG_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "shot_scale": {"type": "string"},
        "vantage": {"type": "string"},
        "composition": {"type": "string"},
        "environment_category": {"type": "string"},
        "terrain": {"type": "array", "items": {"type": "string"}},
        "architecture": {"type": "array", "items": {"type": "string"}},
        "water": {"type": "array", "items": {"type": "string"}},
        "vegetation": {"type": "array", "items": {"type": "string"}},
        "lighting": {"type": "string"},
        "weather": {"type": "string"},
        "mood": {"type": "string"},
        "notable_objects": {"type": "array", "items": {"type": "string"}},
        "useful_for": {"type": "array", "items": {"type": "string"}},
        "keep_for_world": {"type": "array", "items": {"type": "string"}},
        "avoid_for_world": {"type": "array", "items": {"type": "string"}},
        "translate_to_world": {"type": "array", "items": {"type": "string"}},
        "tags": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "summary",
        "shot_scale",
        "vantage",
        "composition",
        "environment_category",
        "terrain",
        "architecture",
        "water",
        "vegetation",
        "lighting",
        "weather",
        "mood",
        "notable_objects",
        "useful_for",
        "keep_for_world",
        "avoid_for_world",
        "translate_to_world",
        "tags",
    ],
}

CATALOG_GROUP_RECORD_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "relative_path": {"type": "string"},
        **CATALOG_SCHEMA["properties"],
    },
    "required": ["relative_path", *CATALOG_SCHEMA["required"]],
}

CATALOG_GROUP_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "records": {
            "type": "array",
            "items": CATALOG_GROUP_RECORD_SCHEMA,
        }
    },
    "required": ["records"],
}


@dataclass(frozen=True)
class PlateDefinition:
    id: str
    title: str
    canonical_location: str
    narrative_use: str
    visual_brief: str
    continuity_anchors: list[str]
    preferred_folders: list[str]
    include_keywords: list[str]
    avoid_keywords: list[str]
    desired_refs: int = 3
    aspect_ratio: str = "16:9"
    image_size: str = "1K"
    test_pick: bool = False


PLATE_DEFINITIONS: list[PlateDefinition] = [
    PlateDefinition(
        id="valley_master_ridge_dawn",
        title="Valley Master — Ridge Dawn",
        canonical_location="The Base / Ridge Overlook",
        narrative_use="Primary world-establishing valley view from the ridge side.",
        visual_brief="Wide dawn view from a higher ridge-side base looking across the river to the left-bank town and up toward snow-fed mountains. The base should sit clearly higher on the hillside, and the opposite-bank memorial/cemetery zone should read below it near the water.",
        continuity_anchors=[
            "Town sits on the left bank when facing the mountains",
            "Tiny temporary base sits higher on the opposite ridge hillside",
            "Memorial/cemetery zone sits on the ridge side near the river below the base",
            "Above-tree-line valley with sparse pasture and dry dirt",
            "Snow/glacier-fed peaks visible upstream",
        ],
        preferred_folders=["peru", "canada", "borrego"],
        include_keywords=["valley", "mountain", "river", "ridge", "panorama", "wide", "snow", "glacier", "alpine"],
        avoid_keywords=["forest", "city", "beach", "dense jungle"],
        test_pick=True,
    ),
    PlateDefinition(
        id="bridge_hero_wide",
        title="Bridge Hero Wide",
        canonical_location="The Bridge",
        narrative_use="Hero threshold image for the crossing and shooting geography.",
        visual_brief="A wide photoreal view of the ancient single-lane stone bridge crossing the river in the steep valley, with the town beyond and no railings. The shot should feel like a believable documentary photograph, not a heroic fantasy vista.",
        continuity_anchors=[
            "Ancient weathered stone bridge",
            "Barely wide enough for one vehicle",
            "No railings",
            "Town beyond the bridge, mountains up-valley",
        ],
        preferred_folders=["bosnia", "peru"],
        include_keywords=["bridge", "stone", "river", "town", "gorge", "arch", "crossing"],
        avoid_keywords=["lush", "steel", "modern highway"],
        test_pick=True,
    ),
    PlateDefinition(
        id="river_road_grave_marker",
        title="River Road & Grave Marker",
        canonical_location="The River / The River Road",
        narrative_use="The path between bridge and town, including the lonely grave-marker geography.",
        visual_brief="A realistic river road on the village side with water close by, a humble low stone grave marker at the edge, and the bridge/town relationship readable.",
        continuity_anchors=[
            "On village side between bridge and town",
            "Low stone grave marker at water's edge",
            "Sparse reeds / pasture, not lush riverbank growth",
        ],
        preferred_folders=["peru", "canada", "borrego"],
        include_keywords=["river", "road", "bank", "stream", "shore", "rocky", "water"],
        avoid_keywords=["dock", "boat", "tropical"],
        test_pick=True,
    ),
    PlateDefinition(
        id="marketplace_prestrike",
        title="Marketplace Pre-Strike",
        canonical_location="The Marketplace",
        narrative_use="Living town-center image before the bombing.",
        visual_brief="A lower-village market square / street near the bridge end of town, modest and crowded in layout even if empty for the plate, with old stone/plaster architecture and a clear sense of commerce.",
        continuity_anchors=[
            "Near the bridge end of the town",
            "Open-air commercial center",
            "Persian/Afghan highland stone + plaster materials",
            "Beautiful but rundown, not polished tourism",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["town", "street", "square", "market", "plaza", "shops", "alley", "stone"],
        avoid_keywords=["cars packed", "neon", "european cafe umbrellas"],
        test_pick=True,
    ),
    PlateDefinition(
        id="rubble_field_twilight",
        title="Rubble Field Twilight",
        canonical_location="The Rubble Field",
        narrative_use="Destroyed version of the marketplace after the strike.",
        visual_brief="The same lower-village market area after a bombing: broken stalls, fractured masonry, blown dust, damaged awnings, and a twilight hush. It should read as the same place as the marketplace plate, just devastated.",
        continuity_anchors=[
            "Must feel like marketplace aftermath",
            "Twilight after violence",
            "No active fireball or cinematic explosion moment",
            "Human absence in this plate pass",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["town", "market", "square", "stone", "wall", "street"],
        avoid_keywords=["lush", "modern vehicles"],
        test_pick=True,
    ),
    PlateDefinition(
        id="village_main_road",
        title="Village Main Road",
        canonical_location="The Village Streets",
        narrative_use="General town-traversal geography from market up toward clinic.",
        visual_brief="A long main road threading through the old mountain town, with stone and plaster buildings, elevation changes, and the sense that the settlement climbs up the valley.",
        continuity_anchors=[
            "Roads run parallel to river and climb the slope",
            "Small old structures, a few slightly larger civic/religious forms",
            "Dry highland atmosphere with modest pasture edges",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["road", "street", "town", "village", "slope", "stone", "buildings"],
        avoid_keywords=["dense trees", "asphalt boulevard"],
        test_pick=True,
    ),
    PlateDefinition(
        id="village_alley_escape",
        title="Village Back Alley",
        canonical_location="The Village Streets / Back Alleys",
        narrative_use="Tight escape-space geography for Something More.",
        visual_brief="A narrow atmospheric back alley between weathered stone/plaster buildings, intimate and labyrinthine but still realistic and walkable.",
        continuity_anchors=[
            "Narrow alley, foot-traffic scale",
            "Stone + plaster textures",
            "Old, worn, beautiful, slightly neglected",
        ],
        preferred_folders=["bosnia", "peru"],
        include_keywords=["alley", "narrow", "lane", "stone", "archway", "passage", "wall"],
        avoid_keywords=["graffiti modern", "dense foliage"],
        test_pick=True,
    ),
    PlateDefinition(
        id="gathering_space_lamplight",
        title="Gathering Space Lamplight",
        canonical_location="The Gathering Space",
        narrative_use="Communal spiritual/meeting interior.",
        visual_brief="A modest communal interior with rugs, cushions, hanging lamps, and restrained geometric decoration. It should feel local, practical, and spiritually resonant without becoming palatial or overly formal.",
        continuity_anchors=[
            "Not a formal mosque, but mosque-inspired aesthetics",
            "Rugs everywhere, intimate communal scale",
            "Low warm lamplight",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["interior", "room", "hall", "rugs", "lamps", "arches", "decorative"],
        avoid_keywords=["church pews", "cathedral", "luxury palace"],
        test_pick=True,
    ),
    PlateDefinition(
        id="amiras_home_lamplight",
        title="Amira's Home Lamplight",
        canonical_location="Amira's Home",
        narrative_use="Warm modest domestic space.",
        visual_brief="A modest family home interior with a table, kettle, lamp, textiles, and old stone/plaster domestic materials. Lived-in and warm, not wealthy.",
        continuity_anchors=[
            "Domestic warmth",
            "Simple lived-in room",
            "Journal could plausibly live here",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["interior", "home", "room", "domestic", "table", "doorway"],
        avoid_keywords=["luxury", "modern appliances", "western suburban"],
        test_pick=True,
    ),
    PlateDefinition(
        id="clinic_treatment_room",
        title="Clinic Treatment Room",
        canonical_location="The Village Clinic",
        narrative_use="Main working medical interior for first meeting and treatment.",
        visual_brief="A clean but materially scarce rural clinic interior: practical treatment table, shelves, worn supplies, daylight, and a doctor-built community space rather than a polished hospital. The room is embedded within the town fabric, not perched alone above the whole valley.",
        continuity_anchors=[
            "Functional, resource-limited",
            "Clean despite scarcity",
            "No modern sterile hospital gloss",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["interior", "room", "bed", "shelves", "clinic", "workspace"],
        avoid_keywords=["modern ER", "neon hospital"],
        test_pick=True,
    ),
    PlateDefinition(
        id="clinic_exterior_upper_village",
        title="Clinic Exterior Upper Village",
        canonical_location="The Village Clinic",
        narrative_use="Exterior geography near far end of town.",
        visual_brief="An upper-village clinic exterior, farther from the bridge, where the town begins to thin toward the shepherd's huts and mountains.",
        continuity_anchors=[
            "Upper end of village",
            "Transition toward outskirts and mountain edge",
            "Functional community building",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["building", "town", "road", "upper", "village", "stone"],
        avoid_keywords=["dense market bustle", "urban center"],
    ),
    PlateDefinition(
        id="photo_shop",
        title="Photo Shop",
        canonical_location="The Photo Shop",
        narrative_use="Small war-zone development shop near town center.",
        visual_brief="A cramped film-development shop interior with a counter, drying lines, chemical clutter, and old-world practical atmosphere.",
        continuity_anchors=[
            "Small, cramped, analog film place",
            "Town-center-adjacent",
            "War-zone practicality",
        ],
        preferred_folders=["peru", "bosnia"],
        include_keywords=["interior", "shop", "counter", "small room", "workspace"],
        avoid_keywords=["modern camera store", "big city retail"],
    ),
    PlateDefinition(
        id="memorial_stones_morning",
        title="Memorial Stones Morning",
        canonical_location="The Memorial Stones",
        narrative_use="Ridge-side riverside memorial ground.",
        visual_brief="An open memorial area of stacked stones and simple markers above the high watermark on the ridge side of the river.",
        continuity_anchors=[
            "Ridge side of river, below the base",
            "Stacked stones, informal markers",
            "Open sky and water nearby",
        ],
        preferred_folders=["canada", "peru", "borrego"],
        include_keywords=["stones", "river", "bank", "rocky", "shore", "open"],
        avoid_keywords=["formal cemetery rows", "lush lawns"],
        test_pick=True,
    ),
    PlateDefinition(
        id="shepherds_huts_night",
        title="Shepherd's Huts Night",
        canonical_location="The Shepherd's Huts",
        narrative_use="Upper-village refuge at the edge of settlement.",
        visual_brief="A small cluster of rough shepherd structures at the edge of town, pastoral but sparse, with the mountains near and the village falling away below.",
        continuity_anchors=[
            "Past the clinic, edge of settlement",
            "Stone-and-wood simple structures",
            "Hidden refuge feel",
        ],
        preferred_folders=["peru", "canada"],
        include_keywords=["hut", "small building", "mountain", "pasture", "outskirts", "stone"],
        avoid_keywords=["dense forest cabin", "lush meadow village"],
    ),
    PlateDefinition(
        id="hillside_sunrise",
        title="Hillside Sunrise",
        canonical_location="The Hillside",
        narrative_use="Upper-village dawn overlook for Luke's sunrise moment.",
        visual_brief="An open hillside above the huts with sunrise light, a view across the valley, and a sense of altitude and thin air. The foreground should feel like rough pasture and scattered stones rather than an idealized scenic overlook.",
        continuity_anchors=[
            "Above shepherd's huts",
            "Open hillside with stones and sparse grass",
            "Sunrise over mountains",
        ],
        preferred_folders=["peru", "canada", "borrego"],
        include_keywords=["hillside", "sunrise", "mountain", "pasture", "open", "alpine", "ridge"],
        avoid_keywords=["dense forest", "tropical green"],
        test_pick=True,
    ),
    PlateDefinition(
        id="base_tent_row",
        title="Base Tent Row",
        canonical_location="The Base",
        narrative_use="Temporary field-outpost ground-level geography.",
        visual_brief="A small temporary surveillance/humanitarian base: a handful of tents and a handful of vehicles on a ridge, austere and improvised.",
        continuity_anchors=[
            "Very small temporary base",
            "No permanent buildings",
            "Ridge-side overlook context",
        ],
        preferred_folders=["borrego", "peru"],
        include_keywords=["ridge", "road", "open", "dry", "plateau", "camp"],
        avoid_keywords=["large military FOB", "fortified concrete base"],
    ),
    PlateDefinition(
        id="base_comms_tent",
        title="Base Comms Tent",
        canonical_location="The Base / Comms Tent",
        narrative_use="Mark's communications interior.",
        visual_brief="A tent interior filled with radios, notebooks, cables, field tables, and soft utilitarian light; temporary and cramped, never barracks-like.",
        continuity_anchors=[
            "Inside a tent, not a building",
            "Field communications setup",
            "Cramped and temporary",
        ],
        preferred_folders=["borrego", "peru"],
        include_keywords=["interior", "tent", "workspace", "table"],
        avoid_keywords=["office cubicle", "permanent room"],
    ),
]


def slugify(text: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return value or "item"


def now_stamp() -> str:
    return datetime.now().strftime("%Y%m%dT%H%M%S")


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


def iter_images(root: Path) -> list[Path]:
    return sorted(
        [
            path
            for path in root.rglob("*")
            if path.is_file() and path.suffix.lower() in SUPPORTED_EXTS
        ],
        key=lambda p: str(p).lower(),
    )


def image_mime(path: Path) -> str:
    ext = path.suffix.lower()
    return {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".heic": "image/heic",
        ".tif": "image/tiff",
        ".tiff": "image/tiff",
    }.get(ext, "image/jpeg")


def make_inline_data(path: Path, max_dim: int = 1600, quality: int = 82) -> dict[str, Any]:
    image = Image.open(path)
    image = ImageOps.exif_transpose(image)
    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGB")
    if image.mode == "RGBA":
        bg = Image.new("RGB", image.size, (255, 255, 255))
        bg.paste(image, mask=image.split()[-1])
        image = bg
    width, height = image.size
    longest = max(width, height)
    if longest > max_dim:
        scale = max_dim / float(longest)
        image = image.resize((max(1, int(width * scale)), max(1, int(height * scale))), Image.Resampling.LANCZOS)
    buffer = BytesIO()
    image.save(buffer, format="JPEG", quality=quality, optimize=True)
    return {
        "inlineData": {
            "mimeType": "image/jpeg",
            "data": base64.b64encode(buffer.getvalue()).decode("utf-8"),
        }
    }


def simple_json_request(
    *,
    api_key: str,
    model: str,
    prompt: str,
    image_paths: list[Path] | None = None,
    response_schema: dict[str, Any] | None = None,
    temperature: float | None = 0.2,
    retries: int = 5,
) -> Any:
    parts: list[dict[str, Any]] = [{"text": prompt}]
    for image_path in image_paths or []:
        parts.append(make_inline_data(image_path))

    generation_config: dict[str, Any] = {}
    if response_schema is not None:
        generation_config["responseMimeType"] = "application/json"
        generation_config["responseJsonSchema"] = response_schema
    if temperature is not None:
        generation_config["temperature"] = temperature

    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": generation_config,
    }
    url = f"{BASE_URL}/{model}:generateContent"
    last_error: str | None = None

    for attempt in range(1, retries + 1):
        try:
            response = requests.post(
                url,
                headers={
                    "Content-Type": "application/json",
                    "x-goog-api-key": api_key,
                },
                json=payload,
                timeout=API_TIMEOUT,
            )
        except Exception as error:  # noqa: BLE001
            last_error = f"network error: {error}"
            time.sleep(min(12, 1.5 * attempt) + random.random())
            continue

        if response.status_code != 200:
            last_error = f"HTTP {response.status_code}: {response.text[:1200]}"
            time.sleep(min(12, 1.5 * attempt) + random.random())
            continue

        data = response.json()
        candidates = data.get("candidates") or []
        if not candidates:
            last_error = f"no candidates: {data}"
            time.sleep(min(12, 1.5 * attempt) + random.random())
            continue

        parts_out = candidates[0].get("content", {}).get("parts", [])
        text_response = None
        for part in parts_out:
            if "text" in part:
                text_response = part["text"]
                break

        if text_response is None:
            last_error = f"no text in response: {data}"
            time.sleep(min(12, 1.5 * attempt) + random.random())
            continue

        try:
            return json.loads(text_response)
        except json.JSONDecodeError:
            cleaned = text_response.strip().removeprefix("```json").removesuffix("```").strip()
            return json.loads(cleaned)

    raise RuntimeError(f"Gemini JSON request failed for model {model}: {last_error}")


def generate_image(
    *,
    api_key: str,
    prompt: str,
    reference_paths: list[Path],
    aspect_ratio: str = "16:9",
    image_size: str | None = "1K",
    model: str = IMAGE_MODEL,
    retries: int = 4,
) -> tuple[bytes, str | None]:
    parts: list[dict[str, Any]] = [{"text": prompt}]
    for path in reference_paths:
        parts.append(make_inline_data(path, max_dim=1800, quality=84))

    image_config: dict[str, Any] = {
        "aspectRatio": aspect_ratio,
    }
    if image_size:
        image_config["imageSize"] = image_size

    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "imageConfig": image_config,
        },
    }
    url = f"{BASE_URL}/{model}:generateContent"
    last_error: str | None = None

    for attempt in range(1, retries + 1):
        try:
            response = requests.post(
                url,
                headers={
                    "Content-Type": "application/json",
                    "x-goog-api-key": api_key,
                },
                json=payload,
                timeout=API_TIMEOUT,
            )
        except Exception as error:  # noqa: BLE001
            last_error = f"network error: {error}"
            time.sleep(min(18, 2 * attempt) + random.random())
            continue

        if response.status_code != 200:
            last_error = f"HTTP {response.status_code}: {response.text[:1500]}"
            time.sleep(min(18, 2 * attempt) + random.random())
            continue

        data = response.json()
        candidates = data.get("candidates") or []
        if not candidates:
            last_error = f"no candidates: {data}"
            time.sleep(min(18, 2 * attempt) + random.random())
            continue

        text_response = None
        image_bytes = None
        for part in candidates[0].get("content", {}).get("parts", []):
            if "text" in part:
                text_response = part["text"]
            inline = part.get("inlineData")
            if inline and inline.get("data"):
                image_bytes = base64.b64decode(inline["data"])

        if image_bytes:
            return image_bytes, text_response

        last_error = f"no image returned: {data}"
        time.sleep(min(18, 2 * attempt) + random.random())

    raise RuntimeError(f"Gemini image request failed for model {model}: {last_error}")


def sha1_path(path: Path) -> str:
    return hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:12]


def normalize_list(value: Any) -> list[str]:
    if not value:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    result: list[str] = []
    for item in value:
        if item is None:
            continue
        text = str(item).strip()
        if text:
            result.append(text)
    return result


def catalog_prompt(path: Path, rel_path: str) -> str:
    return textwrap.dedent(
        f"""
        You are cataloging a single real travel photograph for a photoreal environment-design library.

        Analyze the actual photograph first, not the fictional world.
        Then evaluate how it could inspire a fictional setting for "Amira: A Modern Opera":
        - steep river valley
        - high altitude, above the tree line
        - sparse green pasture, lots of dirt and stone
        - snow-capped peaks and some glacier/snowmelt upstream
        - town architecture inspired by Afghan / Iranian / Persian highland aesthetics
        - beautiful but run down
        - no modern tourism sheen

        The file being analyzed is:
        - relative path: {rel_path}
        - source folder: {path.parent.name}

        Return concise but specific JSON only.
        - `summary` should describe the photo in one or two vivid sentences.
        - `useful_for`, `keep_for_world`, `avoid_for_world`, and `translate_to_world` should each be short, concrete bullet-like strings.
        - `tags` should be short lowercase phrases.
        """
    ).strip()


def catalog_group_prompt(paths: list[Path], rel_paths: list[str]) -> str:
    rel_list = "\n".join(f"- {rel_path}" for rel_path in rel_paths)
    return textwrap.dedent(
        f"""
        You are cataloging several real travel photographs for a photoreal environment-design library.

        Analyze EACH photograph separately.
        First describe the actual image, then evaluate how it could inspire a fictional setting for "Amira: A Modern Opera":
        - steep river valley
        - high altitude, above the tree line
        - sparse green pasture, lots of dirt and stone
        - snow-capped peaks and some glacier/snowmelt upstream
        - town architecture inspired by Afghan / Iranian / Persian highland aesthetics
        - beautiful but run down
        - no modern tourism sheen

        Return JSON only with a top-level `records` array.
        Each record must contain the exact `relative_path` string for one image from this list:
        {rel_list}

        Important rules:
        - One record per image.
        - Keep the records aligned to the real image content, not the folder assumptions.
        - `summary` should be one or two vivid sentences.
        - `useful_for`, `keep_for_world`, `avoid_for_world`, and `translate_to_world` should be short, concrete bullet-like strings.
        - `tags` should be short lowercase phrases.
        """
    ).strip()


def analyze_single_image(api_key: str, path: Path, inspiration_root: Path) -> dict[str, Any]:
    rel_path = str(path.relative_to(inspiration_root))
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image)
        width, height = image.size
    orientation = "square"
    if width > height:
        orientation = "landscape"
    elif height > width:
        orientation = "portrait"

    analysis = simple_json_request(
        api_key=api_key,
        model=TEXT_MODEL,
        prompt=catalog_prompt(path, rel_path),
        image_paths=[path],
        response_schema=CATALOG_SCHEMA,
        temperature=0.1,
    )

    record = {
        "id": f"{path.parent.name}-{sha1_path(path)}",
        "path": str(path),
        "relative_path": rel_path,
        "folder": path.parent.name.lower(),
        "filename": path.name,
        "width": width,
        "height": height,
        "orientation": orientation,
        "summary": analysis.get("summary", "").strip(),
        "shot_scale": analysis.get("shot_scale", "").strip(),
        "vantage": analysis.get("vantage", "").strip(),
        "composition": analysis.get("composition", "").strip(),
        "environment_category": analysis.get("environment_category", "").strip(),
        "terrain": normalize_list(analysis.get("terrain")),
        "architecture": normalize_list(analysis.get("architecture")),
        "water": normalize_list(analysis.get("water")),
        "vegetation": normalize_list(analysis.get("vegetation")),
        "lighting": analysis.get("lighting", "").strip(),
        "weather": analysis.get("weather", "").strip(),
        "mood": analysis.get("mood", "").strip(),
        "notable_objects": normalize_list(analysis.get("notable_objects")),
        "useful_for": normalize_list(analysis.get("useful_for")),
        "keep_for_world": normalize_list(analysis.get("keep_for_world")),
        "avoid_for_world": normalize_list(analysis.get("avoid_for_world")),
        "translate_to_world": normalize_list(analysis.get("translate_to_world")),
        "tags": [tag.lower() for tag in normalize_list(analysis.get("tags"))],
        "analyzed_at": datetime.utcnow().isoformat() + "Z",
    }
    return record


def analyze_image_group(api_key: str, paths: list[Path], inspiration_root: Path) -> list[dict[str, Any]]:
    rel_paths = [str(path.relative_to(inspiration_root)) for path in paths]
    analysis = simple_json_request(
        api_key=api_key,
        model=TEXT_MODEL,
        prompt=catalog_group_prompt(paths, rel_paths),
        image_paths=paths,
        response_schema=CATALOG_GROUP_SCHEMA,
        temperature=0.1,
    )

    returned = analysis.get("records") or []
    by_rel: dict[str, dict[str, Any]] = {}
    for item in returned:
        rel_path = str(item.get("relative_path", "")).strip()
        if rel_path:
            by_rel[rel_path] = item

    records: list[dict[str, Any]] = []
    for path in paths:
        rel_path = str(path.relative_to(inspiration_root))
        with Image.open(path) as image:
            image = ImageOps.exif_transpose(image)
            width, height = image.size
        orientation = "square"
        if width > height:
            orientation = "landscape"
        elif height > width:
            orientation = "portrait"

        item = by_rel.get(rel_path)
        if item is None:
            # Safety fallback — keep progress moving if the grouped response misses one image.
            records.append(analyze_single_image(api_key, path, inspiration_root))
            continue

        record = {
            "id": f"{path.parent.name}-{sha1_path(path)}",
            "path": str(path),
            "relative_path": rel_path,
            "folder": path.parent.name.lower(),
            "filename": path.name,
            "width": width,
            "height": height,
            "orientation": orientation,
            "summary": item.get("summary", "").strip(),
            "shot_scale": item.get("shot_scale", "").strip(),
            "vantage": item.get("vantage", "").strip(),
            "composition": item.get("composition", "").strip(),
            "environment_category": item.get("environment_category", "").strip(),
            "terrain": normalize_list(item.get("terrain")),
            "architecture": normalize_list(item.get("architecture")),
            "water": normalize_list(item.get("water")),
            "vegetation": normalize_list(item.get("vegetation")),
            "lighting": item.get("lighting", "").strip(),
            "weather": item.get("weather", "").strip(),
            "mood": item.get("mood", "").strip(),
            "notable_objects": normalize_list(item.get("notable_objects")),
            "useful_for": normalize_list(item.get("useful_for")),
            "keep_for_world": normalize_list(item.get("keep_for_world")),
            "avoid_for_world": normalize_list(item.get("avoid_for_world")),
            "translate_to_world": normalize_list(item.get("translate_to_world")),
            "tags": [tag.lower() for tag in normalize_list(item.get("tags"))],
            "analyzed_at": datetime.utcnow().isoformat() + "Z",
        }
        records.append(record)

    return records


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def write_catalog_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = [
        "id",
        "folder",
        "relative_path",
        "filename",
        "width",
        "height",
        "orientation",
        "summary",
        "shot_scale",
        "vantage",
        "composition",
        "environment_category",
        "terrain",
        "architecture",
        "water",
        "vegetation",
        "lighting",
        "weather",
        "mood",
        "notable_objects",
        "useful_for",
        "keep_for_world",
        "avoid_for_world",
        "translate_to_world",
        "tags",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            flat = dict(row)
            for key in ("terrain", "architecture", "water", "vegetation", "notable_objects", "useful_for", "keep_for_world", "avoid_for_world", "translate_to_world", "tags"):
                flat[key] = " | ".join(row.get(key) or [])
            writer.writerow({name: flat.get(name, "") for name in fieldnames})


def write_catalog_summary(path: Path, rows: list[dict[str, Any]]) -> None:
    folder_counts = Counter(row["folder"] for row in rows)
    tag_counts: dict[str, Counter[str]] = {}
    for row in rows:
        counter = tag_counts.setdefault(row["folder"], Counter())
        counter.update(row.get("tags") or [])

    lines = [
        "# Inspiration Catalog Summary",
        "",
        f"Generated: {datetime.now().isoformat()}",
        "",
        "## Folder Counts",
        "",
    ]
    for folder, count in sorted(folder_counts.items()):
        lines.append(f"- **{folder}** — {count} images")
    lines.append("")
    lines.append("## Top Tags By Folder")
    lines.append("")
    for folder in sorted(tag_counts):
        lines.append(f"### {folder}")
        lines.append("")
        for tag, count in tag_counts[folder].most_common(20):
            lines.append(f"- {tag} ({count})")
        lines.append("")
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def score_entry_for_plate(entry: dict[str, Any], plate: PlateDefinition) -> int:
    text_chunks = [
        entry.get("summary", ""),
        entry.get("shot_scale", ""),
        entry.get("vantage", ""),
        entry.get("composition", ""),
        entry.get("environment_category", ""),
        entry.get("lighting", ""),
        entry.get("weather", ""),
        entry.get("mood", ""),
        " ".join(entry.get("terrain") or []),
        " ".join(entry.get("architecture") or []),
        " ".join(entry.get("water") or []),
        " ".join(entry.get("vegetation") or []),
        " ".join(entry.get("notable_objects") or []),
        " ".join(entry.get("useful_for") or []),
        " ".join(entry.get("keep_for_world") or []),
        " ".join(entry.get("tags") or []),
    ]
    haystack = " ".join(text_chunks).lower()
    score = 0
    if entry.get("folder") in plate.preferred_folders:
        score += 10
    for keyword in plate.include_keywords:
        if keyword.lower() in haystack:
            score += 4
    for keyword in plate.avoid_keywords:
        if keyword.lower() in haystack:
            score -= 6
    if plate.id.endswith("wide") or "master" in plate.id or "hillside" in plate.id:
        if entry.get("orientation") == "landscape":
            score += 3
        if "panorama" in haystack or "wide" in haystack:
            score += 4
    if "interior" in plate.id or "home" in plate.id or "clinic" in plate.id or "shop" in plate.id:
        if "interior" in haystack or "room" in haystack:
            score += 6
    return score


def top_refs_for_plate(entries: list[dict[str, Any]], plate: PlateDefinition) -> list[dict[str, Any]]:
    scored = []
    for entry in entries:
        score = score_entry_for_plate(entry, plate)
        if score > 0:
            scored.append((score, entry))
    scored.sort(key=lambda item: (item[0], item[1]["relative_path"]), reverse=True)
    refs: list[dict[str, Any]] = []
    seen_paths: set[str] = set()
    for score, entry in scored:
        if entry["path"] in seen_paths:
            continue
        refs.append(
            {
                "score": score,
                "path": entry["path"],
                "relative_path": entry["relative_path"],
                "folder": entry["folder"],
                "summary": entry.get("summary", ""),
                "keep_for_world": entry.get("keep_for_world") or [],
                "avoid_for_world": entry.get("avoid_for_world") or [],
                "translate_to_world": entry.get("translate_to_world") or [],
                "tags": entry.get("tags") or [],
            }
        )
        seen_paths.add(entry["path"])
        if len(refs) >= max(plate.desired_refs * 2, 6):
            break
    return refs


def build_prompt(plate: PlateDefinition, refs: list[dict[str, Any]]) -> str:
    keep_bits: list[str] = []
    avoid_bits: list[str] = []
    translate_bits: list[str] = []
    for ref in refs[: plate.desired_refs]:
        keep_bits.extend(ref.get("keep_for_world") or [])
        avoid_bits.extend(ref.get("avoid_for_world") or [])
        translate_bits.extend(ref.get("translate_to_world") or [])

    def uniq(items: list[str], limit: int) -> list[str]:
        seen: set[str] = set()
        result: list[str] = []
        for item in items:
            key = item.strip().lower()
            if not key or key in seen:
                continue
            seen.add(key)
            result.append(item.strip())
            if len(result) >= limit:
                break
        return result

    keep_bits = uniq(keep_bits, 6)
    avoid_bits = uniq(avoid_bits, 6)
    translate_bits = uniq(translate_bits, 6)

    interior_like = any(
        token in plate.id
        for token in [
            "gathering_space",
            "home",
            "clinic_treatment",
            "photo_shop",
            "base_comms",
        ]
    )

    lines = [
        "Create a realistic documentary-style photograph of a fictional place in a modern opera setting.",
        "No people, no characters, no visible animals, no text, no signage, no watermark.",
        "This should look like a believable real photograph, not a painted background, matte painting, concept art, or video-game environment.",
        "Natural camera behavior, natural materials, restrained realism, plausible geography.",
        "Do not force every major story-world element into the frame. Only show what would naturally be visible from this exact vantage point.",
        "",
        f"Target image: {plate.title}",
        f"Canonical location: {plate.canonical_location}",
        f"Scene function: {plate.narrative_use}",
        f"Visual brief: {plate.visual_brief}",
        "",
        "Local scene truth:",
    ]
    lines.extend([f"- {item}" for item in plate.continuity_anchors])
    if interior_like:
        lines.extend(
            [
                "- This interior belongs to a remote, resource-limited high-altitude mountain town.",
                "- Materials should feel local, weathered, practical, and modest.",
                "- If any exterior is visible through a window or doorway, keep it partial, limited, and geographically plausible from inside the town.",
            ]
        )
    else:
        lines.extend(
            [
                "- The broader setting is a steep mountain river valley above the tree line.",
                "- The town sits on the left bank when facing toward the mountains.",
                "- Architecture should feel Afghan / Iranian / Persian highland inspired: stone, plaster, weathered, beautiful but run down.",
            ]
        )
    if keep_bits:
        lines.append("")
        lines.append("Useful cues to preserve from the reference photos:")
        lines.extend([f"- {item}" for item in keep_bits])
    if translate_bits:
        lines.append("")
        lines.append("Translate the references into the Amira world by doing these things:")
        lines.extend([f"- {item}" for item in translate_bits])
    if avoid_bits:
        lines.append("")
        lines.append("Do NOT carry over these incompatible real-world cues from the references:")
        lines.extend([f"- {item}" for item in avoid_bits])
    lines.append("")
    lines.append("Treat the reference images as composition, material, and atmosphere inspiration only. Re-photograph the scene into this fictional world without making it feel over-designed or illustrative.")
    lines.append("Avoid exaggerated hyperreal perfection, fantasy grandeur, or a postcard composition.")
    return "\n".join(lines).strip()


def copy_thumb(src: Path, dest: Path, max_dim: int = 900, quality: int = 85) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    image = Image.open(src)
    image = ImageOps.exif_transpose(image)
    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGB")
    if image.mode == "RGBA":
        bg = Image.new("RGB", image.size, (255, 255, 255))
        bg.paste(image, mask=image.split()[-1])
        image = bg
    image.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
    image.save(dest, format="JPEG", quality=quality, optimize=True)


def write_review_html(path: Path, title: str, items: list[dict[str, Any]]) -> None:
    sections = []
    for item in items:
        refs_html = "".join(
            f'<figure><img src="{escape(ref["thumb_rel"])}" alt=""><figcaption>{escape(ref["relative_path"])}</figcaption></figure>'
            for ref in item["review_refs"]
        )
        sections.append(
            f"""
            <section class="card">
              <h2>{escape(item["title"])}</h2>
              <p><strong>Plate ID:</strong> {escape(item["id"])}</p>
              <p><strong>Location:</strong> {escape(item["canonical_location"])}</p>
              <img class="output" src="{escape(item["output_rel"])}" alt="">
              <details open>
                <summary>Prompt</summary>
                <pre>{escape(item["prompt"])}</pre>
              </details>
              <details>
                <summary>Reference images</summary>
                <div class="refs">{refs_html}</div>
              </details>
            </section>
            """
        )
    html = f"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>{escape(title)}</title>
      <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; background: #f5f1ea; color: #1f1a16; }}
        h1 {{ margin-bottom: 8px; }}
        .card {{ background: white; border-radius: 16px; padding: 18px; margin: 18px 0; box-shadow: 0 4px 18px rgba(0,0,0,0.08); }}
        .output {{ width: 100%; max-width: 960px; border-radius: 12px; display: block; margin: 12px 0; }}
        pre {{ white-space: pre-wrap; background: #f7f5f2; padding: 14px; border-radius: 10px; overflow-wrap: anywhere; }}
        .refs {{ display: flex; gap: 12px; flex-wrap: wrap; }}
        figure {{ width: 220px; margin: 0; }}
        figure img {{ width: 100%; border-radius: 10px; display: block; }}
        figcaption {{ font-size: 12px; margin-top: 6px; color: #4f4944; }}
      </style>
    </head>
    <body>
      <h1>{escape(title)}</h1>
      <p>Generated {escape(datetime.now().isoformat())}</p>
      {''.join(sections)}
    </body>
    </html>
    """
    path.write_text(textwrap.dedent(html).strip() + "\n", encoding="utf-8")


def command_catalog(args: argparse.Namespace) -> int:
    api_key = load_api_key()
    inspiration_root = Path(args.inspiration_root).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = output_dir / "inspiration_catalog.jsonl"

    existing_rows = load_jsonl(jsonl_path)
    completed = {row["path"] for row in existing_rows}
    rows = list(existing_rows)
    images = iter_images(inspiration_root)
    pending = [path for path in images if str(path) not in completed]
    group_size = max(1, int(args.group_size))
    pending_groups = [pending[index:index + group_size] for index in range(0, len(pending), group_size)]

    print(f"Cataloging {len(images)} inspiration images from {inspiration_root}")
    print(f"Already complete: {len(rows)} | Pending: {len(pending)} in {len(pending_groups)} request groups")

    lock = threading.Lock()

    def worker(group: list[Path]) -> list[dict[str, Any]]:
        if len(group) == 1:
            return [analyze_single_image(api_key, group[0], inspiration_root)]
        return analyze_image_group(api_key, group, inspiration_root)

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        future_map = {executor.submit(worker, group): group for group in pending_groups}
        for index, future in enumerate(as_completed(future_map), start=1):
            group = future_map[future]
            try:
                batch_records = future.result()
            except Exception as error:  # noqa: BLE001
                names = ", ".join(path.name for path in group)
                print(f"[catalog] ERROR {names}: {error}", file=sys.stderr)
                continue
            with lock:
                with jsonl_path.open("a", encoding="utf-8") as handle:
                    for record in batch_records:
                        rows.append(record)
                        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            last_rel = batch_records[-1]["relative_path"] if batch_records else "(empty)"
            print(f"[catalog] {len(rows)}/{len(images)} — {last_rel}")

    rows.sort(key=lambda row: row["relative_path"])
    write_json(output_dir / "inspiration_catalog.json", rows)
    write_catalog_csv(output_dir / "inspiration_catalog.csv", rows)
    write_catalog_summary(output_dir / "inspiration_catalog_summary.md", rows)
    print(f"Catalog complete: {output_dir}")
    return 0


def command_build_matrix(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog_json).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = json.loads(catalog_path.read_text(encoding="utf-8"))

    matrix: list[dict[str, Any]] = []
    lines = [
        "# Background Plate Matrix",
        "",
        f"Generated: {datetime.now().isoformat()}",
        "",
        f"Catalog source: `{catalog_path}`",
        "",
    ]

    for plate in PLATE_DEFINITIONS:
        refs = top_refs_for_plate(rows, plate)
        prompt = build_prompt(plate, refs[: plate.desired_refs])
        entry = {
            "id": plate.id,
            "title": plate.title,
            "canonical_location": plate.canonical_location,
            "narrative_use": plate.narrative_use,
            "visual_brief": plate.visual_brief,
            "continuity_anchors": plate.continuity_anchors,
            "prompt": prompt,
            "aspect_ratio": plate.aspect_ratio,
            "image_size": plate.image_size,
            "reference_candidates": refs,
            "test_pick": plate.test_pick,
        }
        matrix.append(entry)

        lines.extend(
            [
                f"## {plate.title}",
                "",
                f"- **Plate ID:** `{plate.id}`",
                f"- **Canonical location:** {plate.canonical_location}",
                f"- **Narrative use:** {plate.narrative_use}",
                f"- **Visual brief:** {plate.visual_brief}",
                "",
                "### Continuity anchors",
                "",
            ]
        )
        lines.extend([f"- {item}" for item in plate.continuity_anchors])
        lines.extend(["", "### Top reference candidates", ""])
        if refs:
            for ref in refs[:8]:
                lines.append(
                    f"- `{ref['relative_path']}` (score {ref['score']}) — {ref['summary']}"
                )
        else:
            lines.append("- No strong direct photo references found; generate from canon and material logic.")
        lines.extend(["", "### Prompt scaffold", "", "```", prompt, "```", ""])

    write_json(output_dir / "background_plate_matrix.json", matrix)
    (output_dir / "background_plate_matrix.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Matrix written to {output_dir}")
    return 0


def command_generate_tests(args: argparse.Namespace) -> int:
    api_key = load_api_key()
    matrix_path = Path(args.matrix_json).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    desktop_dir = Path(args.desktop_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    desktop_dir.mkdir(parents=True, exist_ok=True)

    matrix: list[dict[str, Any]] = json.loads(matrix_path.read_text(encoding="utf-8"))
    selected = [entry for entry in matrix if entry.get("test_pick")]
    selected = selected[: args.count]

    prompt_manifest: list[dict[str, Any]] = []
    review_items: list[dict[str, Any]] = []

    outputs_dir = output_dir / "outputs"
    outputs_dir.mkdir(parents=True, exist_ok=True)
    refs_dir = desktop_dir / "review_refs"
    imgs_dir = desktop_dir / "outputs"
    refs_dir.mkdir(parents=True, exist_ok=True)
    imgs_dir.mkdir(parents=True, exist_ok=True)

    for index, entry in enumerate(selected, start=1):
        refs = entry.get("reference_candidates") or []
        reference_paths = [Path(ref["path"]) for ref in refs[:3]]
        prompt = entry["prompt"]
        output_name = f"{index:02d}-{entry['id']}.png"
        if args.image_size is not None:
            resolved_image_size = args.image_size or None
        elif args.model.startswith("gemini-2.5-flash-image"):
            resolved_image_size = None
        else:
            resolved_image_size = entry.get("image_size") or "1K"

        image_bytes, response_text = generate_image(
            api_key=api_key,
            prompt=prompt,
            reference_paths=reference_paths,
            aspect_ratio=entry.get("aspect_ratio") or "16:9",
            image_size=resolved_image_size,
            model=args.model,
        )
        run_output_path = outputs_dir / output_name
        run_output_path.write_bytes(image_bytes)
        desktop_output_path = imgs_dir / output_name
        shutil.copy2(run_output_path, desktop_output_path)

        review_refs: list[dict[str, str]] = []
        for ref_index, ref in enumerate(refs[:3], start=1):
            source_path = Path(ref["path"])
            thumb_name = f"{index:02d}-{entry['id']}-{ref_index:02d}.jpg"
            thumb_path = refs_dir / thumb_name
            copy_thumb(source_path, thumb_path, max_dim=900)
            review_refs.append(
                {
                    "relative_path": ref["relative_path"],
                    "thumb_rel": f"review_refs/{thumb_name}",
                }
            )

        item = {
            "id": entry["id"],
            "title": entry["title"],
            "canonical_location": entry["canonical_location"],
            "prompt": prompt,
            "reference_paths": [str(path) for path in reference_paths],
            "response_text": response_text,
            "output_path": str(run_output_path),
        }
        prompt_manifest.append(item)
        review_items.append(
            {
                "id": entry["id"],
                "title": entry["title"],
                "canonical_location": entry["canonical_location"],
                "prompt": prompt,
                "output_rel": f"outputs/{output_name}",
                "review_refs": review_refs,
            }
        )
        print(f"[test] {index}/{len(selected)} generated {entry['title']}")

    write_json(output_dir / "prompt_manifest.json", {"prompts": prompt_manifest})
    prompt_md_lines = [
        "# Amira Background Plate Test Prompts",
        "",
        f"Generated: {datetime.now().isoformat()}",
        "",
    ]
    for index, item in enumerate(prompt_manifest, start=1):
        prompt_md_lines.extend(
            [
                f"## {index:02d}. {item['title']}",
                "",
                f"- **Plate ID:** `{item['id']}`",
                f"- **Location:** {item['canonical_location']}",
                f"- **Output:** `{item['output_path']}`",
                "",
                "### Reference images",
                "",
            ]
        )
        prompt_md_lines.extend([f"- `{path}`" for path in item["reference_paths"]])
        prompt_md_lines.extend(["", "### Prompt", "", "```", item["prompt"], "```", ""])
    (desktop_dir / "prompts.md").write_text("\n".join(prompt_md_lines).rstrip() + "\n", encoding="utf-8")
    write_review_html(desktop_dir / "index.html", args.packet_title, review_items)
    shutil.copy2(output_dir / "prompt_manifest.json", desktop_dir / "prompt_manifest.json")

    print(f"Immediate tests complete: {output_dir}")
    print(f"Desktop review packet: {desktop_dir}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Amira background-plate planning pipeline.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    catalog = subparsers.add_parser("catalog", help="Catalog all inspiration images with Gemini Flash-Lite.")
    catalog.add_argument("--inspiration-root", default=str(INSPIRATION_ROOT))
    catalog.add_argument("--output-dir", required=True)
    catalog.add_argument("--workers", type=int, default=4)
    catalog.add_argument("--group-size", type=int, default=4)

    matrix = subparsers.add_parser("build-matrix", help="Build the background plate matrix from a catalog.")
    matrix.add_argument("--catalog-json", required=True)
    matrix.add_argument("--output-dir", required=True)

    tests = subparsers.add_parser("generate-tests", help="Run immediate Gemini image tests from the matrix.")
    tests.add_argument("--matrix-json", required=True)
    tests.add_argument("--output-dir", required=True)
    tests.add_argument("--desktop-dir", required=True)
    tests.add_argument("--count", type=int, default=10)
    tests.add_argument("--model", default=IMAGE_MODEL)
    tests.add_argument("--image-size", default=None,
                       help="Override image size (for Gemini 2.5 Flash Image, omit this).")
    tests.add_argument("--packet-title", default="Amira Background Plate Tests")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "catalog":
        return command_catalog(args)
    if args.command == "build-matrix":
        return command_build_matrix(args)
    if args.command == "generate-tests":
        return command_generate_tests(args)
    raise AssertionError(f"Unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
