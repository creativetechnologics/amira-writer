#!/usr/bin/env python3
from __future__ import annotations
import argparse
import asyncio
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, "/tmp/draw-things-comfyui")

import flatbuffers
import grpc
import numpy as np
from PIL import Image, ImageChops, ImageDraw
from src.generated import imageService_pb2, imageService_pb2_grpc
from src.generated.config_generated import GenerationConfigurationT


ROOT = Path("/Volumes/Storage VIII/Programming/Amira Writer")
DEFAULT_OUT_DIR = ROOT / ".codex/draw-things-real-assets-tests/ablation"


@dataclass(frozen=True)
class Asset:
    label: str
    path: Path


AMIRA_ASSETS = {
    "face": Asset(
        "amira_face_identity",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/amira-nazari/reference/casting_reference_photo__young_afghan_persian_woman_in_her_early_20s__olive_skin_tone__dark_brown_eyes__slim_build__anxious_but_defiant_expression__dark_hair_under_light_scarf__d_1334103279_2_of_4.png"),
    ),
    "master": Asset(
        "amira_master_sheet",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/amira-nazari/reference-workflow/master-sheet/master-sheet-2026-03-31T164020Z.png"),
    ),
    "costume": Asset(
        "amira_day2_costume",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/amira-nazari/reference-workflow/storyboard-rig-correction/2026-05-09T-amira-costume-review/selected-daywear/amira-nazari-day-2-brown-tunic-high-mountain-costume-ref-2026-05-09.png"),
    ),
}


LUKE_ASSETS = {
    "face": Asset(
        "luke_front_head",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/luke-hart/reference-workflow/head-turnaround/head-frontNeutral-2026-05-09T071906Z.png"),
    ),
    "master": Asset(
        "luke_master_sheet",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/luke-hart/reference-workflow/master-sheet/master-sheet-2026-04-25T235237Z.png"),
    ),
    "costume": Asset(
        "luke_medic_costume",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Characters/luke-hart/reference-workflow/storyboard-rig-correction/2026-05-09T-luke-costume-review/luke-hart-military-medic-costume-sheet-color-v3-shorter-proportions-2026-05-09.png"),
    ),
    "pose": Asset(
        "luke_reach_storyboard_pose",
        Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/scaffolds/character-rigs/v1/luke-hart__military-medic/previews/reach-storyboard.png"),
    ),
}


def load_rgb(path: Path) -> Image.Image:
    img = Image.open(path)
    if img.mode == "RGBA":
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        bg.alpha_composite(img)
        return bg.convert("RGB")
    return img.convert("RGB")


def crop_nonwhite(img: Image.Image, margin: int = 20) -> Image.Image:
    bg = Image.new("RGB", img.size, (255, 255, 255))
    diff = ImageChops.difference(img, bg).convert("L")
    mask = diff.point(lambda p: 255 if p > 12 else 0)
    box = mask.getbbox()
    if not box:
        return img
    left, top, right, bottom = box
    left = max(0, left - margin)
    top = max(0, top - margin)
    right = min(img.width, right + margin)
    bottom = min(img.height, bottom + margin)
    return img.crop((left, top, right, bottom))


