#!/usr/bin/env python3
"""Build the Amira background continuity pack from current chosen references."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


PROJECT_ROOT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
ANIMATE_ROOT = PROJECT_ROOT / "Animate"
CHOSEN_REFS = ANIMATE_ROOT / "backgrounds" / "chosen-references"
PACK_ROOT = ANIMATE_ROOT / "backgrounds" / "continuity-pack"
MAP_PATH = CHOSEN_REFS / "map" / "01-master_valley_topdown_map_4k_v5.png"
BRIDGE_DIR = CHOSEN_REFS / "bridge"
TOWN_BATCH_RESULTS = Path(
    "/Volumes/Storage VIII/Users/gary/Desktop/Amira Background Generations/"
    "Amira Town Liveliness Batch 2026-04-12 1641/results"
)


@dataclass
class ShotFamily:
    id: str
    name: str
    description: str
    camera_logic: str
    must_show: list[str]
    must_not_show: list[str]
    primary_refs: list[str]
    local_map_crop: str
    recommended_anchor_candidates: list[str]


def draw_arrow(draw: ImageDraw.ImageDraw, start: tuple[int, int], end: tuple[int, int], color: tuple[int, int, int], width: int = 10) -> None:
    draw.line([start, end], fill=color, width=width)
    ex, ey = end
    sx, sy = start
    dx = ex - sx
    dy = ey - sy
    length = max((dx * dx + dy * dy) ** 0.5, 1)
    ux = dx / length
    uy = dy / length
    left = (-uy, ux)
    right = (uy, -ux)
    head = 26
    base_x = ex - ux * head
    base_y = ey - uy * head
    p1 = (ex, ey)
    p2 = (base_x + left[0] * head * 0.5, base_y + left[1] * head * 0.5)
    p3 = (base_x + right[0] * head * 0.5, base_y + right[1] * head * 0.5)
    draw.polygon([p1, p2, p3], fill=color)


def save_map_crop(source: Image.Image, box: tuple[int, int, int, int], destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    crop = source.crop(box)
    crop.save(destination)


def build_camera_sheet(source: Image.Image, destination: Path, families: dict[str, dict]) -> None:
    overlay = source.convert("RGBA")
    draw = ImageDraw.Draw(overlay, "RGBA")
    label_draw = ImageDraw.Draw(overlay)
    font = ImageFont.load_default()

    # Orientation labels
    label_draw.rectangle((20, 20, 280, 150), fill=(0, 0, 0, 160))
    label_draw.text((35, 38), "NORTH = town side", fill="white", font=font)
    label_draw.text((35, 62), "SOUTH = empty ridge/base side", fill="white", font=font)
    label_draw.text((35, 86), "EAST = glacier / upstream", fill="white", font=font)
    label_draw.text((35, 110), "WEST = bridge/base approach", fill="white", font=font)

    colors = {
        "family-a": (77, 177, 255, 28),
        "family-b": (255, 139, 61, 28),
        "family-c": (114, 215, 120, 28),
        "family-d": (236, 99, 192, 28),
        "family-e": (255, 214, 64, 28),
        "family-f": (180, 135, 255, 28),
    }
    line_colors = {k: (v[0], v[1], v[2]) for k, v in colors.items()}

    for family_id, payload in families.items():
        box = payload["box"]
        draw.rectangle(box, outline=line_colors[family_id] + (255,), fill=None, width=10)
        label_bg = (box[0] + 10, box[1] + 10, box[0] + 290, box[1] + 58)
        draw.rectangle(label_bg, fill=(0, 0, 0, 170))
        label_draw.text((box[0] + 18, box[1] + 22), payload["label"], fill="white", font=font)
        if payload.get("arrow"):
            draw_arrow(draw, payload["arrow"][0], payload["arrow"][1], line_colors[family_id], width=10)

    destination.parent.mkdir(parents=True, exist_ok=True)
    overlay.convert("RGB").save(destination, quality=92)


def build_bridge_contact_sheet(image_paths: list[Path], destination: Path) -> None:
    thumbs = []
    for path in image_paths:
        image = Image.open(path).convert("RGB")
        thumbs.append((path.stem, ImageOps.fit(image, (520, 300), method=Image.Resampling.LANCZOS)))

    cols = 2
    rows = (len(thumbs) + cols - 1) // cols
    margin = 22
    label_h = 30
    sheet = Image.new("RGB", (cols * 520 + (cols + 1) * margin, rows * (300 + label_h) + (rows + 1) * margin), (22, 22, 22))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()

    for idx, (label, thumb) in enumerate(thumbs):
        col = idx % cols
        row = idx // cols
        x = margin + col * (520 + margin)
        y = margin + row * (300 + label_h + margin)
        sheet.paste(thumb, (x, y))
        draw.text((x, y + 308), label[:56], fill=(235, 235, 235), font=font)

    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, quality=92)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def main() -> int:
    PACK_ROOT.mkdir(parents=True, exist_ok=True)
    crops_dir = PACK_ROOT / "map-crops"
    anchors_dir = PACK_ROOT / "recommended-anchor-shortlist"

    bridge_refs = sorted(BRIDGE_DIR.glob("*.png"))
    town_anchor_candidates = {
        "town-wide-21-south-ridge-full-spread-morning": TOWN_BATCH_RESULTS / "town-wide-21-south-ridge-full-spread-morning.jpg",
        "town-wide-23-west-approach-long-view": TOWN_BATCH_RESULTS / "town-wide-23-west-approach-long-view.jpg",
        "town-wide-30-riverside-bend-full-town": TOWN_BATCH_RESULTS / "town-wide-30-riverside-bend-full-town.jpg",
        "town-wide-31-upper-slope-looking-down": TOWN_BATCH_RESULTS / "town-wide-31-upper-slope-looking-down.jpg",
        "town-wide-35-blue-hour-across-river": TOWN_BATCH_RESULTS / "town-wide-35-blue-hour-across-river.jpg",
        "town-wide-39-bridge-secondary-town-primary": TOWN_BATCH_RESULTS / "town-wide-39-bridge-secondary-town-primary.jpg",
    }

    with Image.open(MAP_PATH) as map_image:
        map_image = map_image.convert("RGB")
        crop_specs = {
            "family-a-wide-town-north-bank.png": (220, 0, 4580, 1600),
            "family-b-across-river-empty-south-bank.png": (1750, 850, 4750, 2200),
            "family-c-bridge-and-lower-town.png": (1050, 550, 3150, 1650),
            "family-d-market-and-lower-core.png": (1450, 240, 3650, 1350),
            "family-e-upper-residential-and-terraces.png": (1800, 0, 4300, 1040),
            "family-f-west-approach-base-separation.png": (0, 850, 2700, 2550),
            "family-g-east-glacier-context.png": (3550, 0, 6336, 1700),
        }
        for name, box in crop_specs.items():
            save_map_crop(map_image, box, crops_dir / name)

        camera_sheet_families = {
            "family-a": {
                "box": crop_specs["family-a-wide-town-north-bank.png"],
                "label": "A wide whole-town",
                "arrow": ((1700, 2000), (2900, 930)),
            },
            "family-b": {
                "box": crop_specs["family-b-across-river-empty-south-bank.png"],
                "label": "B across-river",
                "arrow": ((3500, 700), (3400, 1500)),
            },
            "family-c": {
                "box": crop_specs["family-c-bridge-and-lower-town.png"],
                "label": "C bridge/lower town",
                "arrow": ((1100, 1400), (2200, 1020)),
            },
            "family-d": {
                "box": crop_specs["family-d-market-and-lower-core.png"],
                "label": "D market core",
                "arrow": ((2600, 1170), (2500, 780)),
            },
            "family-e": {
                "box": crop_specs["family-e-upper-residential-and-terraces.png"],
                "label": "E upper slope",
                "arrow": ((3980, 760), (2600, 460)),
            },
            "family-f": {
                "box": crop_specs["family-f-west-approach-base-separation.png"],
                "label": "F west/base logic",
                "arrow": ((1000, 2200), (1750, 1380)),
            },
        }
        build_camera_sheet(map_image, PACK_ROOT / "camera-direction-sheet.png", camera_sheet_families)

    build_bridge_contact_sheet(bridge_refs, PACK_ROOT / "bridge-canon-contact-sheet.jpg")

    prompt_template = """
