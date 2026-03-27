#!/usr/bin/env bash
set -euo pipefail

# Cleans local Amira Writer project caches for folder-based projects.
# This script keeps cache usage small and removes stale artifacts from
# prior project path/layout changes.

PROJECT_ROOT_PREFERRED="$HOME/Documents/Amira - A Modern Opera/Amira"
PROJECT_ROOT_DEFAULT="$HOME/Documents/Amira - A Modern Opera"
SUPPORT_ROOT="$HOME/Library/Application Support/Novotro"
PROJECT_CACHE_ROOT="$SUPPORT_ROOT/Project Databases"
MIRROR_ROOT="$SUPPORT_ROOT/Project Mirrors"
KEEP_DAYS="${NOVOTRO_CACHE_KEEP_DAYS:-30}"
SERVICE_LABEL="com.novotro.project-service"
SERVICE_BINARY="/Volumes/Storage VIII/Programming/!Applications/novotro-project-service"
SERVICE_LAUNCH_AGENT="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"

usage() {
  cat <<'USAGE'
Usage:
  cleanup-opera-cache.sh [--project <path>] [--all-caches] [--force]
                          [--disable-server-launchagent]

Options:
  --project <path>   Clean caches for a specific project path.
                     Defaults to:
                     "$HOME/Documents/Amira - A Modern Opera/Amira" if exists,
                     otherwise "$HOME/Documents/Amira - A Modern Opera".
  --all-caches       Remove every entry in Project Databases and Project Mirrors.
  --disable-server-launchagent
                     Stop and remove the Novotro project service launch agent
                     used by old client/server workflows.
  --force            Skip confirmation prompts.
  --help              Show this help text.

Environment:
  NOVOTRO_CACHE_KEEP_DAYS  Optional integer for stale-cache cleanup (default 30).
USAGE
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found."
    exit 1
  fi
}

resolve_cache_root() {
  local project_path="$1"

  local normalized_path
  normalized_path="$(python3 - "$project_path" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
print(path)
PY
)"
  local base_name
  base_name="$(python3 - "$normalized_path" <<'PY'
import os
import sys

path = sys.argv[1]
base_name = os.path.splitext(os.path.basename(path.rstrip("/")))[0]
print(base_name.replace("/", "-"))
PY
)"
  local digest
  digest="$(python3 - "$normalized_path" <<'PY'
import hashlib
import sys

path = sys.argv[1]
print(hashlib.sha256(path.encode("utf-8")).hexdigest()[:12])
PY
)"
  echo "${base_name}-${digest}"
}

clean_project_cache() {
  local project_path="$1"

  if [[ ! -d "$project_path" ]]; then
    echo "Warning: project path does not exist: $project_path"
    return 1
  fi

  echo "Cleaning project cache for: $project_path"
  rm -rf "$project_path/.novtro"

  local cache_key
  cache_key="$(resolve_cache_root "$project_path")"

  local project_db_dir="$PROJECT_CACHE_ROOT/$cache_key"
  local project_mirror_dir="$MIRROR_ROOT/$cache_key"

  rm -rf "$project_db_dir" "$project_mirror_dir"
  echo "Removed:"
  echo "  $project_db_dir"
  echo "  $project_mirror_dir"
}

confirm() {
  local prompt="$1"
  local response
  if [[ "${FORCE:-false}" == true ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " response
  [[ "$response" == "y" || "$response" == "Y" ]]
}

cleanup_stale_cachedir() {
  local cache_dir="$1"
  if [[ ! -d "$cache_dir" ]]; then
    return 0
  fi

  while IFS= read -r -d '' entry; do
    local mtime
    mtime="$(stat -f "%m" "$entry")"
    local now
    now="$(date +%s)"
    local age_days=$(( (now - mtime) / 86400 ))
    if (( age_days > KEEP_DAYS )); then
      local size
      size="$(du -sm "$entry" 2>/dev/null | awk '{print $1}')"
      rm -rf "$entry"
      echo "Removed stale cache: $entry (${size} MB)"
    fi
  done < <(find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -print0)
}

disable_server_launchagent() {
  local uid
  uid="$(id -u)"

  launchctl bootout "gui/${uid}/${SERVICE_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}" "$SERVICE_LAUNCH_AGENT" >/dev/null 2>&1 || true
  pgrep -f "$SERVICE_BINARY" >/dev/null 2>&1 && pkill -f "$SERVICE_BINARY" || true

  if [[ -f "$SERVICE_LAUNCH_AGENT" ]]; then
    rm -f "$SERVICE_LAUNCH_AGENT"
    echo "Removed launch agent file: $SERVICE_LAUNCH_AGENT"
  else
    echo "No launch agent file found at $SERVICE_LAUNCH_AGENT"
  fi
}

delete_all_cache_roots() {
  if [[ ! -d "$PROJECT_CACHE_ROOT" && ! -d "$MIRROR_ROOT" ]]; then
    echo "No cache roots found. Nothing to remove."
    return 0
  fi

  if ! confirm "Remove all project caches under Project Databases and Project Mirrors?"; then
    echo "Aborted."
    return 0
  fi

  rm -rf "$PROJECT_CACHE_ROOT" "$MIRROR_ROOT"
  echo "Removed complete cache roots:"
  echo "  $PROJECT_CACHE_ROOT"
  echo "  $MIRROR_ROOT"
  mkdir -p "$PROJECT_CACHE_ROOT" "$MIRROR_ROOT"
}

main() {
  require_command python3
  require_command stat
  require_command du
  require_command find

  local target_project=""
  local all=false
  local disable_service=false
  FORCE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        if [[ $# -lt 2 ]]; then
          echo "Error: --project requires a path."
          return 1
        fi
        target_project="$2"
        shift 2
        ;;
      --all-caches)
        all=true
        shift
        ;;
      --disable-server-launchagent)
        disable_service=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        return 1
        ;;
    esac
  done

  mkdir -p "$PROJECT_CACHE_ROOT" "$MIRROR_ROOT"

  if [[ "$all" == true ]]; then
    delete_all_cache_roots
  else
    if [[ -z "$target_project" ]]; then
      if [[ -d "$PROJECT_ROOT_PREFERRED" && -f "$PROJECT_ROOT_PREFERRED/Metadata/project.json" ]]; then
        target_project="$PROJECT_ROOT_PREFERRED"
      elif [[ -d "$PROJECT_ROOT_DEFAULT" && -f "$PROJECT_ROOT_DEFAULT/Metadata/project.json" ]]; then
        target_project="$PROJECT_ROOT_DEFAULT"
      else
        echo "No default OWP project folder found."
        echo "Pass --project <path> or edit $0 default path list."
        return 1
      fi
    fi

    clean_project_cache "$target_project"
    cleanup_stale_cachedir "$PROJECT_CACHE_ROOT"
    cleanup_stale_cachedir "$MIRROR_ROOT"
  fi

  if [[ "$disable_service" == true ]]; then
    disable_server_launchagent
  fi

  if [[ -d "$SUPPORT_ROOT" ]]; then
    local cache_size_db
    local cache_size_mirror
    cache_size_db="$(du -sm "$PROJECT_CACHE_ROOT" 2>/dev/null | awk '{print $1}')"
    cache_size_mirror="$(du -sm "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
    echo "Remaining cache sizes:"
    echo "  Project Databases: ${cache_size_db} MB"
    echo "  Project Mirrors:   ${cache_size_mirror} MB"
  fi
}

main "$@"
