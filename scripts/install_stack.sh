#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "install_stack.sh must run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_SHORT="$(hostname -s)"
ROLE="${1:-}"
ENV_DIR="/etc/offlinemesh"
ENV_FILE="${ENV_DIR}/env"
SYSTEM_CLUSTER="${ENV_DIR}/cluster.json"
MESH_USER="${OFFLINEMESH_LIGHTNING_USER:-meshlink}"
MESH_GROUP="${OFFLINEMESH_LIGHTNING_GROUP:-meshlink}"
SRC_DIR="/home/${MESH_USER}/src/offlinemesh-lightning"
CLN_VERSION_TAG="${OFFLINEMESH_CLN_VERSION_TAG:-}"
CLN_REPO_URL="${OFFLINEMESH_CLN_REPO_URL:-https://github.com/ElementsProject/lightning.git}"
ALLOW_NETWORK_SOURCE="${OFFLINEMESH_ALLOW_NETWORK_SOURCE:-}"
SOURCE_CACHE_PORT="${OFFLINEMESH_SOURCE_CACHE_PORT:-}"
SOURCE_CACHE_DIR="/var/lib/offlinemesh/src-cache"
BITCOIN_CONFIG="/home/${MESH_USER}/.bitcoin/bitcoin.conf"
LIGHTNING_CONFIG="/home/${MESH_USER}/.lightning/config"
RPC_PASSWORD_FILE="${OFFLINEMESH_BITCOIN_RPC_PASSWORD_FILE:-/etc/offlinemesh/bitcoin-rpc-password}"
BACKUP_EXT=".offlinemesh.bak"

usage() {
  cat <<EOF
Usage: sudo bash $0 [gateway|node]

Installs the post-mesh OfflineMesh stack. The BATMAN mesh must already be up,
or at least configured by setup_mesh.sh. gateway installs Bitcoin Core access,
CLN, source cache, and watchtower. node installs CLN and registers with the
gateway watchtower.
EOF
}

if [[ -z "$ROLE" ]]; then
  usage >&2
  echo "Pass gateway or node explicitly; hostnames do not choose roles." >&2
  exit 2
fi

if [[ "$ROLE" != "gateway" && "$ROLE" != "node" ]]; then
  usage >&2
  exit 2
fi

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
        if isinstance(value, bool):
            print("1" if value else "0")
        else:
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

MESH_PROFILE="$(cluster_value mesh.profile mesh-a)"
NODE_ID="${OFFLINEMESH_NODE_ID:-}"
if [[ -z "$NODE_ID" && -f "$ENV_FILE" ]]; then
  NODE_ID="$(awk -F= '$1 == "OFFLINEMESH_NODE_ID" {print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
fi
if [[ -z "$NODE_ID" && "$ROLE" == "gateway" ]]; then
  NODE_ID="$HOST_SHORT"