# Amira Strict Geography Prompt Template

Use this template for every background generation after the continuity pack is in play.

## 1. Non-negotiable geography
- The town exists only on the **north side of the river**.
- The south side of the river is **empty ridge / terrain only**, with no houses, streets, walls, or second settlement.
- If graves are visible, they are small **stone cairns** near the south bank only.
- If the bridge is visible, it must match the supplied bridge-canon images: a narrow ancient **single-lane stone bridge**.
- The shot must match the supplied **map reference and local map crop**.

## 2. Shot-specific brief
Describe only the local shot content:
- camera position
- camera direction
- which district / street / edge is visible
- whether the bridge is present or absent
- whether the river is present or absent

## 3. Life / realism
- realistic documentary-style photograph
- living mountain town with a few thousand residents
- mixed old and newer structures
- visible repairs, textiles, produce crates, painted doors, laundry, awnings, carts, retaining walls
- no visible people, but clear signs of use and maintenance

## 4. Hard negatives
- no second settlement
- no town buildings on the south bank
- no fantasy city
- no monumental ruins
- no extra bridges
- no oversized bridge
- no perfectly symmetrical street plan
- not a painting, not concept art, not matte painting, not game art

## 5. Reference stack order
1. Master map
2. Local map crop for the shot family
3. Canonical bridge refs if the bridge is visible
4. Approved generated town anchor for the same shot family
5. One style/detail ref only if needed

