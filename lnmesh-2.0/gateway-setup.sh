#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LNMESH_USER="${USER:-akurt}"
NODE_PASSWORD="${LNMESH_NODE_PASSWORD:-}"
DRY_RUN=0
FOREGROUND=0
WORKER=0
PASSWORD_FILE=""
UPLINK_IFACE="${LNMESH_UPLINK_IFACE:-eth0}"
KEY_PATH="${HOME}/.ssh/lnmesh_ed25519"
STATE_DIR="${HOME}/.lnmesh"
STATE_FILE="${STATE_DIR}/lnmesh-2.0.env"
LOG_FILE="${STATE_DIR}/gateway-setup.log"
PID_FILE="${STATE_DIR}/gateway-setup.pid"
DEFAULT_PAYMENT_MSAT="${LNMESH_PAYMENT_MSAT:-1000000}"

declare -A NODE_WIFI_HOST=()
declare -A NODE_MESH_IP=([pi1]="10.0.0.1" [pi2]="10.0.0.2" [pi3]="10.0.0.3")
declare -A NODE_MESH_CIDR=([pi1]="10.0.0.1/24" [pi2]="10.0.0.2/24" [pi3]="10.0.0.3/24")
declare -A NODE_BTC_CONF=([pi1]="bitcoin.conf.pi1" [pi2]="bitcoin.conf.pi2" [pi3]="bitcoin.conf.pi3")
declare -A NODE_PROGRESS=([pi1]=0 [pi2]=0 [pi3]=0)
declare -A NODE_STATUS=([pi1]="queued" [pi2]="queued" [pi3]="queued")
PROGRESS_WIDTH=28

SSH_COMMON_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
  -o ConnectTimeout=8
)

usage() {
  cat <<'EOF'
Usage:
  ./gateway-setup.sh [--user akurt] [--node-password PASSWORD] [--node pi2=HOST --node pi3=HOST] [--dry-run] [--foreground]

Runs on pi1 from the lnmesh-2.0 directory. It discovers pi2/pi3 on normal
Wi-Fi, moves the three Pis onto the IBSS mesh, installs Bitcoin Core/Core
Lightning, starts regtest daemons, funds wallets, and opens the demo channels.
By default, the real setup runs detached so it survives SSH drops when wlan0
switches into IBSS mode. Use --foreground only for debugging from a local console.

Environment:
  LNMESH_NODE_PASSWORD   Shared Pi password, used once for bootstrap.
  LNMESH_PAYMENT_MSAT    Default amount written for pay-demo.sh.
  LNMESH_UPLINK_IFACE    Gateway uplink for NAT, default: eth0.
EOF
}

log() {
  printf '[lnmesh-setup] %s\n' "$*"
}

progress_bar() {
  local percent="$1"
  local filled empty
  filled=$((percent * PROGRESS_WIDTH / 100))
  empty=$((PROGRESS_WIDTH - filled))
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
}

progress_dashboard() {
  local node percent status
  printf '[lnmesh-progress] ------------------------------------------------------------\n'
  for node in pi1 pi2 pi3; do
    percent="${NODE_PROGRESS[$node]:-0}"
    status="${NODE_STATUS[$node]:-queued}"
    printf '[lnmesh-progress] %-3s [%s] %3d%%  %s\n' \
      "$node" "$(progress_bar "$percent")" "$percent" "$status"
  done
}

progress_node() {
  local node="$1"
  local percent="$2"
  shift 2
  NODE_PROGRESS["$node"]="$percent"
  NODE_STATUS["$node"]="$*"
  progress_dashboard
}

progress_all() {
  local percent="$1"
  shift
  local node
  for node in pi1 pi2 pi3; do
    NODE_PROGRESS["$node"]="$percent"
    NODE_STATUS["$node"]="$*"
  done
  progress_dashboard
}

