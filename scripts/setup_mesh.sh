#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "setup_mesh.sh must run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
ROLE=""
PROFILE="${OFFLINEMESH_PROFILE:-}"
NODE_ID="${OFFLINEMESH_NODE_ID:-}"
SKIP_APT=0
START_SERVICES=1
BACKUP_EXT=".offlinemesh.bak"
ENV_DIR="/etc/offlinemesh"
ENV_FILE="${ENV_DIR}/env"
SYSTEM_CLUSTER="${ENV_DIR}/cluster.json"

if [[ -z "$NODE_ID" && -f "$ENV_FILE" ]]; then
  NODE_ID="$(awk -F= '$1 == "OFFLINEMESH_NODE_ID" {print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
fi

usage() {
  cat <<EOF
Usage: sudo bash $0 --role gateway|node [--profile NAME] [--skip-apt] [--no-start]

Configures the original OfflineMesh BATMAN layer. It is safe to rerun on a Pi
that already has the mesh installed.

Prefer the explicit entrypoints:
  sudo bash ${SCRIPT_DIR}/setup_mesh_gateway.sh
  sudo bash ${SCRIPT_DIR}/setup_mesh_node.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --skip-apt)
      SKIP_APT=1
      shift
      ;;
    --no-start)
      START_SERVICES=0
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

if [[ -z "$ROLE" ]]; then
  echo "Mesh role is explicit now. Run setup_mesh_gateway.sh, setup_mesh_node.sh, or pass --role gateway|node." >&2
  exit 2
fi

if [[ "$ROLE" != "gateway" && "$ROLE" != "node" ]]; then
  echo "--role must be gateway or node" >&2
  exit 2
fi

cluster_value() {
  local key="$1"
  local default="$2"
  OFFLINEMESH_PROFILE="${PROFILE}" /usr/bin/python3 - "${ROOT_DIR}" "$key" "$default" <<'PY'
import json
import os
import sys
from pathlib import Path

root, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
candidates = [Path(root) / "config" / "cluster.json"]
if Path("/etc/offlinemesh/cluster.json").exists():
    candidates.insert(0, Path("/etc/offlinemesh/cluster.json"))
for path in candidates:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        mesh = data.get("mesh", {})
        profiles = mesh.get("profiles", {})
        profile = os.environ.get("OFFLINEMESH_PROFILE") or mesh.get("profile")
        if profile in profiles:
            merged = dict(mesh)
            merged.update(profiles[profile])
            merged["profile"] = profile
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

subnet_attr() {
  local subnet="$1"
  local attr="$2"
  /usr/bin/python3 - "$subnet" "$attr" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
attr = sys.argv[2]
if attr == "prefixlen":
    print(network.prefixlen)
elif attr == "netmask":
    print(network.netmask)
else:
    raise SystemExit(f"unknown subnet attribute: {attr}")
PY
}

PROFILE="${PROFILE:-$(cluster_value mesh.profile mesh-a)}"
ESSID="$(cluster_value mesh.essid pi-mesh)"
CHANNEL="$(cluster_value mesh.channel 1)"
WIFI_FREQ="$(cluster_value mesh.wifi_freq 2412)"
WIFI_IFACE="$(cluster_value mesh.wifi_iface wlan0)"
BAT_IFACE="$(cluster_value mesh.bat_iface bat0)"
BAT_MTU="$(cluster_value mesh.bat_mtu 1450)"
SUBNET="$(cluster_value mesh.subnet 192.168.199.0/24)"
GATEWAY_PREFIX="$(subnet_attr "$SUBNET" prefixlen)"
DHCP_NETMASK="$(subnet_attr "$SUBNET" netmask)"
GATEWAY_IP="$(cluster_value mesh.gateway_ip 192.168.199.1)"
DHCP_START="$(cluster_value mesh.dhcp_start 192.168.199.2)"
DHCP_END="$(cluster_value mesh.dhcp_end 192.168.199.99)"
DOMAIN="$(cluster_value mesh.domain local.test)"
GATEWAY_NAME="$(cluster_value mesh.gateway_name gateway01)"
WAN_IFACE="${OFFLINEMESH_WAN_IFACE:-eth0}"

if [[ -z "$NODE_ID" && "$ROLE" == "gateway" ]]; then
  NODE_ID="$GATEWAY_NAME"
fi

log() {
  printf '[setup-mesh] %s\n' "$*"
}

backup_once() {
  local path="$1"
  if [[ -e "$path" && ! -e "${path}${BACKUP_EXT}" ]]; then
    cp -a "$path" "${path}${BACKUP_EXT}"
  fi
}

apt_get_update_with_retries() {
  local attempts="${OFFLINEMESH_APT_UPDATE_ATTEMPTS:-3}"
  local delay="${OFFLINEMESH_APT_UPDATE_RETRY_DELAY:-10}"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if apt-get update; then
      return 0
    fi
    [[ "$attempt" -lt "$attempts" ]] && sleep "$delay"
  done
  return 1
}

missing_packages() {
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || printf '%s\n' "$pkg"
  done
}

install_packages() {
  [[ "$SKIP_APT" -eq 0 ]] || return 0
  local packages=(batctl ifupdown iw rfkill wireless-tools net-tools iproute2)
  if [[ "$ROLE" == "gateway" ]]; then
    packages+=(dnsmasq iptables)
  else
    packages+=(dhcpcd5)
  fi
  local missing=()
  mapfile -t missing < <(missing_packages "${packages[@]}")
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  apt_get_update_with_retries || log "apt-get update failed; trying install anyway"
  if ! apt-get install -y "${packages[@]}"; then
    mapfile -t missing < <(missing_packages "${packages[@]}")
    [[ "${#missing[@]}" -eq 0 ]] || {
      echo "Missing mesh packages: ${missing[*]}" >&2
      exit 1
    }
  fi
}

write_env() {
  mkdir -p "$ENV_DIR"
  cp -a "${ROOT_DIR}/config/cluster.json" "$SYSTEM_CLUSTER"
  chmod 644 "$SYSTEM_CLUSTER"
  cat >"$ENV_FILE" <<EOF
OFFLINEMESH_ROLE=${ROLE}
OFFLINEMESH_ROOT=${ROOT_DIR}
OFFLINEMESH_PROFILE=${PROFILE}
OFFLINEMESH_WIFI_IFACE=${WIFI_IFACE}
OFFLINEMESH_BAT_IFACE=${BAT_IFACE}
OFFLINEMESH_ESSID=${ESSID}
OFFLINEMESH_CHANNEL=${CHANNEL}
OFFLINEMESH_WIFI_FREQ=${WIFI_FREQ}
OFFLINEMESH_BAT_MTU=${BAT_MTU}
OFFLINEMESH_SUBNET=${SUBNET}
OFFLINEMESH_GATEWAY_CIDR=${GATEWAY_IP}/${GATEWAY_PREFIX}
OFFLINEMESH_DHCP_START=${DHCP_START}
OFFLINEMESH_DHCP_END=${DHCP_END}
OFFLINEMESH_DOMAIN=${DOMAIN}
OFFLINEMESH_IBSS_JOIN_ATTEMPTS=${OFFLINEMESH_IBSS_JOIN_ATTEMPTS:-12}
OFFLINEMESH_GATEWAY_IP=${GATEWAY_IP}
OFFLINEMESH_GATEWAY_HOST=${GATEWAY_IP}
OFFLINEMESH_WAN_IFACE=${WAN_IFACE}
OFFLINEMESH_NODE_ID=${NODE_ID}
EOF
  chmod 644 "$ENV_FILE"
}

write_network_files() {
  backup_once /etc/network/interfaces
  backup_once /etc/dhcpcd.conf
  backup_once /etc/modules
  mkdir -p /etc/network/interfaces.d

  cat >/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF

  cat >/etc/network/interfaces.d/"${WIFI_IFACE}" <<EOF
auto ${WIFI_IFACE}
iface ${WIFI_IFACE} inet manual
    wireless-channel ${CHANNEL}
    wireless-essid ${ESSID}
    wireless-mode ad-hoc
EOF

  grep -qxF "batman-adv" /etc/modules || echo "batman-adv" >>/etc/modules

  if [[ -f /etc/dhcpcd.conf ]]; then
    /usr/bin/python3 - /etc/dhcpcd.conf <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
start = "# BEGIN OFFLINEMESH"
end = "# END OFFLINEMESH"
while start in text and end in text:
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    text = before.rstrip() + "\n" + after.lstrip()
path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
  fi

  cat >>/etc/dhcpcd.conf <<EOF

# BEGIN OFFLINEMESH
denyinterfaces ${WIFI_IFACE}
interface ${BAT_IFACE}
noipv4ll
metric 500
# END OFFLINEMESH
EOF

  if [[ "$ROLE" == "gateway" ]]; then
    backup_once /etc/dnsmasq.conf
    cat >/etc/dnsmasq.conf <<EOF
interface=${BAT_IFACE}
domain-needed
local=/${DOMAIN}/
domain=${DOMAIN}
expand-hosts
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_NETMASK},12h
dhcp-option=option:router,${GATEWAY_IP}
dhcp-option=option:dns-server,${GATEWAY_IP}
no-resolv
server=8.8.8.8
server=8.8.4.4
EOF
  fi
}

