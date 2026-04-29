#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ROOT="${OFFLINEMESH_ROOT:-/opt/offlinemesh}"
ROLE="${1:-}"
PROFILE="${OFFLINEMESH_PROFILE:-mesh-a}"
SKIP_APT=0
NO_START=0

usage() {
  cat <<EOF
Usage: sudo bash setup_pi.sh gateway|node [--profile NAME] [--skip-apt] [--no-start]

Clone this repo on any Pi, then run this script once:
  sudo bash setup_pi.sh gateway
  sudo bash setup_pi.sh node

The script refreshes /opt/offlinemesh from the clone and configures only the
BATMAN mesh layer. After all Pis have mesh, run setup_gateway.sh on the gateway.
EOF
}

if [[ "$ROLE" == "-h" || "$ROLE" == "--help" || -z "$ROLE" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "setup_pi.sh must run as root. Use: sudo bash setup_pi.sh gateway|node" >&2
  exit 1
fi
shift

if [[ "$ROLE" != "gateway" && "$ROLE" != "node" ]]; then
  echo "Role must be gateway or node." >&2
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --skip-apt)
      SKIP_APT=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

same_path() {
  [[ "$(readlink -f "$1")" == "$(readlink -f "$2")" ]]
}

sync_to_opt() {
  if [[ -d "$TARGET_ROOT" ]] && same_path "$SCRIPT_DIR" "$TARGET_ROOT"; then
    return 0
  fi

  local staging
  staging="$(mktemp -d "${TARGET_ROOT}.staging.XXXXXX")"
  mkdir -p "$TARGET_ROOT"
  tar \
    --exclude='.git' \
    --exclude='state' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -C "$SCRIPT_DIR" -cf - . | tar -C "$staging" -xf -
  rm -rf "$TARGET_ROOT"
  mv "$staging" "$TARGET_ROOT"
}

sync_to_opt

if id meshlink >/dev/null 2>&1; then
  chown -R meshlink:meshlink "$TARGET_ROOT"
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown -R "$SUDO_USER:$SUDO_USER" "$TARGET_ROOT"
fi

chmod +x "$TARGET_ROOT"/setup_*.sh "$TARGET_ROOT"/scripts/*.sh "$TARGET_ROOT"/scripts/*.py 2>/dev/null || true

args=(--profile "$PROFILE")
[[ "$SKIP_APT" -eq 1 ]] && args+=(--skip-apt)
[[ "$NO_START" -eq 1 ]] && args+=(--no-start)

if [[ "$ROLE" == "gateway" ]]; then
  exec bash "$TARGET_ROOT/scripts/setup_mesh_gateway.sh" "${args[@]}"
else
  exec bash "$TARGET_ROOT/scripts/setup_mesh_node.sh" "${args[@]}"
fi
