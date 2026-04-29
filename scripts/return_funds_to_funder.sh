#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${ROOT_DIR}/config/funding_wallet.json"
BITCOIN_DATADIR="${BITCOIN_DATADIR:-/home/meshlink/.bitcoin}"
LIGHTNING_DIR="${LIGHTNING_DIR:-/home/meshlink/.lightning}"
LIGHTNING_CONFIG="${OFFLINEMESH_LIGHTNING_CONFIG:-${LIGHTNING_DIR}/config}"
LIGHTNING_SERVICE="${OFFLINEMESH_LIGHTNING_SERVICE:-lightningd.service}"
RETURN_RESERVE_DROPIN="/etc/systemd/system/${LIGHTNING_SERVICE}.d/offlinemesh-return-reserve.conf"
NETWORK="${OFFLINEMESH_BITCOIN_NETWORK:-testnet4}"
FEE_RATE="${OFFLINEMESH_RETURN_FEE_RATE:-1}"
CLN_WITHDRAW_FEERATE="${OFFLINEMESH_CLN_WITHDRAW_FEERATE:-1000perkw}"
CLN_WITHDRAW_MINCONF="${OFFLINEMESH_CLN_WITHDRAW_MINCONF:-1}"
STRICT_CHANNEL_RETURN="${OFFLINEMESH_STRICT_CHANNEL_RETURN:-1}"
RELEASE_EMERGENCY_RESERVE="${OFFLINEMESH_RELEASE_EMERGENCY_RESERVE:-1}"
RELEASE_MIN_EMERGENCY_MSAT="${OFFLINEMESH_RELEASE_MIN_EMERGENCY_MSAT:-1000000}"
RETURN_DUST_LIMIT_SAT="${OFFLINEMESH_RETURN_DUST_LIMIT_SAT:-1000}"
CHECK_ONLY=0
YES=0
RETURN_ADDRESS=""
RESERVE_RELEASED=0

usage() {
  cat <<EOF
Usage: $0 [--check-only] [--yes] [--address ADDRESS]

Returns spendable testnet4 funds from this Pi to the main-machine
offlinemesh_funder wallet address in config/funding_wallet.json.

--check-only       Exit nonzero if funds or channels still need attention.
--yes              Actually broadcast sweep transactions.
--address ADDRESS  Override the configured return address.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --address)
      RETURN_ADDRESS="$2"
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

configured_return_address() {
  python3 - "$CONFIG_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8"))["return_address"])
PY
}

btc() {
  bitcoin-cli "-${NETWORK}" "-datadir=${BITCOIN_DATADIR}" "$@"
}

ln() {
  lightning-cli "--network=${NETWORK}" "--lightning-dir=${LIGHTNING_DIR}" "$@"
}

json_number() {
  python3 - "$1" <<'PY'
import json
import sys

data = json.load(sys.stdin)
expr = sys.argv[1]
value = data
for part in expr.split("."):
    value = value[part]
print(value)
PY
}