write_units() {
  cat >/etc/systemd/system/batman-adv.service <<EOF
[Unit]
Description=OfflineMesh BATMAN mesh bootstrap
After=network.target systemd-modules-load.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=OFFLINEMESH_ENV_FILE=${ENV_FILE}
ExecStart=/bin/bash ${ROOT_DIR}/scripts/mesh_start.sh
Restart=on-failure
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  if [[ "$ROLE" == "node" ]]; then
    cat >/etc/systemd/system/mesh-dhcp.service <<EOF
[Unit]
Description=Acquire DHCP lease on ${BAT_IFACE}
After=batman-adv.service network-online.target
Requires=batman-adv.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -lc 'dhcpcd -n ${BAT_IFACE} >/dev/null 2>&1 || true; for i in \$(seq 1 60); do ip -4 addr show dev ${BAT_IFACE} | grep -q "inet " && ip route replace default via ${GATEWAY_IP} dev ${BAT_IFACE} metric 500 && exit 0; sleep 1; done; echo "${BAT_IFACE} did not receive DHCP" >&2; exit 1'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f /etc/systemd/system/mesh-dhcp.service
    mkdir -p /etc/systemd/system/dnsmasq.service.d
    cat >/etc/systemd/system/dnsmasq.service.d/offlinemesh.conf <<'EOF'
[Unit]
After=batman-adv.service
Wants=batman-adv.service
EOF
  fi
}

start_services() {
  systemctl daemon-reload
  systemctl enable batman-adv.service
  systemctl restart batman-adv.service
  if [[ "$ROLE" == "gateway" ]]; then
    systemctl enable dnsmasq.service
    systemctl restart dnsmasq.service
  else
    systemctl enable mesh-dhcp.service
    systemctl restart mesh-dhcp.service
  fi
}

main() {
  log "configuring ${ROLE} mesh role on ${HOST_SHORT} with profile ${PROFILE}"
  chmod +x "${ROOT_DIR}/scripts/mesh_start.sh"
  install_packages
  write_env
  write_network_files
  write_units
  if [[ "$START_SERVICES" -eq 1 ]]; then
    start_services
  fi
  log "mesh setup complete"
}

main "$@"
