#!/usr/bin/env bash
# IBSS (ad-hoc) on wlan0. Run as root.
# Usage: sudo bash mesh-up.sh <ip/cidr>   e.g. sudo bash mesh-up.sh 10.0.0.1/24

set -euo pipefail

IFACE="${LNMESH_WIFI_IFACE:-wlan0}"
SSID="${LNMESH_IBSS_SSID:-lnmesh}"
FREQ="${LNMESH_IBSS_FREQ:-2412}"
IP="${1:-}"

usage() {
  echo "Usage: sudo bash mesh-up.sh <ip/cidr>" >&2
  echo "Example: sudo bash mesh-up.sh 10.0.0.1/24" >&2
}

if [[ $EUID -ne 0 ]]; then
  echo "mesh-up.sh must run as root" >&2
  usage
  exit 1
fi

if [[ -z "$IP" || "$IP" != */* ]]; then
  usage
  exit 1
fi

command -v iw >/dev/null 2>&1 || {
  echo "Missing required command: iw" >&2
  exit 1
}

ip link show "$IFACE" >/dev/null 2>&1 || {
  echo "Interface not found: $IFACE" >&2
  exit 1
}

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-mesh.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE}
EOF

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
  systemctl reload NetworkManager || true
  sleep 1
fi

rfkill unblock wifi 2>/dev/null || true
ip link set "$IFACE" down
ip addr flush dev "$IFACE" || true
iw dev "$IFACE" set type ibss
ip link set "$IFACE" up
iw dev "$IFACE" ibss join "$SSID" "$FREQ"
ip addr replace "$IP" dev "$IFACE"
