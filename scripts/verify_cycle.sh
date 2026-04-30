#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="/etc/offlinemesh/env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

ROLE="${OFFLINEMESH_ROLE:-node}"
BAT_IFACE="${OFFLINEMESH_BAT_IFACE:-bat0}"
GATEWAY_IP="${OFFLINEMESH_GATEWAY_IP:-192.168.199.1}"
READY_TIMEOUT=300
SYNC_TIMEOUT="${OFFLINEMESH_SYNC_TIMEOUT:-0}"
WAIT_FUNDS=0
FUNDS_TIMEOUT=3600
PEER=""
CHANNEL_AMOUNT=""
CHANNEL_ID=""
WAIT_STATE="broadcast"
INVOICE=""
RUN_CLOSE=0
CLOSE_MODE="auto"
SKIP_WATCHTOWER=0
WATCHTOWER_ENABLED="${OFFLINEMESH_ENABLE_WATCHTOWER:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ready-timeout)
      READY_TIMEOUT="$2"
      shift 2
      ;;
    --sync-timeout)
      SYNC_TIMEOUT="$2"
      shift 2
      ;;
    --wait-funds)
      WAIT_FUNDS=1
      shift
      ;;
    --funds-timeout)
      FUNDS_TIMEOUT="$2"
      shift 2
      ;;
    --peer)
      PEER="$2"
      shift 2
      ;;
    --channel-amount-sat)
      CHANNEL_AMOUNT="$2"
      shift 2
      ;;
    --channel-id)
      CHANNEL_ID="$2"
      shift 2
      ;;
    --wait-state)
      WAIT_STATE="$2"
      shift 2
      ;;
    --invoice)
      INVOICE="$2"
      shift 2
      ;;
    --close)
      RUN_CLOSE=1
      shift
      ;;
    --close-mode)
      CLOSE_MODE="$2"
      shift 2
      ;;
    --skip-watchtower)
      SKIP_WATCHTOWER=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

wait_until() {
  local description="$1"
  shift
  local deadline=$((SECONDS + READY_TIMEOUT))
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for ${description}" >&2
      "$@" >&2 || true
      return 1
    fi
    sleep 2
  done
}

wait_for_service() {
  local svc="$1"
  wait_until "${svc} to become active" systemctl is-active --quiet "$svc" || {
    systemctl status --no-pager -l "$svc" >&2 || true
    return 1
  }
}

has_bat0_ipv4() {
  ip -4 addr show dev "$BAT_IFACE" | grep -q "inet "
}

gateway_routes_over_bat0() {
  ip route get "$GATEWAY_IP" | grep -q "dev ${BAT_IFACE}"
}

services=(batman-adv.service lightningd.service)
if [[ "$ROLE" == "gateway" ]]; then
  services+=(dnsmasq.service bitcoind.service lnmesh-source-cache.service)
  if [[ "$WATCHTOWER_ENABLED" == "1" && "$SKIP_WATCHTOWER" -ne 1 ]]; then
    services+=(lnmesh-watchtower.service)
  fi
else
  services+=(mesh-dhcp.service)
fi

for svc in "${services[@]}"; do
  wait_for_service "$svc"
done

wait_until "${BAT_IFACE} link" ip link show "$BAT_IFACE"
wait_until "${BAT_IFACE} IPv4 address" has_bat0_ipv4

if [[ "$ROLE" == "node" ]]; then
  wait_until "node route to gateway over ${BAT_IFACE}" gateway_routes_over_bat0
fi

if [[ "$WATCHTOWER_ENABLED" == "1" && "$SKIP_WATCHTOWER" -ne 1 ]]; then
  wait_until "watchtower readiness" bash "${ROOT_DIR}/scripts/watchtower_setup.sh" status
fi

python3 "${ROOT_DIR}/scripts/lnmesh_common.py" local-info
python3 "${ROOT_DIR}/scripts/lnmesh_common.py" wait-sync --timeout "$SYNC_TIMEOUT" --progress

if [[ "$WAIT_FUNDS" -eq 1 ]]; then
  python3 "${ROOT_DIR}/scripts/lnmesh_common.py" wait-funds --timeout "$FUNDS_TIMEOUT"
fi

if [[ -n "$PEER" && -n "$CHANNEL_AMOUNT" ]]; then
  OPEN_JSON="$(
    python3 "${ROOT_DIR}/scripts/open_channel_offline.py" \
    --peer "$PEER" \
    --amount-sat "$CHANNEL_AMOUNT" \
    --wait-state "$WAIT_STATE"
  )"
  printf '%s\n' "$OPEN_JSON"
  if [[ -z "$CHANNEL_ID" ]]; then
    CHANNEL_ID="$(printf '%s\n' "$OPEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("channel_id", ""))')"
  fi
fi

if [[ -n "$INVOICE" ]]; then
  python3 "${ROOT_DIR}/scripts/pay_mesh.py" pay --peer "${PEER}" --bolt11 "$INVOICE"
fi

if [[ "$RUN_CLOSE" -eq 1 && -n "$PEER" ]]; then
  close_args=(--peer "$PEER" --mode "$CLOSE_MODE")
  if [[ -n "$CHANNEL_ID" ]]; then
    close_args+=(--channel-id "$CHANNEL_ID")
  fi
  python3 "${ROOT_DIR}/scripts/close_channel_offline.py" "${close_args[@]}"
fi
