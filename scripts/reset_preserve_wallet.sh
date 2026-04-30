#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "reset_preserve_wallet.sh must run as root" >&2
  exit 1
fi

BACKUP_EXT=".offlinemesh.bak"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="/etc/offlinemesh/env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

ROLE="${OFFLINEMESH_ROLE:-}"
BAT_IFACE="${OFFLINEMESH_BAT_IFACE:-bat0}"
WAN_IFACE="${OFFLINEMESH_WAN_IFACE:-eth0}"
WATCHTOWER_STATE_PRESERVE=""
SKIP_FUND_RETURN_CHECK="${OFFLINEMESH_SKIP_FUND_RETURN_CHECK:-0}"
STRIP_MESH="${OFFLINEMESH_STRIP_MESH:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-fund-return-check)
      SKIP_FUND_RETURN_CHECK=1
      shift
      ;;
    --strip-mesh)
      STRIP_MESH=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

restore_if_backed_up() {
  local path="$1"
  if [[ -e "${path}${BACKUP_EXT}" ]]; then
    cp -a "${path}${BACKUP_EXT}" "$path"
  else
    rm -f "$path"
  fi
}

cleanup_gateway_network_state() {
  local removed_rules=0

  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; do
      iptables -t nat -D POSTROUTING -o "$WAN_IFACE" -j MASQUERADE || break
      removed_rules=1
    done

    while iptables -C FORWARD -i "$BAT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -i "$BAT_IFACE" -o "$WAN_IFACE" -j ACCEPT || break
      removed_rules=1
    done

    while iptables -C FORWARD -i "$WAN_IFACE" -o "$BAT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -i "$WAN_IFACE" -o "$BAT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || break
      removed_rules=1
    done
  fi

  if [[ "$ROLE" == "gateway" || "$removed_rules" -eq 1 ]]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
  fi
}

preserve_watchtower_state() {
  if [[ -d /var/lib/offlinemesh/watchtower ]]; then
    WATCHTOWER_STATE_PRESERVE="$(mktemp -d)"
    cp -a /var/lib/offlinemesh/watchtower "${WATCHTOWER_STATE_PRESERVE}/watchtower"
  fi
}

restore_watchtower_state() {
  if [[ -n "$WATCHTOWER_STATE_PRESERVE" && -d "${WATCHTOWER_STATE_PRESERVE}/watchtower" ]]; then
    mkdir -p /var/lib/offlinemesh
    cp -a "${WATCHTOWER_STATE_PRESERVE}/watchtower" /var/lib/offlinemesh/watchtower
    chown -R meshlink:meshlink /var/lib/offlinemesh/watchtower 2>/dev/null || true
    rm -rf "$WATCHTOWER_STATE_PRESERVE"
  fi
}

if [[ "$SKIP_FUND_RETURN_CHECK" != "1" && -x "${ROOT_DIR}/scripts/return_funds_to_funder.sh" ]]; then
  if ! bash "${ROOT_DIR}/scripts/return_funds_to_funder.sh" --check-only; then
    echo "Refusing to strip OfflineMesh while this Pi still has detectable funds or channels." >&2
    echo "Run: bash ${ROOT_DIR}/scripts/return_funds_to_funder.sh --yes" >&2
    echo "Then close any reported channels and retry reset, or pass --skip-fund-return-check if you are intentionally preserving wallets." >&2
    exit 1
  fi
fi

for svc in lnmesh-watchtower-info.service lnmesh-watchtower-register.service lnmesh-watchtower.service lnmesh-source-cache.service lightningd.service dnsmasq.service bitcoind.service; do
  systemctl stop "$svc" 2>/dev/null || true
done
if [[ "$STRIP_MESH" == "1" ]]; then
  for svc in mesh-dhcp.service batman-adv.service; do
    systemctl stop "$svc" 2>/dev/null || true
  done
fi

for svc in lnmesh-watchtower-info.service lnmesh-watchtower-register.service lnmesh-watchtower.service lnmesh-source-cache.service; do
  systemctl disable "$svc" 2>/dev/null || true
