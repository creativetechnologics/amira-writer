#!/usr/bin/env python3
"""Submit/watch Gemini Batch API jobs for Animate inspiration image sets."""

from __future__ import annotations

import argparse
import base64
import importlib
import json
import os
import site
import shutil
import subprocess
import sys
import tempfile
import time
import warnings
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


warnings.filterwarnings(
    "ignore",
    message=r"You are using a Python version 3\.9 past its end of life\..*",
    category=FutureWarning,
)
warnings.filterwarnings(
    "ignore",
    message=r"urllib3 v2 only supports OpenSSL 1\.1\.1\+.*",
)


def _append_user_site_packages() -> None:
    vendor_dir = _vendor_package_dir()
    vendor_dir.mkdir(parents=True, exist_ok=True)
    vendor_root = vendor_dir.parent

    cleaned_paths: list[str] = []
    for existing in sys.path:
        try:
            existing_path = Path(existing).resolve()
        except Exception:
            cleaned_paths.append(existing)
            continue

        if existing_path == vendor_dir.resolve():
            cleaned_paths.append(existing)
            continue

        if existing_path == vendor_root.resolve() or vendor_root.resolve() in existing_path.parents:
            continue

        cleaned_paths.append(existing)

    sys.path[:] = cleaned_paths

    if str(vendor_dir) not in sys.path:
        sys.path.append(str(vendor_dir))

    try:
        user_site = site.getusersitepackages()
    except Exception:
        return

    paths = [user_site] if isinstance(user_site, str) else list(user_site)
    for path in paths:
        if path and path not in sys.path:
            sys.path.append(path)


def _vendor_package_dir() -> Path:
    version_tag = f"python{sys.version_info.major}.{sys.version_info.minor}"
    return Path.home() / "Library" / "Application Support" / "Amira Writer" / "python-packages" / version_tag


def _reset_import_state() -> None:
    prefixes = ("google", "pydantic", "pydantic_core", "annotated_types", "typing_inspection")
    for key in list(sys.modules.keys()):
        if any(key == prefix or key.startswith(prefix + ".") for prefix in prefixes):
            sys.modules.pop(key, None)


def _run_bootstrap_command(arguments: list[str]) -> None:
    subprocess.run(
        arguments,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _load_google_genai_modules() -> tuple[object, object]:
    _append_user_site_packages()
    _reset_import_state()
    try:
        genai_module = importlib.import_module("google.genai")
        types_module = importlib.import_module("google.genai.types")
        return genai_module, types_module
    except ModuleNotFoundError as error:
        if error.name not in {"google", "google.genai", "google.genai.types"}:
            raise

    python = sys.executable or "python3"

    try:
        import pip  # noqa: F401
    except ModuleNotFoundError:
        try:
            _run_bootstrap_command([python, "-m", "ensurepip", "--upgrade", "--user"])
        except Exception:
            pass

    try:
        _run_bootstrap_command(
            [
                python,
                "-m",
                "pip",
                "install",
                "--target",
                str(_vendor_package_dir()),
                "--upgrade",
                "--quiet",
                "--disable-pip-version-check",
                "google-genai",
            ]
        )
    except Exception as error:
        raise RuntimeError(
            "Unable to install the required google-genai package automatically. "
            "Please run `python3 -m pip install --user google-genai` and try again."
        ) from error

    _append_user_site_packages()
    _reset_import_state()
    try:
        genai_module = importlib.import_module("google.genai")
        types_module = importlib.import_module("google.genai.types")
        return genai_module, types_module
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "The google-genai package was installed but could not be imported by the batch helper."
        ) from error


genai, types = _load_google_genai_modules()


