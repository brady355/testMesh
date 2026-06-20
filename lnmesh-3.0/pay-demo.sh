#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${HOME}/.lnmesh/lnmesh-3.0.env"

LNMESH_USER="${USER:-brady}"
LNMESH_KEY_PATH="${HOME}/.ssh/lnmesh_ed25519"
LNMESH_PI1_IP="10.0.0.1"
LNMESH_PI2_IP="10.0.0.2"
LNMESH_PI3_IP="10.0.0.3"
ENV_PAYMENT_MSAT="${LNMESH_PAYMENT_MSAT:-}"
LNMESH_PAYMENT_MSAT="1000000"
VERBOSE=0

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

if [[ -n "$ENV_PAYMENT_MSAT" ]]; then
  LNMESH_PAYMENT_MSAT="$ENV_PAYMENT_MSAT"
fi

usage() {
  cat <<'EOF'
Usage:
  ./pay-demo.sh [--amount-msat 1000000] [--verbose]

Creates an invoice on pi3 and pays it from pi1 over the pi1 -> pi2 -> pi3 route.
Run this on pi1 after gateway-setup.sh completes.
EOF
}

die() {
  printf '[lnmesh-pay] ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --amount-msat)
        [[ $# -ge 2 ]] || die "--amount-msat requires a value"
        LNMESH_PAYMENT_MSAT="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "missing jq; rerun gateway setup"
  command -v lightning-cli >/dev/null 2>&1 || die "missing lightning-cli; rerun gateway setup"
  command -v ssh >/dev/null 2>&1 || die "missing ssh"
  [[ -f "$LNMESH_KEY_PATH" ]] || die "missing SSH key: ${LNMESH_KEY_PATH}"
}

ssh_pi3() {
  ssh \
    -i "$LNMESH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    "${LNMESH_USER}@${LNMESH_PI3_IP}" \
    "$1"
}

main() {
  local label invoice_json bolt11 pay_json status payment_hash preimage

  parse_args "$@"
  [[ "$LNMESH_PAYMENT_MSAT" =~ ^[0-9]+$ ]] || die "--amount-msat must be an integer"
  require_tools

  label="lnmesh-demo-$(date +%s)"
  invoice_json="$(ssh_pi3 "lightning-cli --regtest invoice amount_msat=${LNMESH_PAYMENT_MSAT} label=${label} description=lnmesh-demo")"
  bolt11="$(printf '%s\n' "$invoice_json" | jq -r '.bolt11 // empty')"
  payment_hash="$(printf '%s\n' "$invoice_json" | jq -r '.payment_hash // empty')"

  [[ -n "$bolt11" ]] || die "pi3 did not return a bolt11 invoice"

  pay_json="$(lightning-cli --regtest pay "$bolt11")"
  status="$(printf '%s\n' "$pay_json" | jq -r '.status // empty')"
  preimage="$(printf '%s\n' "$pay_json" | jq -r '.payment_preimage // empty')"

  printf 'LNMesh demo payment complete\n'
  printf 'payer: pi1 (%s)\n' "$LNMESH_PI1_IP"
  printf 'receiver: pi3 (%s)\n' "$LNMESH_PI3_IP"
  printf 'route: pi1 -> pi2 -> pi3\n'
  printf 'amount_msat: %s\n' "$LNMESH_PAYMENT_MSAT"
  printf 'status: %s\n' "${status:-unknown}"
  printf 'payment_hash: %s\n' "${payment_hash:-unknown}"
  printf 'preimage: %s\n' "${preimage:-unknown}"

  if [[ "$VERBOSE" == "1" ]]; then
    printf '\ninvoice_json:\n%s\n' "$invoice_json"
    printf '\npay_json:\n%s\n' "$pay_json"
  fi
}

main "$@"