fi
ESSID="$(cluster_value mesh.essid pi-mesh)"
CHANNEL="$(cluster_value mesh.channel 1)"
WIFI_FREQ="$(cluster_value mesh.wifi_freq 2412)"
WIFI_IFACE="$(cluster_value mesh.wifi_iface wlan0)"
BAT_IFACE="$(cluster_value mesh.bat_iface bat0)"
BAT_MTU="$(cluster_value mesh.bat_mtu 1450)"
SUBNET="$(cluster_value mesh.subnet 192.168.199.0/24)"
GATEWAY_PREFIX="$(subnet_attr "$SUBNET" prefixlen)"
GATEWAY_IP="$(cluster_value mesh.gateway_ip 192.168.199.1)"
DHCP_START="$(cluster_value mesh.dhcp_start 192.168.199.2)"
DHCP_END="$(cluster_value mesh.dhcp_end 192.168.199.99)"
DOMAIN="$(cluster_value mesh.domain local.test)"
WAN_IFACE="${OFFLINEMESH_WAN_IFACE:-eth0}"
LIGHTNING_NETWORK="$(cluster_value lightning.network testnet4)"
LIGHTNING_PORT="$(cluster_value lightning.bind_port 19735)"
SOURCE_CACHE_PORT="${SOURCE_CACHE_PORT:-$(cluster_value lightning.source_cache_port 19737)}"
CLN_VERSION_TAG="${CLN_VERSION_TAG:-$(cluster_value lightning.cln_version_tag v25.12.1)}"
ALLOW_NETWORK_SOURCE="${ALLOW_NETWORK_SOURCE:-$(cluster_value lightning.allow_network_source 1)}"
BITCOIN_NETWORK="$(cluster_value bitcoin.network "$LIGHTNING_NETWORK")"
BITCOIN_CORE_VERSION="${OFFLINEMESH_BITCOIN_CORE_VERSION:-$(cluster_value bitcoin.version 31.0)}"
BITCOIN_RPC_PORT="$(cluster_value bitcoin.rpc_port 48332)"
BITCOIN_RPC_USER="$(cluster_value bitcoin.rpc_user offlinemesh)"
BITCOIN_DATADIR="$(cluster_value bitcoin.datadir "/home/${MESH_USER}/.bitcoin")"
CLN_SOURCE_ARCHIVE_NAME="lightning-${CLN_VERSION_TAG}.tar.gz"
SOURCE_CACHE_ARCHIVE="${SOURCE_CACHE_DIR}/${CLN_SOURCE_ARCHIVE_NAME}"
BITCOIN_CLI_CACHE="${SOURCE_CACHE_DIR}/bitcoin-cli"
BITCOIN_CORE_PLATFORM="${OFFLINEMESH_BITCOIN_CORE_PLATFORM:-}"
BITCOIN_CORE_ARCHIVE_NAME="${OFFLINEMESH_BITCOIN_CORE_ARCHIVE_NAME:-}"

log() {
  printf '[install-stack] %s\n' "$*"
}

die() {
  printf '[install-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

backup_once() {
  local path="$1"
  if [[ -e "$path" && ! -e "${path}${BACKUP_EXT}" ]]; then
    cp -a "$path" "${path}${BACKUP_EXT}"
  fi
}

random_password() {
  /usr/bin/python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(36))
PY
}

ensure_rpc_password() {
  mkdir -p "$ENV_DIR"
  if [[ ! -s "$RPC_PASSWORD_FILE" ]]; then
    random_password >"$RPC_PASSWORD_FILE"
  fi
  chown root:"$MESH_GROUP" "$RPC_PASSWORD_FILE" 2>/dev/null || chown root:root "$RPC_PASSWORD_FILE"
  chmod 640 "$RPC_PASSWORD_FILE"
}

rpc_password() {
  tr -d '\r\n' <"$RPC_PASSWORD_FILE"
}

