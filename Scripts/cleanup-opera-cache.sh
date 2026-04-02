#!/usr/bin/env bash
set -euo pipefail

# Cleans local Amira Writer project caches for folder-based projects.
# This script keeps cache usage small and removes stale artifacts from
# prior project path/layout changes.

PROJECT_ROOT_PREFERRED="$HOME/Documents/Amira - A Modern Opera/Amira"
PROJECT_ROOT_DEFAULT="$HOME/Documents/Amira - A Modern Opera"
SUPPORT_ROOT_PREFERRED="$HOME/Library/Application Support/Opera"
SUPPORT_ROOT_LEGACY="$HOME/Library/Application Support/Novotro"
if [[ -d "$SUPPORT_ROOT_PREFERRED" ]]; then
  SUPPORT_ROOT="$SUPPORT_ROOT_PREFERRED"
elif [[ -d "$SUPPORT_ROOT_LEGACY" ]]; then
  SUPPORT_ROOT="$SUPPORT_ROOT_LEGACY"
else
  SUPPORT_ROOT="$SUPPORT_ROOT_PREFERRED"
fi
PROJECT_CACHE_ROOT="$SUPPORT_ROOT/Project Databases"
MIRROR_ROOT="$SUPPORT_ROOT/Project Mirrors"
KEEP_DAYS="${OPERA_CACHE_KEEP_DAYS:-${NOVOTRO_CACHE_KEEP_DAYS:-30}}"
SERVICE_LABELS=("com.opera.project-service" "com.novotro.project-service")
SERVICE_BINARIES=(
  "/Volumes/Storage VIII/Programming/!Applications/project-service"
  "/Volumes/Storage VIII/Programming/!Applications/novotro-project-service"
)
SERVICE_LAUNCH_AGENTS=(
  "$HOME/Library/LaunchAgents/com.opera.project-service.plist"
  "$HOME/Library/LaunchAgents/com.novotro.project-service.plist"
)

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
                     Stop and remove the project-service launch agent
                     used by old client/server workflows.
  --force            Skip confirmation prompts.
  --help              Show this help text.

Environment:
  OPERA_CACHE_KEEP_DAYS    Optional integer for stale-cache cleanup (default 30).
  NOVOTRO_CACHE_KEEP_DAYS  Legacy alias for OPERA_CACHE_KEEP_DAYS.
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

  for support_root in "$SUPPORT_ROOT_PREFERRED" "$SUPPORT_ROOT_LEGACY"; do
    local project_db_dir="$support_root/Project Databases/$cache_key"
    local project_mirror_dir="$support_root/Project Mirrors/$cache_key"

    rm -rf "$project_db_dir" "$project_mirror_dir"
    echo "Removed:"
    echo "  $project_db_dir"
    echo "  $project_mirror_dir"
  done
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

cleanup_support_root() {
  local support_root="$1"
  cleanup_stale_cachedir "$support_root/Project Databases"
  cleanup_stale_cachedir "$support_root/Project Mirrors"
}

disable_server_launchagent() {
  local uid
  uid="$(id -u)"
  local service_label
  local service_binary
  local service_launch_agent

  for service_label in "${SERVICE_LABELS[@]}"; do
    launchctl bootout "gui/${uid}/${service_label}" >/dev/null 2>&1 || true
  done

  for service_launch_agent in "${SERVICE_LAUNCH_AGENTS[@]}"; do
    launchctl bootout "gui/${uid}" "$service_launch_agent" >/dev/null 2>&1 || true
    if [[ -f "$service_launch_agent" ]]; then
      rm -f "$service_launch_agent"
      echo "Removed launch agent file: $service_launch_agent"
    else
      echo "No launch agent file found at $service_launch_agent"
    fi
  done

  for service_binary in "${SERVICE_BINARIES[@]}"; do
    pgrep -f "$service_binary" >/dev/null 2>&1 && pkill -f "$service_binary" || true
  done
}

delete_all_cache_roots() {
  local has_any_root=false
  for support_root in "$SUPPORT_ROOT_PREFERRED" "$SUPPORT_ROOT_LEGACY"; do
    if [[ -d "$support_root/Project Databases" || -d "$support_root/Project Mirrors" ]]; then
      has_any_root=true
      break
    fi
  done

  if [[ "$has_any_root" != true ]]; then
    echo "No cache roots found. Nothing to remove."
    return 0
  fi

  if ! confirm "Remove all project caches under Project Databases and Project Mirrors?"; then
    echo "Aborted."
    return 0
  fi

  for support_root in "$SUPPORT_ROOT_PREFERRED" "$SUPPORT_ROOT_LEGACY"; do
    rm -rf "$support_root/Project Databases" "$support_root/Project Mirrors"
    echo "Removed complete cache roots under: $support_root"
    mkdir -p "$support_root/Project Databases" "$support_root/Project Mirrors"
  done
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

  mkdir -p \
    "$SUPPORT_ROOT_PREFERRED/Project Databases" \
    "$SUPPORT_ROOT_PREFERRED/Project Mirrors" \
    "$SUPPORT_ROOT_LEGACY/Project Databases" \
    "$SUPPORT_ROOT_LEGACY/Project Mirrors"

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
  cleanup_support_root "$SUPPORT_ROOT_PREFERRED"
  cleanup_support_root "$SUPPORT_ROOT_LEGACY"
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
