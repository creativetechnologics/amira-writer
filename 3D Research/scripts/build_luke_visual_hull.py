#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image
from skimage import measure


ROOT = Path(__file__).resolve().parents[1]
INPUT_IMAGE = ROOT / "luke-anime-reference-sheet-4k-v2-16x9.png"
OUTPUT_DIR = ROOT / "output" / "luke-visual-hull"

FULL_BODY_ROW = 0
GRID_COLUMNS = 7
GRID_ROWS = 2

FRONT_COLUMN = 0
FRONT_SMILE_COLUMN = 1
QUARTER_LEFT_COLUMN = 2
QUARTER_RIGHT_COLUMN = 3
LEFT_PROFILE_COLUMN = 4
RIGHT_PROFILE_COLUMN = 5
BACK_COLUMN = 6

VOXEL_HEIGHT = 220
VOXEL_WIDTH = 96
VOXEL_DEPTH = 52


def cell_bounds(width: int, height: int, col: int, row: int) -> tuple[int, int, int, int]:
    x0 = round(col * width / GRID_COLUMNS)
    x1 = round((col + 1) * width / GRID_COLUMNS)
    y0 = round(row * height / GRID_ROWS)
    y1 = round((row + 1) * height / GRID_ROWS)
    return x0, y0, x1, y1


def extract_panel(image: Image.Image, col: int, row: int) -> Image.Image:
    return image.crop(cell_bounds(*image.size, col, row))


def build_mask(image: Image.Image) -> np.ndarray:
    arr = np.asarray(image.convert("RGBA"))
    rgb = arr[..., :3]
    alpha = arr[..., 3]
    return (alpha > 0) & (np.min(rgb, axis=-1) < 245)


def normalize_panel(image: Image.Image, target_width: int, target_height: int) -> tuple[np.ndarray, np.ndarray]:
    mask = build_mask(image)
    ys, xs = np.where(mask)
    if ys.size == 0 or xs.size == 0:
        raise RuntimeError("No subject pixels detected in panel")

    pad = 20
    x0 = max(int(xs.min()) - pad, 0)
    x1 = min(int(xs.max()) + pad + 1, image.width)
    y0 = max(int(ys.min()) - pad, 0)
    y1 = min(int(ys.max()) + pad + 1, image.height)

    subject = image.crop((x0, y0, x1, y1)).convert("RGBA")
    subject_mask = build_mask(subject)

    scale = min(target_width / subject.width, (target_height - 2) / subject.height)
    scaled_width = max(1, int(round(subject.width * scale)))
    scaled_height = max(1, int(round(subject.height * scale)))

    subject = subject.resize((scaled_width, scaled_height), Image.Resampling.LANCZOS)
    subject_mask_img = Image.fromarray((subject_mask.astype(np.uint8) * 255)).resize(
        (scaled_width, scaled_height),
        Image.Resampling.LANCZOS,
    )
    subject_mask = np.asarray(subject_mask_img) > 127

    canvas = Image.new("RGBA", (target_width, target_height), (255, 255, 255, 0))
    mask_canvas = np.zeros((target_height, target_width), dtype=bool)

    left = (target_width - scaled_width) // 2
    top = target_height - scaled_height

    canvas.alpha_composite(subject, (left, top))
    mask_canvas[top : top + scaled_height, left : left + scaled_width] = subject_mask

    rgb = np.asarray(canvas.convert("RGB"))
    return rgb, mask_canvas


