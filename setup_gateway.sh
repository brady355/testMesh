#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${OFFLINEMESH_ROOT:-/opt/offlinemesh}"
NODE_USER="${OFFLINEMESH_NODE_USER:-meshlink}"
NODE_PASSWORD="${OFFLINEMESH_NODE_PASSWORD:-1111}"
FORCE=0
SKIP_VERIFY=0

usage() {
  cat <<EOF
Usage: sudo bash setup_gateway.sh [--force] [--skip-verify] [--user USER]

Run this on the gateway after every Pi has joined the mesh. It installs the
gateway stack, discovers mesh neighbors by Linux hostname, installs any new node
Pis, and verifies the result.

Options:
  --force        Reinstall nodes even if the gateway has seen them before.
  --skip-verify  Skip the final verify pass.
  --user USER    SSH user for node Pis. Default: meshlink.

Set OFFLINEMESH_NODE_PASSWORD to override the default node sudo/SSH password.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "setup_gateway.sh must run as root. Use: sudo bash setup_gateway.sh" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    --user)
      NODE_USER="$2"
      shift 2
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

ORCH="${ROOT_DIR}/scripts/gateway_orchestrator.py"
if [[ ! -f "$ORCH" ]]; then
  echo "Missing ${ORCH}. Run 'sudo bash setup_pi.sh gateway' from the cloned repo first." >&2
  exit 1
fi

base=(python3 "$ORCH" --user "$NODE_USER" --password "$NODE_PASSWORD")

echo "[setup-gateway] installing gateway stack"
"${base[@]}" install-gateway

echo "[setup-gateway] discovering mesh nodes"
"${base[@]}" discover

echo "[setup-gateway] installing node stacks"
install_args=(install-nodes)
[[ "$FORCE" -eq 1 ]] && install_args+=(--force)
"${base[@]}" "${install_args[@]}"

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
  echo "[setup-gateway] verifying gateway and nodes"
  "${base[@]}" verify
fi

echo "[setup-gateway] complete"