def fit_image(path: Path, width: int, height: int, *, crop: bool = False) -> Image.Image:
    img = load_rgb(path)
    if crop:
        img = crop_nonwhite(img)
    img.thumbnail((width, height), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (width, height), (255, 255, 255))
    canvas.paste(img, ((width - img.width) // 2, (height - img.height) // 2))
    return canvas


def cover_image(path: Path, width: int, height: int) -> Image.Image:
    img = load_rgb(path)
    scale = max(width / img.width, height / img.height)
    resized = img.resize((round(img.width * scale), round(img.height * scale)), Image.Resampling.LANCZOS)
    left = max(0, (resized.width - width) // 2)
    top = max(0, (resized.height - height) // 2)
    return resized.crop((left, top, left + width, top + height))


def tensor_bytes(
    path: Path,
    width: int,
    height: int,
    *,
    control_type: str | None,
    crop: bool = False,
    cover: bool = False,
) -> bytes:
    img = cover_image(path, width, height) if cover else fit_image(path, width, height, crop=crop)
    arr = np.asarray(img).astype(np.float32) / 255.0
    if control_type == "pose":
        mn, mx = arr.min(), arr.max()
        arr = (arr - mn) / max(mx - mn, 1e-6)
        arr = arr / 2.0 + 0.5
        arr = arr * 2.0 - 1.0
    else:
        arr = arr * 2.0 - 1.0
    arr = arr.astype(np.float16)
    payload = bytearray(68 + width * height * 3 * 2)
    struct.pack_into("<9I", payload, 0, 0, 0x1, 0x02, 0x20000, 0, 1, height, width, 3)
    payload[68:] = arr.tobytes()
    return bytes(payload)


def response_to_png(payload: bytes, path: Path) -> tuple[int, int, int]:
    header = struct.unpack_from("<17I", payload, 0)
    if header[0] == 1012247:
        raise RuntimeError("response was compressed despite --no-response-compression")
    height, width, channels = header[6], header[7], header[8]
    arr = np.frombuffer(payload[68:], dtype=np.float16, count=height * width * channels)
    arr = np.clip((arr + 1.0) * 127.0, 0, 255).astype(np.uint8).reshape((height, width, channels))
    if channels == 3:
        img = Image.fromarray(arr, "RGB")
    elif channels == 4:
        img = Image.fromarray(arr, "RGBA")
    elif channels == 1:
        img = Image.fromarray(arr[:, :, 0], "L")
    else:
        raise RuntimeError(f"unsupported output channels={channels}, header={header}")
    img.save(path)
    return width, height, channels


def config_bytes(width: int, height: int, seed: int, steps: int, strength: float) -> bytes:
    cfg = GenerationConfigurationT()
    cfg.model = "flux_2_klein_9b_q8p.ckpt"
    cfg.startWidth = width // 64
    cfg.startHeight = height // 64
    cfg.seed = seed
    cfg.seedMode = 2
    cfg.steps = steps
    cfg.sampler = 17  # UniPC Trailing, matching saved 9B-ish configs.
    cfg.guidanceScale = 1.0
    cfg.guidanceEmbed = 3.5
    cfg.shift = 3.0
    cfg.strength = strength
    cfg.clipSkip = 1
    cfg.batchCount = 1
    cfg.batchSize = 1
    cfg.resolutionDependentShift = False
    cfg.speedUpWithGuidanceEmbed = True
    cfg.imageGuidanceScale = 1.5
    cfg.t5TextEncoder = True
    cfg.negativePromptForImagePrior = True
    cfg.imagePriorSteps = 5
    cfg.tiledDecoding = True
    cfg.decodingTileWidth = 10
    cfg.decodingTileHeight = 10
    cfg.decodingTileOverlap = 2
    builder = flatbuffers.Builder(0)
    builder.Finish(cfg.Pack(builder))
    return bytes(builder.Output())


def make_hint(kind: str, items: list[tuple], width: int, height: int) -> imageService_pb2.HintProto:
    tensors = []
    for item in items:
        asset, weight, crop = item[:3]
        cover = bool(item[3]) if len(item) > 3 else False
        tensors.append(
            imageService_pb2.TensorAndWeight(
                tensor=tensor_bytes(asset.path, width, height, control_type=kind, crop=crop, cover=cover),
                weight=weight,
            )
        )
    return imageService_pb2.HintProto(
        hintType=kind,
        tensors=tensors,
    )


def contact_sheet(assets: list[Asset], width: int, height: int, path: Path) -> None:
    tile_w, tile_h = 220, 330
    sheet = Image.new("RGB", (tile_w * len(assets), tile_h + 42), (255, 255, 255))
    for i, asset in enumerate(assets):
        img = fit_image(asset.path, tile_w, tile_h, crop=True)
        sheet.paste(img, (i * tile_w, 0))
        ImageDraw.Draw(sheet).text((i * tile_w + 6, tile_h + 10), asset.label[:30], fill=(0, 0, 0))
    sheet.save(path)


def case_for(
    character: str,
    case: str,
    width: int,
    height: int,
    background: Asset | None = None,
) -> tuple[list[imageService_pb2.HintProto], str, list[Asset]]:
    assets = AMIRA_ASSETS if character == "amira" else LUKE_ASSETS
    if character == "amira":
        prompt = (
            "Create one clean full-body production animation concept image of Amira Nazari, the same young Afghan woman, "
            "standing calmly on a clean white studio background. Preserve her face, dark eyes, olive skin tone, slim build, "
            "dark brown tunic and cream chadar/shawl. Mature 2D anime feature-film realism, restrained cel shading, clean linework."
        )
        used = [assets["face"], assets["costume"]]
        if case == "text":
            return [], prompt, []
        if case == "shuffle_face":
            return [make_hint("shuffle", [(assets["face"], 1.0, True)], width, height)], prompt, [assets["face"]]
        if case == "shuffle_face_costume":
            return [make_hint("shuffle", [(assets["face"], 1.0, True), (assets["costume"], 0.65, True)], width, height)], prompt, used
        if case == "shuffle_color":
            return [
                make_hint("shuffle", [(assets["face"], 1.0, True), (assets["costume"], 0.55, True)], width, height),
                make_hint("color", [(assets["costume"], 0.35, True)], width, height),
            ], prompt, used
    else:
        prompt = (
            "Create one clean full-body production animation concept image of Luke Hart, the same young American military medic, "
            "standing on a clean white studio background. Preserve his short sandy-brown hair, youthful face, lean build, "
            "desert tan and brown medic uniform, tan boots, khaki scarf, and medic bag. Mature 2D anime feature-film realism, "
            "restrained cel shading, clean linework."
        )
        used = [assets["face"], assets["costume"]]
        if case == "text":
            return [], prompt, []
        if case == "shuffle_face":
            return [make_hint("shuffle", [(assets["face"], 1.0, True)], width, height)], prompt, [assets["face"]]
        if case == "shuffle_face_costume":
            return [make_hint("shuffle", [(assets["face"], 1.0, True), (assets["costume"], 0.65, True)], width, height)], prompt, used
        if case == "shuffle_color":
            return [
                make_hint("shuffle", [(assets["face"], 1.0, True), (assets["costume"], 0.55, True)], width, height),
                make_hint("color", [(assets["costume"], 0.30, True)], width, height),
            ], prompt, used
        if case == "shuffle_pose":
            return [
                make_hint("shuffle", [(assets["face"], 1.0, True), (assets["costume"], 0.55, True)], width, height),
                make_hint("pose", [(assets["pose"], 0.45, True)], width, height),
            ], prompt, [assets["face"], assets["costume"], assets["pose"]]
        if case in {"bg_shuffle", "bg_img2img", "bg_shuffle_color"}:
            if background is None:
                raise ValueError(f"{case} requires --background")
            prompt = (
                "A wide cinematic 2D animation production frame in the Amira Rider visual style. "
                "Luke Hart, the same young American military medic from the reference, stands in the lower foreground "
                "on the dusty road at the dry threshold entrance to a tan mountain village. Preserve Luke's short "
                "sandy-blond hair, blue-gray eyes, straight brows, clean-shaven narrow youthful face, lean build, desert tan and "
                "brown medic uniform, scarf, boots, and medic bag. Match the provided background plate: sunlit Afghan "
                "mountain village, tan adobe walls, rocky dirt road, dry valley air, distant snow mountains, clean "
                "feature-film animation background painting, elegant ink linework, restrained cel-shaded character, "
                "painterly but controlled fills, warm natural daylight, grounded serious mood."
            )
            used = [assets["face"], assets["costume"], background]
            if case == "bg_shuffle":
                return [
                    make_hint(
                        "shuffle",
                        [
                            (assets["face"], 1.80, True),
                            (assets["costume"], 0.55, True),
                            (background, 0.65, False, True),
                        ],
                        width,
                        height,
                    )
                ], prompt, used
            if case == "bg_shuffle_color":
                return [
                    make_hint(
                        "shuffle",
                        [
                            (assets["face"], 1.75, True),
                            (assets["costume"], 0.50, True),
                            (background, 0.75, False, True),
                        ],
                        width,
                        height,
                    ),
                    make_hint("color", [(background, 0.35, False, True)], width, height),
                ], prompt, used
            return [
                make_hint(
                    "shuffle",
                    [
                        (assets["face"], 2.00, True),
                        (assets["costume"], 0.60, True),
                    ],
                    width,
                    height,
                )
            ], prompt, used
    raise ValueError(f"unsupported case {character}:{case}")


async def run(args: argparse.Namespace) -> None:
    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    width, height = args.width, args.height
    background = Asset(args.background_label, args.background) if args.background else None
    hints, prompt, assets = case_for(args.character, args.case, width, height, background)
    prefix = f"{args.character}-{args.case}-seed{args.seed}-steps{args.steps}-{width}x{height}"
    out = out_dir / f"{prefix}.png"
    inputs = out_dir / f"{prefix}-inputs.png"
    prompt_path = out_dir / f"{prefix}-prompt.txt"
    if assets:
        contact_sheet(assets, width, height, inputs)
    prompt_path.write_text(prompt + "\n", encoding="utf-8")
    init_image = None
    if args.init_image:
        init_image = tensor_bytes(args.init_image, width, height, control_type=None, cover=True)

    negative = (
        "text, watermark, labels, extra characters, duplicate body, broken anatomy, chibi, oversized eyes, photorealistic, "
        "3d, cgi, neon glow, green skin, green color cast, overexposed face, distorted face, beard, mustache, heavy stubble, black hair"
    )
    async with grpc.aio.insecure_channel(
        f"{args.host}:{args.port}",
        options=[("grpc.max_send_message_length", -1), ("grpc.max_receive_message_length", -1)],
    ) as channel:
        stub = imageService_pb2_grpc.ImageGenerationServiceStub(channel)
        echo = await stub.Echo(imageService_pb2.EchoRequest(name=f"codex-{args.character}-{args.case}"), timeout=10)
        request_kwargs = dict(
            scaleFactor=1,
            hints=hints,
            prompt=prompt,
            negativePrompt=negative,
            configuration=config_bytes(width, height, args.seed, args.steps, args.strength),
            override=echo.override,
            user="Codex",
            device=imageService_pb2.LAPTOP,
        )
        if init_image is not None:
            request_kwargs["image"] = init_image
        request = imageService_pb2.ImageGenerationRequest(**request_kwargs)
        started = time.time()
        response_count = 0
        async for response in stub.GenerateImage(request, timeout=args.timeout):
            response_count += 1
            if response.HasField("currentSignpost"):
                print(f"signpost_response={response_count}")
            if response.generatedImages:
                w, h, c = response_to_png(response.generatedImages[0], out)
                print(f"saved={out}")
                if assets:
                    print(f"inputs={inputs}")
                print(f"prompt={prompt_path}")
                print(f"dimensions={w}x{h} channels={c}")
                print(f"elapsed={time.time() - started:.1f}s")
                return
        raise RuntimeError("stream ended without generated image")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--character", choices=["amira", "luke"], required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument("--seed", type=int, default=9101)
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=768)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7859)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--strength", type=float, default=1.0)
    parser.add_argument("--background", type=Path)
    parser.add_argument("--background-label", default="background_plate")
    parser.add_argument("--init-image", type=Path)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