def color_sample(rgb: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    width = rgb.shape[1]
    height = rgb.shape[0]
    xi = np.clip(np.round(x).astype(int), 0, width - 1)
    yi = np.clip(np.round(y).astype(int), 0, height - 1)
    return rgb[yi, xi].astype(np.float32)


def make_visual_hull(front_mask: np.ndarray, side_mask: np.ndarray) -> np.ndarray:
    volume = np.zeros((VOXEL_HEIGHT, VOXEL_WIDTH, VOXEL_DEPTH), dtype=np.uint8)
    x_positions = np.arange(VOXEL_WIDTH)
    z_positions = np.arange(VOXEL_DEPTH)
    y_positions = np.arange(VOXEL_HEIGHT)

    front_x = np.clip(np.round(x_positions / max(VOXEL_WIDTH - 1, 1) * (front_mask.shape[1] - 1)).astype(int), 0, front_mask.shape[1] - 1)
    front_y = np.clip(np.round(y_positions / max(VOXEL_HEIGHT - 1, 1) * (front_mask.shape[0] - 1)).astype(int), 0, front_mask.shape[0] - 1)
    side_x = np.clip(np.round(z_positions / max(VOXEL_DEPTH - 1, 1) * (side_mask.shape[1] - 1)).astype(int), 0, side_mask.shape[1] - 1)
    side_y = np.clip(np.round(y_positions / max(VOXEL_HEIGHT - 1, 1) * (side_mask.shape[0] - 1)).astype(int), 0, side_mask.shape[0] - 1)

    for yi, fy in enumerate(front_y):
        front_row = front_mask[fy, front_x]
        side_row = side_mask[side_y[yi], side_x]
        volume[yi] = np.logical_and(front_row[:, None], side_row[None, :]).astype(np.uint8)

    return volume


def build_mesh(volume: np.ndarray) -> trimesh.Trimesh:
    verts_raw, faces, _, _ = measure.marching_cubes(volume.astype(np.float32), level=0.5)

    raw_y = verts_raw[:, 0]
    raw_x = verts_raw[:, 1]
    raw_z = verts_raw[:, 2]

    verts = np.column_stack(
        [
            (raw_x / max(VOXEL_WIDTH - 1, 1) - 0.5) * 1.0,
            (1.0 - raw_y / max(VOXEL_HEIGHT - 1, 1)) * 1.8 - 0.9,
            (raw_z / max(VOXEL_DEPTH - 1, 1) - 0.5) * 0.55,
        ]
    )

    mesh = trimesh.Trimesh(vertices=verts, faces=faces, process=False)
    mesh.remove_unreferenced_vertices()
    trimesh.smoothing.filter_taubin(mesh, lamb=0.4, nu=-0.35, iterations=8)
    return mesh


def apply_vertex_colors(
    mesh: trimesh.Trimesh,
    front_rgb: np.ndarray,
    back_rgb: np.ndarray,
    left_rgb: np.ndarray,
    right_rgb: np.ndarray,
) -> trimesh.Trimesh:
    verts = mesh.vertices
    normals = mesh.vertex_normals

    y_tex = (0.9 - verts[:, 1]) / 1.8 * (front_rgb.shape[0] - 1)
    x_front = (verts[:, 0] + 0.5) / 1.0 * (front_rgb.shape[1] - 1)
    x_back = x_front
    x_left = (verts[:, 2] + 0.275) / 0.55 * (left_rgb.shape[1] - 1)
    x_right = x_left

    front_colors = color_sample(front_rgb, x_front, y_tex)
    back_colors = color_sample(back_rgb, x_back, y_tex)
    left_colors = color_sample(left_rgb, x_left, y_tex)
    right_colors = color_sample(right_rgb, x_right, y_tex)

    use_front = normals[:, 2] >= 0
    primary_fb = np.where(use_front[:, None], front_colors, back_colors)
    primary_lr = np.where((normals[:, 0] >= 0)[:, None], right_colors, left_colors)

    w_fb = np.abs(normals[:, 2:3])
    w_lr = np.abs(normals[:, 0:1])
    base = primary_fb * w_fb + primary_lr * w_lr

    has_weight = np.maximum(w_fb + w_lr, 1e-5)
    colors = base / has_weight

    tone_strength = np.clip(0.58 + 0.42 * np.maximum(normals[:, 1:2], 0), 0.45, 1.0)
    colors *= tone_strength
    colors = np.clip(colors, 0, 255).astype(np.uint8)
    alpha = np.full((colors.shape[0], 1), 255, dtype=np.uint8)
    mesh.visual.vertex_colors = np.concatenate([colors, alpha], axis=1)
    return mesh


def build_metadata() -> dict:
    return {
        "sourceImage": str(INPUT_IMAGE.name),
        "pipeline": "local_visual_hull_from_reference_sheet",
        "notes": [
            "Geometry reconstructed from front plus side silhouettes of the supplied reference sheet.",
            "Vertex colors projected from front, back, and side panels of the same sheet.",
            "Final cel shading is expected to come from the viewer/runtime toon material, not from baked lighting."
        ],
    }


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    sheet = Image.open(INPUT_IMAGE)

    front_panel = extract_panel(sheet, FRONT_COLUMN, FULL_BODY_ROW)
    back_panel = extract_panel(sheet, BACK_COLUMN, FULL_BODY_ROW)
    left_panel = extract_panel(sheet, LEFT_PROFILE_COLUMN, FULL_BODY_ROW)
    right_panel = extract_panel(sheet, RIGHT_PROFILE_COLUMN, FULL_BODY_ROW)

    front_rgb, front_mask = normalize_panel(front_panel, VOXEL_WIDTH, VOXEL_HEIGHT)
    back_rgb, _ = normalize_panel(back_panel, VOXEL_WIDTH, VOXEL_HEIGHT)
    left_rgb, left_mask = normalize_panel(left_panel, VOXEL_DEPTH, VOXEL_HEIGHT)
    right_rgb, right_mask = normalize_panel(right_panel, VOXEL_DEPTH, VOXEL_HEIGHT)
    side_mask = np.logical_or(left_mask, right_mask)

    Image.fromarray(front_rgb).save(OUTPUT_DIR / "front-normalized.png")
    Image.fromarray(back_rgb).save(OUTPUT_DIR / "back-normalized.png")
    Image.fromarray(left_rgb).save(OUTPUT_DIR / "left-normalized.png")
    Image.fromarray(right_rgb).save(OUTPUT_DIR / "right-normalized.png")
    Image.fromarray((front_mask.astype(np.uint8) * 255)).save(OUTPUT_DIR / "front-mask.png")
    Image.fromarray((side_mask.astype(np.uint8) * 255)).save(OUTPUT_DIR / "side-mask.png")

    volume = make_visual_hull(front_mask, side_mask)
    mesh = build_mesh(volume)
    mesh = apply_vertex_colors(mesh, front_rgb, back_rgb, left_rgb, right_rgb)

    glb_path = OUTPUT_DIR / "luke-visual-hull.glb"
    mesh.export(glb_path)

    with (OUTPUT_DIR / "build-metadata.json").open("w", encoding="utf-8") as handle:
        json.dump(build_metadata(), handle, indent=2)

    print(f"Generated: {glb_path}")


if __name__ == "__main__":
    main()
