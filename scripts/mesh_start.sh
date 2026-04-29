#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${OFFLINEMESH_ENV_FILE:-/etc/offlinemesh/env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

ROLE="${OFFLINEMESH_ROLE:-node}"
WIFI_IFACE="${OFFLINEMESH_WIFI_IFACE:-wlan0}"
BAT_IFACE="${OFFLINEMESH_BAT_IFACE:-bat0}"
ESSID="${OFFLINEMESH_ESSID:-pi-mesh}"
CHANNEL="${OFFLINEMESH_CHANNEL:-1}"
BAT_MTU="${OFFLINEMESH_BAT_MTU:-1450}"
GATEWAY_IP="${OFFLINEMESH_GATEWAY_IP:-192.168.199.1}"
GATEWAY_CIDR="${OFFLINEMESH_GATEWAY_CIDR:-${GATEWAY_IP}/24}"
WAN_IFACE="${OFFLINEMESH_WAN_IFACE:-eth0}"
WIFI_FREQ="${OFFLINEMESH_WIFI_FREQ:-2412}"
IBSS_JOIN_ATTEMPTS="${OFFLINEMESH_IBSS_JOIN_ATTEMPTS:-12}"

join_ibss() {
  ifconfig "$WIFI_IFACE" down || true
  iw dev "$WIFI_IFACE" set type ibss
  ip addr flush dev "$WIFI_IFACE" 2>/dev/null || true
  ifconfig "$WIFI_IFACE" up
  iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
  iw dev "$WIFI_IFACE" ibss leave >/dev/null 2>&1 || true
  if iw dev "$WIFI_IFACE" ibss join "$ESSID" "$WIFI_FREQ" fixed-freq 2>/dev/null; then
    return 0
  fi
  iwconfig "$WIFI_IFACE" channel "$CHANNEL" essid "$ESSID" mode ad-hoc
}

ibss_joined() {
  iwconfig "$WIFI_IFACE" 2>/dev/null | grep -Eq 'Cell: ([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}'
}

modprobe batman-adv
rfkill unblock all || true

for attempt in $(seq 1 "$IBSS_JOIN_ATTEMPTS"); do
  join_ibss
  sleep 2
  if ibss_joined; then
    break
  fi
  echo "${WIFI_IFACE} has not joined ${ESSID} yet; retry ${attempt}/${IBSS_JOIN_ATTEMPTS}" >&2
done

if ! ibss_joined; then
  iwconfig "$WIFI_IFACE" >&2 || true
  echo "${WIFI_IFACE} failed to join ${ESSID} after ${IBSS_JOIN_ATTEMPTS} attempts" >&2
  exit 1
fi

batctl if add "$WIFI_IFACE" || true
for _ in $(seq 1 10); do
  ip link show "$BAT_IFACE" >/dev/null 2>&1 && break
  sleep 1
done
ip link show "$BAT_IFACE" >/dev/null
ifconfig "$BAT_IFACE" mtu "$BAT_MTU"

if [[ "$ROLE" == "gateway" ]]; then
  batctl gw_mode server
else
  batctl gw_mode client
fi

ifconfig "$WIFI_IFACE" up
ifconfig "$BAT_IFACE" up
ip link set "$WIFI_IFACE" up

if [[ "$ROLE" == "gateway" ]]; then
  ip addr replace "$GATEWAY_CIDR" dev "$BAT_IFACE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
  iptables -C FORWARD -i "$BAT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$BAT_IFACE" -o "$WAN_IFACE" -j ACCEPT
  iptables -C FORWARD -i "$WAN_IFACE" -o "$BAT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$WAN_IFACE" -o "$BAT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