TERMINAL_STATES = {
    "JOB_STATE_SUCCEEDED",
    "JOB_STATE_FAILED",
    "JOB_STATE_CANCELLED",
    "JOB_STATE_EXPIRED",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Submit and watch arbitrary Gemini inspiration-image batch jobs.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    submit = subparsers.add_parser("submit", help="Submit a new batch job from a JSON plan.")
    submit.add_argument("--plan", type=Path, required=True, help="Path to the batch plan JSON.")
    submit.add_argument("--api-key", default=None)

    status = subparsers.add_parser("status", help="Check a batch and download finished results.")
    status.add_argument("--metadata", type=Path, required=True)
    status.add_argument("--api-key", default=None)
    status.add_argument("--download-results", action="store_true")

    watch = subparsers.add_parser("watch", help="Poll a batch until completion and download results.")
    watch.add_argument("--metadata", type=Path, required=True)
    watch.add_argument("--api-key", default=None)
    watch.add_argument("--poll-seconds", type=int, default=120)

    return parser


@dataclass
class PromptRequest:
    id: str
    title: str
    prompt: str
    reference_paths: list[str]


@dataclass
class BatchPlan:
    character_name: str
    character_slug: str
    display_name: str
    model: str
    aspect_ratio: str
    image_size: str
    output_root: Path
    prompts: list[PromptRequest]


def load_api_key(explicit: str | None) -> str:
    key = (explicit or os.environ.get("GEMINI_API_KEY") or "").strip()
    if not key:
        raise RuntimeError("Gemini API key is required.")
    return key


def load_plan(path: Path) -> BatchPlan:
    payload = json.loads(path.read_text(encoding="utf-8"))
    prompts = [
        PromptRequest(
            id=item["id"],
            title=item.get("title") or item["id"],
            prompt=item["prompt"],
            reference_paths=item.get("reference_paths") or [],
        )
        for item in payload["prompts"]
    ]
    return BatchPlan(
        character_name=payload["character_name"],
        character_slug=payload["character_slug"],
        display_name=payload["display_name"],
        model=payload["model"],
        aspect_ratio=payload["aspect_ratio"],
        image_size=payload["image_size"],
        output_root=Path(payload["output_root"]).expanduser().resolve(),
        prompts=prompts,
    )


def _project_roots_for_output(output_root: Path) -> tuple[Path | None, Path | None]:
    resolved_output = output_root.expanduser().resolve()
    animate_root: Path | None = None

    for candidate in [resolved_output, *resolved_output.parents]:
        if candidate.name == "Animate":
            animate_root = candidate
            break

    project_root = animate_root.parent if animate_root is not None else None
    return animate_root, project_root


def _resolve_reference_path(reference_path: str, output_root: Path) -> Path:
    raw = reference_path.strip()
    if not raw:
        raise FileNotFoundError("Reference image path is empty.")

    candidate = Path(raw).expanduser()
    if candidate.exists():
        return candidate.resolve()

    animate_root, project_root = _project_roots_for_output(output_root)
    normalized = raw.replace("\\", "/")

    fallback_candidates: list[Path] = []
    if normalized.startswith("/Animate/") and project_root is not None:
        fallback_candidates.append(project_root / normalized.lstrip("/"))
    if normalized.startswith("Animate/") and project_root is not None:
        fallback_candidates.append(project_root / normalized)
    if normalized.startswith("/characters/") and animate_root is not None:
        fallback_candidates.append(animate_root / normalized.removeprefix("/"))
    if normalized.startswith("characters/") and animate_root is not None:
        fallback_candidates.append(animate_root / normalized)
    if normalized.startswith("/backgrounds/") and animate_root is not None:
        fallback_candidates.append(animate_root / normalized.removeprefix("/"))
    if normalized.startswith("backgrounds/") and animate_root is not None:
        fallback_candidates.append(animate_root / normalized)

    for fallback in fallback_candidates:
        expanded = fallback.expanduser()
        if expanded.exists():
            return expanded.resolve()

    raise FileNotFoundError(f"Reference image not found: {raw}")


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _write_jsonl(path: Path, lines: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(json.dumps(line))
            handle.write("\n")


def _copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def _metadata_path(output_root: Path) -> Path:
    return output_root / "batch_submission.json"


def _load_metadata(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _guard_output_root(output_root: Path) -> None:
    metadata_path = _metadata_path(output_root)
    if metadata_path.exists():
        payload = _load_metadata(metadata_path)
        raise RuntimeError(
            "Refusing to submit a new paid batch because this output folder already contains "
            f"metadata for {payload.get('batch_name', '<unknown>')}. No new Gemini API requests were sent."
        )
    if output_root.exists() and any(output_root.iterdir()):
        raise RuntimeError(
            "Refusing to submit a new paid batch because the output folder is not empty. "
            "No new Gemini API requests were sent. If this folder came from an interrupted older run, "
            "inspect it before retrying because Gemini batch creation is not idempotent."
        )


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _fetch_batch_payload(client: genai.Client, batch_name: str) -> tuple[object, dict]:
    batch_job = client.batches.get(name=batch_name)
    state = getattr(getattr(batch_job, "state", None), "name", None) or str(getattr(batch_job, "state", ""))
    payload = {
        "batch_name": batch_name,
        "state": state,
        "display_name": getattr(batch_job, "display_name", None),
        "dest": batch_job.dest.model_dump(by_alias=True, exclude_none=True) if getattr(batch_job, "dest", None) else None,
        "error": batch_job.error.model_dump(by_alias=True, exclude_none=True) if getattr(batch_job, "error", None) else None,
    }
    return batch_job, payload


def _save_status(metadata_path: Path, status_payload: dict) -> None:
    metadata = _load_metadata(metadata_path)
    metadata["last_status_check"] = _now_iso()
    metadata["latest_status"] = status_payload
    _write_json(metadata_path, metadata)


def _sidecar_payload(*, prompt: str, model: str, image_size: str, aspect_ratio: str) -> dict:
    return {
        "request": {
            "prompt": prompt,
            "model": model,
            "image_size": image_size,
            "aspect_ratio": aspect_ratio,
        }
    }


def _decode_result_file(result_path: Path, output_root: Path, metadata: dict) -> list[str]:
    decoded_paths: list[str] = []
    images_dir = output_root / "results"
    images_dir.mkdir(parents=True, exist_ok=True)

    prompt_map = {item["id"]: item for item in metadata.get("prompt_manifest", [])}
    model = metadata.get("model", "")
    image_size = metadata.get("image_size", "1K")
    aspect_ratio = metadata.get("aspect_ratio", "1:1")

    for line in result_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        key = row.get("key") or row.get("metadata", {}).get("key") or f"result-{len(decoded_paths)+1:02d}"
        response = row.get("response") or {}
        candidates = response.get("candidates") or []
        if not candidates:
            continue
        parts = ((candidates[0].get("content") or {}).get("parts")) or []
        for part in parts:
            inline_data = part.get("inlineData") or part.get("inline_data")
            if not inline_data:
                continue
            mime_type = inline_data.get("mimeType") or inline_data.get("mime_type") or "image/png"
            suffix = ".png" if "png" in mime_type else ".jpg"
            image_path = images_dir / f"{key}{suffix}"
            image_path.write_bytes(base64.b64decode(inline_data["data"]))
            decoded_paths.append(str(image_path))

            prompt_info = prompt_map.get(key) or {}
            sidecar_path = image_path.with_suffix(".json")
            _write_json(
                sidecar_path,
                _sidecar_payload(
                    prompt=prompt_info.get("prompt", ""),
                    model=model,
                    image_size=image_size,
                    aspect_ratio=aspect_ratio,
                ),
            )
            break

    return decoded_paths


def submit_batch(args: argparse.Namespace) -> int:
    api_key = load_api_key(args.api_key)
    plan = load_plan(args.plan.expanduser().resolve())
    _guard_output_root(plan.output_root)

    client = genai.Client(api_key=api_key)
    staging_root = Path(tempfile.mkdtemp(prefix="amira-inspiration-batch-"))

    try:
        uploaded_refs: dict[str, object] = {}
        request_lines: list[dict] = []
        prompt_manifest: list[dict] = []

        for prompt in plan.prompts:
            parts: list[dict] = [{"text": prompt.prompt}]
            for reference_path in prompt.reference_paths:
                ref_path = _resolve_reference_path(reference_path, plan.output_root)
                upload = uploaded_refs.get(str(ref_path))
                if upload is None:
                    upload = client.files.upload(
                        file=str(ref_path),
                        config=types.UploadFileConfig(display_name=ref_path.stem),
                    )
                    uploaded_refs[str(ref_path)] = upload
                parts.append(
                    types.Part.from_uri(
                        file_uri=upload.uri,
                        mime_type=upload.mime_type,
                    ).model_dump(by_alias=True, exclude_none=True)
                )

            request_lines.append(
                {
                    "key": prompt.id,
                    "request": {
                        "contents": [{"role": "user", "parts": parts}],
                        "generationConfig": types.GenerateContentConfig(
                            response_modalities=["IMAGE"],
                            image_config=types.ImageConfig(
                                aspect_ratio=plan.aspect_ratio,
                                image_size=plan.image_size,
                            ),
                        ).model_dump(by_alias=True, exclude_none=True),
                    },
                }
            )

            prompt_manifest.append(
                {
                    "id": prompt.id,
                    "title": prompt.title,
                    "prompt": prompt.prompt,
                    "reference_paths": prompt.reference_paths,
                }
            )

        staging_plan_path = staging_root / "batch_plan.json"
        staging_requests_path = staging_root / "batch_requests.jsonl"
        staging_prompts_path = staging_root / "prompt_manifest.json"
        _copy_file(args.plan.expanduser().resolve(), staging_plan_path)
        _write_jsonl(staging_requests_path, request_lines)
        _write_json(staging_prompts_path, {"prompts": prompt_manifest})

        uploaded_requests = client.files.upload(
            file=str(staging_requests_path),
            config=types.UploadFileConfig(
                display_name=f"{plan.display_name}-requests",
                mime_type="jsonl",
            ),
        )

        batch_job = client.batches.create(
            model=plan.model,
            src=uploaded_requests.name,
            config=types.CreateBatchJobConfig(display_name=plan.display_name),
        )

        plan.output_root.mkdir(parents=True, exist_ok=True)
        requests_path = plan.output_root / "batch_requests.jsonl"
        prompts_path = plan.output_root / "prompt_manifest.json"
        local_plan_path = plan.output_root / "batch_plan.json"
        _copy_file(staging_plan_path, local_plan_path)
        _copy_file(staging_requests_path, requests_path)
        _copy_file(staging_prompts_path, prompts_path)

        state = getattr(getattr(batch_job, "state", None), "name", None) or str(getattr(batch_job, "state", ""))
        submitted_at = _now_iso()
        metadata = {
            "submitted_at": submitted_at,
            "character_name": plan.character_name,
            "character_slug": plan.character_slug,
            "model": plan.model,
            "image_size": plan.image_size,
            "aspect_ratio": plan.aspect_ratio,
            "prompt_count": len(prompt_manifest),
            "display_name": plan.display_name,
            "batch_name": batch_job.name,
            "batch_state": state,
            "prompt_manifest": prompt_manifest,
            "local_files": {
                "batch_plan": str(local_plan_path),
                "requests_jsonl": str(requests_path),
                "prompt_manifest": str(prompts_path),
            },
        }
        metadata_path = _metadata_path(plan.output_root)
        _write_json(metadata_path, metadata)

        print(
            json.dumps(
                {
                    "batch_name": batch_job.name,
                    "metadata_path": str(metadata_path),
                    "output_root": str(plan.output_root),
                    "batch_state": state,
                    "prompt_count": len(prompt_manifest),
                    "submitted_at": submitted_at,
                }
            )
        )
        return 0
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)


def check_status(args: argparse.Namespace) -> int:
    api_key = load_api_key(args.api_key)
    metadata_path = args.metadata.expanduser().resolve()
    metadata = _load_metadata(metadata_path)
    client = genai.Client(api_key=api_key)
    batch_job, payload = _fetch_batch_payload(client, metadata["batch_name"])

    decoded_paths: list[str] = []
    if args.download_results and payload["state"] == "JOB_STATE_SUCCEEDED":
        output_root = metadata_path.parent
        dest = getattr(batch_job, "dest", None)
        file_name = getattr(dest, "file_name", None) if dest else None
        if file_name:
            result_bytes = client.files.download(file=file_name)
            result_path = output_root / "batch_results.jsonl"
            result_path.write_bytes(result_bytes)
            decoded_paths = _decode_result_file(result_path, output_root, metadata)
            payload["downloaded_results_file"] = str(result_path)
            payload["decoded_images"] = decoded_paths

    _save_status(metadata_path, payload)
    print(json.dumps(payload))
    return 0


def watch_batch(args: argparse.Namespace) -> int:
    metadata_path = args.metadata.expanduser().resolve()
    while True:
        status_args = argparse.Namespace(
            metadata=metadata_path,
            api_key=args.api_key,
            download_results=False,
        )
        api_key = load_api_key(args.api_key)
        metadata = _load_metadata(metadata_path)
        client = genai.Client(api_key=api_key)
        _, payload = _fetch_batch_payload(client, metadata["batch_name"])
        _save_status(metadata_path, payload)

        if payload["state"] in TERMINAL_STATES:
            if payload["state"] == "JOB_STATE_SUCCEEDED":
                status_args.download_results = True
                check_status(status_args)
            return 0

        time.sleep(max(30, args.poll_seconds))


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "submit":
        return submit_batch(args)
    if args.command == "status":
        return check_status(args)
    if args.command == "watch":
        return watch_batch(args)
    raise RuntimeError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