write_env() {
  mkdir -p "$ENV_DIR"
  cp -a "${ROOT_DIR}/config/cluster.json" "$SYSTEM_CLUSTER"
  chmod 644 "$SYSTEM_CLUSTER"
  ensure_rpc_password

  cat >"$ENV_FILE" <<EOF
OFFLINEMESH_ROLE=${ROLE}
OFFLINEMESH_ROOT=${ROOT_DIR}
OFFLINEMESH_PROFILE=${MESH_PROFILE}
OFFLINEMESH_NODE_ID=${NODE_ID}
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
OFFLINEMESH_GATEWAY_IP=${GATEWAY_IP}
OFFLINEMESH_GATEWAY_HOST=${GATEWAY_IP}
OFFLINEMESH_WAN_IFACE=${WAN_IFACE}
OFFLINEMESH_LIGHTNING_NETWORK=${LIGHTNING_NETWORK}
OFFLINEMESH_LIGHTNING_PORT=${LIGHTNING_PORT}
OFFLINEMESH_LIGHTNING_CONFIG=${LIGHTNING_CONFIG}
OFFLINEMESH_LIGHTNING_USER=${MESH_USER}
OFFLINEMESH_LIGHTNING_GROUP=${MESH_GROUP}
OFFLINEMESH_CLN_VERSION_TAG=${CLN_VERSION_TAG}
OFFLINEMESH_ALLOW_NETWORK_SOURCE=${ALLOW_NETWORK_SOURCE}
OFFLINEMESH_SOURCE_CACHE_PORT=${SOURCE_CACHE_PORT}
OFFLINEMESH_BITCOIN_NETWORK=${BITCOIN_NETWORK}
OFFLINEMESH_BITCOIN_DATADIR=${BITCOIN_DATADIR}
OFFLINEMESH_BITCOIN_RPC_CONNECT=${GATEWAY_IP}
OFFLINEMESH_BITCOIN_RPC_PORT=${BITCOIN_RPC_PORT}
OFFLINEMESH_BITCOIN_RPC_USER=${BITCOIN_RPC_USER}
OFFLINEMESH_BITCOIN_RPC_PASSWORD_FILE=${RPC_PASSWORD_FILE}
OFFLINEMESH_ENABLE_WATCHTOWER=$(cluster_value watchtower.enabled 1)
OFFLINEMESH_WATCHTOWER_PROVIDER=$(cluster_value watchtower.provider teos)
OFFLINEMESH_WATCHTOWER_NETWORK=$(cluster_value watchtower.network "$LIGHTNING_NETWORK")
OFFLINEMESH_WATCHTOWER_API_HOST=${GATEWAY_IP}
OFFLINEMESH_WATCHTOWER_API_PORT=$(cluster_value watchtower.api_port 9814)
OFFLINEMESH_WATCHTOWER_RPC_HOST=$(cluster_value watchtower.rpc_host 127.0.0.1)
OFFLINEMESH_WATCHTOWER_RPC_PORT=$(cluster_value watchtower.rpc_port 8814)
OFFLINEMESH_WATCHTOWER_BTC_RPC_HOST=127.0.0.1
OFFLINEMESH_WATCHTOWER_BTC_RPC_PORT=${BITCOIN_RPC_PORT}
OFFLINEMESH_WATCHTOWER_BTC_RPC_USER=${BITCOIN_RPC_USER}
OFFLINEMESH_WATCHTOWER_BTC_RPC_PASSWORD_FILE=${RPC_PASSWORD_FILE}
OFFLINEMESH_WATCHTOWER_SOURCE_ARCHIVE=$(cluster_value watchtower.source_cache_name rust-teos.tar.gz)
OFFLINEMESH_TEOS_REF=$(cluster_value watchtower.source_ref master)
OFFLINEMESH_TEOS_REPO_URL=$(cluster_value watchtower.repo_url https://github.com/talaia-labs/rust-teos.git)
EOF
  chmod 644 "$ENV_FILE"
}

apt_get_update_with_retries() {
  local attempts="${OFFLINEMESH_APT_UPDATE_ATTEMPTS:-3}"
  local delay="${OFFLINEMESH_APT_UPDATE_RETRY_DELAY:-10}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if apt-get update; then
      return 0
    fi
    if [[ "$attempt" -lt "$attempts" ]]; then
      log "apt-get update failed on attempt ${attempt}/${attempts}; retrying in ${delay}s"
      sleep "$delay"
    fi
  done
  return 1
}

missing_packages() {
  local pkg
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      printf '%s\n' "$pkg"
    fi
  done
}

install_packages() {
  local packages=(
    autoconf
    automake
    build-essential
    ca-certificates
    curl
    gettext
    git
    jq
    libev-dev
    libffi-dev
    libgmp-dev
    libpq-dev
    libsodium-dev
    libsqlite3-dev
    libssl-dev
    libtool
    lowdown
    pkg-config
    python3
    python3-mako
    python3-msgpack
    zlib1g-dev
  )
  if [[ "$ROLE" == "gateway" ]]; then
    packages+=(dnsmasq iptables openssh-client sshpass tar gzip)
  fi

  local missing=()
  mapfile -t missing < <(missing_packages "${packages[@]}")
  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "required stack packages are already installed"
    return 0
  fi

  apt_get_update_with_retries || log "apt-get update failed; attempting install with current package metadata"
  if ! apt-get install -y "${packages[@]}"; then
    mapfile -t missing < <(missing_packages "${packages[@]}")
    [[ "${#missing[@]}" -eq 0 ]] || die "required packages are missing: ${missing[*]}"
  fi
}

configure_bitcoin_gateway() {
  [[ "$ROLE" == "gateway" ]] || return 0
  backup_once "$BITCOIN_CONFIG"
  mkdir -p "$BITCOIN_DATADIR" "/home/${MESH_USER}/.lightning"
  chown -R "$MESH_USER:$MESH_GROUP" "$BITCOIN_DATADIR" "/home/${MESH_USER}/.lightning"

  cat >"$BITCOIN_CONFIG" <<EOF
server=1
daemon=0
fallbackfee=0.00020000
[${BITCOIN_NETWORK}]
rpcbind=127.0.0.1
rpcbind=${GATEWAY_IP}
rpcallowip=127.0.0.1
rpcallowip=${SUBNET}
rpcport=${BITCOIN_RPC_PORT}
rpcuser=${BITCOIN_RPC_USER}
rpcpassword=$(rpc_password)
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
EOF
  chown "$MESH_USER:$MESH_GROUP" "$BITCOIN_CONFIG"
  chmod 600 "$BITCOIN_CONFIG"
}

bitcoin_core_platform() {
  if [[ -n "$BITCOIN_CORE_PLATFORM" ]]; then
    printf '%s\n' "$BITCOIN_CORE_PLATFORM"
    return 0
  fi
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64) printf 'aarch64-linux-gnu\n' ;;
    amd64|x86_64) printf 'x86_64-linux-gnu\n' ;;
    armhf|armv7l) printf 'arm-linux-gnueabihf\n' ;;
    *) die "unsupported Bitcoin Core platform; set OFFLINEMESH_BITCOIN_CORE_PLATFORM" ;;
  esac
}

