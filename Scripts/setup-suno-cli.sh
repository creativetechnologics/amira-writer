#!/usr/bin/env bash
#
# setup-suno-cli.sh — Rebuild the Suno CLI venv + shared Chromium cache on
# Storage VIII so the same venv works on both of Gary's Macs.
#
# Why this exists: the old venv had `python -> /opt/miniconda3/bin/python`,
# which is only present on Garys-Server. On the laptop the symlink chain
# breaks and the CLI errors out with "No such file or directory". This
# script replaces the per-machine Python reference with a portable,
# self-contained Python installed on the shared Storage VIII volume — plus
# a shared Playwright Chromium cache, also on Storage VIII — so nothing
# is machine-specific anymore.
#
# Safe to re-run. Idempotency:
#   - Python install is skipped if the target dir already exists.
#   - Venv is rebuilt from scratch each run (old one renamed to .venv.old).
#   - Chromium install is skipped if the browsers dir already contains
#     a chromium-* bundle.
#
# Usage:
#   bash Scripts/setup-suno-cli.sh
#   bash Scripts/setup-suno-cli.sh --force   # force chromium reinstall too
#
# Prerequisites: the Storage VIII volume must be mounted.
set -euo pipefail

SUNOSKILL="/Volumes/Storage VIII/Programming/SunoSkill"
SUNO_CLI_DIR="$SUNOSKILL/suno_cli"
PYTHON_INSTALL_DIR="$SUNOSKILL/python-installs"
PLAYWRIGHT_DIR="$SUNOSKILL/.ms-playwright"
PYTHON_VERSION="3.13"

FORCE_CHROMIUM=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE_CHROMIUM=1
fi

log() { printf '[setup-suno-cli] %s\n' "$*"; }
die() { printf '[setup-suno-cli] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
[[ -d "$SUNOSKILL" ]] || die "Storage VIII not mounted or SunoSkill missing at $SUNOSKILL"
[[ -d "$SUNO_CLI_DIR" ]] || die "suno_cli source missing at $SUNO_CLI_DIR"
[[ -f "$SUNO_CLI_DIR/pyproject.toml" ]] || die "suno_cli pyproject.toml missing"

# ---------------------------------------------------------------------------
# 1. Locate or bootstrap `uv`
# ---------------------------------------------------------------------------
UV_BIN=""
for candidate in \
    /opt/miniconda3/bin/uv \
    /opt/homebrew/bin/uv \
    /usr/local/bin/uv \
    "$HOME/.local/bin/uv" \
    "$(command -v uv 2>/dev/null || true)"
do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        UV_BIN="$candidate"
        break
    fi
done

if [[ -z "$UV_BIN" ]]; then
    log "uv not found; bootstrapping to ~/.local/bin/uv ..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    UV_BIN="$HOME/.local/bin/uv"
    [[ -x "$UV_BIN" ]] || die "uv bootstrap failed — please install manually"
fi
log "using uv: $UV_BIN ($("$UV_BIN" --version))"

# ---------------------------------------------------------------------------
# 2. Install portable Python into shared Storage VIII location (once)
# ---------------------------------------------------------------------------
mkdir -p "$PYTHON_INSTALL_DIR"
EXISTING_PY="$(find "$PYTHON_INSTALL_DIR" -maxdepth 3 -path '*/bin/python3' 2>/dev/null | head -1 || true)"
if [[ -z "$EXISTING_PY" ]]; then
    log "installing Python $PYTHON_VERSION to $PYTHON_INSTALL_DIR ..."
    "$UV_BIN" python install --install-dir "$PYTHON_INSTALL_DIR" "$PYTHON_VERSION"
    EXISTING_PY="$(find "$PYTHON_INSTALL_DIR" -maxdepth 2 -name python3 -type l | head -1)"
    [[ -n "$EXISTING_PY" ]] || die "Python install completed but binary not found"
else
    log "reusing existing shared Python: $EXISTING_PY"
fi
SHARED_PYTHON="$EXISTING_PY"

# Quick sanity: the Python binary must actually run on THIS machine.
"$SHARED_PYTHON" --version >/dev/null || die "Shared Python at $SHARED_PYTHON won't execute on this machine"

# ---------------------------------------------------------------------------
# 3. Rebuild the venv against the shared Python
# ---------------------------------------------------------------------------
cd "$SUNO_CLI_DIR"
if [[ -d .venv ]]; then
    BACKUP=".venv.old-$(date +%Y%m%d-%H%M%S)"
    log "moving existing .venv → $BACKUP"
    mv .venv "$BACKUP"
fi

log "creating relocatable venv against shared Python ..."
"$UV_BIN" venv --relocatable --python "$SHARED_PYTHON" .venv

log "installing suno_cli (editable) + dependencies into .venv ..."
VIRTUAL_ENV="$PWD/.venv" "$UV_BIN" pip install -e .

# ---------------------------------------------------------------------------
# 4. Install Chromium into shared Playwright browsers cache
# ---------------------------------------------------------------------------
NEEDS_CHROMIUM=1
if [[ $FORCE_CHROMIUM -eq 0 ]] && ls "$PLAYWRIGHT_DIR"/chromium-* >/dev/null 2>&1; then
    log "chromium already present in $PLAYWRIGHT_DIR — skipping install (use --force to redo)"
    NEEDS_CHROMIUM=0
fi
if [[ $NEEDS_CHROMIUM -eq 1 ]]; then
    mkdir -p "$PLAYWRIGHT_DIR"
    log "installing Chromium into $PLAYWRIGHT_DIR ..."
    PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_DIR" \
        .venv/bin/python -m playwright install chromium
fi

# ---------------------------------------------------------------------------
# 5. End-to-end smoke test
# ---------------------------------------------------------------------------
log "smoke test: suno --json browser status ..."
if PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_DIR" .venv/bin/suno --json browser status | grep -q '"ok": true'; then
    log "OK — suno CLI responds with {ok: true}"
else
    die "smoke test failed — suno CLI did not return ok=true"
fi

log "done."
log "venv:      $SUNO_CLI_DIR/.venv"
log "python:    $SHARED_PYTHON"
log "chromium:  $PLAYWRIGHT_DIR"
log ""
log "Amira Writer's SunoCLIRunner sets PLAYWRIGHT_BROWSERS_PATH automatically,"
log "so no further configuration is needed inside the app."