die() {
  printf '[lnmesh-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

quote() {
  printf '%q' "$1"
}

run() {
  log "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

run_bash() {
  local cmd="$1"
  log "+ bash -lc ${cmd}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  bash -lc "$cmd"
}

run_sudo_bash() {
  local cmd="$1"
  log "+ sudo -n bash -lc ${cmd}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  sudo -n bash -lc "$cmd"
}

ssh_password() {
  local host="$1"
  local cmd="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ sshpass -p ******** ssh ${LNMESH_USER}@${host} ${cmd}"
    return 0
  fi
  sshpass -p "$NODE_PASSWORD" ssh "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" "$cmd"
}

ssh_key() {
  local host="$1"
  local cmd="$2"
  log "+ ssh -i ${KEY_PATH} ${LNMESH_USER}@${host} ${cmd}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  ssh -i "$KEY_PATH" "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" "$cmd"
}

scp_key() {
  local src="$1"
  local dest="$2"
  log "+ scp -i ${KEY_PATH} ${src} ${dest}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  scp -i "$KEY_PATH" "${SSH_COMMON_OPTS[@]}" "$src" "$dest"
}

remote_sudo_password() {
  local host="$1"
  local cmd="$2"
  local pass_q cmd_q
  pass_q="$(quote "$NODE_PASSWORD")"
  cmd_q="$(quote "$cmd")"
  ssh_password "$host" "printf '%s\n' ${pass_q} | sudo -S -p '' bash -lc ${cmd_q}"
}

remote_sudo_key() {
  local host="$1"
  local cmd="$2"
  local cmd_q
  cmd_q="$(quote "$cmd")"
  ssh_key "$host" "sudo -n bash -lc ${cmd_q}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 ]] || die "--user requires a value"
        LNMESH_USER="$2"
        shift 2
        ;;
      --node-password)
        [[ $# -ge 2 ]] || die "--node-password requires a value"
        NODE_PASSWORD="$2"
        shift 2
        ;;
      --node)
        [[ $# -ge 2 ]] || die "--node requires NAME=HOST"
        case "$2" in
          pi2=*|pi3=*)
            NODE_WIFI_HOST["${2%%=*}"]="${2#*=}"
            ;;
          *)
            die "--node must be pi2=HOST or pi3=HOST"
            ;;
        esac
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --foreground)
        FOREGROUND=1
        shift
        ;;
      --worker)
        WORKER=1
        shift
        ;;
      --password-file)
        [[ $# -ge 2 ]] || die "--password-file requires a value"
        PASSWORD_FILE="$2"
        shift 2
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

load_password_file() {
  if [[ -z "$PASSWORD_FILE" ]]; then
    return
  fi

  [[ -r "$PASSWORD_FILE" ]] || die "password file is not readable: ${PASSWORD_FILE}"
  NODE_PASSWORD="$(<"$PASSWORD_FILE")"
  rm -f "$PASSWORD_FILE"
}

validate_inputs() {
  [[ "$LNMESH_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "unsafe username: $LNMESH_USER"

  if [[ "$(basename "$SCRIPT_DIR")" != "lnmesh-2.0" ]]; then
    log "warning: expected to run from lnmesh-2.0, script dir is ${SCRIPT_DIR}"
  fi

  if [[ "$DRY_RUN" == "0" && -z "$NODE_PASSWORD" ]]; then
    read -r -s -p "Shared Pi password for ${LNMESH_USER}: " NODE_PASSWORD
    printf '\n'
  fi

  if [[ "$DRY_RUN" == "0" && -z "$NODE_PASSWORD" ]]; then
    die "node password is required for initial SSH/sudo bootstrap"
  fi
}

ensure_local_passwordless_sudo() {
  local user_q

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ ensure local passwordless sudo works without a tty"
    return
  fi

  if sudo -n true >/dev/null 2>&1; then
    progress_node pi1 3 "passwordless sudo ready"
    return
  fi

  [[ -n "$NODE_PASSWORD" ]] || die "node password is required to configure passwordless sudo on pi1"
  user_q="$(quote "$LNMESH_USER")"
  printf '%s\n' "$NODE_PASSWORD" |
    sudo -S -p '' bash -lc "printf '%s ALL=(ALL) NOPASSWD:ALL\n' ${user_q} > /etc/sudoers.d/${LNMESH_USER} && chmod 440 /etc/sudoers.d/${LNMESH_USER}" ||
    die "could not configure passwordless sudo on pi1"

  sudo -n true >/dev/null 2>&1 || die "passwordless sudo check failed on pi1"
  progress_node pi1 3 "passwordless sudo ready"
}

launch_detached_if_needed() {
  local credential_file pid
  local worker_args=()

  if [[ "$WORKER" == "1" || "$FOREGROUND" == "1" || "$DRY_RUN" == "1" ]]; then
    return
  fi

  validate_inputs
  ensure_local_passwordless_sudo
  mkdir -p "$STATE_DIR"
  credential_file="$(mktemp "${STATE_DIR}/gateway-setup.password.XXXXXX")"
  chmod 600 "$credential_file"
  printf '%s' "$NODE_PASSWORD" > "$credential_file"

  worker_args=(--worker --user "$LNMESH_USER" --password-file "$credential_file")
  if [[ -n "${NODE_WIFI_HOST[pi2]:-}" ]]; then
    worker_args+=(--node "pi2=${NODE_WIFI_HOST[pi2]}")
  fi
  if [[ -n "${NODE_WIFI_HOST[pi3]:-}" ]]; then
    worker_args+=(--node "pi3=${NODE_WIFI_HOST[pi3]}")
  fi

  : > "$LOG_FILE"
  (
    cd "$SCRIPT_DIR"
    nohup env \
      LNMESH_UPLINK_IFACE="$UPLINK_IFACE" \
      LNMESH_PAYMENT_MSAT="$DEFAULT_PAYMENT_MSAT" \
      bash "$SCRIPT_DIR/gateway-setup.sh" "${worker_args[@]}" \
      >>"$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
  )

  pid="$(cat "$PID_FILE")"
  log "setup is running detached as PID ${pid}"
  log "follow progress with:"
  log "  tail -f ${LOG_FILE}"
  log "if this SSH session drops, reconnect to pi1 and run that tail command again"
  exit 0
}

install_gateway_dependencies() {
  local missing=()
  local tool pkg_string
  progress_node pi1 4 "checking gateway packages"

  for tool in nmap sshpass jq wget curl tar iw rfkill nft ip ping; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "gateway dependencies are already installed"
    progress_node pi1 8 "gateway packages ready"
    return
  fi

  pkg_string="nmap sshpass jq wget curl tar iw rfkill nftables iproute2 iputils-ping"
  progress_node pi1 5 "downloading gateway packages"
  run_sudo_bash "apt-get update && apt-get install -y ${pkg_string}"
  progress_node pi1 8 "gateway packages ready"
}

validate_uplink() {
  if [[ "$DRY_RUN" == "1" ]]; then
    progress_node pi1 10 "uplink check skipped in dry-run"
    return
  fi

  ip link show "$UPLINK_IFACE" >/dev/null 2>&1 ||
    die "uplink interface ${UPLINK_IFACE} not found; set LNMESH_UPLINK_IFACE or plug Ethernet into pi1"
  progress_node pi1 10 "uplink ${UPLINK_IFACE} ready"
}

probe_hostname() {
  local host="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 1
  fi
  sshpass -p "$NODE_PASSWORD" ssh "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" 'hostname -s' 2>/dev/null | tr -d '\r'
}

try_known_hostnames() {
  local node ip found_name
  for node in pi2 pi3; do
    [[ -n "${NODE_WIFI_HOST[$node]:-}" ]] && continue
    ip="$(getent ahostsv4 "$node" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ -n "$ip" ]] || continue
    found_name="$(probe_hostname "$ip" || true)"
    if [[ "$found_name" == "$node" ]]; then
      NODE_WIFI_HOST["$node"]="$ip"
      log "found ${node} at ${ip} via hostname lookup"
    fi
  done
}

lan_cidr() {
  local iface cidr
  iface="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
  [[ -n "$iface" ]] || return 1
  cidr="$(ip -o -4 addr show dev "$iface" | awk 'NR == 1 {print $4}')"
  [[ -n "$cidr" ]] || return 1
  printf '%s\n' "$cidr"
}

discover_nodes() {
  local cidr ip found_name

  if [[ -n "${NODE_WIFI_HOST[pi2]:-}" && -n "${NODE_WIFI_HOST[pi3]:-}" ]]; then
    log "using manually supplied node addresses: pi2=${NODE_WIFI_HOST[pi2]}, pi3=${NODE_WIFI_HOST[pi3]}"
    progress_node pi2 10 "discovered at ${NODE_WIFI_HOST[pi2]}"
    progress_node pi3 10 "discovered at ${NODE_WIFI_HOST[pi3]}"
    return
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    die "dry-run discovery needs --node pi2=HOST --node pi3=HOST"
  fi

  try_known_hostnames

  if [[ -n "${NODE_WIFI_HOST[pi2]:-}" && -n "${NODE_WIFI_HOST[pi3]:-}" ]]; then
    return
  fi

  cidr="$(lan_cidr)" || die "could not determine LAN CIDR; pass --node pi2=HOST --node pi3=HOST"
  log "scanning ${cidr} for SSH hosts"

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    found_name="$(probe_hostname "$ip" || true)"
    case "$found_name" in
      pi2|pi3)
        NODE_WIFI_HOST["$found_name"]="$ip"
        log "found ${found_name} at ${ip}"
        ;;
    esac
  done < <(nmap -n -p 22 --open "$cidr" -oG - 2>/dev/null | awk '/Ports: 22\/open/ {print $2}')

  [[ -n "${NODE_WIFI_HOST[pi2]:-}" ]] || die "could not discover pi2; rerun with --node pi2=HOST"
  [[ -n "${NODE_WIFI_HOST[pi3]:-}" ]] || die "could not discover pi3; rerun with --node pi3=HOST"
  progress_node pi2 10 "discovered at ${NODE_WIFI_HOST[pi2]}"
  progress_node pi3 10 "discovered at ${NODE_WIFI_HOST[pi3]}"
}

ensure_gateway_key() {
  run mkdir -p "${HOME}/.ssh"
  if [[ "$DRY_RUN" == "0" && ! -f "$KEY_PATH" ]]; then
    run ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -q
  elif [[ "$DRY_RUN" == "1" ]]; then
    log "+ ssh-keygen -t ed25519 -N '' -f ${KEY_PATH} -q # if missing"
  else
    log "reusing SSH key ${KEY_PATH}"
  fi
}

install_key_on_node() {
  local node="$1"
  local host="${NODE_WIFI_HOST[$node]}"
  local pub pub_q

  if [[ "$DRY_RUN" == "1" ]]; then
    pub="DRY_RUN_PUBLIC_KEY"
  else
    pub="$(cat "${KEY_PATH}.pub")"
  fi
  pub_q="$(quote "$pub")"

  ssh_password "$host" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && if ! grep -qxF ${pub_q} ~/.ssh/authorized_keys; then printf '%s\n' ${pub_q} >> ~/.ssh/authorized_keys; fi; chmod 600 ~/.ssh/authorized_keys"
}

install_sudoers_on_node() {
  local node="$1"
  local host="${NODE_WIFI_HOST[$node]}"
  local user_q
  user_q="$(quote "$LNMESH_USER")"
  remote_sudo_password "$host" "printf '%s ALL=(ALL) NOPASSWD:ALL\n' ${user_q} > /etc/sudoers.d/${LNMESH_USER} && chmod 440 /etc/sudoers.d/${LNMESH_USER}"
}

bootstrap_nodes() {
  local node
  ensure_gateway_key
  progress_node pi1 15 "gateway SSH key ready"
  for node in pi2 pi3; do
    progress_node "$node" 12 "bootstrapping SSH and sudo"
    log "bootstrapping ${node} at ${NODE_WIFI_HOST[$node]}"
    install_key_on_node "$node"
    install_sudoers_on_node "$node"
    ssh_key "${NODE_WIFI_HOST[$node]}" "sudo -n true"
    progress_node "$node" 18 "SSH and passwordless sudo ready"
  done
}

install_node_base_dependencies() {
  local node
  for node in pi2 pi3; do
    progress_node "$node" 20 "downloading base mesh packages"
    remote_sudo_key "${NODE_WIFI_HOST[$node]}" "apt-get update && apt-get install -y iw rfkill wget curl tar jq"
    progress_node "$node" 25 "base mesh packages ready"
  done
}

verify_passwordless_sudo_over_mesh() {
  progress_all 36 "verifying passwordless sudo over mesh"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ sudo -n true on pi1, pi2, pi3"
    return
  fi

  sudo -n true >/dev/null 2>&1 || die "passwordless sudo is not working on pi1"
  ssh_key "${NODE_MESH_IP[pi2]}" "sudo -n true" || die "passwordless sudo is not working on pi2"
  ssh_key "${NODE_MESH_IP[pi3]}" "sudo -n true" || die "passwordless sudo is not working on pi3"
  progress_all 37 "passwordless sudo verified"
}

copy_mesh_script_to_nodes() {
  local node host
  for node in pi2 pi3; do
    host="${NODE_WIFI_HOST[$node]}"
    ssh_key "$host" "mkdir -p /home/${LNMESH_USER}/lnmesh"
    scp_key "${SCRIPT_DIR}/mesh-up.sh" "${LNMESH_USER}@${host}:/home/${LNMESH_USER}/lnmesh/mesh-up.sh"
    ssh_key "$host" "chmod +x /home/${LNMESH_USER}/lnmesh/mesh-up.sh"
  done
}

start_mesh() {
  local node host unit

  copy_mesh_script_to_nodes

  for node in pi2 pi3; do
    host="${NODE_WIFI_HOST[$node]}"
    unit="lnmesh-mesh-${node}-$(date +%s)"
    progress_node "$node" 30 "switching wlan0 to IBSS mesh"
    remote_sudo_key "$host" "systemd-run --no-block --unit=${unit} bash /home/${LNMESH_USER}/lnmesh/mesh-up.sh ${NODE_MESH_CIDR[$node]}"
  done

  progress_node pi1 30 "switching wlan0 to IBSS mesh"
  run_sudo_bash "bash $(quote "${SCRIPT_DIR}/mesh-up.sh") ${NODE_MESH_CIDR[pi1]}"
  wait_for_mesh_node pi2
  progress_node pi2 35 "mesh reachable at ${NODE_MESH_IP[pi2]}"
  wait_for_mesh_node pi3
  progress_node pi3 35 "mesh reachable at ${NODE_MESH_IP[pi3]}"
  progress_node pi1 35 "mesh IP ${NODE_MESH_IP[pi1]} ready"
}

wait_for_mesh_node() {
  local node="$1"
  local ip="${NODE_MESH_IP[$node]}"
  local attempt

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ wait for ${node} at ${ip}"
    return
  fi

  for attempt in $(seq 1 60); do
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      log "${node} is reachable at ${ip}"
      return
    fi
    sleep 2
  done

  die "${node} did not become reachable at ${ip}"
}

configure_bridge() {
  progress_all 38 "configuring pi1 internet bridge"
  run_sudo_bash "sysctl -w net.ipv4.ip_forward=1"
  run_sudo_bash "nft list table ip nat >/dev/null 2>&1 || nft add table ip nat"
  run_sudo_bash "nft list chain ip nat postrouting >/dev/null 2>&1 || nft 'add chain ip nat postrouting { type nat hook postrouting priority 100; }'"
  run_sudo_bash "nft list chain ip nat postrouting 2>/dev/null | grep -Fq 'oifname \"${UPLINK_IFACE}\" masquerade' || nft add rule ip nat postrouting oifname ${UPLINK_IFACE} masquerade"

  remote_sudo_key "${NODE_MESH_IP[pi2]}" "ip route replace default via ${NODE_MESH_IP[pi1]} dev wlan0 metric 100 && rm -f /etc/resolv.conf && printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf"
  remote_sudo_key "${NODE_MESH_IP[pi3]}" "ip route replace default via ${NODE_MESH_IP[pi1]} dev wlan0 metric 100 && rm -f /etc/resolv.conf && printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf"
  progress_all 40 "internet bridge ready"
}

bitcoin_install_cmd() {
  cat <<'EOF'
set -e
if command -v bitcoind >/dev/null 2>&1 && bitcoind -version 2>/dev/null | grep -q 'v31.0'; then
  exit 0
fi
cd /tmp
archive=bitcoin-31.0-aarch64-linux-gnu.tar.gz
wget -c --progress=bar:force:noscroll "https://bitcoincore.org/bin/bitcoin-core-31.0/${archive}"
sudo -n tar -xzf "$archive" -C /opt/
sudo -n ln -sf /opt/bitcoin-31.0/bin/bitcoind /usr/local/bin/
sudo -n ln -sf /opt/bitcoin-31.0/bin/bitcoin-cli /usr/local/bin/
EOF
}

install_bitcoin_core() {
  local cmd node
  cmd="$(bitcoin_install_cmd)"
  progress_node pi1 44 "downloading/installing Bitcoin Core 31.0"
  run_bash "$cmd"
  progress_node pi1 55 "Bitcoin Core ready"
  for node in pi2 pi3; do
    progress_node "$node" 44 "downloading/installing Bitcoin Core 31.0"
    ssh_key "${NODE_MESH_IP[$node]}" "$cmd"
    progress_node "$node" 55 "Bitcoin Core ready"
  done
}

cln_build_cmd() {
  cat <<'EOF'
set -e
if command -v lightningd >/dev/null 2>&1 && lightningd --version 2>/dev/null | grep -q 'v26.04.1'; then
  exit 0
fi
sudo -n apt-get update
sudo -n apt-get install -y jq autoconf automake build-essential git libtool \
  libsqlite3-dev libffi-dev python3 python3-pip python3-venv net-tools \
  zlib1g-dev libsodium-dev libssl-dev gettext lowdown cargo rustfmt protobuf-compiler
if ! command -v uv >/dev/null 2>&1; then
  curl -#Lf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
if [[ ! -d "$HOME/cln/.git" ]]; then
  git clone --progress --branch v26.04.1 https://github.com/ElementsProject/lightning.git "$HOME/cln"
fi
cd "$HOME/cln"
git fetch --progress --tags origin v26.04.1 || true
git checkout v26.04.1
git submodule update --init --recursive --progress
uv sync --all-extras --all-groups --frozen
source .venv/bin/activate
./configure
make -j"$(nproc)"
sudo -n make install
sudo -n strip /usr/local/bin/lightning* /usr/local/libexec/c-lightning/lightning_* /usr/local/libexec/c-lightning/plugins/* || true
EOF
}

install_cln_runtime_cmd() {
  cat <<'EOF'
set -e
sudo -n apt-get update
sudo -n apt-get install -y libsodium23 jq
EOF
}

install_core_lightning() {
  local cmd node

  cmd="$(cln_build_cmd)"
  progress_node pi1 58 "downloading/building Core Lightning v26.04.1"
  run_bash "$cmd"
  progress_node pi1 75 "Core Lightning ready"

  cmd="$(install_cln_runtime_cmd)"
  for node in pi2 pi3; do
    progress_node "$node" 58 "downloading CLN runtime packages"
    ssh_key "${NODE_MESH_IP[$node]}" "$cmd"
    progress_node "$node" 62 "CLN runtime packages ready"
  done

  progress_node pi1 78 "packing CLN binaries for nodes"
  run_sudo_bash "tar -cf /tmp/cln.tar -C / usr/local/bin/lightning-cli usr/local/bin/lightningd usr/local/bin/lightning-hsmtool usr/local/libexec/c-lightning && chmod a+r /tmp/cln.tar"
  for node in pi2 pi3; do
    progress_node "$node" 70 "copying CLN binaries from pi1"
    scp_key "/tmp/cln.tar" "${LNMESH_USER}@${NODE_MESH_IP[$node]}:/tmp/cln.tar"
    remote_sudo_key "${NODE_MESH_IP[$node]}" "cd / && tar -xf /tmp/cln.tar"
    progress_node "$node" 75 "Core Lightning ready"
  done
}

make_lightning_config() {
  local path="$1"
  cat > "$path" <<EOF
network=regtest
bind-addr=0.0.0.0:9735
log-level=info
log-file=/home/${LNMESH_USER}/.lightning/lightningd.log
EOF
}

write_configs() {
  local node tmp_cfg
  tmp_cfg="$(mktemp)"
  make_lightning_config "$tmp_cfg"

  progress_all 80 "writing Bitcoin and Lightning configs"
  run mkdir -p "${HOME}/.bitcoin" "${HOME}/.lightning"
  run cp "${SCRIPT_DIR}/${NODE_BTC_CONF[pi1]}" "${HOME}/.bitcoin/bitcoin.conf"
  run cp "$tmp_cfg" "${HOME}/.lightning/config"

  for node in pi2 pi3; do
    ssh_key "${NODE_MESH_IP[$node]}" "mkdir -p /home/${LNMESH_USER}/.bitcoin /home/${LNMESH_USER}/.lightning"
    scp_key "${SCRIPT_DIR}/${NODE_BTC_CONF[$node]}" "${LNMESH_USER}@${NODE_MESH_IP[$node]}:/home/${LNMESH_USER}/.bitcoin/bitcoin.conf"
    scp_key "$tmp_cfg" "${LNMESH_USER}@${NODE_MESH_IP[$node]}:/home/${LNMESH_USER}/.lightning/config"
  done

  rm -f "$tmp_cfg"
  progress_all 82 "configs written"
}

start_stack_cmd() {
  cat <<'EOF'
set -e
bitcoind -daemon 2>/dev/null || true
bitcoin-cli -regtest -rpcwait getblockchaininfo >/dev/null
if ! lightning-cli --regtest getinfo >/dev/null 2>&1; then
  lightningd --daemon --network=regtest
fi
sleep 8
lightning-cli --regtest getinfo | jq '{id, alias, blockheight}'
EOF
}

start_stack() {
  local cmd node
  cmd="$(start_stack_cmd)"
  progress_node pi1 86 "starting bitcoind and lightningd"
  run_bash "$cmd"
  progress_node pi1 90 "daemons running"
  for node in pi2 pi3; do
    progress_node "$node" 86 "starting bitcoind and lightningd"
    ssh_key "${NODE_MESH_IP[$node]}" "$cmd"
    progress_node "$node" 90 "daemons running"
  done
}

local_json() {
  local cmd="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ ${cmd}"
    printf '{}\n'
    return
  fi
  bash -lc "$cmd"
}

remote_json() {
  local node="$1"
  local cmd="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ ssh ${node} ${cmd}"
    printf '{}\n'
    return
  fi
  ssh -i "$KEY_PATH" "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${NODE_MESH_IP[$node]}" "$cmd"
}

ensure_miner_wallet() {
  run_bash "if bitcoin-cli -regtest listwallets | jq -e 'index(\"miner\")' >/dev/null; then true; elif bitcoin-cli -regtest loadwallet miner >/dev/null 2>&1; then true; else bitcoin-cli -regtest createwallet miner >/dev/null; fi"
}

mine_blocks() {
  local count="$1"
  run_bash "bitcoin-cli -regtest -rpcwallet=miner generatetoaddress ${count} \$(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) >/dev/null"
}

channel_exists_local() {
  local peer_id="$1"
  [[ "$DRY_RUN" == "1" ]] && return 1
  lightning-cli --regtest listpeerchannels |
    jq -e --arg peer "$peer_id" '.channels[]? | select(.peer_id == $peer and .state != "CLOSED" and .state != "ONCHAIN")' >/dev/null
}

channel_exists_remote() {
  local node="$1"
  local peer_id="$2"
  [[ "$DRY_RUN" == "1" ]] && return 1
  ssh -i "$KEY_PATH" "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${NODE_MESH_IP[$node]}" \
    "lightning-cli --regtest listpeerchannels | jq -e --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and .state != \"CLOSED\" and .state != \"ONCHAIN\")' >/dev/null"
}

wait_channel_normal_local() {
  local peer_id="$1"
  local attempt
  [[ "$DRY_RUN" == "1" ]] && return 0
  for attempt in $(seq 1 60); do
    if lightning-cli --regtest listpeerchannels |
      jq -e --arg peer "$peer_id" '.channels[]? | select(.peer_id == $peer and .state == "CHANNELD_NORMAL")' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_channel_normal_remote() {
  local node="$1"
  local peer_id="$2"
  local attempt
  [[ "$DRY_RUN" == "1" ]] && return 0
  for attempt in $(seq 1 60); do
    if ssh -i "$KEY_PATH" "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${NODE_MESH_IP[$node]}" \
      "lightning-cli --regtest listpeerchannels | jq -e --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and .state == \"CHANNELD_NORMAL\")' >/dev/null"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

fund_wallets_and_open_channels() {
  local pi1_addr pi2_addr pi2_id pi3_id opened=0

  progress_all 92 "creating/loading miner wallet"
  ensure_miner_wallet
  progress_all 93 "mining regtest maturity blocks"
  mine_blocks 101

  progress_node pi1 94 "creating CLN receive address"
  progress_node pi2 94 "creating CLN receive address"
  if [[ "$DRY_RUN" == "1" ]]; then
    pi1_addr="bcrt1dryrunpi1"
    pi2_addr="bcrt1dryrunpi2"
  else
    pi1_addr="$(local_json 'lightning-cli --regtest newaddr' | jq -r '.bech32 // empty')"
    pi2_addr="$(remote_json pi2 'lightning-cli --regtest newaddr' | jq -r '.bech32 // empty')"
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    [[ -n "$pi1_addr" ]] || die "could not get pi1 CLN address"
    [[ -n "$pi2_addr" ]] || die "could not get pi2 CLN address"
  fi

  progress_node pi1 95 "funding CLN wallet"
  progress_node pi2 95 "funding CLN wallet"
  run_bash "bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $(quote "$pi1_addr") 0.5 >/dev/null"
  run_bash "bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $(quote "$pi2_addr") 0.5 >/dev/null"
  mine_blocks 1
  [[ "$DRY_RUN" == "1" ]] || sleep 4

  progress_all 96 "collecting Lightning node IDs"
  if [[ "$DRY_RUN" == "1" ]]; then
    pi2_id="dryrun-pi2-node-id"
    pi3_id="dryrun-pi3-node-id"
  else
    pi2_id="$(remote_json pi2 'lightning-cli --regtest getinfo' | jq -r '.id // empty')"
    pi3_id="$(remote_json pi3 'lightning-cli --regtest getinfo' | jq -r '.id // empty')"
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    [[ -n "$pi2_id" ]] || die "could not get pi2 CLN id"
    [[ -n "$pi3_id" ]] || die "could not get pi3 CLN id"
  fi

  progress_all 97 "connecting peers and opening channels"
  run_bash "lightning-cli --regtest connect $(quote "${pi2_id}@${NODE_MESH_IP[pi2]}:9735") >/dev/null 2>&1 || true"
  ssh_key "${NODE_MESH_IP[pi2]}" "lightning-cli --regtest connect $(quote "${pi3_id}@${NODE_MESH_IP[pi3]}:9735") >/dev/null 2>&1 || true"

  if ! channel_exists_local "$pi2_id"; then
    run_bash "lightning-cli --regtest fundchannel id=$(quote "$pi2_id") amount=5000000 mindepth=1 >/dev/null"
    opened=1
  else
    log "pi1 <-> pi2 channel already exists"
  fi

  if ! channel_exists_remote pi2 "$pi3_id"; then
    ssh_key "${NODE_MESH_IP[pi2]}" "lightning-cli --regtest fundchannel id=$(quote "$pi3_id") amount=5000000 mindepth=1 >/dev/null"
    opened=1
  else
    log "pi2 <-> pi3 channel already exists"
  fi

  if [[ "$opened" == "1" ]]; then
    progress_all 98 "confirming channel funding transactions"
    [[ "$DRY_RUN" == "1" ]] || sleep 6
    mine_blocks 6
    [[ "$DRY_RUN" == "1" ]] || sleep 6
  fi

  progress_all 99 "verifying CHANNELD_NORMAL"
  wait_channel_normal_local "$pi2_id" || die "pi1 <-> pi2 channel did not become CHANNELD_NORMAL"
  wait_channel_normal_remote pi2 "$pi3_id" || die "pi2 <-> pi3 channel did not become CHANNELD_NORMAL"
}

write_state_file() {
  run mkdir -p "$STATE_DIR"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ write ${STATE_FILE}"
    progress_all 100 "setup complete"
    return
  fi
  cat > "$STATE_FILE" <<EOF
LNMESH_USER=${LNMESH_USER@Q}
LNMESH_KEY_PATH=${KEY_PATH@Q}
LNMESH_PI1_IP=${NODE_MESH_IP[pi1]@Q}
LNMESH_PI2_IP=${NODE_MESH_IP[pi2]@Q}
LNMESH_PI3_IP=${NODE_MESH_IP[pi3]@Q}
LNMESH_PAYMENT_MSAT=${DEFAULT_PAYMENT_MSAT@Q}
EOF
  chmod 600 "$STATE_FILE"
  log "wrote runtime state to ${STATE_FILE}"
  progress_all 100 "setup complete"
}

summary() {
  log "setup complete"
  log "next payment test:"
  log "  ./pay-demo.sh"
}

main() {
  parse_args "$@"
  load_password_file
  launch_detached_if_needed
  validate_inputs
  progress_all 0 "queued"
  ensure_local_passwordless_sudo
  install_gateway_dependencies
  validate_uplink
  discover_nodes
  bootstrap_nodes
  install_node_base_dependencies
  start_mesh
  verify_passwordless_sudo_over_mesh
  configure_bridge
  install_bitcoin_core
  install_core_lightning
  write_configs
  start_stack
  fund_wallets_and_open_channels
  write_state_file
  summary
}

main "$@"