done
if [[ "$STRIP_MESH" == "1" ]]; then
  for svc in mesh-dhcp.service batman-adv.service; do
    systemctl disable "$svc" 2>/dev/null || true
  done
fi

preserve_watchtower_state

rm -f /etc/systemd/system/lnmesh-source-cache.service
rm -f /etc/systemd/system/lnmesh-watchtower.service
rm -f /etc/systemd/system/lnmesh-watchtower-info.service
rm -f /etc/systemd/system/lnmesh-watchtower-register.service
rm -f /etc/systemd/system/dnsmasq.service.d/offlinemesh.conf
rm -f /etc/systemd/system/lightningd.service.d/offlinemesh.conf
rm -f /etc/systemd/system/lightningd.service.d/watchtower.conf
rmdir /etc/systemd/system/dnsmasq.service.d 2>/dev/null || true
rmdir /etc/systemd/system/lightningd.service.d 2>/dev/null || true
restore_if_backed_up /etc/systemd/system/bitcoind.service
restore_if_backed_up /etc/systemd/system/lightningd.service

if [[ "$STRIP_MESH" == "1" ]]; then
  rm -f /etc/systemd/system/batman-adv.service
  rm -f /etc/systemd/system/mesh-dhcp.service
  restore_if_backed_up /etc/network/interfaces
  rm -f /etc/network/interfaces.d/wlan0
  restore_if_backed_up /etc/dhcpcd.conf
  restore_if_backed_up /etc/modules
  restore_if_backed_up /etc/dnsmasq.conf
fi
restore_if_backed_up /home/meshlink/.bitcoin/bitcoin.conf
restore_if_backed_up /home/meshlink/.lightning/config

if [[ "$STRIP_MESH" == "1" ]]; then
  cleanup_gateway_network_state
  ip route del default dev bat0 2>/dev/null || true
  ip addr flush dev bat0 2>/dev/null || true
  batctl if del wlan0 2>/dev/null || true
  ip link set bat0 down 2>/dev/null || true
  ip link del bat0 2>/dev/null || true

  if command -v dhcpcd >/dev/null 2>&1; then
    systemctl restart dhcpcd.service 2>/dev/null || true
    dhcpcd -n eth0 2>/dev/null || true
  fi
fi

if [[ "$STRIP_MESH" == "1" ]]; then
  rm -rf /etc/offlinemesh
else
  find /etc/offlinemesh -mindepth 1 ! -name env -exec rm -rf {} + 2>/dev/null || true
fi
rm -rf /var/lib/offlinemesh
restore_watchtower_state
rm -rf /home/meshlink/src/offlinemesh-lightning
rm -rf /home/meshlink/src/offlinemesh-rust-teos
rm -rf /usr/local/libexec/c-lightning
rm -rf /usr/local/share/doc/c-lightning
rm -f /usr/local/bin/lightning-cli
rm -f /usr/local/bin/lightningd
rm -f /usr/local/bin/lightning-hsmtool
rm -f /usr/local/bin/reckless
rm -f /usr/local/bin/teosd
rm -f /usr/local/bin/teos-cli
rm -f /home/meshlink/.cargo/bin/teosd
rm -f /home/meshlink/.cargo/bin/teos-cli
rm -f /home/meshlink/.cargo/bin/watchtower-client
rm -f /home/meshlink/.lightning/plugins/watchtower-client

if [[ "${ROOT_DIR}" == /opt/offlinemesh ]]; then
  rm -rf /opt/offlinemesh
fi

systemctl daemon-reload
systemctl restart systemd-modules-load.service 2>/dev/null || true
if [[ -x /usr/local/bin/bitcoind && -e /etc/systemd/system/bitcoind.service ]]; then
  systemctl restart bitcoind.service 2>/dev/null || true
fi
if [[ -x /usr/local/bin/lightningd && -e /etc/systemd/system/lightningd.service ]]; then
  systemctl restart lightningd.service 2>/dev/null || true
fi

echo "OfflineMesh software removed; wallets, chain data, and watchtower appointment data preserved."