bitcoin_core_archive_name() {
  if [[ -n "$BITCOIN_CORE_ARCHIVE_NAME" ]]; then
    printf '%s\n' "$BITCOIN_CORE_ARCHIVE_NAME"
  else
    printf 'bitcoin-%s-%s.tar.gz\n' "$BITCOIN_CORE_VERSION" "$(bitcoin_core_platform)"
  fi
}

install_bitcoin_core_archive() {
  local archive="$1"
  local tmp_dir
  local extracted_dir
  tmp_dir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp_dir"
  extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name "bitcoin-${BITCOIN_CORE_VERSION}" -print -quit)"
  [[ -n "${extracted_dir:-}" ]] || extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name "bitcoin-*" -print -quit)"
  [[ -n "${extracted_dir:-}" && -d "${extracted_dir}/bin" ]] || {
    rm -rf "$tmp_dir"
    die "could not find Bitcoin Core bin directory in ${archive}"
  }
  install -m 0755 "${extracted_dir}/bin/"* /usr/local/bin/
  rm -rf "$tmp_dir"
  [[ -x /usr/local/bin/bitcoind && -x /usr/local/bin/bitcoin-cli ]] || die "Bitcoin Core install did not provide bitcoind and bitcoin-cli"
}

download_bitcoin_core_archive() {
  local archive="$1"
  local archive_name
  local base_url
  archive_name="$(bitcoin_core_archive_name)"
  base_url="${OFFLINEMESH_BITCOIN_CORE_BASE_URL:-https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_CORE_VERSION}}"
  mkdir -p "$(dirname "$archive")"
  log "downloading Bitcoin Core ${BITCOIN_CORE_VERSION} ${archive_name}"
  curl --fail --location --retry 5 --retry-delay 5 --output "$archive" "${base_url}/${archive_name}"

  if curl --fail --location --retry 5 --retry-delay 5 --output "${archive}.SHA256SUMS" "${base_url}/SHA256SUMS"; then
    (cd "$(dirname "$archive")" && sha256sum --ignore-missing --check "$(basename "${archive}.SHA256SUMS")")
  else
    log "could not download SHA256SUMS; continuing without checksum verification"
  fi
}

ensure_bitcoin_core_gateway() {
  [[ "$ROLE" == "gateway" ]] || return 0
  if [[ -x /usr/local/bin/bitcoind && -x /usr/local/bin/bitcoin-cli ]]; then
    log "Bitcoin Core binaries already installed"
    return 0
  fi

  local archive_name
  local archive
  local candidates=()
  archive_name="$(bitcoin_core_archive_name)"
  candidates+=(
    "${ROOT_DIR}/sources/${archive_name}"
    "/home/${MESH_USER}/src/${archive_name}"
    "${SOURCE_CACHE_DIR}/${archive_name}"
  )

  for archive in "${candidates[@]}"; do
    if [[ -f "$archive" ]]; then
      log "using Bitcoin Core archive ${archive}"
      install_bitcoin_core_archive "$archive"
      return 0
    fi
  done

  [[ "$ALLOW_NETWORK_SOURCE" == "1" ]] || die "Bitcoin Core missing and network source disabled; seed ${ROOT_DIR}/sources/${archive_name}"
  archive="/home/${MESH_USER}/src/${archive_name}"
  mkdir -p "/home/${MESH_USER}/src"
  chown "$MESH_USER:$MESH_GROUP" "/home/${MESH_USER}/src"
  download_bitcoin_core_archive "$archive"
  install_bitcoin_core_archive "$archive"
}