## 6. Example opening
\"Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. The town must remain only on the north side of the river, and the south bank must remain empty terrain except for small cemetery stones if visible.\"
"""

    write_text(PACK_ROOT / "strict-prompt-template.md", prompt_template)

    shot_families = [
        ShotFamily(
            id="family-a",
            name="Wide whole-town views from south/ridge side",
            description="Broad establishing or semi-establishing views where the town mass is the primary subject.",
            camera_logic="Camera lives on the south/ridge side looking north and usually eastward toward the glacier.",
            must_show=["the full north-bank town mass", "clear one-sided settlement logic", "liveliness across the whole town footprint"],
            must_not_show=["south-bank houses", "base too close to town", "bridge redesign if visible"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-a-wide-town-north-bank.png")],
            local_map_crop=str(crops_dir / "family-a-wide-town-north-bank.png"),
            recommended_anchor_candidates=[
                str(town_anchor_candidates["town-wide-21-south-ridge-full-spread-morning"]),
                str(town_anchor_candidates["town-wide-23-west-approach-long-view"]),
                str(town_anchor_candidates["town-wide-30-riverside-bend-full-town"]),
            ],
        ),
        ShotFamily(
            id="family-b",
            name="Across-river views",
            description="Shots from town or near town that look across the river to the empty south bank.",
            camera_logic="Camera starts on or near the north bank looking south or southwest across the river.",
            must_show=["empty south bank", "possible small stone-cairn cemetery", "no second settlement"],
            must_not_show=["houses or streets across the river", "base turning into a village"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-b-across-river-empty-south-bank.png")],
            local_map_crop=str(crops_dir / "family-b-across-river-empty-south-bank.png"),
            recommended_anchor_candidates=[str(town_anchor_candidates["town-wide-35-blue-hour-across-river"])],
        ),
        ShotFamily(
            id="family-c",
            name="Bridge and lower-town approaches",
            description="Approach views where the bridge and lower district interact.",
            camera_logic="Camera sits near the bridge or its approaches; use bridge canon every time.",
            must_show=["canonical bridge shape", "lower-town density near the bridge", "one-sided town geography"],
            must_not_show=["different bridge family", "extra bridge spans", "south-bank urban spill"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-c-bridge-and-lower-town.png"), *[str(p) for p in bridge_refs]],
            local_map_crop=str(crops_dir / "family-c-bridge-and-lower-town.png"),
            recommended_anchor_candidates=[str(town_anchor_candidates["town-wide-39-bridge-secondary-town-primary"])],
        ),
        ShotFamily(
            id="family-d",
            name="Market and lower core",
            description="Tighter urban fabric around the market and lower streets.",
            camera_logic="Camera remains within the lower north-bank district; the river can appear but south bank stays empty.",
            must_show=["shops, awnings, produce, repairs, color", "dense lower-town continuity"],
            must_not_show=["ruin-city feel", "grand fantasy plaza", "formal monumental architecture"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-d-market-and-lower-core.png")],
            local_map_crop=str(crops_dir / "family-d-market-and-lower-core.png"),
            recommended_anchor_candidates=[],
        ),
        ShotFamily(
            id="family-e",
            name="Upper residential and terraces",
            description="Views from or toward the upper slope neighborhoods and terraced edges.",
            camera_logic="Camera sits on the upper north slope looking down or across through the settlement.",
            must_show=["upper-to-lower continuity", "terraces, retaining walls, dense habitability"],
            must_not_show=["isolated dead ruins at the edges", "detached second neighborhood across the river"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-e-upper-residential-and-terraces.png")],
            local_map_crop=str(crops_dir / "family-e-upper-residential-and-terraces.png"),
            recommended_anchor_candidates=[str(town_anchor_candidates["town-wide-31-upper-slope-looking-down"])],
        ),
        ShotFamily(
            id="family-f",
            name="West approach / base separation logic",
            description="Views that must preserve distance between base, bridge, and town.",
            camera_logic="Camera is west or southwest of the bridge; if the base is present it should stay small and far away.",
            must_show=["clear separation between town and base", "bridge approach logic", "empty south bank apart from base zone when relevant"],
            must_not_show=["base reading like a second town", "oversized tents or structures", "grave field scaling like buildings"],
            primary_refs=[str(MAP_PATH), str(crops_dir / "family-f-west-approach-base-separation.png")],
            local_map_crop=str(crops_dir / "family-f-west-approach-base-separation.png"),
            recommended_anchor_candidates=[str(town_anchor_candidates["town-wide-23-west-approach-long-view"])],
        ),
    ]

    shot_family_md = ["# Amira Shot Families", "", "These are the continuity-safe families to use instead of free-floating one-off prompts.", ""]
    for family in shot_families:
        shot_family_md.extend(
            [
                f"## {family.id}: {family.name}",
                f"- Description: {family.description}",
                f"- Camera logic: {family.camera_logic}",
                "- Must show:",
                *[f"  - {item}" for item in family.must_show],
                "- Must not show:",
                *[f"  - {item}" for item in family.must_not_show],
                f"- Local map crop: `{family.local_map_crop}`",
                "- Primary refs:",
                *[f"  - `{item}`" for item in family.primary_refs],
            ]
        )
        if family.recommended_anchor_candidates:
            shot_family_md.extend(
                [
                    "- Recommended generated anchor candidates:",
                    *[f"  - `{item}`" for item in family.recommended_anchor_candidates],
                ]
            )
        shot_family_md.append("")
    write_text(PACK_ROOT / "shot-families.md", "\n".join(shot_family_md))

    anchor_shortlist_md = [
        "# Recommended Anchor Shortlist",
        "",
        "These are **recommended** current candidates to promote into chosen references after review. They are not automatically treated as approved canon yet.",
        "",
        "## Wide-town anchors",
        f"- South/ridge broad anchor: `{town_anchor_candidates['town-wide-21-south-ridge-full-spread-morning']}`",
        f"- West approach broad anchor: `{town_anchor_candidates['town-wide-23-west-approach-long-view']}`",
        f"- Riverside / full-mass anchor: `{town_anchor_candidates['town-wide-30-riverside-bend-full-town']}`",
        f"- Across-river / blue-hour anchor: `{town_anchor_candidates['town-wide-35-blue-hour-across-river']}`",
        "",
        "## Family-specific anchors",
        f"- Upper slope continuity anchor: `{town_anchor_candidates['town-wide-31-upper-slope-looking-down']}`",
        f"- Bridge-visible town anchor: `{town_anchor_candidates['town-wide-39-bridge-secondary-town-primary']}`",
    ]
    write_text(PACK_ROOT / "recommended-anchor-shortlist.md", "\n".join(anchor_shortlist_md))

    continuity_pack = {
        "created_at": datetime.now().isoformat(),
        "master_map": str(MAP_PATH),
        "camera_direction_sheet": str(PACK_ROOT / "camera-direction-sheet.png"),
        "strict_prompt_template": str(PACK_ROOT / "strict-prompt-template.md"),
        "shot_families_markdown": str(PACK_ROOT / "shot-families.md"),
        "bridge_canon_contact_sheet": str(PACK_ROOT / "bridge-canon-contact-sheet.jpg"),
        "global_invariants": [
            "Town exists only on the north side of the river.",
            "South side of the river remains empty ridge/terrain except for small cemetery cairns when visible.",
            "Bridge must match the chosen bridge canon whenever visible.",
            "Town should read as lived-in and active across the entire settlement footprint.",
            "Use map + local crop + family anchor before using extra style refs.",
        ],
        "bridge_canon_refs": [str(path) for path in bridge_refs],
        "recommended_anchor_candidates": {key: str(path) for key, path in town_anchor_candidates.items()},
        "map_crops": {path.name: str(path) for path in sorted(crops_dir.glob("*.png"))},
        "shot_families": [asdict(family) for family in shot_families],
    }
    write_text(PACK_ROOT / "continuity-pack.json", json.dumps(continuity_pack, indent=2))

    pilot_prompts = [
        {
            "id": "canon-01-south-ridge-wide",
            "title": "Canon 01 — south ridge wide",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. The town must remain only on the north side of the river, and the south bank must remain empty terrain except for small cemetery stones if visible. Use the approved south-ridge whole-town anchor to keep massing and density consistent. Broad view from the south ridge looking across the town toward the glacier. The entire town should feel inhabited across the full footprint. No second settlement, no fantasy ruins, no extra bridge.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-a-wide-town-north-bank.png"), str(town_anchor_candidates["town-wide-21-south-ridge-full-spread-morning"])],
        },
        {
            "id": "canon-02-west-approach-wide",
            "title": "Canon 02 — west approach wide",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. The town must remain only on the north side of the river. Wide west-approach view with the bridge zone secondary and the whole town reading as a single inhabited settlement. Preserve the approved west-approach anchor. No buildings on the south bank except the distant small base zone if it is barely visible.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-f-west-approach-base-separation.png"), str(town_anchor_candidates["town-wide-23-west-approach-long-view"])],
        },
        {
            "id": "canon-03-riverside-full-mass",
            "title": "Canon 03 — riverside full mass",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. Looking from a river bend toward the full town mass on the north bank only. Use the approved riverside whole-town anchor to preserve density, layering, and town edge behavior. No second settlement, no town on the south bank, no painterly exaggeration.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-a-wide-town-north-bank.png"), str(town_anchor_candidates["town-wide-30-riverside-bend-full-town"])],
        },
        {
            "id": "canon-04-across-river-empty-bank",
            "title": "Canon 04 — across river empty bank",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. View across the river with the town on the north bank only and the south bank staying empty terrain with small stone cemetery cairns if visible. Use the approved across-river anchor to preserve riverbank logic. No second settlement, no base growing into a village.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-b-across-river-empty-south-bank.png"), str(town_anchor_candidates["town-wide-35-blue-hour-across-river"])],
        },
        {
            "id": "canon-05-bridge-town-primary",
            "title": "Canon 05 — bridge visible town primary",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. The bridge must match the supplied canonical stone-bridge references. The town remains only on the north bank and is the primary subject. Use the approved bridge-visible town anchor to preserve bridge shape and town placement. No extra arches, no modern bridge, no south-bank town.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-c-bridge-and-lower-town.png"), *[str(path) for path in bridge_refs], str(town_anchor_candidates["town-wide-39-bridge-secondary-town-primary"])],
        },
        {
            "id": "canon-06-upper-slope",
            "title": "Canon 06 — upper slope continuity",
            "prompt": "Create a realistic documentary-style photograph that exactly follows the supplied map and local geography references. Camera from the upper north slope looking down through the town. Use the approved upper-slope anchor to preserve upper-to-lower continuity. The town should feel active and repaired, not ruinous. No buildings across the river.",
            "reference_paths": [str(MAP_PATH), str(crops_dir / "family-e-upper-residential-and-terraces.png"), str(town_anchor_candidates["town-wide-31-upper-slope-looking-down"])],
        },
    ]

    controlled_batch_plan = {
        "character_name": "Town Canon Lock",
        "character_slug": "town-canon-lock",
        "display_name": "Amira Town Canon Lock Pilot",
        "model": "gemini-3.1-flash-image-preview",
        "aspect_ratio": "16:9",
        "image_size": "1K",
        "output_root": str(PACK_ROOT / "next-batch-output-town-canon-lock"),
        "prompts": pilot_prompts,
    }
    write_text(PACK_ROOT / "controlled-batch-pilot-plan.json", json.dumps(controlled_batch_plan, indent=2))

    readme = f"""
# Amira Background Continuity Pack

This folder locks the geography and prompt strategy before future town/background batches.

## Core files
- Master map: `{MAP_PATH}`
- Camera direction sheet: `{PACK_ROOT / 'camera-direction-sheet.png'}`
- Strict prompt template: `{PACK_ROOT / 'strict-prompt-template.md'}`
- Shot families: `{PACK_ROOT / 'shot-families.md'}`
- Continuity pack JSON: `{PACK_ROOT / 'continuity-pack.json'}`
- Controlled pilot batch plan (not submitted): `{PACK_ROOT / 'controlled-batch-pilot-plan.json'}`

## Workflow
1. Start every outdoor prompt with the master map.
2. Add the family-specific local map crop.
3. If the bridge is visible, add bridge canon refs.
4. Add the approved generated town anchor for that family.
5. Add only one extra style/detail ref if still needed.

## Important
- Do not rely on brute-force generation alone for continuity.
- Promote approved generated anchors into chosen references once selected.
- Use the pilot plan only after reviewing and approving the recommended anchors.
"""
    write_text(PACK_ROOT / "README.md", readme)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
