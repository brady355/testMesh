#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${OFFLINEMESH_ENV_FILE:-/etc/offlinemesh/env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROLE="${OFFLINEMESH_ROLE:-node}"
BAT_IFACE="${OFFLINEMESH_BAT_IFACE:-bat0}"
LIGHTNING_PORT="${OFFLINEMESH_LIGHTNING_PORT:-19735}"
LIGHTNING_CONFIG="${OFFLINEMESH_LIGHTNING_CONFIG:-/home/meshlink/.lightning/config}"
LIGHTNING_USER="${OFFLINEMESH_LIGHTNING_USER:-meshlink}"
LIGHTNING_GROUP="${OFFLINEMESH_LIGHTNING_GROUP:-meshlink}"
HOST_SHORT="$(hostname -s)"
NODE_ID="${OFFLINEMESH_NODE_ID:-$HOST_SHORT}"
NETWORK="${OFFLINEMESH_LIGHTNING_NETWORK:-testnet4}"
BITCOIN_RPC_CONNECT="${OFFLINEMESH_BITCOIN_RPC_CONNECT:-}"
BITCOIN_RPC_PORT="${OFFLINEMESH_BITCOIN_RPC_PORT:-}"
BITCOIN_RPC_USER="${OFFLINEMESH_BITCOIN_RPC_USER:-}"
BITCOIN_RPC_PASSWORD="${OFFLINEMESH_BITCOIN_RPC_PASSWORD:-}"
BITCOIN_RPC_PASSWORD_FILE="${OFFLINEMESH_BITCOIN_RPC_PASSWORD_FILE:-}"
BITCOIN_DATADIR="${OFFLINEMESH_BITCOIN_DATADIR:-/home/meshlink/.bitcoin}"

cluster_value() {
  local key="$1"
  local default="$2"
  /usr/bin/python3 - "${ROOT_DIR}" "$key" "$default" <<'PY'
import json
import os
import sys
from pathlib import Path

root, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
candidates = []
if os.environ.get("LNMESH_CLUSTER_CONFIG"):
    candidates.append(Path(os.environ["LNMESH_CLUSTER_CONFIG"]))
candidates.extend([Path("/etc/offlinemesh/cluster.json"), Path(root) / "config" / "cluster.json"])
for path in candidates:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        mesh = data.get("mesh", {})
        profile = os.environ.get("OFFLINEMESH_PROFILE") or mesh.get("profile")
        profiles = mesh.get("profiles", {})
        if profile in profiles:
            merged = dict(mesh)
            merged.update(profiles[profile])
            data["mesh"] = merged
        value = data
        for part in key.split("."):
            value = value[part]
        print(value)
        break
    except Exception:
        continue
else:
    print(default)
PY
}

NETWORK="${NETWORK:-$(cluster_value lightning.network testnet4)}"
BITCOIN_RPC_CONNECT="${BITCOIN_RPC_CONNECT:-$(cluster_value bitcoin.rpc_host 192.168.199.1)}"
BITCOIN_RPC_PORT="${BITCOIN_RPC_PORT:-$(cluster_value bitcoin.rpc_port 48332)}"
BITCOIN_RPC_USER="${BITCOIN_RPC_USER:-$(cluster_value bitcoin.rpc_user offlinemesh)}"
BITCOIN_RPC_PASSWORD_FILE="${BITCOIN_RPC_PASSWORD_FILE:-$(cluster_value bitcoin.rpc_password_file /etc/offlinemesh/bitcoin-rpc-password)}"

BAT_IP=""
if [[ "$ROLE" == "node" ]]; then
  for _ in $(seq 1 60); do
    BAT_IP="$(ip -4 -o addr show dev "$BAT_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    if [[ -n "$BAT_IP" ]]; then
      break
    fi
    sleep 1
  done
  if [[ -z "$BAT_IP" ]]; then
    echo "No IPv4 address on $BAT_IFACE yet" >&2
    exit 1
  fi
else
  BAT_IP="$(ip -4 -o addr show dev "$BAT_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
fi
if [[ -z "$BAT_IP" && "$ROLE" == "gateway" ]]; then
  BAT_IP="${OFFLINEMESH_GATEWAY_IP:-192.168.199.1}"
fi

if [[ ! -f "${LIGHTNING_CONFIG}.offlinemesh.bak" && -f "$LIGHTNING_CONFIG" ]]; then
  cp -a "$LIGHTNING_CONFIG" "${LIGHTNING_CONFIG}.offlinemesh.bak"
fi

mkdir -p "$(dirname "$LIGHTNING_CONFIG")"
{
  cat <<EOF
network=${NETWORK}
alias=${NODE_ID}
log-level=info
experimental-dual-fund
bind-addr=${BAT_IP}:${LIGHTNING_PORT}
announce-addr=${BAT_IP}:${LIGHTNING_PORT}
EOF

  if [[ "$ROLE" == "gateway" ]]; then
    echo "bitcoin-rpcconnect=127.0.0.1"
    echo "bitcoin-rpcport=${BITCOIN_RPC_PORT}"
    echo "bitcoin-datadir=${BITCOIN_DATADIR}"
  else
    echo "bitcoin-rpcconnect=${BITCOIN_RPC_CONNECT}"
    echo "bitcoin-rpcport=${BITCOIN_RPC_PORT}"
  fi

  if [[ -n "$BITCOIN_RPC_USER" ]]; then
    echo "bitcoin-rpcuser=${BITCOIN_RPC_USER}"
  fi
  if [[ -z "$BITCOIN_RPC_PASSWORD" && -n "$BITCOIN_RPC_PASSWORD_FILE" && -f "$BITCOIN_RPC_PASSWORD_FILE" ]]; then
    BITCOIN_RPC_PASSWORD="$(tr -d '\r\n' <"$BITCOIN_RPC_PASSWORD_FILE")"
  fi
  if [[ -n "$BITCOIN_RPC_PASSWORD" ]]; then
    echo "bitcoin-rpcpassword=${BITCOIN_RPC_PASSWORD}"
  fi
} >"$LIGHTNING_CONFIG"

chown "$LIGHTNING_USER:$LIGHTNING_GROUP" "$LIGHTNING_CONFIG"
chmod 600 "$LIGHTNING_CONFIG"