ensure_bitcoin_cli() {
  if [[ "$ROLE" == "gateway" ]]; then
    [[ -x /usr/local/bin/bitcoin-cli ]] || die "gateway is missing /usr/local/bin/bitcoin-cli"
    mkdir -p "$SOURCE_CACHE_DIR"
    cp -a /usr/local/bin/bitcoin-cli "$BITCOIN_CLI_CACHE"
    chmod 0755 "$BITCOIN_CLI_CACHE"
    chown "$MESH_USER:$MESH_GROUP" "$BITCOIN_CLI_CACHE"
    return 0
  fi

  if [[ -x /usr/local/bin/bitcoin-cli ]]; then
    return 0
  fi

  log "installing bitcoin-cli client from gateway cache"
  runuser -u "$MESH_USER" -- curl --fail --location --retry 12 --retry-delay 3 \
    --output "/tmp/offlinemesh-bitcoin-cli" \
    "http://${GATEWAY_IP}:${SOURCE_CACHE_PORT}/bitcoin-cli"
  install -m 0755 /tmp/offlinemesh-bitcoin-cli /usr/local/bin/bitcoin-cli
  rm -f /tmp/offlinemesh-bitcoin-cli
}

is_cln_source_dir() {
  local path="$1"
  [[ -d "$path" && -f "${path}/configure" && -f "${path}/.version" ]]
}

copy_cln_source_dir() {
  local source_dir="$1"
  rm -rf "$SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  cp -a "$source_dir" "$SRC_DIR"
  chown -R "$MESH_USER:$MESH_GROUP" "$SRC_DIR"
}

extract_cln_source_archive() {
  local archive="$1"
  local tmp_dir
  local extracted_dir

  tmp_dir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp_dir"
  if [[ -f "${tmp_dir}/configure" ]]; then
    extracted_dir="$tmp_dir"
  else
    extracted_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 2 -type f -name configure -printf '%h\n' | head -n 1)"
  fi
  [[ -n "${extracted_dir:-}" ]] || {
    rm -rf "$tmp_dir"
    die "could not find a CLN source tree in ${archive}"
  }
  copy_cln_source_dir "$extracted_dir"
  rm -rf "$tmp_dir"
}

seed_cln_source_from_candidates() {
  local archive
  local source_dir
  local archive_candidates=()
  local source_candidates=()

  [[ -n "${OFFLINEMESH_CLN_SOURCE_ARCHIVE:-}" ]] && archive_candidates+=("$OFFLINEMESH_CLN_SOURCE_ARCHIVE")
  archive_candidates+=(
    "${ROOT_DIR}/sources/${CLN_SOURCE_ARCHIVE_NAME}"
    "/home/${MESH_USER}/src/${CLN_SOURCE_ARCHIVE_NAME}"
    "$SOURCE_CACHE_ARCHIVE"
  )
  for archive in "${archive_candidates[@]}"; do
    if [[ -f "$archive" ]]; then
      log "using CLN source archive ${archive}"
      extract_cln_source_archive "$archive"
      return 0
    fi
  done

  [[ -n "${OFFLINEMESH_CLN_SOURCE_DIR:-}" ]] && source_candidates+=("$OFFLINEMESH_CLN_SOURCE_DIR")
  source_candidates+=(
    "${ROOT_DIR}/sources/lightning-${CLN_VERSION_TAG}"
    "/home/${MESH_USER}/src/lightning-${CLN_VERSION_TAG}"
    "/home/${MESH_USER}/src/lightning"
  )
  for source_dir in "${source_candidates[@]}"; do
    if [[ "$source_dir" != "$SRC_DIR" ]] && is_cln_source_dir "$source_dir"; then
      log "using CLN source tree ${source_dir}"
      copy_cln_source_dir "$source_dir"
      return 0
    fi
  done
  return 1
}

