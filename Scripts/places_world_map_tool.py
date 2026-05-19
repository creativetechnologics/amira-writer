#!/usr/bin/env python3
"""Headless Places world-map tool.

Provides CLI access to the Amira Places master map and inferred pin placements
without opening the app UI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

DEFAULT_PROJECT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
MASTER_MAP_FALLBACK = "Animate/backgrounds/chosen-references/map/01-master_valley_topdown_map_4k_v5.png"

PROTOTYPES = [
    ("ridge_overlook", (0.115, 0.315), 110, ["the ridge", "ridge overlook", "ridge dawn", "mountain valley road", "convoy unload", "valley road", "base gate", "base perimeter"]),
    ("west_approach", (0.18, 0.38), 92, ["west approach", "west road", "south ridge", "high west ridge", "southwest long lens", "glacier context"]),
    ("base_tents", (0.14, 0.19), 95, ["comms tent", "operations tent", "tent row", "briefing room", "barracks", "base tent", "base roof", "base interior"]),
    ("memorial", (0.235, 0.57), 70, ["grave marker", "yasmin", "memorial", "cemetery", "river road", "riverbank", "ancient waters"]),
    ("riverside", (0.44, 0.565), 72, ["riverside", "river bend", "lower town riverside", "blue hour across river", "river path and town"]),
    ("bridge_ridge_approach", (0.285, 0.505), 86, ["bridge approach ridge", "approach ridge", "approach from the base", "ridge side of bridge", "bridge ahead"]),
    ("bridge_midspan", (0.34, 0.5), 90, ["the bridge", "bridge", "midspan", "onto the bridge", "stone bridge", "single-lane stone bridge"]),
    ("bridge_village_approach", (0.40, 0.505), 82, ["bridge approach village", "approach village", "town-side end of bridge", "bridge behind", "bridge end"]),
    ("marketplace", (0.47, 0.505), 77, ["marketplace", "town center", "market wall", "rubble field", "bombing site", "photo shop", "market entry"]),
    ("village_streets", (0.585, 0.47), 67, ["village street", "streets", "main road", "back alleys", "alley", "rooftop", "upper street", "village"]),
    ("village_edge", (0.72, 0.355), 52, ["village edge", "upper slope", "terraces", "residential lane", "neighborhood edge"]),
    ("gathering_space", (0.655, 0.445), 60, ["gathering space", "community center", "mosque", "courtyard"]),
    ("amira_home", (0.715, 0.425), 58, ["amira's home", "quiet moment", "home"]),
    ("clinic", (0.79, 0.39), 50, ["clinic", "clinic doorway", "clinic edge", "back room", "treatment area"]),
    ("shepherds_huts", (0.885, 0.29), 35, ["shepherd", "huts", "hillside", "sunrise", "escape destination", "mountain overlook"]),
]

ANCHOR_RE = re.compile(r"Map anchor: normalized x ([0-9.]+), y ([0-9.]+) on the master map")
HEADING_RE = re.compile(r"Camera pose: heading ([0-9.\-]+) degrees")
FOCAL_RE = re.compile(r"focal length ([0-9.]+)mm")

MAP_TERMS = [
    "topdown", "top-down", "master map", "world map", "bird's-eye", "birds-eye", "satellite view", "orthographic",
    "from master map", "master_valley", "valley_master", "angled_valley_from_master_map", "ultrawide master"
]
INTERIOR_TERMS = ["interior", "room", "back room", "briefing room", "operations tent", "comms tent", "treatment", "lamplight", "inside", "home", "quiet moment"]
STEM_STRUCTURED_HINT_RE = re.compile(r"^(town-\d+|town-wide-\d+|bridge-design-\d+|route-|canon-\d+|confirm-|retry-)")

TRUSTED_SOURCES = {"exact"}
PROVISIONAL_SOURCES = {"batch_prompt", "stem_profile", "place_anchor", "semantic_zone", "stored_inferred"}
REVIEWABLE_SOURCES = {"batch_prompt", "stem_profile", "place_anchor", "semantic_zone", "stored_inferred"}
MIRROR_PAIRS = {
    frozenset(("bridge_ridge_approach", "bridge_village_approach")),
}
EXTERIOR_ZONES = {
    "ridge_overlook", "west_approach", "memorial", "riverside", "bridge_ridge_approach", "bridge_midspan",
    "bridge_village_approach", "marketplace", "village_streets", "village_edge", "gathering_space", "shepherds_huts",
}
BUILDING_ANCHOR_ZONES = {"base_tents", "amira_home", "clinic", "gathering_space"}
PROTO_BY_ID = {item[0]: item for item in PROTOTYPES}


def project_paths(project: Path) -> tuple[Path, Path, Path]:
    animate = project / "Animate"
    places = project / "Places"
    return animate, places / "places-workflow.json", places / "places.json"


def world_map_canon_path(project: Path) -> Path:
    return project / "Places" / "places-world-map-canon.json"


def path_relative_to_project(project: Path, raw_path: str | None) -> str | None:
    cleaned = clean(raw_path)
    if not cleaned:
        return None
    candidate = Path(cleaned)
    try:
        if candidate.is_absolute():
            return candidate.resolve().relative_to(project.resolve()).as_posix()
    except Exception:
        pass
    normalized = cleaned.replace("\\", "/").lstrip("./")
    if normalized.startswith(project.name + "/"):
        normalized = normalized.split("/", 1)[1]
    return normalized


def stable_record_key(project: Path, raw_path: str | None) -> str | None:
    relative = path_relative_to_project(project, raw_path)
    if not relative:
        return None
    digest = hashlib.sha1(relative.lower().encode("utf-8")).hexdigest()[:12]
    return f"path::{relative.lower()}#{digest}"


def record_lookup_keys(project: Path, record: dict[str, Any]) -> list[str]:
    keys: list[str] = []
    stable = stable_record_key(project, record.get("activePath"))
    if stable:
        keys.append(stable)
    stem = cleaned_lower(Path(record.get("activePath") or "").stem)
    if stem:
        keys.append(f"stem::{stem}")
    return keys


def stable_place_key(place: dict[str, Any]) -> str | None:
    name = cleaned_lower(place.get("name"))
    if name:
        return f"name::{name}"
    return cleaned_lower(place.get("id"))


def empty_world_map_canon() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "updatedAt": None,
        "generatedRecords": {},
        "placeAnchors": {},
    }


def load_world_map_canon(project: Path) -> dict[str, Any]:
    path = world_map_canon_path(project)
    if not path.exists():
        return empty_world_map_canon()
    try:
        payload = load_json(path)
    except Exception:
        return empty_world_map_canon()
    if not isinstance(payload, dict):
        return empty_world_map_canon()
    payload.setdefault("schemaVersion", 1)
    payload.setdefault("updatedAt", None)
    payload.setdefault("generatedRecords", {})
    payload.setdefault("placeAnchors", {})
    return payload


def save_world_map_canon(project: Path, canon: dict[str, Any]) -> Path:
    path = world_map_canon_path(project)
    canon["updatedAt"] = now_iso()
    save_json(path, canon)
    return path


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def save_json(path: Path, obj: Any) -> None:
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def clean(text: str | None) -> str:
    return (text or "").strip()


def cleaned_lower(text: str | None) -> str:
    return clean(text).lower()


def clamp01(value: float, lower: float = 0.03, upper: float = 0.97) -> float:
    return min(max(float(value), lower), upper)


def angular_difference(a: float | None, b: float | None) -> float | None:
    if a is None or b is None:
        return None
    return abs(((float(a) - float(b) + 180.0) % 360.0) - 180.0)


def canonical_master_map_path(workflow: dict[str, Any]) -> str:
    explicit = workflow.get("masterMapImagePath")
    if explicit:
        return explicit
    for record in workflow.get("generatedImageRecords", []):
        path = (record.get("activePath") or "").lower()
        summary = (record.get("summary") or "").lower()
        keywords = {k.lower() for k in record.get("keywords") or []}
        if "/backgrounds/chosen-references/map/" in path and ("map" in keywords or "topdown" in keywords or "master" in summary):
            return record["activePath"]
    return MASTER_MAP_FALLBACK


def restore_master_map(project: Path) -> Path:
    _, workflow_path, _ = project_paths(project)
    workflow = load_json(workflow_path)
    master_path = canonical_master_map_path(workflow)
    workflow["masterMapImagePath"] = master_path
    save_json(workflow_path, workflow)
    return project / master_path


def places_lookup(places_json: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {place["id"]: place for place in places_json if "id" in place}


def places_lookup_by_name(places_json: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {cleaned_lower(place.get("name")): place for place in places_json if place.get("name")}


def merge_camera_pose(existing: dict[str, Any] | None, override: dict[str, Any] | None) -> dict[str, Any]:
    pose = dict(existing or {})
    for key in ("yawDegrees", "pitchDegrees", "rollDegrees", "focalLengthMM"):
        if override and override.get(key) is not None:
            pose[key] = override[key]
    return pose


def apply_record_canon_overrides(project: Path, workflow: dict[str, Any], canon: dict[str, Any]) -> None:
    generated = canon.get("generatedRecords") or {}
    if not isinstance(generated, dict):
        return
    for record in workflow.get("generatedImageRecords", []):
        entry = None
        for key in record_lookup_keys(project, record):
            candidate = generated.get(key)
            if isinstance(candidate, dict):
                entry = candidate
                break
        if entry is None:
            stem = cleaned_lower(Path(record.get("activePath") or "").stem)
            if stem:
                for candidate in generated.values():
                    if isinstance(candidate, dict) and cleaned_lower(candidate.get("filenameStem")) == stem:
                        entry = candidate
                        break
        if not entry:
            continue
        if isinstance(entry.get("mapPoint"), dict):
            point = entry["mapPoint"]
            if point.get("x") is not None and point.get("y") is not None:
                record["mapPoint"] = {
                    "x": clamp01(point["x"]),
                    "y": clamp01(point["y"]),
                }
        if entry.get("cameraPose"):
            record["cameraPose"] = merge_camera_pose(record.get("cameraPose"), entry.get("cameraPose"))
        if entry.get("mapPlacementStatus"):
            record["mapPlacementStatus"] = entry["mapPlacementStatus"]
        if entry.get("mapPlacementConfirmedAt"):
            record["mapPlacementConfirmedAt"] = entry["mapPlacementConfirmedAt"]
        if entry.get("orientationState"):
            record["orientationState"] = entry["orientationState"]
        meta = record.setdefault("worldMapTool", {}) if isinstance(record, dict) else {}
        if isinstance(meta, dict):
            if entry.get("orientationConfirmedAt"):
                meta["orientationConfirmedAt"] = entry["orientationConfirmedAt"]
                meta["orientationConfirmedState"] = entry.get("orientationState")
            if entry.get("worldMapTool") and isinstance(entry["worldMapTool"], dict):
                meta.update(entry["worldMapTool"])


def apply_place_anchor_canon_overrides(workflow: dict[str, Any], places_json: list[dict[str, Any]], canon: dict[str, Any]) -> None:
    anchors = canon.get("placeAnchors") or {}
    if not isinstance(anchors, dict):
        return
    places_by_name = places_lookup_by_name(places_json)
    places_by_id = places_lookup(places_json)
    for place in places_json:
        entry = None
        place_name_key = stable_place_key(place)
        if place_name_key:
            candidate = anchors.get(place_name_key)
            if isinstance(candidate, dict):
                entry = candidate
        if entry is None and place.get("id"):
            candidate = anchors.get(str(place.get("id")).lower())
            if isinstance(candidate, dict):
                entry = candidate
        if not entry:
            continue

        anchor_place = None
        anchor_place_id = entry.get("anchorPlaceID")
        if anchor_place_id:
            anchor_place = places_by_id.get(anchor_place_id)
        if anchor_place is None and entry.get("anchorPlaceName"):
            anchor_place = places_by_name.get(cleaned_lower(entry.get("anchorPlaceName")))

        anchor_node = None
        if anchor_place is not None:
            anchor_node = node_for_place(workflow, anchor_place.get("id"))

        world_map_tool = dict(place.get("worldMapTool") or {})
        for key in ("kind", "anchorHeading", "linkedAt"):
            if entry.get(key) is not None:
                world_map_tool[key] = entry[key]
        if anchor_place is not None:
            world_map_tool["anchorPlaceID"] = anchor_place.get("id")
            world_map_tool["anchorPlaceName"] = anchor_place.get("name")
            place["linkedExteriorPlaceID"] = anchor_place.get("id") if anchor_place.get("id") != place.get("id") else place.get("linkedExteriorPlaceID")
        elif entry.get("anchorPlaceName"):
            world_map_tool["anchorPlaceName"] = entry.get("anchorPlaceName")

        if anchor_node is not None:
            world_map_tool["anchorNodeID"] = anchor_node.get("id")
            place["buildingAnchorNodeID"] = anchor_node.get("id")
        elif entry.get("anchorNodeID"):
            world_map_tool["anchorNodeID"] = entry.get("anchorNodeID")

        if isinstance(entry.get("anchorPoint"), dict):
            point = entry["anchorPoint"]
            if point.get("x") is not None and point.get("y") is not None:
                world_map_tool["anchorPoint"] = {
                    "x": clamp01(point["x"]),
                    "y": clamp01(point["y"]),
                }
        if isinstance(entry.get("offset"), dict):
            world_map_tool["offset"] = {
                "x": float(entry["offset"].get("x", 0.0) or 0.0),
                "y": float(entry["offset"].get("y", 0.0) or 0.0),
            }

        if world_map_tool:
            place["worldMapTool"] = world_map_tool


def load_project_state(project: Path) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    _, workflow_path, places_path = project_paths(project)
    workflow = load_json(workflow_path)
    places_json = load_json(places_path)
    canon = load_world_map_canon(project)
    apply_record_canon_overrides(project, workflow, canon)
    apply_place_anchor_canon_overrides(workflow, places_json, canon)
    return workflow, places_json, canon


def batch_prompt_anchors(project: Path) -> dict[str, dict[str, float | None]]:
    animate, _, _ = project_paths(project)
    root = animate / "backgrounds" / "place-batches"
    anchors: dict[str, dict[str, float | None]] = {}
    if not root.exists():
        return anchors
    for submission in root.rglob("batch_submission.json"):
        data = load_json(submission)
        for entry in data.get("prompt_manifest", []):
            key = (entry.get("id") or Path(entry.get("title") or "").stem).lower()
            prompt = entry.get("prompt") or ""
            anchor = ANCHOR_RE.search(prompt)
            heading = HEADING_RE.search(prompt)
            focal = FOCAL_RE.search(prompt)
            if anchor:
                anchors[key] = {
                    "x": float(anchor.group(1)),
                    "y": float(anchor.group(2)),
                    "heading": float(heading.group(1)) if heading else None,
                    "focal": float(focal.group(1)) if focal else None,
                }
    return anchors


def metadata_text(record: dict[str, Any], place: dict[str, Any] | None) -> str:
    return " ".join(
        [
            record.get("summary") or "",
            " ".join(record.get("keywords") or []),
            record.get("sourcePrompt") or "",
            (place or {}).get("name") or "",
            (place or {}).get("notes") or "",
            (place or {}).get("workflowPromptNotes") or "",
            Path(record.get("activePath") or "").stem.replace("-", " "),
        ]
    ).lower()


def best_prototype(text: str):
    best = None
    best_score = 0.0
    for proto_id, point, heading, aliases in PROTOTYPES:
        score = 0.0
        for alias in aliases:
            alias = alias.lower()
            if alias in text:
                score += 1.1 if " " in alias else 0.45
        if score > best_score:
            best_score = score
            best = (proto_id, point, heading, score)
    return best


def top_prototypes(text: str, limit: int = 3) -> list[dict[str, Any]]:
    scored: list[tuple[float, str, tuple[float, float], float]] = []
    for proto_id, point, heading, aliases in PROTOTYPES:
        score = 0.0
        for alias in aliases:
            alias = alias.lower()
            if alias in text:
                score += 1.1 if " " in alias else 0.45
        if score > 0:
            scored.append((score, proto_id, point, heading))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [
        {"prototype": proto_id, "score": score, "x": point[0], "y": point[1], "heading": heading}
        for score, proto_id, point, heading in scored[:limit]
    ]


def scene_kind(record: dict[str, Any]) -> str:
    text = metadata_text(record, None)
    if any(term in text for term in MAP_TERMS):
        return "map"
    if any(term in text for term in INTERIOR_TERMS):
        return "interior"
    if any(term in text for term in ["design", "study", "geometry", "profile", "documentary"]):
        return "design"
    return "exterior"


def place_text(place: dict[str, Any] | None) -> str:
    if not place:
        return ""
    refs = " ".join(
        " ".join(
            [
                ref.get("title") or "",
                ref.get("notes") or "",
                ref.get("category") or "",
            ]
        )
        for ref in place.get("referenceImages") or []
        if isinstance(ref, dict)
    )
    return " ".join(
        [
            place.get("name") or "",
            place.get("notes") or "",
            place.get("workflowPromptNotes") or "",
            refs,
        ]
    ).lower()


def exact_stem_prototype(stem: str) -> str | None:
    s = stem.lower()
    mappings = [
        (lambda v: v.startswith("town-01") or v.startswith("town-wide-21") or v.startswith("town-wide-22") or v.startswith("town-wide-34") or v.startswith("town-wide-36"), "ridge_overlook"),
        (lambda v: v.startswith("town-02") or v.startswith("town-wide-23") or v.startswith("town-wide-26") or v.startswith("town-wide-27") or v.startswith("town-wide-40") or "west-road" in v, "west_approach"),
        (lambda v: v.startswith("town-03") or v.startswith("town-wide-30") or v.startswith("town-wide-35"), "riverside"),
        (lambda v: v.startswith("town-04") or v.startswith("town-05") or v.startswith("town-06") or "confirm-market" in v or "market-entry" in v, "marketplace"),
        (lambda v: v.startswith("town-07") or v.startswith("town-08") or v.startswith("town-09") or v.startswith("town-10") or v.startswith("town-wide-38") or "alley" in v, "village_streets"),
        (lambda v: v.startswith("town-11") or v.startswith("town-19") or v.startswith("town-wide-31") or v.startswith("town-wide-32") or v.startswith("town-wide-37"), "village_edge"),
        (lambda v: v.startswith("town-12") or "gathering-space" in v or "gathering_space" in v, "gathering_space"),
        (lambda v: v.startswith("town-13") or v.startswith("town-14") or v.startswith("town-15") or "clinic" in v, "clinic"),
        (lambda v: v.startswith("town-16") or v.startswith("town-17") or v.startswith("town-wide-39") or "bridge-into-town" in v or "town-toward-bridge" in v, "bridge_village_approach"),
        (lambda v: v.startswith("town-18") or v.startswith("town-wide-24") or v.startswith("town-wide-25") or "grave-marker" in v or "river-road" in v, "memorial"),
        (lambda v: "bridge-design-01" in v or "bridge-design-04" in v or "bridge-design-10" in v, "bridge_midspan"),
        (lambda v: "bridge-design-02" in v or "bridge-design-09" in v or "confirm-town-side-bridge-exit" in v, "bridge_village_approach"),
        (lambda v: "bridge-design-03" in v or "bridge-design-05" in v or "bridge-design-06" in v or "retry-bridge-approach" in v or "route-west-approach" in v, "bridge_ridge_approach"),
        (lambda v: "bridge-design-07" in v or "bridge-design-08" in v or "bridge-hero" in v, "bridge_midspan"),
        (lambda v: "amiras_home" in v or "quiet-moment" in v, "amira_home"),
        (lambda v: "briefing-room" in v or "operations-tent" in v or "comms-tent" in v or "bunk" in v, "base_tents"),
        (lambda v: "hillside" in v or "shepherd" in v, "shepherds_huts"),
    ]
    for matcher, proto_id in mappings:
        if matcher(s):
            return proto_id
    return None


def stable_offset(index: int, key: str, radius: float):
    h = abs(hash(key))
    angle = ((h + index * 37) % 360) * math.pi / 180.0
    ring = 0.35 + ((h // 97) % 100) / 100.0
    return math.cos(angle) * radius * ring, math.sin(angle) * radius * ring


def stem_profile_diagnostics(record: dict[str, Any], place: dict[str, Any] | None) -> list[str]:
    path = record.get("activePath") or ""
    stem = Path(path).stem.lower()
    diagnostics: list[str] = []
    stem_proto = exact_stem_prototype(stem)
    candidates = top_prototypes(metadata_text(record, place), limit=3)

    if STEM_STRUCTURED_HINT_RE.search(stem) and stem_proto is None:
        diagnostics.append("structured filename has no exact stem-profile mapping")

    if len(candidates) >= 2:
        delta = abs(float(candidates[0]["score"]) - float(candidates[1]["score"]))
        if delta <= 0.35 and candidates[0]["prototype"] != candidates[1]["prototype"]:
            diagnostics.append(
                f"semantic placement is ambiguous between {candidates[0]['prototype']} ({candidates[0]['score']:.2f}) and {candidates[1]['prototype']} ({candidates[1]['score']:.2f})"
            )

    if stem_proto and candidates:
        semantic_proto = candidates[0]["prototype"]
        if semantic_proto != stem_proto:
            diagnostics.append(f"stem profile points to {stem_proto} but semantic text leans toward {semantic_proto}")

    ptext = place_text(place)
    if "bridge" in ptext and stem_proto not in {None, "bridge_ridge_approach", "bridge_midspan", "bridge_village_approach"}:
        diagnostics.append("place references mention bridge but stem profile resolves outside bridge zones")
    if "clinic" in ptext and stem_proto not in {None, "clinic"} and "clinic" in stem:
        diagnostics.append("clinic-named asset is not captured by clinic stem profile")

    return diagnostics


def unresolved_diagnostics(record: dict[str, Any], place: dict[str, Any] | None, placement: dict[str, Any] | None) -> list[str]:
    diagnostics = stem_profile_diagnostics(record, place)
    if placement is None:
        if scene_kind(record) == "exterior":
            diagnostics.append("no trustworthy exterior placement candidate")
        return diagnostics
    if placement.get("source") == "semantic_zone":
        diagnostics.append("placement depends on weak semantic-zone inference only")
    if placement.get("source") in {"place_anchor", "stored_inferred"} and scene_kind(record) == "exterior":
        diagnostics.append(f"placement is trust-limited because it depends on {placement.get('source')}")
    return diagnostics


def eligible_world_record(record: dict[str, Any], workflow_mode: str) -> bool:
    if record.get("workflow") != workflow_mode:
        return False
    if record.get("isRejected"):
        return False
    kind = scene_kind(record)
    return kind not in {"map", "design"}


def world_graph_nodes(workflow: dict[str, Any]) -> list[dict[str, Any]]:
    return (workflow.get("worldGraph") or {}).get("nodes") or []


def node_for_place(workflow: dict[str, Any], place_id: str | None) -> dict[str, Any] | None:
    if not place_id:
        return None
    candidates = [
        node for node in world_graph_nodes(workflow)
        if node.get("placeID") == place_id
    ]
    candidates.sort(key=lambda node: (0 if node.get("role") == "landmark" else 1, node.get("sequenceIndex") or 0, node.get("title") or ""))
    return candidates[0] if candidates else None


def record_lookup(workflow: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {record.get("id"): record for record in workflow.get("generatedImageRecords", []) if record.get("id")}


def find_record(workflow: dict[str, Any], selector: str) -> dict[str, Any] | None:
    records = workflow.get("generatedImageRecords", [])
    query = cleaned_lower(selector)
    if not query:
        return None
    exact = next((r for r in records if cleaned_lower(r.get("id")) == query), None)
    if exact:
        return exact
    exact = next((r for r in records if cleaned_lower(r.get("activePath")) == query), None)
    if exact:
        return exact
    exact = next((r for r in records if cleaned_lower(Path(r.get("activePath") or "").stem) == query), None)
    if exact:
        return exact
    substring = [
        r for r in records
        if query in cleaned_lower(r.get("summary"))
        or query in cleaned_lower(r.get("activePath"))
        or query in cleaned_lower(Path(r.get("activePath") or "").stem)
    ]
    if len(substring) == 1:
        return substring[0]
    return None


def find_place(places_json: list[dict[str, Any]], selector: str) -> dict[str, Any] | None:
    query = cleaned_lower(selector)
    if not query:
        return None
    exact = next((p for p in places_json if cleaned_lower(p.get("id")) == query), None)
    if exact:
        return exact
    exact = next((p for p in places_json if cleaned_lower(p.get("name")) == query), None)
    if exact:
        return exact
    matches = [p for p in places_json if query in cleaned_lower(p.get("name"))]
    if len(matches) == 1:
        return matches[0]
    return None


def anchor_metadata(place: dict[str, Any]) -> dict[str, Any] | None:
    nested = place.get("worldMapTool")
    if isinstance(nested, dict):
        return nested
    if place.get("buildingAnchorNodeID") or place.get("linkedExteriorPlaceID"):
        return {
            "anchorPlaceID": place.get("linkedExteriorPlaceID") or place.get("id"),
            "anchorNodeID": place.get("buildingAnchorNodeID"),
            "kind": "interior" if cleaned_lower(place.get("locationCategory")) == "interior" else "linked_place",
        }
    flat_keys = [
        "anchorPlaceID", "anchorPlaceName", "anchorNodeID", "anchorPoint", "offset", "kind"
    ]
    if any(key in place for key in flat_keys):
        return {
            "anchorPlaceID": place.get("anchorPlaceID"),
            "anchorPlaceName": place.get("anchorPlaceName"),
            "anchorNodeID": place.get("anchorNodeID"),
            "anchorPoint": place.get("anchorPoint"),
            "offset": place.get("offset"),
            "kind": place.get("kind"),
        }
    return None


def anchor_point_from_metadata(meta: dict[str, Any] | None) -> tuple[float, float] | None:
    if not meta:
        return None
    point = meta.get("anchorPoint")
    if isinstance(point, dict) and point.get("x") is not None and point.get("y") is not None:
        return float(point["x"]), float(point["y"])
    return None


def resolve_place_anchor(place: dict[str, Any], workflow: dict[str, Any], places_by_id: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    meta = anchor_metadata(place)
    if not meta:
        return None
    anchor_place_id = meta.get("anchorPlaceID")
    anchor_place = places_by_id.get(anchor_place_id) if anchor_place_id else None
    anchor_node = None
    if meta.get("anchorNodeID"):
        anchor_node = next((node for node in world_graph_nodes(workflow) if node.get("id") == meta.get("anchorNodeID")), None)
    if anchor_node is None and anchor_place_id:
        anchor_node = node_for_place(workflow, anchor_place_id)

    point = anchor_point_from_metadata(meta)
    heading = None
    focal = None
    source = "place_anchor_meta"
    if anchor_node:
        point = point or (
            float(anchor_node.get("mapPoint", {}).get("x", 0.5)),
            float(anchor_node.get("mapPoint", {}).get("y", 0.5)),
        )
        pose = anchor_node.get("cameraPose") or {}
        heading = pose.get("yawDegrees")
        focal = pose.get("focalLengthMM")
        source = "anchor_node"

    if point is None:
        return None

    offset = meta.get("offset") if isinstance(meta.get("offset"), dict) else {}
    dx = float(offset.get("x", 0.0) or 0.0)
    dy = float(offset.get("y", 0.0) or 0.0)
    return {
        "point": (clamp01(point[0] + dx), clamp01(point[1] + dy)),
        "heading": heading,
        "focal": focal,
        "anchor_place": anchor_place,
        "anchor_node": anchor_node,
        "source": source,
        "kind": meta.get("kind") or "linked_place",
    }


def prototype_candidates_for_record(record: dict[str, Any], place: dict[str, Any] | None) -> list[dict[str, Any]]:
    return top_prototypes(metadata_text(record, place), limit=3)


def placement_base(record: dict[str, Any], place: dict[str, Any] | None, project: Path, anchors: dict[str, dict[str, float | None]], workflow: dict[str, Any], places_by_id: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    path = record.get("activePath") or ""
    stem = Path(path).stem.lower()
    kind = scene_kind(record)
    placement_status = cleaned_lower(record.get("mapPlacementStatus")) or ("inferred" if record.get("mapPoint") or record.get("cameraPose") else "unplaced")

    if record.get("worldNodeID"):
        node = next((node for node in world_graph_nodes(workflow) if node.get("id") == record.get("worldNodeID")), None)
        if node and node.get("mapPoint"):
            pose = record.get("cameraPose") or node.get("cameraPose") or {}
            return {
                "x": float(node["mapPoint"]["x"]),
                "y": float(node["mapPoint"]["y"]),
                "heading": pose.get("yawDegrees"),
                "focal": pose.get("focalLengthMM"),
                "source": "exact",
                "confidence": 1.0,
                "bucket": "node_anchor",
            }

    if record.get("buildingAnchorNodeID"):
        node = next((node for node in world_graph_nodes(workflow) if node.get("id") == record.get("buildingAnchorNodeID")), None)
        if node and node.get("mapPoint"):
            pose = record.get("cameraPose") or node.get("cameraPose") or {}
            return {
                "x": float(node["mapPoint"]["x"]),
                "y": float(node["mapPoint"]["y"]),
                "heading": pose.get("yawDegrees"),
                "focal": pose.get("focalLengthMM"),
                "source": "exact",
                "confidence": 1.0,
                "bucket": "building_anchor",
            }

    if record.get("mapPoint") and placement_status == "confirmed":
        pose = record.get("cameraPose") or {}
        return {
            "x": float(record["mapPoint"]["x"]),
            "y": float(record["mapPoint"]["y"]),
            "heading": pose.get("yawDegrees"),
            "focal": pose.get("focalLengthMM"),
            "source": "exact",
            "confidence": 1.0,
            "bucket": "exact",
        }

    if record.get("mapPoint"):
        pose = record.get("cameraPose") or {}
        return {
            "x": float(record["mapPoint"]["x"]),
            "y": float(record["mapPoint"]["y"]),
            "heading": pose.get("yawDegrees"),
            "focal": pose.get("focalLengthMM"),
            "source": "stored_inferred",
            "confidence": 0.89,
            "bucket": "stored_inferred",
        }

    if stem in anchors:
        data = anchors[stem]
        return {
            "x": float(data["x"]),
            "y": float(data["y"]),
            "heading": data.get("heading"),
            "focal": data.get("focal"),
            "source": "batch_prompt",
            "confidence": 0.98,
            "bucket": "batch_prompt",
        }

    if place:
        resolved_anchor = resolve_place_anchor(place, workflow, places_by_id)
        if resolved_anchor is not None and resolved_anchor.get("point") is not None:
            point = resolved_anchor["point"]
            return {
                "x": float(point[0]),
                "y": float(point[1]),
                "heading": resolved_anchor.get("heading"),
                "focal": resolved_anchor.get("focal") or 35,
                "source": "place_anchor",
                "confidence": 0.9 if kind == "interior" else 0.86,
                "bucket": f"anchor:{cleaned_lower((resolved_anchor.get('anchor_place') or {}).get('name')) or 'place'}",
                "anchor_place_name": (resolved_anchor.get("anchor_place") or {}).get("name"),
                "anchor_kind": resolved_anchor.get("kind"),
            }

    exact_proto_id = exact_stem_prototype(stem)
    proto = PROTO_BY_ID.get(exact_proto_id) if exact_proto_id else None
    if proto is None:
        proto = best_prototype(metadata_text(record, place))
    if proto is None:
        return None

    proto_id, point, proto_heading, score = proto
    return {
        "x": float(point[0]),
        "y": float(point[1]),
        "heading": proto_heading,
        "focal": 35,
        "source": "stem_profile" if exact_proto_id else "semantic_zone",
        "confidence": 0.94 if exact_proto_id else min(0.82, 0.54 + score * 0.08),
        "bucket": proto_id,
        "prototype_score": score,
    }


def mirror_suspect_reasons(record: dict[str, Any], place: dict[str, Any] | None, placement: dict[str, Any]) -> list[str]:
    text = metadata_text(record, place)
    stem = Path(record.get("activePath") or "").stem.lower()
    reasons: list[str] = []
    bucket = placement.get("bucket")
    stem_proto = exact_stem_prototype(stem)
    semantic_candidates = top_prototypes(text, limit=2)
    semantic_proto = semantic_candidates[0]["prototype"] if semantic_candidates else None

    if stem_proto and semantic_proto and stem_proto != semantic_proto and frozenset((stem_proto, semantic_proto)) in MIRROR_PAIRS:
        reasons.append(f"stem profile suggests {stem_proto} but semantic text suggests {semantic_proto}")

    opposite_hints = {
        "bridge_ridge_approach": ["town-side", "town side", "village-side", "village side", "bridge behind", "into town", "town toward bridge"],
        "bridge_village_approach": ["ridge-side", "ridge side", "from base", "approach ridge", "bridge ahead", "west approach"],
    }
    for hint in opposite_hints.get(bucket, []):
        if hint in text:
            reasons.append(f"text contains opposite-side hint: '{hint}'")
            break

    proto = PROTO_BY_ID.get(bucket)
    if proto:
        _, _, proto_heading, _ = proto
        delta = angular_difference(placement.get("heading"), proto_heading)
        if delta is not None and delta > 120:
            reasons.append(f"heading {placement.get('heading'):.0f}° diverges sharply from {bucket} prototype heading {proto_heading:.0f}°")

    if any(token in text for token in ["mirror", "mirrored", "flipped"]):
        reasons.append("prompt or summary explicitly mentions mirror/flipped")

    return reasons


def infer_placements(project: Path, workflow_mode: str = "photorealistic") -> list[dict[str, Any]]:
    workflow, places_json, _ = load_project_state(project)
    places = places_lookup(places_json)
    anchors = batch_prompt_anchors(project)

    entries: list[dict[str, Any]] = []
    buckets: dict[str, list[int]] = {}
    for record in workflow.get("generatedImageRecords", []):
        if not eligible_world_record(record, workflow_mode):
            continue
        path = record.get("activePath") or ""
        record_id = record.get("id")
        place = places.get(record.get("linkedPlaceID") or "")

        base = placement_base(record, place, project, anchors, workflow, places)
        if base is None:
            continue

        entry = {
            "record_id": record_id,
            "path": path,
            "title": record.get("summary") or Path(path).stem,
            "place_name": (place or {}).get("name"),
            "x": float(base["x"]),
            "y": float(base["y"]),
            "base_x": float(base["x"]),
            "base_y": float(base["y"]),
            "heading": base.get("heading"),
            "focal": base.get("focal"),
            "source": base.get("source"),
            "confidence": float(base.get("confidence", 0.0)),
            "rating": record.get("rating"),
            "bucket": base.get("bucket"),
            "scene_kind": scene_kind(record),
            "anchor_place_name": base.get("anchor_place_name"),
            "anchor_kind": base.get("anchor_kind"),
            "prototype_candidates": prototype_candidates_for_record(record, place),
        }
        entry["mirror_suspect_reasons"] = mirror_suspect_reasons(record, place, entry)
        entry["mirror_suspect"] = bool(entry["mirror_suspect_reasons"])
        buckets.setdefault(entry["bucket"], []).append(len(entries))
        entries.append(entry)

    for bucket, indices in buckets.items():
        for idx, entry_index in enumerate(indices):
            entry = entries[entry_index]
            if entry["source"] in TRUSTED_SOURCES:
                entry["jitter_dx"] = 0.0
                entry["jitter_dy"] = 0.0
                continue
            radius = max(0.006, 0.024 * (1.0 - entry["confidence"]))
            dx, dy = stable_offset(idx, entry["path"], radius)
            entry["x"] = clamp01(entry["x"] + dx)
            entry["y"] = clamp01(entry["y"] + dy)
            entry["jitter_dx"] = dx
            entry["jitter_dy"] = dy

    return sorted(entries, key=lambda e: ((e["place_name"] or ""), e["title"]))


def placement_lookup(project: Path, workflow_mode: str = "photorealistic") -> dict[str, dict[str, Any]]:
    return {entry["record_id"]: entry for entry in infer_placements(project, workflow_mode=workflow_mode) if entry.get("record_id")}


def list_unplaced(project: Path, workflow_mode: str = "photorealistic", include_weak: bool = True) -> list[dict[str, Any]]:
    workflow, places_json, _ = load_project_state(project)
    places = places_lookup(places_json)
    placements = placement_lookup(project, workflow_mode)
    missing: list[dict[str, Any]] = []
    for record in workflow.get("generatedImageRecords", []):
        if not eligible_world_record(record, workflow_mode):
            continue
        placement = placements.get(record.get("id"))
        if placement is None:
            state = "missing"
            reason = "no trustworthy placement candidate"
        elif placement["source"] == "semantic_zone" and include_weak:
            state = "weak"
            reason = f"only weak semantic-zone candidate ({placement['bucket']}, conf {placement['confidence']:.2f})"
        else:
            continue
        place = places.get(record.get("linkedPlaceID") or "")
        diagnostics = unresolved_diagnostics(record, place, placement)
        missing.append({
            "record_id": record.get("id"),
            "path": record.get("activePath"),
            "title": record.get("summary") or Path(record.get("activePath") or "").stem,
            "place_name": (place or {}).get("name"),
            "scene_kind": scene_kind(record),
            "state": state,
            "reason": reason,
            "prototype_candidates": prototype_candidates_for_record(record, place),
            "diagnostics": diagnostics,
        })
    return missing


def provisional_placements(project: Path, workflow_mode: str = "photorealistic", include_weak: bool = True) -> list[dict[str, Any]]:
    items = [entry for entry in infer_placements(project, workflow_mode=workflow_mode) if entry.get("source") in REVIEWABLE_SOURCES]
    if not include_weak:
        items = [entry for entry in items if entry.get("source") != "semantic_zone"]
    return items


def mirror_suspects(project: Path, workflow_mode: str = "photorealistic") -> list[dict[str, Any]]:
    return [entry for entry in infer_placements(project, workflow_mode=workflow_mode) if entry.get("mirror_suspect")]


def file_url(path: Path) -> str:
    return "file://" + quote(str(path))


def write_overlay_svg(project: Path, output: Path | None = None, workflow_mode: str = "photorealistic") -> Path:
    animate, workflow_path, _ = project_paths(project)
    workflow = load_json(workflow_path)
    master_map = canonical_master_map_path(workflow)
    master_map_abs = project / master_map

    placements = infer_placements(project, workflow_mode=workflow_mode)
    out = output or (animate / "debug" / f"places-world-map-{workflow_mode}.svg")
    out.parent.mkdir(parents=True, exist_ok=True)
    width = 1600
    height = 1000
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#101317"/>',
        f'<image href="{file_url(master_map_abs)}" x="0" y="0" width="{width}" height="{height}" preserveAspectRatio="xMidYMid meet"/>',
        '<rect x="0" y="0" width="100%" height="100%" fill="rgba(0,0,0,0.08)"/>',
    ]
    for item in placements:
        x = item["x"] * width
        y = item["y"] * height
        heading = item.get("heading")
        if heading is not None:
            angle = math.radians(float(heading) - 90)
            spread = math.radians(18)
            radius = 90
            x1 = x + math.cos(angle - spread) * radius
            y1 = y + math.sin(angle - spread) * radius
            x2 = x + math.cos(angle + spread) * radius
            y2 = y + math.sin(angle + spread) * radius
            lines.append(f'<path d="M {x:.1f},{y:.1f} L {x1:.1f},{y1:.1f} A {radius},{radius} 0 0,1 {x2:.1f},{y2:.1f} Z" fill="rgba(93,173,226,0.16)" stroke="rgba(93,173,226,0.28)" stroke-width="1"/>')
        color = "#ff5c5c" if item.get("rating") == 1 else ("#7ed957" if (item.get("rating") or 0) >= 5 else "#f4d35e")
        lines.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="8" fill="{color}" stroke="#111" stroke-width="1.5"/>')
        label = (item.get("title") or "").replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        lines.append(f'<text x="{x + 12:.1f}" y="{y - 12:.1f}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="14" fill="#f5f7fa">{label}</text>')
    lines.append('</svg>')
    out.write_text("\n".join(lines))
    return out


def write_placements_json(project: Path, output: Path | None = None, workflow_mode: str = "photorealistic") -> Path:
    animate, _, _ = project_paths(project)
    out = output or (animate / "debug" / f"places-world-map-{workflow_mode}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "workflow": workflow_mode,
        "placements": infer_placements(project, workflow_mode=workflow_mode),
    }
    save_json(out, data)
    return out


def trusted_coverage_report(project: Path, workflow_mode: str = "photorealistic") -> dict[str, Any]:
    workflow, places_json, _ = load_project_state(project)
    places = places_lookup(places_json)
    placements = infer_placements(project, workflow_mode=workflow_mode)
    placements_by_record = {entry["record_id"]: entry for entry in placements if entry.get("record_id")}
    place_counts: dict[str, dict[str, int]] = {}
    zone_counts: dict[str, int] = {proto_id: 0 for proto_id, *_ in PROTOTYPES}

    for record in workflow.get("generatedImageRecords", []):
        if not eligible_world_record(record, workflow_mode):
            continue
        place_id = record.get("linkedPlaceID") or ""
        entry = placements_by_record.get(record.get("id"))
        bucket = entry.get("bucket") if entry else None
        if bucket in zone_counts:
            zone_counts[bucket] += 1
        place_bucket = place_counts.setdefault(place_id, {"exact": 0, "provisional": 0, "total": 0})
        place_bucket["total"] += 1
        if entry:
            if entry["source"] in TRUSTED_SOURCES:
                place_bucket["exact"] += 1
            else:
                place_bucket["provisional"] += 1

    missing_exteriors: list[dict[str, Any]] = []
    missing_interiors: list[dict[str, Any]] = []
    linked_interiors: list[dict[str, Any]] = []
    for place in places_json:
        category = cleaned_lower(place.get("locationCategory"))
        counts = place_counts.get(place.get("id"), {"exact": 0, "provisional": 0, "total": 0})
        anchor = resolve_place_anchor(place, workflow, places)
        item = {
            "place_id": place.get("id"),
            "place_name": place.get("name"),
            "image_count": counts["total"],
            "exact_count": counts["exact"],
            "provisional_count": counts["provisional"],
            "anchor_linked": anchor is not None,
        }
        if category == "exterior":
            if counts["exact"] == 0 and counts["provisional"] == 0:
                item["reason"] = "no world-map-eligible generated image records"
                missing_exteriors.append(item)
            elif counts["exact"] == 0:
                item["reason"] = "only provisional placement coverage"
                missing_exteriors.append(item)
        elif category == "interior":
            if anchor is not None:
                linked_interiors.append({**item, "anchor_place_name": (anchor.get("anchor_place") or {}).get("name")})
            if counts["total"] == 0:
                item["reason"] = "no generated interior coverage"
                missing_interiors.append(item)
            elif anchor is None:
                item["reason"] = "interior lacks building-anchor linkage"
                missing_interiors.append(item)
            elif counts["exact"] == 0 and counts["provisional"] == 0:
                item["reason"] = "interior has anchor link but no placeable captures"
                missing_interiors.append(item)

    missing_zones = [
        {
            "zone": proto_id,
            "count": count,
            "kind": "building_anchor" if proto_id in BUILDING_ANCHOR_ZONES else ("exterior" if proto_id in EXTERIOR_ZONES else "mixed"),
            "aliases": aliases,
        }
        for proto_id, _, _, aliases in PROTOTYPES
        for count in [zone_counts.get(proto_id, 0)]
        if count == 0
    ]

    return {
        "workflow": workflow_mode,
        "summary": {
            "total_placements": len(placements),
            "trusted_exact": sum(1 for entry in placements if entry["source"] in TRUSTED_SOURCES),
            "provisional": sum(1 for entry in placements if entry["source"] in PROVISIONAL_SOURCES),
            "unplaced_or_weak": len(list_unplaced(project, workflow_mode=workflow_mode)),
            "mirror_suspects": len(mirror_suspects(project, workflow_mode=workflow_mode)),
        },
        "missing_exteriors": sorted(missing_exteriors, key=lambda item: item["place_name"] or ""),
        "missing_interiors": sorted(missing_interiors, key=lambda item: item["place_name"] or ""),
        "linked_interiors": sorted(linked_interiors, key=lambda item: item["place_name"] or ""),
        "missing_zones": missing_zones,
        "zone_counts": zone_counts,
    }


def normalized_path(path: str | None) -> str | None:
    if not path:
        return None
    return str(Path(path))


def record_prompt_text(record: dict[str, Any]) -> str:
    return cleaned_lower(record.get("sourcePrompt") or record.get("summary") or Path(record.get("activePath") or "").stem)


def gather_place_records(workflow: dict[str, Any], place_id: str | None, workflow_mode: str) -> list[dict[str, Any]]:
    if not place_id:
        return []
    return [
        record for record in workflow.get("generatedImageRecords", [])
        if record.get("linkedPlaceID") == place_id and eligible_world_record(record, workflow_mode)
    ]


def record_reference_paths(record: dict[str, Any], place: dict[str, Any] | None, project: Path, limit: int = 6) -> list[str]:
    refs: list[str] = [str(project / canonical_master_map_path(load_json(project_paths(project)[1])))]
    if place:
        for ref in place.get("referenceImages") or []:
            if not isinstance(ref, dict):
                continue
            path = ref.get("imagePath")
            if path:
                refs.append(str((project / path) if not Path(path).is_absolute() else Path(path)))
    for candidate in [place.get("approvedImagePath") if place else None]:
        if candidate:
            refs.append(str((project / candidate) if not Path(candidate).is_absolute() else Path(candidate)))
    active = record.get("activePath")
    if active:
        refs.append(str((project / active) if not Path(active).is_absolute() else Path(active)))
    deduped: list[str] = []
    seen: set[str] = set()
    for item in refs:
        key = normalized_path(item)
        if key and key not in seen:
            seen.add(key)
            deduped.append(item)
        if len(deduped) >= limit:
            break
    return deduped


def suggest_place_zone(place: dict[str, Any], workflow: dict[str, Any], places_by_id: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    anchor = resolve_place_anchor(place, workflow, places_by_id)
    if anchor and anchor.get("point") is not None:
        anchor_place = anchor.get("anchor_place") or place
        anchor_node = anchor.get("anchor_node")
        point = anchor["point"]
        heading = anchor.get("heading")
        bucket = exact_stem_prototype(cleaned_lower(anchor_place.get("name"))) if anchor_place else None
        if anchor_node is not None:
            bucket = bucket or cleaned_lower(anchor_node.get("title")).replace(" ", "_")
        return {
            "zone": bucket,
            "x": float(point[0]),
            "y": float(point[1]),
            "heading": heading,
            "source": "place_anchor",
            "anchor_place_name": anchor_place.get("name") if anchor_place else None,
        }

    node = node_for_place(workflow, place.get("id"))
    if node and node.get("mapPoint"):
        pose = node.get("cameraPose") or {}
        point = node.get("mapPoint") or {}
        return {
            "zone": exact_stem_prototype(cleaned_lower(place.get("name"))) or cleaned_lower(node.get("title")).replace(" ", "_"),
            "x": float(point.get("x", 0.5)),
            "y": float(point.get("y", 0.5)),
            "heading": pose.get("yawDegrees"),
            "source": "node",
            "anchor_place_name": place.get("name"),
        }

    candidates = top_prototypes(place_text(place), limit=1)
    if candidates:
        best = candidates[0]
        return {
            "zone": best["prototype"],
            "x": float(best["x"]),
            "y": float(best["y"]),
            "heading": best.get("heading"),
            "source": "semantic_place",
            "anchor_place_name": place.get("name"),
        }
    return None


def bridge_prompt_suffix(text: str) -> str:
    if "bridge" not in text:
        return ""
    return " Keep the bridge modest in scale relative to the town mass, and keep the full deck top completely flat and open with no parapets, railings, curbs, or raised side stones."


def place_generation_prompt(place: dict[str, Any], target: dict[str, Any], workflow_mode: str) -> str:
    name = place.get("name") or "Unknown place"
    notes = clean(place.get("notes"))
    prompt_notes = clean(place.get("workflowPromptNotes"))
    heading = target.get("heading")
    map_sentence = ""
    if target.get("x") is not None and target.get("y") is not None:
        map_sentence = f" Map anchor: normalized x {target['x']:.3f}, y {target['y']:.3f} on the master map."
    heading_sentence = f" Camera heading {heading:.0f} degrees." if heading is not None else ""
    category = cleaned_lower(place.get("locationCategory"))
    if category == "interior":
        anchor_sentence = ""
        if target.get("anchor_place_name"):
            anchor_sentence = f" This interior belongs to {target['anchor_place_name']} and should feel spatially connected to that building from the outside."
        return (
            f"Create a {'photoreal' if workflow_mode == 'photorealistic' else 'cinematic animated'} background plate for {name}."
            f"{anchor_sentence}{map_sentence}{heading_sentence} Preserve the established world geography and building identity."
            f" Match the known material palette, architecture, and continuity of this location."
            f" {notes} {prompt_notes}".strip()
        )

    zone = target.get("zone") or "world location"
    return (
        f"Create a {'photoreal cinematic' if workflow_mode == 'photorealistic' else 'cinematic animated'} background plate for {name}."
        f" Treat this as an exterior in the {zone.replace('_', ' ')} zone of the Amira world."
        f"{map_sentence}{heading_sentence} Match the master map, preserve north-bank/south-bank geography, and keep the settlement compact, old, and believable."
        f" {notes} {prompt_notes}{bridge_prompt_suffix(place_text(place))}".strip()
    )


def zone_generation_prompt(proto_id: str) -> str:
    _, point, heading, aliases = PROTO_BY_ID[proto_id]
    kind = "interior-linked building anchor" if proto_id in BUILDING_ANCHOR_ZONES else "exterior"
    alias_text = ", ".join(aliases[:4])
    return (
        f"Create a photoreal cinematic background plate covering the {proto_id.replace('_', ' ')} {kind} zone."
        f" Map anchor: normalized x {point[0]:.3f}, y {point[1]:.3f} on the master map."
        f" Camera heading {heading:.0f} degrees. Expected cues: {alias_text}."
        " Preserve the existing world map, one-sided town geography, and continuity with adjacent approved images."
    )


def generation_shopping_list(project: Path, workflow_mode: str = "photorealistic") -> dict[str, Any]:
    workflow, places_json, _ = load_project_state(project)
    places = places_lookup(places_json)
    places_by_id = places_lookup(places_json)
    coverage = trusted_coverage_report(project, workflow_mode=workflow_mode)
    placements = placement_lookup(project, workflow_mode)
    unplaced = list_unplaced(project, workflow_mode=workflow_mode, include_weak=True)

    weak_exteriors: list[dict[str, Any]] = []
    missing_unlinked_interiors: list[dict[str, Any]] = []
    missing_zones: list[dict[str, Any]] = []
    generation_targets: list[dict[str, Any]] = []

    place_counts: dict[str, dict[str, int]] = {}
    for record in workflow.get("generatedImageRecords", []):
        if not eligible_world_record(record, workflow_mode):
            continue
        place_id = record.get("linkedPlaceID") or ""
        counts = place_counts.setdefault(place_id, {"exact": 0, "provisional": 0, "total": 0})
        counts["total"] += 1
        placement = placements.get(record.get("id"))
        if placement:
            if placement.get("source") in TRUSTED_SOURCES:
                counts["exact"] += 1
            else:
                counts["provisional"] += 1

    for item in coverage["missing_exteriors"]:
        place = places.get(item.get("place_id") or "")
        if not place:
            continue
        suggested = suggest_place_zone(place, workflow, places_by_id) or {}
        target = {
            "action": "generate_exterior" if item["image_count"] == 0 else "strengthen_exterior",
            "place_id": place.get("id"),
            "place_name": place.get("name"),
            "reason": item.get("reason"),
            "target_zone": suggested.get("zone"),
            "x": suggested.get("x"),
            "y": suggested.get("y"),
            "heading": suggested.get("heading"),
            "reference_paths": record_reference_paths({}, place, project),
        }
        target["prompt"] = place_generation_prompt(place, target, workflow_mode)
        generation_targets.append(target)
        weak_exteriors.append(target)

    for item in coverage["missing_interiors"]:
        place = places.get(item.get("place_id") or "")
        if not place:
            continue
        suggested = suggest_place_zone(place, workflow, places_by_id) or {}
        anchor_candidates = top_prototypes(place_text(place), limit=2)
        target = {
            "action": "link_anchor_then_generate" if not item.get("anchor_linked") else "generate_interior",
            "place_id": place.get("id"),
            "place_name": place.get("name"),
            "reason": item.get("reason"),
            "anchor_place_name": suggested.get("anchor_place_name"),
            "target_zone": suggested.get("zone"),
            "x": suggested.get("x"),
            "y": suggested.get("y"),
            "heading": suggested.get("heading"),
            "anchor_candidates": anchor_candidates,
            "reference_paths": record_reference_paths({}, place, project),
        }
        target["prompt"] = place_generation_prompt(place, target, workflow_mode)
        generation_targets.append(target)
        missing_unlinked_interiors.append(target)

    for zone in coverage["missing_zones"]:
        proto_id = zone["zone"]
        proto = PROTO_BY_ID.get(proto_id)
        if not proto:
            continue
        _, point, heading, aliases = proto
        target = {
            "action": "generate_zone_probe",
            "target_zone": proto_id,
            "kind": zone["kind"],
            "x": point[0],
            "y": point[1],
            "heading": heading,
            "aliases": aliases,
            "reference_paths": [str(project / canonical_master_map_path(workflow))],
            "prompt": zone_generation_prompt(proto_id),
        }
        generation_targets.append(target)
        missing_zones.append(target)

    diagnostics = {
        "unplaced_records": unplaced,
        "stem_profile_warnings": [
            {
                "record_id": record.get("id"),
                "title": record.get("summary") or Path(record.get("activePath") or "").stem,
                "path": record.get("activePath"),
                "place_name": (places.get(record.get("linkedPlaceID") or "") or {}).get("name"),
                "warnings": stem_profile_diagnostics(record, places.get(record.get("linkedPlaceID") or "")),
            }
            for record in workflow.get("generatedImageRecords", [])
            if eligible_world_record(record, workflow_mode)
            and stem_profile_diagnostics(record, places.get(record.get("linkedPlaceID") or ""))
        ],
    }

    diagnostics["stem_profile_warnings"].sort(key=lambda item: (item.get("place_name") or "", item["title"]))

    generation_targets.sort(key=lambda item: (item.get("action") or "", item.get("place_name") or item.get("target_zone") or ""))

    return {
        "workflow": workflow_mode,
        "summary": {
            **coverage["summary"],
            "generation_target_count": len(generation_targets),
            "weak_exterior_targets": len(weak_exteriors),
            "interior_targets": len(missing_unlinked_interiors),
            "zone_targets": len(missing_zones),
        },
        "missing_weak_exteriors": weak_exteriors,
        "missing_unlinked_interiors": missing_unlinked_interiors,
        "missing_zones": missing_zones,
        "generation_targets": generation_targets,
        "diagnostics": diagnostics,
    }


def format_text_list(items: list[dict[str, Any]], formatter) -> str:
    if not items:
        return "(none)"
    return "\n".join(formatter(item) for item in items)


def fmt_coord(value: Any) -> str:
    if value is None:
        return "-"
    return f"{float(value):.3f}"


def fmt_heading(value: Any) -> str:
    if value is None:
        return "-"
    return f"{float(value):.0f}"


def upsert_generated_record_canon(project: Path, canon: dict[str, Any], record: dict[str, Any]) -> str | None:
    key = stable_record_key(project, record.get("activePath"))
    if key is None:
        return None
    entry = dict(canon.setdefault("generatedRecords", {}).get(key) or {})
    relative_path = path_relative_to_project(project, record.get("activePath"))
    entry.update(
        {
            "stablePath": relative_path,
            "filenameStem": Path(record.get("activePath") or "").stem,
            "summary": record.get("summary"),
            "linkedPlaceID": record.get("linkedPlaceID"),
            "linkedPlaceName": record.get("linkedPlaceName"),
            "updatedAt": now_iso(),
        }
    )
    if record.get("mapPoint"):
        point = record["mapPoint"]
        entry["mapPoint"] = {"x": clamp01(point["x"]), "y": clamp01(point["y"])}
    if record.get("cameraPose"):
        entry["cameraPose"] = merge_camera_pose({}, record.get("cameraPose"))
    if record.get("mapPlacementStatus"):
        entry["mapPlacementStatus"] = record.get("mapPlacementStatus")
    if record.get("mapPlacementConfirmedAt"):
        entry["mapPlacementConfirmedAt"] = record.get("mapPlacementConfirmedAt")
    if record.get("orientationState"):
        entry["orientationState"] = record.get("orientationState")
    meta = record.get("worldMapTool")
    if isinstance(meta, dict) and meta:
        entry["worldMapTool"] = dict(meta)
        if meta.get("orientationConfirmedAt"):
            entry["orientationConfirmedAt"] = meta.get("orientationConfirmedAt")
    canon.setdefault("generatedRecords", {})[key] = entry
    return key


def upsert_place_anchor_canon(canon: dict[str, Any], place: dict[str, Any]) -> str | None:
    key = stable_place_key(place)
    if not key:
        return None
    meta = dict(place.get("worldMapTool") or {})
    entry = dict(canon.setdefault("placeAnchors", {}).get(key) or {})
    entry.update(
        {
            "placeID": place.get("id"),
            "placeName": place.get("name"),
            "linkedExteriorPlaceID": place.get("linkedExteriorPlaceID"),
            "buildingAnchorNodeID": place.get("buildingAnchorNodeID"),
            "updatedAt": now_iso(),
        }
    )
    for field in ("anchorPlaceID", "anchorPlaceName", "anchorNodeID", "anchorPoint", "offset", "kind", "anchorHeading", "linkedAt"):
        if meta.get(field) is not None:
            entry[field] = meta.get(field)
    canon.setdefault("placeAnchors", {})[key] = entry
    if place.get("id"):
        canon["placeAnchors"][str(place.get("id")).lower()] = entry
    return key


def cmd_status(args):
    project = Path(args.project)
    _, workflow_path, _ = project_paths(project)
    workflow, _, canon = load_project_state(project)
    master_map = canonical_master_map_path(workflow)
    placements = infer_placements(project, workflow_mode=args.workflow)
    canon_record_count = sum(1 for key in (canon.get("generatedRecords") or {}) if str(key).startswith("path::"))
    print(f"Project: {project}")
    print(f"Master map: {master_map}")
    print(f"Canon sidecar: {world_map_canon_path(project)}")
    print(f"Canon records: {canon_record_count}")
    print(f"Generated placements: {len(placements)}")
    counts: dict[str, int] = {}
    for item in placements:
        counts[item['source']] = counts.get(item['source'], 0) + 1
    for key, value in sorted(counts.items()):
        print(f"  {key}: {value}")


def cmd_restore_master_map(args):
    project = Path(args.project)
    restored = restore_master_map(project)
    print(f"Restored master map to: {restored}")


def cmd_anchor_place(args):
    project = Path(args.project)
    _, workflow_path, places_path = project_paths(project)
    workflow = load_json(workflow_path)
    places = load_json(places_path)
    target = find_place(places, args.place)
    if target is None:
        raise SystemExit(f"Place not found: {args.place}")

    world_graph = workflow.setdefault("worldGraph", {})
    nodes = world_graph.setdefault("nodes", [])
    existing = next((node for node in nodes if node.get("placeID") == target["id"] and node.get("routeID") is None and node.get("role") == "landmark"), None)
    payload = {
        "routeID": None,
        "placeID": target["id"],
        "title": target["name"],
        "sequenceIndex": 0,
        "role": "landmark",
        "mapPoint": {"x": float(args.x), "y": float(args.y)},
        "cameraPose": {"yawDegrees": 0, "pitchDegrees": 0, "rollDegrees": 0, "focalLengthMM": 35},
        "notes": "",
        "linkedNodeIDs": [],
        "expectedLandmarkIDs": [],
        "expectedLandmarkTitles": [],
        "forbiddenLandmarkTitles": [],
        "approvedPhotorealImagePath": None,
        "approvedAnimatedImagePath": None,
        "lastReviewID": None,
    }
    if existing:
        existing.update(payload)
    else:
        payload["id"] = str(uuid.uuid4()).upper()
        nodes.append(payload)

    save_json(workflow_path, workflow)
    print(f"Anchored {target['name']} at ({args.x:.3f}, {args.y:.3f})")


def cmd_link_place_anchor(args):
    project = Path(args.project)
    _, workflow_path, places_path = project_paths(project)
    workflow = load_json(workflow_path)
    places = load_json(places_path)
    canon = load_world_map_canon(project)
    places_by_id = places_lookup(places)

    target = find_place(places, args.place)
    if target is None:
        raise SystemExit(f"Target place not found: {args.place}")
    anchor_place = find_place(places, args.anchor_place)
    if anchor_place is None:
        raise SystemExit(f"Anchor place not found: {args.anchor_place}")

    anchor_node = node_for_place(workflow, anchor_place.get("id"))
    anchor_point = None
    anchor_heading = None
    if anchor_node:
        point = anchor_node.get("mapPoint") or {}
        if point.get("x") is not None and point.get("y") is not None:
            anchor_point = (float(point["x"]), float(point["y"]))
        pose = anchor_node.get("cameraPose") or {}
        anchor_heading = pose.get("yawDegrees")

    if anchor_point is None:
        anchor_record = next((r for r in workflow.get("generatedImageRecords", []) if r.get("linkedPlaceID") == anchor_place.get("id") and r.get("mapPoint")), None)
        if anchor_record:
            anchor_point = (float(anchor_record["mapPoint"]["x"]), float(anchor_record["mapPoint"]["y"]))
            anchor_heading = (anchor_record.get("cameraPose") or {}).get("yawDegrees")

    if anchor_point is None:
        inferred = next((item for item in infer_placements(project, workflow_mode=args.workflow) if cleaned_lower(item.get("place_name")) == cleaned_lower(anchor_place.get("name"))), None)
        if inferred:
            anchor_point = (float(inferred["base_x"]), float(inferred["base_y"]))
            anchor_heading = inferred.get("heading")

    if anchor_point is None:
        raise SystemExit(f"Could not resolve anchor point for {anchor_place['name']}; anchor it first with anchor-place or confirm a placed image.")

    target["worldMapTool"] = {
        **(target.get("worldMapTool") or {}),
        "anchorPlaceID": anchor_place.get("id"),
        "anchorPlaceName": anchor_place.get("name"),
        "anchorNodeID": anchor_node.get("id") if anchor_node else None,
        "anchorPoint": {"x": anchor_point[0], "y": anchor_point[1]},
        "offset": {"x": float(args.offset_x), "y": float(args.offset_y)},
        "kind": args.kind,
        "anchorHeading": anchor_heading,
        "linkedAt": now_iso(),
    }
    if anchor_place.get("id") != target.get("id"):
        target["linkedExteriorPlaceID"] = anchor_place.get("id")
    if anchor_node and anchor_node.get("id"):
        target["buildingAnchorNodeID"] = anchor_node.get("id")
    save_json(places_path, places)
    upsert_place_anchor_canon(canon, target)
    canon_path = save_world_map_canon(project, canon)
    print(f"Linked {target['name']} to anchor {anchor_place['name']} at ({anchor_point[0]:.3f}, {anchor_point[1]:.3f}) with offset ({args.offset_x:.3f}, {args.offset_y:.3f})")
    print(f"Updated canon sidecar: {canon_path}")


def cmd_list_place_anchors(args):
    project = Path(args.project)
    workflow, places, _ = load_project_state(project)
    places_by_id = places_lookup(places)
    rows = []
    for place in places:
        anchor = resolve_place_anchor(place, workflow, places_by_id)
        if anchor is None:
            continue
        rows.append({
            "place_name": place.get("name"),
            "kind": anchor.get("kind"),
            "anchor_place_name": (anchor.get("anchor_place") or {}).get("name"),
            "x": round(anchor["point"][0], 4),
            "y": round(anchor["point"][1], 4),
        })
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        print(format_text_list(rows, lambda row: f"- {row['place_name']} -> {row['anchor_place_name'] or 'direct'} ({row['x']:.4f}, {row['y']:.4f}) [{row['kind'] or 'linked_place'}]"))


def cmd_export_overlay(args):
    project = Path(args.project)
    out = write_overlay_svg(project, output=Path(args.output) if args.output else None, workflow_mode=args.workflow)
    json_out = write_placements_json(project, workflow_mode=args.workflow)
    print(f"SVG overlay: {out}")
    print(f"Placements JSON: {json_out}")


def cmd_list_unplaced(args):
    rows = list_unplaced(Path(args.project), workflow_mode=args.workflow, include_weak=not args.exclude_weak)
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return
    if not rows:
        print("No unplaced images.")
        return
    for row in rows[: args.limit or len(rows)]:
        print(f"- [{row['state']}] {row['title']} :: {row['reason']}")
        print(f"    record={row['record_id']} place={row.get('place_name') or '-'} kind={row.get('scene_kind')}")
        print(f"    path={row['path']}")
        if row.get("prototype_candidates"):
            top = row["prototype_candidates"][0]
            print(f"    best_candidate={top['prototype']} score={top['score']:.2f} at ({top['x']:.3f}, {top['y']:.3f})")
        for diagnostic in row.get("diagnostics") or []:
            print(f"    diagnostic: {diagnostic}")


def cmd_list_mirror_suspects(args):
    rows = mirror_suspects(Path(args.project), workflow_mode=args.workflow)
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return
    if not rows:
        print("No mirror suspects found.")
        return
    for row in rows[: args.limit or len(rows)]:
        print(f"- {row['title']} [{row['source']} {row['confidence']:.2f}] :: {row['bucket']}")
        print(f"    record={row['record_id']} path={row['path']}")
        for reason in row.get("mirror_suspect_reasons", []):
            print(f"    reason: {reason}")


def cmd_review_provisional(args):
    rows = provisional_placements(Path(args.project), workflow_mode=args.workflow, include_weak=args.include_weak)
    if args.record:
        query = cleaned_lower(args.record)
        rows = [row for row in rows if query in cleaned_lower(row.get("record_id")) or query in cleaned_lower(row.get("path")) or query in cleaned_lower(row.get("title"))]
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return
    if not rows:
        print("No provisional placements found.")
        return
    for row in rows[: args.limit or len(rows)]:
        print(f"- {row['title']} [{row['source']} conf {row['confidence']:.2f}]")
        print(f"    record={row['record_id']} place={row.get('place_name') or '-'} scene={row['scene_kind']}")
        print(f"    proposed=({row['x']:.4f}, {row['y']:.4f}) base=({row['base_x']:.4f}, {row['base_y']:.4f}) heading={row.get('heading')} focal={row.get('focal')}")
        print(f"    bucket={row['bucket']} path={row['path']}")
        if row.get("anchor_place_name"):
            print(f"    anchor_place={row['anchor_place_name']} [{row.get('anchor_kind')}]")
        if row.get("prototype_candidates"):
            alts = ", ".join(f"{cand['prototype']}:{cand['score']:.2f}" for cand in row['prototype_candidates'])
            print(f"    prototype_candidates={alts}")
        if row.get("mirror_suspect"):
            print(f"    mirror_suspect={' | '.join(row.get('mirror_suspect_reasons', []))}")
        print(f"    confirm: Scripts/places_world_map_tool.py confirm-placement --record '{row['record_id']}' --workflow {args.workflow}")


def cmd_confirm_placement(args):
    project = Path(args.project)
    _, workflow_path, _ = project_paths(project)
    workflow = load_json(workflow_path)
    canon = load_world_map_canon(project)
    record = find_record(workflow, args.record)
    if record is None:
        raise SystemExit(f"Record not found: {args.record}")

    placements = placement_lookup(project, workflow_mode=args.workflow)
    candidate = placements.get(record.get("id"))
    if candidate is None and (args.x is None or args.y is None):
        raise SystemExit("No provisional placement found for that record. Pass --x and --y to confirm manually.")
    if candidate is not None and candidate.get("source") == "semantic_zone" and not args.allow_weak and args.x is None and args.y is None:
        raise SystemExit("Selected record only has a weak semantic-zone proposal. Re-run with --allow-weak or specify --x/--y manually.")

    point_x = float(args.x) if args.x is not None else float(candidate["x"])
    point_y = float(args.y) if args.y is not None else float(candidate["y"])
    heading = float(args.heading) if args.heading is not None else (candidate.get("heading") if candidate else None)
    focal = float(args.focal) if args.focal is not None else (candidate.get("focal") if candidate else None)

    point_x = clamp01(point_x)
    point_y = clamp01(point_y)
    record["mapPoint"] = {"x": point_x, "y": point_y}
    pose = record.get("cameraPose") or {}
    if heading is not None:
        pose["yawDegrees"] = float(heading)
    pose.setdefault("pitchDegrees", 0)
    pose.setdefault("rollDegrees", 0)
    if focal is not None:
        pose["focalLengthMM"] = float(focal)
    elif "focalLengthMM" not in pose:
        pose["focalLengthMM"] = 35.0
    record["cameraPose"] = pose
    record["mapPlacementStatus"] = "confirmed"
    record["mapPlacementConfirmedAt"] = now_iso()
    meta = record.setdefault("worldMapTool", {}) if isinstance(record, dict) else {}
    if isinstance(meta, dict):
        meta.update({
            "confirmedAt": now_iso(),
            "confirmedFrom": args.record,
            "confirmedSource": candidate.get("source") if candidate else "manual",
            "basePoint": {"x": candidate.get("base_x"), "y": candidate.get("base_y")} if candidate else None,
        })
    save_json(workflow_path, workflow)
    canon_key = upsert_generated_record_canon(project, canon, record)
    canon_path = save_world_map_canon(project, canon)
    print(f"Confirmed placement for {record.get('summary') or record.get('activePath')} at ({point_x:.4f}, {point_y:.4f}) heading={heading} focal={focal}")
    if canon_key:
        print(f"Updated canon sidecar: {canon_path} [{canon_key}]")


def cmd_confirm_orientation(args):
    project = Path(args.project)
    _, workflow_path, _ = project_paths(project)
    workflow = load_json(workflow_path)
    canon = load_world_map_canon(project)
    record = find_record(workflow, args.record)
    if record is None:
        raise SystemExit(f"Record not found: {args.record}")

    state = cleaned_lower(args.state)
    if state not in {"original", "mirrored", "unknown"}:
        raise SystemExit("Orientation state must be one of: original, mirrored, unknown")

    record["orientationState"] = state
    meta = record.setdefault("worldMapTool", {}) if isinstance(record, dict) else {}
    if isinstance(meta, dict):
        meta["orientationConfirmedAt"] = now_iso()
        meta["orientationConfirmedState"] = state
    save_json(workflow_path, workflow)
    canon_key = upsert_generated_record_canon(project, canon, record)
    canon_path = save_world_map_canon(project, canon)
    print(f"Set orientation for {record.get('summary') or record.get('activePath')} to {state}.")
    if canon_key:
        print(f"Updated canon sidecar: {canon_path} [{canon_key}]")


def cmd_coverage_analysis(args):
    project = Path(args.project)
    report = trusted_coverage_report(project, workflow_mode=args.workflow)
    if args.output:
        save_json(Path(args.output), report)
    if args.format == "json":
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return
    print(f"Workflow: {report['workflow']}")
    summary = report['summary']
    print(f"Placements: {summary['total_placements']} total • {summary['trusted_exact']} exact • {summary['provisional']} provisional • {summary['unplaced_or_weak']} unplaced/weak • {summary['mirror_suspects']} mirror suspects")
    print("\nMissing / weak exteriors:")
    print(format_text_list(report['missing_exteriors'], lambda item: f"- {item['place_name']} :: {item['reason']} (images={item['image_count']} exact={item['exact_count']} provisional={item['provisional_count']})"))
    print("\nMissing / unlinked interiors:")
    print(format_text_list(report['missing_interiors'], lambda item: f"- {item['place_name']} :: {item['reason']} (images={item['image_count']} anchor_linked={item['anchor_linked']})"))
    print("\nLinked interiors:")
    print(format_text_list(report['linked_interiors'], lambda item: f"- {item['place_name']} -> {item.get('anchor_place_name') or 'direct'} (images={item['image_count']})"))
    print("\nMissing zones:")
    print(format_text_list(report['missing_zones'], lambda item: f"- {item['zone']} [{item['kind']}] :: aliases={', '.join(item['aliases'][:4])}"))


def cmd_generation_shopping_list(args):
    project = Path(args.project)
    report = generation_shopping_list(project, workflow_mode=args.workflow)
    if args.output:
        save_json(Path(args.output), report)
    if args.format == "json":
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return

    summary = report["summary"]
    print(f"Workflow: {report['workflow']}")
    print(
        "Shopping list summary: "
        f"{summary['generation_target_count']} targets • "
        f"{summary['weak_exterior_targets']} exterior targets • "
        f"{summary['interior_targets']} interior targets • "
        f"{summary['zone_targets']} zone probes"
    )
    print(
        f"Coverage baseline: {summary['total_placements']} placements, "
        f"{summary['trusted_exact']} exact, {summary['provisional']} provisional, "
        f"{summary['unplaced_or_weak']} unplaced/weak."
    )

    print("\nMissing / weak exteriors:")
    print(
        format_text_list(
            report["missing_weak_exteriors"],
            lambda item: (
                f"- {item['place_name']} :: {item['action']} @ "
                f"({fmt_coord(item.get('x'))}, {fmt_coord(item.get('y'))}) "
                f"heading={fmt_heading(item.get('heading'))} "
                f"zone={item.get('target_zone') or '-'} :: {item['reason']}"
            ),
        )
    )

    print("\nMissing / unlinked interiors:")
    print(
        format_text_list(
            report["missing_unlinked_interiors"],
            lambda item: (
                f"- {item['place_name']} :: {item['action']} "
                f"anchor={item.get('anchor_place_name') or '-'} "
                f"zone={item.get('target_zone') or '-'} :: {item['reason']}"
            ),
        )
    )

    print("\nMissing zones:")
    print(
        format_text_list(
            report["missing_zones"],
            lambda item: (
                f"- {item['target_zone']} [{item['kind']}] @ "
                f"({fmt_coord(item.get('x'))}, {fmt_coord(item.get('y'))}) heading={fmt_heading(item.get('heading'))} "
                f"aliases={', '.join(item['aliases'][:4])}"
            ),
        )
    )

    print("\nGeneration targets:")
    targets = report["generation_targets"][: args.limit or len(report["generation_targets"])]
    if not targets:
        print("(none)")
    for item in targets:
        label = item.get("place_name") or item.get("target_zone") or "target"
        print(f"- {label} [{item['action']}]")
        if item.get("x") is not None and item.get("y") is not None:
            print(
                f"    target=({fmt_coord(item.get('x'))}, {fmt_coord(item.get('y'))}) "
                f"heading={fmt_heading(item.get('heading'))} "
                f"zone={item.get('target_zone') or '-'}"
            )
        if item.get("anchor_place_name"):
            print(f"    anchor_place={item['anchor_place_name']}")
        refs = item.get("reference_paths") or []
        if refs:
            print(f"    refs={len(refs)} -> {refs[0]}")
            for ref in refs[1:3]:
                print(f"         {ref}")
        print(f"    prompt={item['prompt']}")

    warnings = report.get("diagnostics", {}).get("stem_profile_warnings") or []
    print("\nStem-profile brittleness warnings:")
    if not warnings:
        print("(none)")
    else:
        for item in warnings[: args.limit or len(warnings)]:
            print(f"- {item['title']} :: {' | '.join(item['warnings'])}")
            print(f"    record={item['record_id']} place={item.get('place_name') or '-'}")

    unplaced = report.get("diagnostics", {}).get("unplaced_records") or []
    print("\nUnplaced / weak diagnostics:")
    if not unplaced:
        print("(none)")
    else:
        for row in unplaced[: args.limit or len(unplaced)]:
            print(f"- {row['title']} [{row['state']}] :: {row['reason']}")
            for diagnostic in row.get("diagnostics") or []:
                print(f"    diagnostic: {diagnostic}")


def build_parser():
    p = argparse.ArgumentParser(description="Headless Places world-map tool")
    p.add_argument("--project", default=str(DEFAULT_PROJECT))
    sub = p.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser("status")
    p_status.add_argument("--workflow", default="photorealistic")
    p_status.set_defaults(func=cmd_status)

    p_restore = sub.add_parser("restore-master-map")
    p_restore.set_defaults(func=cmd_restore_master_map)

    p_anchor = sub.add_parser("anchor-place")
    p_anchor.add_argument("--place", required=True)
    p_anchor.add_argument("--x", required=True, type=float)
    p_anchor.add_argument("--y", required=True, type=float)
    p_anchor.set_defaults(func=cmd_anchor_place)

    p_link = sub.add_parser("link-place-anchor")
    p_link.add_argument("--place", required=True)
    p_link.add_argument("--anchor-place", required=True)
    p_link.add_argument("--kind", default="interior")
    p_link.add_argument("--workflow", default="photorealistic")
    p_link.add_argument("--offset-x", type=float, default=0.0)
    p_link.add_argument("--offset-y", type=float, default=0.0)
    p_link.set_defaults(func=cmd_link_place_anchor)

    p_list_anchors = sub.add_parser("list-place-anchors")
    p_list_anchors.add_argument("--json", action="store_true")
    p_list_anchors.set_defaults(func=cmd_list_place_anchors)

    p_export = sub.add_parser("export-overlay")
    p_export.add_argument("--workflow", default="photorealistic")
    p_export.add_argument("--output")
    p_export.set_defaults(func=cmd_export_overlay)

    p_unplaced = sub.add_parser("list-unplaced")
    p_unplaced.add_argument("--workflow", default="photorealistic")
    p_unplaced.add_argument("--limit", type=int)
    p_unplaced.add_argument("--json", action="store_true")
    p_unplaced.add_argument("--exclude-weak", action="store_true")
    p_unplaced.set_defaults(func=cmd_list_unplaced)

    p_mirror = sub.add_parser("list-mirror-suspects")
    p_mirror.add_argument("--workflow", default="photorealistic")
    p_mirror.add_argument("--limit", type=int)
    p_mirror.add_argument("--json", action="store_true")
    p_mirror.set_defaults(func=cmd_list_mirror_suspects)

    p_review = sub.add_parser("review-provisional")
    p_review.add_argument("--workflow", default="photorealistic")
    p_review.add_argument("--limit", type=int)
    p_review.add_argument("--json", action="store_true")
    p_review.add_argument("--record")
    p_review.add_argument("--include-weak", action="store_true")
    p_review.set_defaults(func=cmd_review_provisional)

    p_confirm = sub.add_parser("confirm-placement")
    p_confirm.add_argument("--workflow", default="photorealistic")
    p_confirm.add_argument("--record", required=True)
    p_confirm.add_argument("--x", type=float)
    p_confirm.add_argument("--y", type=float)
    p_confirm.add_argument("--heading", type=float)
    p_confirm.add_argument("--focal", type=float)
    p_confirm.add_argument("--allow-weak", action="store_true")
    p_confirm.set_defaults(func=cmd_confirm_placement)

    p_orientation = sub.add_parser("confirm-orientation")
    p_orientation.add_argument("--record", required=True)
    p_orientation.add_argument("--state", required=True, choices=["original", "mirrored", "unknown"])
    p_orientation.set_defaults(func=cmd_confirm_orientation)

    p_cov = sub.add_parser("coverage-analysis", aliases=["generate-world"])
    p_cov.add_argument("--workflow", default="photorealistic")
    p_cov.add_argument("--format", choices=["text", "json"], default="text")
    p_cov.add_argument("--output")
    p_cov.set_defaults(func=cmd_coverage_analysis)

    p_shop = sub.add_parser("shopping-list", aliases=["plan-generation"])
    p_shop.add_argument("--workflow", default="photorealistic")
    p_shop.add_argument("--format", choices=["text", "json"], default="text")
    p_shop.add_argument("--output")
    p_shop.add_argument("--limit", type=int)
    p_shop.set_defaults(func=cmd_generation_shopping_list)
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