cln_summary() {
  python3 -c '
import json
import sys

BLOCKING_STATES = {
    "CHANNELD_NORMAL",
    "CHANNELD_AWAITING_LOCKIN",
    "DUALOPEND_AWAITING_LOCKIN",
    "DUALOPEND_OPEN_COMMITTED",
    "DUALOPEND_OPEN_COMMIT_READY",
    "DUALOPEND_OPEN_INIT",
    "CHANNELD_SHUTTING_DOWN",
    "CLOSINGD_SIGEXCHANGE",
    "CLOSINGD_COMPLETE",
}

def msat(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.endswith("msat"):
        return int(value[:-4])
    return int(value or 0)

data = json.load(sys.stdin)
outputs = data.get("outputs", [])
outputs_msat = sum(msat(o.get("amount_msat", 0)) for o in outputs)
unreserved_outputs_msat = sum(msat(o.get("amount_msat", 0)) for o in outputs if not o.get("reserved"))
reserved_outputs_msat = sum(msat(o.get("amount_msat", 0)) for o in outputs if o.get("reserved"))
channels = data.get("channels", [])
channel_msat = sum(msat(c.get("our_amount_msat", 0)) for c in channels)
blocking = [c for c in channels if c.get("state") in BLOCKING_STATES]
blocking_msat = sum(msat(c.get("our_amount_msat", 0)) for c in blocking)
onchain = [c for c in channels if c.get("state") == "ONCHAIN"]
onchain_msat = sum(msat(c.get("our_amount_msat", 0)) for c in onchain)
print(
    f"{outputs_msat // 1000} {unreserved_outputs_msat // 1000} {reserved_outputs_msat // 1000} "
    f"{len(channels)} {channel_msat // 1000} "
    f"{len(blocking)} {blocking_msat // 1000} {len(onchain)} {onchain_msat // 1000}"
)
'
}

filter_unspendable_cln_outputs() {
  python3 -c '
import json
import subprocess
import sys

network, lightning_dir = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
kept = []
ignored = []

for output in data.get("outputs", []):
    if output.get("status") == "unconfirmed":
        cmd = [
            "lightning-cli",
            f"--network={network}",
            f"--lightning-dir={lightning_dir}",
            "getutxout",
            str(output.get("txid")),
            str(output.get("output")),
        ]
        result = subprocess.run(cmd, text=True, capture_output=True)
        utxo = {}
        if result.returncode == 0:
            try:
                utxo = json.loads(result.stdout)
            except json.JSONDecodeError:
                utxo = {}
        if not utxo.get("amount"):
            ignored.append(output)
            continue
    kept.append(output)

if ignored:
    print(
        f"Ignoring {len(ignored)} conflicted unconfirmed CLN wallet output(s) that are not UTXOs.",
        file=sys.stderr,
    )
data["outputs"] = kept
print(json.dumps(data))
' "$NETWORK" "$LIGHTNING_DIR"
}

wait_for_cln() {
  local attempts="${1:-60}"
  for _ in $(seq 1 "$attempts"); do
    if ln getinfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for lightningd to become reachable." >&2
  return 1
}

restore_emergency_reserve() {
  if [[ "$RESERVE_RELEASED" -ne 1 ]]; then
    return 0
  fi
  echo "Restoring default CLN emergency reserve service configuration." >&2
  rm -f "$RETURN_RESERVE_DROPIN"
  systemctl daemon-reload
  systemctl restart "$LIGHTNING_SERVICE"
  wait_for_cln 60
  RESERVE_RELEASED=0
}

release_emergency_reserve_if_safe() {
  local blocking_count="$1"
  local channel_count="$2"

  if [[ "$CHECK_ONLY" -eq 1 || "$YES" -ne 1 || "$RELEASE_EMERGENCY_RESERVE" != "1" ]]; then
    return 0
  fi
  if [[ "$blocking_count" -gt 0 || "$channel_count" -eq 0 ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root to temporarily release the CLN emergency reserve during fund return." >&2
    return 0
  fi

  echo "Temporarily starting CLN with --min-emergency-msat=${RELEASE_MIN_EMERGENCY_MSAT} so closed-channel reserve funds can be swept." >&2
  mkdir -p "$(dirname "$RETURN_RESERVE_DROPIN")"
  cat >"$RETURN_RESERVE_DROPIN" <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/lightningd --conf=${LIGHTNING_CONFIG} --lightning-dir=${LIGHTNING_DIR} --min-emergency-msat=${RELEASE_MIN_EMERGENCY_MSAT}
EOF
  systemctl daemon-reload
  RESERVE_RELEASED=1
  systemctl restart "$LIGHTNING_SERVICE"
  wait_for_cln 60
}

trap restore_emergency_reserve EXIT

core_wallet_balance_btc() {
  python3 -c '
import json
import sys
from decimal import Decimal

data = json.load(sys.stdin).get("mine", {})
trusted = Decimal(str(data.get("trusted", "0")))
pending = Decimal(str(data.get("untrusted_pending", "0")))
immature = Decimal(str(data.get("immature", "0")))
print(trusted + pending + immature)
'
}

if [[ -z "$RETURN_ADDRESS" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "Missing funding wallet config: $CONFIG_PATH" >&2
    exit 1
  fi
  RETURN_ADDRESS="$(configured_return_address)"
fi

if [[ "$CHECK_ONLY" -eq 0 && "$YES" -ne 1 ]]; then
  echo "Dry run only. Re-run with --yes to broadcast sweeps." >&2
fi

unswept=0
blocked_by_channels=0

if command -v lightning-cli >/dev/null 2>&1; then
  if cln_funds="$(ln listfunds 2>/dev/null)"; then
    cln_funds="$(printf '%s\n' "$cln_funds" | filter_unspendable_cln_outputs)"
    read -r cln_output_sats cln_unreserved_sats cln_reserved_sats cln_channel_count cln_channel_sats cln_blocking_count cln_blocking_sats cln_onchain_count cln_onchain_sats < <(printf '%s\n' "$cln_funds" | cln_summary)
    if [[ "$cln_blocking_count" -gt 0 ]]; then
      echo "CLN has ${cln_blocking_count} active/closing channel(s) with about ${cln_blocking_sats} local sats recorded." >&2
      if [[ "$STRICT_CHANNEL_RETURN" == "1" ]]; then
        unswept=1
        blocked_by_channels=1
        echo "OFFLINEMESH_STRICT_CHANNEL_RETURN=1 is set, so these channels must finish closing before stripping this Pi." >&2
      fi
    fi
    if [[ "$cln_onchain_count" -gt 0 ]]; then
      echo "CLN has ${cln_onchain_count} closed ONCHAIN channel record(s) with about ${cln_onchain_sats} local sats recorded; spendable outputs will be swept separately." >&2
    elif [[ "$cln_channel_count" -gt 0 && "$cln_blocking_count" -eq 0 ]]; then
      echo "CLN has ${cln_channel_count} non-blocking closed channel record(s)." >&2
    fi
    if [[ "$cln_reserved_sats" -gt 0 ]]; then
      unswept=1
      echo "CLN has about ${cln_reserved_sats} sats reserved by pending sweep transaction(s); wait for confirmation before stripping this Pi." >&2
    fi
    if [[ "$cln_unreserved_sats" -gt "$RETURN_DUST_LIMIT_SAT" ]]; then
      unswept=1
      if [[ "$CHECK_ONLY" -eq 1 || "$YES" -ne 1 ]]; then
        echo "CLN has about ${cln_unreserved_sats} unreserved on-chain sats to return." >&2
      else
        release_emergency_reserve_if_safe "$cln_blocking_count" "$cln_channel_count"
        echo "Withdrawing CLN on-chain funds to ${RETURN_ADDRESS}"
        ln withdraw "$RETURN_ADDRESS" all "$CLN_WITHDRAW_FEERATE" "$CLN_WITHDRAW_MINCONF"
      fi
    elif [[ "$cln_unreserved_sats" -gt 0 ]]; then
      echo "CLN has ${cln_unreserved_sats} unreserved sat(s), at or below the ${RETURN_DUST_LIMIT_SAT} sat dust/reserve floor; not blocking reset." >&2
    fi
  else
    echo "CLN is not reachable; skipping CLN sweep check." >&2
  fi
fi

if command -v bitcoin-cli >/dev/null 2>&1; then
  if wallets_json="$(btc listwallets 2>/dev/null)"; then
    mapfile -t wallets < <(printf '%s\n' "$wallets_json" | python3 -c 'import json,sys; [print(w) for w in json.load(sys.stdin)]')
    for wallet in "${wallets[@]}"; do
      balances_json="$(btc "-rpcwallet=${wallet}" getbalances)"
      balance_btc="$(printf '%s\n' "$balances_json" | core_wallet_balance_btc)"
      has_balance="$(python3 - "$balance_btc" <<'PY'
from decimal import Decimal
import sys
print("1" if Decimal(sys.argv[1]) > 0 else "0")
PY
)"
      if [[ "$has_balance" == "1" ]]; then
        unswept=1
        if [[ "$CHECK_ONLY" -eq 1 || "$YES" -ne 1 ]]; then
          echo "Bitcoin Core wallet '${wallet}' has ${balance_btc} BTC to return." >&2
        else
          echo "Sending all spendable Bitcoin Core wallet '${wallet}' funds to ${RETURN_ADDRESS}"
          btc "-rpcwallet=${wallet}" -named sendall "recipients=[\"${RETURN_ADDRESS}\"]" "fee_rate=${FEE_RATE}" send_max=true
        fi
      fi
    done
  else
    echo "Bitcoin Core RPC is not reachable; skipping Core wallet sweep check." >&2
  fi
fi

if [[ "$unswept" -eq 0 ]]; then
  echo "No sweepable funds or channels detected."
  exit 0
fi

if [[ "$blocked_by_channels" -eq 1 ]]; then
  echo "Return sweep incomplete because active or still-closing channels remain." >&2
  exit 1
fi

if [[ "$CHECK_ONLY" -eq 1 || "$YES" -ne 1 ]]; then
  exit 1
fi

echo "Return sweep attempted. Re-run with --check-only after transactions confirm."