network_clone_cln_source() {
  [[ "$ALLOW_NETWORK_SOURCE" == "1" ]] || return 1
  rm -rf "$SRC_DIR"
  runuser -u "$MESH_USER" -- git clone --branch "$CLN_VERSION_TAG" --depth 1 "$CLN_REPO_URL" "$SRC_DIR"
}

clean_cln_source_tree() {
  [[ -f "${SRC_DIR}/configure" ]] || die "CLN source tree is missing configure: ${SRC_DIR}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    runuser -u "$MESH_USER" -- git -C "$SRC_DIR" checkout -f "$CLN_VERSION_TAG"
    runuser -u "$MESH_USER" -- git -C "$SRC_DIR" reset --hard "$CLN_VERSION_TAG"
    runuser -u "$MESH_USER" -- git -C "$SRC_DIR" clean -fdx
    runuser -u "$MESH_USER" -- git -C "$SRC_DIR" submodule sync --recursive
    runuser -u "$MESH_USER" -- git -C "$SRC_DIR" submodule update --init --recursive
  fi
}

publish_cln_source_cache() {
  [[ "$ROLE" == "gateway" ]] || return 0
  mkdir -p "$SOURCE_CACHE_DIR"
  tar -czf "$SOURCE_CACHE_ARCHIVE" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")"
  chown -R "$MESH_USER:$MESH_GROUP" "$SOURCE_CACHE_DIR"
}

prepare_cln_source() {
  mkdir -p "/home/${MESH_USER}/src"
  chown -R "$MESH_USER:$MESH_GROUP" "/home/${MESH_USER}/src"

  if [[ "${OFFLINEMESH_SKIP_CLN_BUILD:-0}" == "1" && -x /usr/local/bin/lightningd ]]; then
    log "OFFLINEMESH_SKIP_CLN_BUILD=1 and lightningd exists; skipping CLN build"
    return 1
  fi

  if [[ "$ROLE" != "gateway" ]]; then
    rm -rf "$SRC_DIR"
    if runuser -u "$MESH_USER" -- curl --fail --location --retry 12 --retry-delay 3 \
      --output "/home/${MESH_USER}/src/${CLN_SOURCE_ARCHIVE_NAME}" \
      "http://${GATEWAY_IP}:${SOURCE_CACHE_PORT}/${CLN_SOURCE_ARCHIVE_NAME}"; then
      extract_cln_source_archive "/home/${MESH_USER}/src/${CLN_SOURCE_ARCHIVE_NAME}"
    elif ! seed_cln_source_from_candidates && ! network_clone_cln_source; then
      die "could not fetch or clone CLN ${CLN_VERSION_TAG}"
    fi
  else
    if ! is_cln_source_dir "$SRC_DIR"; then
      if ! seed_cln_source_from_candidates && ! network_clone_cln_source; then
        die "no CLN ${CLN_VERSION_TAG} source found; seed sources/${CLN_SOURCE_ARCHIVE_NAME} or allow network source"
      fi
    fi
  fi

  clean_cln_source_tree
  /usr/bin/python3 "${ROOT_DIR}/scripts/patch_cln_fee_floor.py" "$SRC_DIR"
  chown -R "$MESH_USER:$MESH_GROUP" "$SRC_DIR"
  publish_cln_source_cache
  return 0
}

install_cln() {
  if [[ "${OFFLINEMESH_SKIP_CLN_BUILD:-0}" == "1" && -x /usr/local/bin/lightningd && -x /usr/local/bin/lightning-cli ]]; then
    log "using existing CLN binaries"
    return 0
  fi

  if prepare_cln_source; then
    runuser -u "$MESH_USER" -- bash -lc "cd '${SRC_DIR}' && ./configure"
    runuser -u "$MESH_USER" -- bash -lc "cd '${SRC_DIR}' && make -j\$(nproc)"
    make -C "$SRC_DIR" install
  fi
}

install_units() {
  backup_once /etc/systemd/system/lightningd.service
  mkdir -p /etc/systemd/system/lightningd.service.d

  if [[ "$ROLE" == "gateway" ]]; then
    backup_once /etc/systemd/system/bitcoind.service
    cat >/etc/systemd/system/bitcoind.service <<EOF
[Unit]
Description=Bitcoin Core daemon (${BITCOIN_NETWORK})
After=network-online.target batman-adv.service
Wants=network-online.target batman-adv.service

[Service]
User=${MESH_USER}
Group=${MESH_GROUP}
Type=simple
ExecStart=/usr/local/bin/bitcoind -${BITCOIN_NETWORK} -conf=${BITCOIN_CONFIG} -datadir=${BITCOIN_DATADIR} -pid=${BITCOIN_DATADIR}/bitcoind.pid
ExecStop=/usr/local/bin/bitcoin-cli -${BITCOIN_NETWORK} -datadir=${BITCOIN_DATADIR} stop
Restart=on-failure
RestartSec=10
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/lnmesh-source-cache.service <<EOF
[Unit]
Description=OfflineMesh source cache
After=batman-adv.service dnsmasq.service
Wants=batman-adv.service dnsmasq.service

[Service]
User=${MESH_USER}
Group=${MESH_GROUP}
WorkingDirectory=${SOURCE_CACHE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SOURCE_CACHE_PORT} --bind ${GATEWAY_IP} --directory ${SOURCE_CACHE_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi

  local after_units="batman-adv.service network-online.target"
  local wants_units="batman-adv.service network-online.target"
  if [[ "$ROLE" == "gateway" ]]; then
    after_units="bitcoind.service ${after_units}"
    wants_units="bitcoind.service ${wants_units}"
  else
    after_units="mesh-dhcp.service ${after_units}"
    wants_units="mesh-dhcp.service ${wants_units}"
  fi

  cat >/etc/systemd/system/lightningd.service <<EOF
[Unit]
Description=Core Lightning daemon (${LIGHTNING_NETWORK})
After=${after_units}
Wants=${wants_units}

[Service]
User=${MESH_USER}
Group=${MESH_GROUP}
Type=simple
ExecStart=/usr/local/bin/lightningd --conf=${LIGHTNING_CONFIG} --lightning-dir=/home/${MESH_USER}/.lightning
ExecStop=/usr/local/bin/lightning-cli --lightning-dir=/home/${MESH_USER}/.lightning --network=${LIGHTNING_NETWORK} stop
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/lightningd.service.d/offlinemesh.conf <<EOF
[Service]
Environment=OFFLINEMESH_ENV_FILE=${ENV_FILE}
Environment=LNMESH_CLUSTER_CONFIG=${SYSTEM_CLUSTER}
ExecStartPre=/bin/bash ${ROOT_DIR}/scripts/update_cln_mesh_addr.sh
EOF
}

restart_services() {
  systemctl daemon-reload
  if [[ "$ROLE" == "gateway" ]]; then
    mkdir -p "$SOURCE_CACHE_DIR"
    chown -R "$MESH_USER:$MESH_GROUP" /var/lib/offlinemesh
    systemctl enable bitcoind.service lnmesh-source-cache.service lightningd.service
    systemctl restart bitcoind.service
    systemctl restart lnmesh-source-cache.service
  else
    systemctl enable lightningd.service
  fi

  systemctl restart lightningd.service

  if [[ "$(cluster_value watchtower.enabled 1)" == "1" ]]; then
    if [[ "$ROLE" == "gateway" ]]; then
      bash "${ROOT_DIR}/scripts/watchtower_setup.sh" install-gateway
      systemctl restart lnmesh-watchtower.service
      systemctl restart lnmesh-watchtower-info.service || true
    else
      bash "${ROOT_DIR}/scripts/watchtower_setup.sh" install-node
      systemctl restart lightningd.service
      systemctl restart lnmesh-watchtower-register.service || true
    fi
  fi
}

main() {
  chmod +x "${ROOT_DIR}/scripts/"*.sh "${ROOT_DIR}/scripts/"*.py 2>/dev/null || true
  install_packages
  write_env
  ensure_bitcoin_core_gateway
  configure_bitcoin_gateway
  ensure_bitcoin_cli
  install_units
  install_cln
  restart_services
  log "OfflineMesh ${ROLE} stack install complete on ${HOST_SHORT}"
}

main "$@"
