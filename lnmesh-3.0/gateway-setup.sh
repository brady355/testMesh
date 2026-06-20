#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LNMESH_USER="${USER:-brady}"
NODE_PASSWORD="${LNMESH_NODE_PASSWORD:-}"
DRY_RUN=0
FOREGROUND=0
WORKER=0
PASSWORD_FILE=""
UPLINK_IFACE="${LNMESH_UPLINK_IFACE:-eth0}"
KEY_PATH="${HOME}/.ssh/lnmesh_ed25519"
STATE_DIR="${HOME}/.lnmesh"
STATE_FILE="${STATE_DIR}/lnmesh-3.0.env"
LOG_FILE="${STATE_DIR}/gateway-setup.log"
PID_FILE="${STATE_DIR}/gateway-setup.pid"
DEFAULT_PAYMENT_MSAT="${LNMESH_PAYMENT_MSAT:-1000000}"
SSH_TIMEOUT="${LNMESH_SSH_TIMEOUT:-3600}"
SSH_SHORT_TIMEOUT="${LNMESH_SSH_SHORT_TIMEOUT:-45}"
SSH_DAEMON_TIMEOUT="${LNMESH_DAEMON_START_TIMEOUT:-300}"
SYNC_WAIT_SECONDS="${LNMESH_SYNC_WAIT_TIMEOUT:-240}"
MEMPOOL_WAIT_SECONDS="${LNMESH_MEMPOOL_WAIT_TIMEOUT:-120}"
CHANNEL_WAIT_SECONDS="${LNMESH_CHANNEL_WAIT_TIMEOUT:-240}"
CHANNEL_AMOUNT_SAT="${LNMESH_CHANNEL_AMOUNT_SAT:-5000000}"
CHANNEL_AMOUNT_MSAT=$((CHANNEL_AMOUNT_SAT * 1000))
CLN_CONFIRMED_FUNDS_FILTER='def msat: if type == "number" then . elif type == "string" then sub("msat$"; "") | tonumber else 0 end; ([.outputs[]? | select(.status == "confirmed" and ((.reserved // false) | not)) | .amount_msat | msat] | add) // 0'

declare -A NODE_WIFI_HOST=()
declare -A NODE_MESH_IP=([pi1]="10.0.0.1" [pi2]="10.0.0.2" [pi3]="10.0.0.3")
declare -A NODE_MESH_CIDR=([pi1]="10.0.0.1/24" [pi2]="10.0.0.2/24" [pi3]="10.0.0.3/24")
declare -A NODE_BTC_CONF=([pi1]="bitcoin.conf.pi1" [pi2]="bitcoin.conf.pi2" [pi3]="bitcoin.conf.pi3")
declare -A NODE_PROGRESS=([pi1]=0 [pi2]=0 [pi3]=0)
declare -A NODE_STATUS=([pi1]="queued" [pi2]="queued" [pi3]="queued")
declare -A NODE_ON_MESH=([pi2]=0 [pi3]=0)
declare -A NODE_BASE_DEPS_READY=([pi2]=0 [pi3]=0)
PROGRESS_WIDTH=28

SSH_COMMON_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
  -o ConnectTimeout=8
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

usage() {
  cat <<'EOF'
Usage:
  ./gateway-setup.sh [--user brady] [--node-password PASSWORD] [--node pi2=HOST --node pi3=HOST] [--dry-run] [--foreground]

Runs on pi1 from the lnmesh-3.0 directory. It discovers pi2/pi3 on normal
Wi-Fi or resumes from their expected mesh IPs, moves the three Pis onto the
IBSS mesh, installs Bitcoin Core/Core Lightning, starts regtest daemons, funds
wallets, and opens the demo channels.
By default, the real setup runs detached so it survives SSH drops when wlan0
switches into IBSS mode. Use --foreground only for debugging from a local console.

Environment:
  LNMESH_NODE_PASSWORD   Shared Pi password, used once for bootstrap.
  LNMESH_PAYMENT_MSAT    Default amount written for pay-demo.sh.
  LNMESH_UPLINK_IFACE    Gateway uplink for NAT, default: eth0.
  LNMESH_SSH_TIMEOUT     Timeout for long remote SSH commands, default: 3600.
  LNMESH_DAEMON_START_TIMEOUT
                         Timeout for remote daemon recovery, default: 300.
  LNMESH_CHANNEL_AMOUNT_SAT
                         Channel capacity for each demo channel, default: 5000000.
  LNMESH_SYNC_WAIT_TIMEOUT
                         Wait for CLN block/fund sync, default: 240.
EOF
}

log() {
  printf '[lnmesh-setup] %s\n' "$*"
}

log_stderr() {
  printf '[lnmesh-setup] %s\n' "$*" >&2
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

redact_secrets() {
  local text="$1"
  if [[ -n "${NODE_PASSWORD:-}" ]]; then
    text="${text//"$NODE_PASSWORD"/********}"
  fi
  printf '%s' "$text"
}

command_preview() {
  local cmd="$1"
  cmd="$(redact_secrets "$cmd")"
  cmd="${cmd//$'\n'/; }"
  if ((${#cmd} > 220)); then
    printf '%s...' "${cmd:0:220}"
  else
    printf '%s' "$cmd"
  fi
}

have_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 ||
    [[ -x "/usr/sbin/${tool}" || -x "/sbin/${tool}" || -x "/usr/local/sbin/${tool}" ]]
}

run_timed() {
  local seconds="$1"
  shift
  command -v timeout >/dev/null 2>&1 || die "timeout command not found; install coreutils before running setup"
  timeout --kill-after=10s "$seconds" "$@"
}

is_timeout_status() {
  case "$1" in
    124|137|143) return 0 ;;
    *) return 1 ;;
  esac
}

remote_command_failed() {
  local label="$1"
  local host="$2"
  local seconds="$3"
  local cmd="$4"
  local status="$5"

  if is_timeout_status "$status"; then
    die "${label} timed out after ${seconds}s on ${host}: $(command_preview "$cmd")"
  fi
  die "${label} failed with exit ${status} on ${host}: $(command_preview "$cmd")"
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
  local seconds="${3:-$SSH_TIMEOUT}"
  local status=0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ timeout ${seconds}s sshpass -p ******** ssh ${LNMESH_USER}@${host} $(command_preview "$cmd")"
    return 0
  fi
  run_timed "$seconds" sshpass -p "$NODE_PASSWORD" ssh "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" "$cmd" || status=$?
  if ((status != 0)); then
    remote_command_failed "password SSH command" "$host" "$seconds" "$cmd" "$status"
  fi
}

ssh_key_raw() {
  local host="$1"
  local cmd="$2"
  local seconds="${3:-$SSH_TIMEOUT}"
  run_timed "$seconds" ssh -i "$KEY_PATH" -o BatchMode=yes "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" "$cmd"
}

ssh_key() {
  local host="$1"
  local cmd="$2"
  local seconds="${3:-$SSH_TIMEOUT}"
  local status=0
  log "+ timeout ${seconds}s ssh -i ${KEY_PATH} ${LNMESH_USER}@${host} $(command_preview "$cmd")"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  ssh_key_raw "$host" "$cmd" "$seconds" || status=$?
  if ((status != 0)); then
    remote_command_failed "key SSH command" "$host" "$seconds" "$cmd" "$status"
  fi
}

scp_key() {
  local src="$1"
  local dest="$2"
  local seconds="${3:-$SSH_TIMEOUT}"
  local status=0
  log "+ timeout ${seconds}s scp -i ${KEY_PATH} ${src} ${dest}"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  run_timed "$seconds" scp -i "$KEY_PATH" -o BatchMode=yes "${SSH_COMMON_OPTS[@]}" "$src" "$dest" || status=$?
  if ((status != 0)); then
    if is_timeout_status "$status"; then
      die "scp timed out after ${seconds}s: ${src} -> ${dest}"
    fi
    die "scp failed with exit ${status}: ${src} -> ${dest}"
  fi
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

  if [[ "$(basename "$SCRIPT_DIR")" != "lnmesh-3.0" ]]; then
    log "warning: expected to run from lnmesh-3.0, script dir is ${SCRIPT_DIR}"
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

  for tool in nmap sshpass jq wget curl tar iw rfkill nft ip ping timeout; do
    if ! have_tool "$tool"; then
      missing+=("$tool")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "gateway dependencies are already installed"
    progress_node pi1 8 "gateway packages ready"
    return
  fi

  pkg_string="nmap sshpass jq wget curl tar iw rfkill nftables iproute2 iputils-ping coreutils"
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

probe_hostname_key() {
  local host="$1"
  local status=0 output
  [[ -f "$KEY_PATH" ]] || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    return 1
  fi
  output="$(ssh_key_raw "$host" 'hostname -s' "$SSH_SHORT_TIMEOUT" 2>/dev/null)" || status=$?
  ((status == 0)) || return "$status"
  printf '%s\n' "$output" | tr -d '\r' | awk 'NR == 1 {print; exit}'
}

probe_hostname_password() {
  local host="$1"
  local status=0 output
  [[ -n "$NODE_PASSWORD" ]] || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    return 1
  fi
  output="$(run_timed "$SSH_SHORT_TIMEOUT" sshpass -p "$NODE_PASSWORD" ssh "${SSH_COMMON_OPTS[@]}" "${LNMESH_USER}@${host}" 'hostname -s' 2>/dev/null)" || status=$?
  ((status == 0)) || return "$status"
  printf '%s\n' "$output" | tr -d '\r' | awk 'NR == 1 {print; exit}'
}

probe_hostname() {
  local host="$1"
  local found=""
  found="$(probe_hostname_key "$host" || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  probe_hostname_password "$host"
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
      [[ "$ip" == "${NODE_MESH_IP[$node]}" ]] && NODE_ON_MESH["$node"]=1
      log "found ${node} at ${ip} via hostname lookup"
    fi
  done
}

mark_supplied_mesh_nodes() {
  local node
  for node in pi2 pi3; do
    if [[ "${NODE_WIFI_HOST[$node]:-}" == "${NODE_MESH_IP[$node]}" ]]; then
      NODE_ON_MESH["$node"]=1
      log "${node} was supplied as its mesh IP ${NODE_MESH_IP[$node]}; treating it as already on mesh"
    fi
  done
}

try_existing_mesh_nodes() {
  local node ip found_name
  for node in pi2 pi3; do
    [[ -z "${NODE_WIFI_HOST[$node]:-}" ]] || continue
    ip="${NODE_MESH_IP[$node]}"
    log "checking whether ${node} is already on mesh at ${ip}"
    if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      continue
    fi

    found_name="$(probe_hostname "$ip" || true)"
    if [[ "$found_name" == "$node" ]]; then
      log "found ${node} already on mesh at ${ip}"
    elif [[ -n "$found_name" ]]; then
      log "${ip} answered SSH as ${found_name}; expected ${node}, so not using it"
      continue
    else
      log "${ip} is pingable but SSH hostname could not be verified; trying it as ${node} for resume"
    fi

    NODE_WIFI_HOST["$node"]="$ip"
    NODE_ON_MESH["$node"]=1
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

  mark_supplied_mesh_nodes

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
  try_existing_mesh_nodes

  if [[ -n "${NODE_WIFI_HOST[pi2]:-}" && -n "${NODE_WIFI_HOST[pi3]:-}" ]]; then
    progress_node pi2 10 "discovered at ${NODE_WIFI_HOST[pi2]}"
    progress_node pi3 10 "discovered at ${NODE_WIFI_HOST[pi3]}"
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
        if [[ "$ip" == "${NODE_MESH_IP[$found_name]}" ]]; then
          NODE_ON_MESH["$found_name"]=1
        else
          NODE_ON_MESH["$found_name"]=0
        fi
        log "found ${found_name} at ${ip}"
        ;;
    esac
  done < <(nmap -n -p 22 --open "$cidr" -oG - 2>/dev/null | awk '/Ports: 22\/open/ {print $2}')

  try_existing_mesh_nodes

  [[ -n "${NODE_WIFI_HOST[pi2]:-}" ]] || die "could not discover pi2 on normal Wi-Fi or mesh IP ${NODE_MESH_IP[pi2]}; rerun with --node pi2=HOST"
  [[ -n "${NODE_WIFI_HOST[pi3]:-}" ]] || die "could not discover pi3 on normal Wi-Fi or mesh IP ${NODE_MESH_IP[pi3]}; rerun with --node pi3=HOST"
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

remote_base_dependencies_ready() {
  local host="$1"
  local cmd status=0

  if [[ "$DRY_RUN" == "1" ]]; then
    return 1
  fi

  cmd='for tool in iw rfkill wget curl tar jq; do command -v "$tool" >/dev/null 2>&1 || [ -x "/usr/sbin/$tool" ] || [ -x "/sbin/$tool" ] || [ -x "/usr/local/sbin/$tool" ] || exit 1; done'
  ssh_key_raw "$host" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null 2>&1 || status=$?
  ((status == 0))
}

install_node_base_dependencies() {
  local node
  for node in pi2 pi3; do
    if [[ "${NODE_ON_MESH[$node]}" == "1" ]]; then
      log "${node} is already on mesh; deferring base package check until pi1 bridge is configured"
      progress_node "$node" 25 "base mesh packages deferred until bridge"
      continue
    fi
    if remote_base_dependencies_ready "${NODE_WIFI_HOST[$node]}"; then
      log "${node} base mesh packages are already installed"
      NODE_BASE_DEPS_READY["$node"]=1
      progress_node "$node" 25 "base mesh packages ready"
      continue
    fi
    progress_node "$node" 20 "downloading base mesh packages"
    remote_sudo_key "${NODE_WIFI_HOST[$node]}" "apt-get update && apt-get install -y iw rfkill wget curl tar jq"
    NODE_BASE_DEPS_READY["$node"]=1
    progress_node "$node" 25 "base mesh packages ready"
  done
}

ensure_deferred_node_base_dependencies() {
  local node
  for node in pi2 pi3; do
    if [[ "${NODE_BASE_DEPS_READY[$node]}" == "1" ]]; then
      continue
    fi
    if remote_base_dependencies_ready "${NODE_MESH_IP[$node]}"; then
      log "${node} base mesh packages are already installed"
      NODE_BASE_DEPS_READY["$node"]=1
      progress_node "$node" 42 "base mesh packages ready"
      continue
    fi
    progress_node "$node" 41 "checking/installing base packages over mesh"
    remote_sudo_key "${NODE_MESH_IP[$node]}" "apt-get update && apt-get install -y iw rfkill wget curl tar jq"
    NODE_BASE_DEPS_READY["$node"]=1
    progress_node "$node" 42 "base mesh packages ready"
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

local_mesh_ready() {
  ip -o -4 addr show dev wlan0 2>/dev/null | awk '{print $4}' | grep -Fxq "${NODE_MESH_CIDR[pi1]}"
}

start_mesh() {
  local node host unit

  copy_mesh_script_to_nodes

  for node in pi2 pi3; do
    if [[ "${NODE_ON_MESH[$node]}" == "1" ]]; then
      log "${node} already appears to be on mesh at ${NODE_MESH_IP[$node]}; not re-running mesh-up remotely"
      progress_node "$node" 30 "already on mesh"
      continue
    fi
    host="${NODE_WIFI_HOST[$node]}"
    unit="lnmesh-mesh-${node}-$(date +%s)"
    progress_node "$node" 30 "switching wlan0 to IBSS mesh"
    remote_sudo_key "$host" "systemd-run --no-block --unit=${unit} bash /home/${LNMESH_USER}/lnmesh/mesh-up.sh ${NODE_MESH_CIDR[$node]}"
  done

  if [[ "$DRY_RUN" == "0" ]] && local_mesh_ready; then
    log "pi1 already has mesh IP ${NODE_MESH_CIDR[pi1]}; not re-running mesh-up locally"
    progress_node pi1 30 "already on mesh"
  else
    progress_node pi1 30 "switching wlan0 to IBSS mesh"
    run_sudo_bash "bash $(quote "${SCRIPT_DIR}/mesh-up.sh") ${NODE_MESH_CIDR[pi1]}"
  fi
  wait_for_mesh_node pi2
  NODE_ON_MESH[pi2]=1
  progress_node pi2 35 "mesh reachable at ${NODE_MESH_IP[pi2]}"
  wait_for_mesh_node pi3
  NODE_ON_MESH[pi3]=1
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
./configure --disable-rust
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

cln_installed_node() {
  local node="$1"
  local cmd status=0

  if [[ "$DRY_RUN" == "1" ]]; then
    return 1
  fi

  cmd="command -v lightningd >/dev/null 2>&1 && lightningd --version 2>/dev/null | grep -q 'v26.04.1'"
  if [[ "$node" == "pi1" ]]; then
    bash -lc "$cmd" >/dev/null 2>&1 || status=$?
  else
    ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null 2>&1 || status=$?
  fi
  ((status == 0))
}

install_core_lightning() {
  local cmd node
  local nodes_needing_cln=()

  if cln_installed_node pi1; then
    log "pi1 Core Lightning v26.04.1 is already installed"
    progress_node pi1 75 "Core Lightning ready"
  else
    cmd="$(cln_build_cmd)"
    progress_node pi1 58 "downloading/building Core Lightning v26.04.1"
    run_bash "$cmd"
    progress_node pi1 75 "Core Lightning ready"
  fi

  cmd="$(install_cln_runtime_cmd)"
  for node in pi2 pi3; do
    if cln_installed_node "$node"; then
      log "${node} Core Lightning v26.04.1 is already installed"
      progress_node "$node" 75 "Core Lightning ready"
      continue
    fi
    progress_node "$node" 58 "downloading CLN runtime packages"
    ssh_key "${NODE_MESH_IP[$node]}" "$cmd"
    progress_node "$node" 62 "CLN runtime packages ready"
    nodes_needing_cln+=("$node")
  done

  if [[ "${#nodes_needing_cln[@]}" -eq 0 ]]; then
    return
  fi

  progress_node pi1 78 "packing CLN binaries for nodes"
  run_sudo_bash "tar -cf /tmp/cln.tar -C / usr/local/bin/lightning-cli usr/local/bin/lightningd usr/local/bin/lightning-hsmtool usr/local/libexec/c-lightning && chmod a+r /tmp/cln.tar"
  for node in "${nodes_needing_cln[@]}"; do
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
set -euo pipefail

host="$(hostname -s 2>/dev/null || hostname)"
bitcoin_start_log="${TMPDIR:-/tmp}/lnmesh-bitcoind-start.log"
lightning_start_log="${TMPDIR:-/tmp}/lnmesh-lightningd-start.log"
lightning_info_json="${TMPDIR:-/tmp}/lnmesh-lightning-getinfo.json"
lightning_info_err="${TMPDIR:-/tmp}/lnmesh-lightning-getinfo.err"

remote_log() {
  printf '[lnmesh-daemon:%s] %s\n' "$host" "$*"
}

run_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  else
    shift
    "$@"
  fi
}

remote_log "starting bitcoind: checking RPC"
if bitcoin-cli -regtest getblockchaininfo >/dev/null 2>&1; then
  remote_log "bitcoind already responding"
else
  remote_log "starting bitcoind with detached stdio"
  mkdir -p "$HOME/.bitcoin"
  : >"$bitcoin_start_log"
  nohup bitcoind -daemon </dev/null >"$bitcoin_start_log" 2>&1 || true
fi

remote_log "waiting for bitcoin-cli -rpcwait"
if ! run_timeout 180 bitcoin-cli -regtest -rpcwait getblockchaininfo >/dev/null; then
  remote_log "bitcoin RPC did not become ready"
  tail -n 80 "$bitcoin_start_log" 2>/dev/null || true
  exit 1
fi
remote_log "bitcoin RPC ready"

remote_log "starting lightningd: checking RPC"
if lightning-cli --regtest getinfo >/dev/null 2>&1; then
  remote_log "lightningd already responding"
else
  remote_log "starting lightningd with detached stdio"
  mkdir -p "$HOME/.lightning"
  : >"$lightning_start_log"
  nohup lightningd --daemon --network=regtest </dev/null >"$lightning_start_log" 2>&1 || true
fi

remote_log "running lightning-cli getinfo"
for attempt in $(seq 1 60); do
  if lightning-cli --regtest getinfo >"$lightning_info_json" 2>"$lightning_info_err"; then
    remote_log "lightningd RPC ready"
    jq '{id, alias, blockheight}' "$lightning_info_json"
    exit 0
  fi
  sleep 2
done

remote_log "lightningd RPC did not become ready"
tail -n 80 "$lightning_start_log" 2>/dev/null || true
tail -n 80 "$lightning_info_err" 2>/dev/null || true
exit 1
EOF
}

start_stack_node() {
  local node="$1"
  local cmd host
  cmd="$(start_stack_cmd)"

  progress_node "$node" 86 "starting/recovering bitcoind and lightningd"
  if [[ "$node" == "pi1" ]]; then
    log "${node} (${NODE_MESH_IP[$node]}): starting/recovering bitcoind and lightningd"
    run_bash "$cmd"
  else
    host="${NODE_MESH_IP[$node]}"
    log "${node} (${host}): starting/recovering bitcoind and lightningd"
    ssh_key "$host" "$cmd" "$SSH_DAEMON_TIMEOUT"
  fi
  progress_node "$node" 90 "daemons running"
}

start_stack() {
  start_stack_node pi1
  log "moving daemon startup from pi1 to pi2"
  start_stack_node pi2
  log "moving daemon startup from pi2 to pi3"
  start_stack_node pi3
}

stack_ready_cmd() {
  cat <<'EOF'
set -e
bitcoin-cli -regtest getblockchaininfo >/dev/null
lightning-cli --regtest getinfo >/dev/null
EOF
}

stack_ready_node() {
  local node="$1"
  local cmd status=0
  cmd="$(stack_ready_cmd)"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ validate Bitcoin/Lightning daemons on ${node}"
    return 0
  fi

  if [[ "$node" == "pi1" ]]; then
    bash -lc "$cmd" >/dev/null 2>&1 || status=$?
  else
    ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null 2>&1 || status=$?
    if is_timeout_status "$status"; then
      remote_command_failed "daemon validation" "${NODE_MESH_IP[$node]}" "$SSH_SHORT_TIMEOUT" "$cmd" "$status"
    fi
  fi

  return "$status"
}

validate_stack_ready() {
  local node status
  for node in pi1 pi2 pi3; do
    progress_node "$node" 91 "validating Bitcoin and Lightning RPC"
    status=0
    stack_ready_node "$node" || status=$?
    if ((status == 0)); then
      log "${node} (${NODE_MESH_IP[$node]}): Bitcoin and Lightning RPC are ready"
      progress_node "$node" 91 "Bitcoin and Lightning RPC ready"
      continue
    fi

    log "${node} (${NODE_MESH_IP[$node]}): daemon validation failed with exit ${status}; attempting recovery"
    start_stack_node "$node"
    status=0
    stack_ready_node "$node" || status=$?
    ((status == 0)) || die "${node} daemons are still not ready after recovery"
    progress_node "$node" 91 "Bitcoin and Lightning RPC recovered"
  done
}

local_json() {
  local cmd="$1"
  local err_file output status=0
  if [[ "$DRY_RUN" == "1" ]]; then
    log_stderr "+ ${cmd}"
    printf '{}\n'
    return
  fi
  log_stderr "+ ${cmd}"
  err_file="$(mktemp)"
  output="$(bash -lc "$cmd" 2>"$err_file")" || status=$?
  if ((status != 0)); then
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2
    fi
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    rm -f "$err_file"
    die "local JSON command failed with exit ${status}: $(command_preview "$cmd")"
  fi
  if [[ -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi
  rm -f "$err_file"
  printf '%s\n' "$output"
}

remote_json() {
  local node="$1"
  local cmd="$2"
  local seconds="${3:-$SSH_SHORT_TIMEOUT}"
  local host="${NODE_MESH_IP[$node]}"
  local err_file status=0 output
  if [[ "$DRY_RUN" == "1" ]]; then
    log_stderr "+ ssh ${node} ${cmd}"
    printf '{}\n'
    return
  fi
  log_stderr "+ timeout ${seconds}s ssh -i ${KEY_PATH} ${LNMESH_USER}@${host} $(command_preview "$cmd")"
  err_file="$(mktemp)"
  output="$(ssh_key_raw "$host" "$cmd" "$seconds" 2>"$err_file")" || status=$?
  if ((status != 0)); then
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2
    fi
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    rm -f "$err_file"
    remote_command_failed "remote JSON command" "$host" "$seconds" "$cmd" "$status"
  fi
  if [[ -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi
  rm -f "$err_file"
  printf '%s\n' "$output"
}

wait_iterations() {
  local seconds="$1"
  local interval="${2:-2}"
  printf '%d\n' $(((seconds + interval - 1) / interval))
}

lightning_blockheight_node() {
  local node="$1"
  local host status=0 output

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '0\n'
    return 0
  fi

  if [[ "$node" == "pi1" ]]; then
    lightning-cli --regtest getinfo | jq -r '.blockheight // 0'
    return
  fi

  host="${NODE_MESH_IP[$node]}"
  output="$(ssh_key_raw "$host" "lightning-cli --regtest getinfo | jq -r '.blockheight // 0'" "$SSH_SHORT_TIMEOUT" 2>/dev/null)" || status=$?
  ((status == 0)) || return "$status"
  printf '%s\n' "$output"
}

wait_lightning_blockheight_node() {
  local node="$1"
  local target="$2"
  local attempts attempt height

  [[ "$DRY_RUN" == "1" ]] && return 0
  attempts="$(wait_iterations "$SYNC_WAIT_SECONDS" 2)"

  for attempt in $(seq 1 "$attempts"); do
    height="$(lightning_blockheight_node "$node" 2>/dev/null || printf '0')"
    if [[ "$height" =~ ^[0-9]+$ ]] && ((height >= target)); then
      log "${node} Lightning blockheight ${height}/${target}"
      return 0
    fi
    sleep 2
  done

  die "${node} Lightning did not sync to blockheight ${target} within ${SYNC_WAIT_SECONDS}s"
}

sync_lightning_to_tip() {
  local node target

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ wait for Lightning daemons to sync to Bitcoin tip"
    return
  fi

  target="$(bitcoin-cli -regtest getblockcount)"
  for node in "$@"; do
    wait_lightning_blockheight_node "$node" "$target"
  done
}

available_cln_funds_msat_node() {
  local node="$1"
  local host status=0 output cmd

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "$CHANNEL_AMOUNT_MSAT"
    return 0
  fi

  if [[ "$node" == "pi1" ]]; then
    lightning-cli --regtest listfunds | jq -r "$CLN_CONFIRMED_FUNDS_FILTER"
    return
  fi

  host="${NODE_MESH_IP[$node]}"
  cmd="lightning-cli --regtest listfunds | jq -r ${CLN_CONFIRMED_FUNDS_FILTER@Q}"
  output="$(ssh_key_raw "$host" "$cmd" "$SSH_SHORT_TIMEOUT" 2>/dev/null)" || status=$?
  ((status == 0)) || return "$status"
  printf '%s\n' "$output"
}

wait_cln_confirmed_funds_node() {
  local node="$1"
  local min_msat="$2"
  local attempts attempt available

  [[ "$DRY_RUN" == "1" ]] && return 0
  attempts="$(wait_iterations "$SYNC_WAIT_SECONDS" 2)"

  for attempt in $(seq 1 "$attempts"); do
    available="$(available_cln_funds_msat_node "$node" 2>/dev/null || printf '0')"
    if [[ "$available" =~ ^[0-9]+$ ]] && ((available >= min_msat)); then
      log "${node} CLN confirmed funds ready: ${available} msat"
      return 0
    fi
    sleep 2
  done

  if [[ "$node" == "pi1" ]]; then
    lightning-cli --regtest listfunds >&2 || true
  else
    ssh_key_raw "${NODE_MESH_IP[$node]}" "lightning-cli --regtest listfunds" "$SSH_SHORT_TIMEOUT" >&2 || true
  fi
  die "${node} CLN confirmed funds did not reach ${min_msat} msat within ${SYNC_WAIT_SECONDS}s"
}

wait_mempool_tx() {
  local txid="$1"
  local label="$2"
  local attempts attempt confirmations

  [[ "$DRY_RUN" == "1" || -z "$txid" ]] && return 0
  attempts="$(wait_iterations "$MEMPOOL_WAIT_SECONDS" 2)"

  for attempt in $(seq 1 "$attempts"); do
    if bitcoin-cli -regtest getrawmempool | jq -e --arg txid "$txid" 'index($txid)' >/dev/null; then
      log "${label} funding tx ${txid} reached pi1 mempool"
      return 0
    fi

    confirmations="$(bitcoin-cli -regtest getrawtransaction "$txid" true 2>/dev/null | jq -r '.confirmations // 0' 2>/dev/null || printf '0')"
    if [[ "$confirmations" =~ ^[0-9]+$ ]] && ((confirmations > 0)); then
      log "${label} funding tx ${txid} is already confirmed"
      return 0
    fi
    sleep 2
  done

  die "${label} funding tx ${txid} did not reach pi1 mempool within ${MEMPOOL_WAIT_SECONDS}s"
}

ensure_miner_wallet() {
  run_bash "if bitcoin-cli -regtest listwallets | jq -e 'index(\"miner\")' >/dev/null; then true; elif bitcoin-cli -regtest loadwallet miner >/dev/null 2>&1; then true; else bitcoin-cli -regtest createwallet miner >/dev/null; fi"
}

mine_blocks() {
  local count="$1"
  run_bash "bitcoin-cli -regtest -rpcwallet=miner generatetoaddress ${count} \$(bitcoin-cli -regtest -rpcwallet=miner getnewaddress) >/dev/null"
}

miner_has_mature_funds() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  bitcoin-cli -regtest -rpcwallet=miner getbalances |
    jq -e '(.mine.trusted // 0) >= 1' >/dev/null
}

ensure_miner_mature_funds() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ ensure miner wallet has mature regtest funds"
    return
  fi

  if miner_has_mature_funds; then
    log "pi1 miner wallet already has mature regtest funds"
    return
  fi

  log "pi1 (${NODE_MESH_IP[pi1]}): mining 101 regtest maturity blocks"
  mine_blocks 101
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
  local cmd status=0
  [[ "$DRY_RUN" == "1" ]] && return 1
  cmd="lightning-cli --regtest listpeerchannels | jq -e --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and .state != \"CLOSED\" and .state != \"ONCHAIN\")' >/dev/null"
  ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    124|137|143)
      remote_command_failed "remote channel check" "${NODE_MESH_IP[$node]}" "$SSH_SHORT_TIMEOUT" "$cmd" "$status"
      ;;
    255)
      remote_command_failed "remote channel check" "${NODE_MESH_IP[$node]}" "$SSH_SHORT_TIMEOUT" "$cmd" "$status"
      ;;
    *)
      return 1
      ;;
  esac
}

channel_normal_local() {
  local peer_id="$1"
  [[ "$DRY_RUN" == "1" ]] && return 1
  lightning-cli --regtest listpeerchannels |
    jq -e --arg peer "$peer_id" '.channels[]? | select(.peer_id == $peer and .state == "CHANNELD_NORMAL")' >/dev/null
}

channel_normal_remote() {
  local node="$1"
  local peer_id="$2"
  local cmd status=0
  [[ "$DRY_RUN" == "1" ]] && return 1
  cmd="lightning-cli --regtest listpeerchannels | jq -e --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and .state == \"CHANNELD_NORMAL\")' >/dev/null"
  ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    124|137|143|255)
      remote_command_failed "remote channel state check" "${NODE_MESH_IP[$node]}" "$SSH_SHORT_TIMEOUT" "$cmd" "$status"
      ;;
    *)
      return 1
      ;;
  esac
}

channel_funding_txid_local() {
  local peer_id="$1"
  [[ "$DRY_RUN" == "1" ]] && return 0
  lightning-cli --regtest listpeerchannels |
    jq -r --arg peer "$peer_id" '.channels[]? | select(.peer_id == $peer and (.funding_txid // "") != "") | .funding_txid' |
    awk 'NR == 1 {print; exit}'
}

channel_funding_txid_remote() {
  local node="$1"
  local peer_id="$2"
  local cmd
  [[ "$DRY_RUN" == "1" ]] && return 0
  cmd="lightning-cli --regtest listpeerchannels | jq -r --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and (.funding_txid // \"\") != \"\") | .funding_txid' | awk 'NR == 1 {print; exit}'"
  ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" 2>/dev/null || true
}

wait_channel_normal_local() {
  local peer_id="$1"
  local attempt attempts
  [[ "$DRY_RUN" == "1" ]] && return 0
  attempts="$(wait_iterations "$CHANNEL_WAIT_SECONDS" 2)"
  for attempt in $(seq 1 "$attempts"); do
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
  local attempt attempts cmd status
  [[ "$DRY_RUN" == "1" ]] && return 0
  cmd="lightning-cli --regtest listpeerchannels | jq -e --arg peer ${peer_id@Q} '.channels[]? | select(.peer_id == \$peer and .state == \"CHANNELD_NORMAL\")' >/dev/null"
  attempts="$(wait_iterations "$CHANNEL_WAIT_SECONDS" 2)"
  for attempt in $(seq 1 "$attempts"); do
    status=0
    ssh_key_raw "${NODE_MESH_IP[$node]}" "$cmd" "$SSH_SHORT_TIMEOUT" >/dev/null || status=$?
    if ((status == 0)); then
      return 0
    fi
    if is_timeout_status "$status"; then
      remote_command_failed "remote channel wait" "${NODE_MESH_IP[$node]}" "$SSH_SHORT_TIMEOUT" "$cmd" "$status"
    fi
    sleep 2
  done
  return 1
}

fund_wallets_and_open_channels() {
  local pi1_addr pi2_addr pi2_id pi3_id opened=0
  local pi1_fund_txid pi2_fund_txid pi1_channel_json pi2_channel_json
  local pi1_channel_txid pi2_channel_txid

  progress_all 92 "creating/loading miner wallet"
  log "pi1 (${NODE_MESH_IP[pi1]}): creating/loading regtest miner wallet"
  ensure_miner_wallet
  progress_all 93 "ensuring mature regtest funds"
  ensure_miner_mature_funds
  sync_lightning_to_tip pi1 pi2 pi3

  progress_all 94 "collecting Lightning node IDs"
  log "pi2 (${NODE_MESH_IP[pi2]}): reading Lightning node ID"
  log "pi3 (${NODE_MESH_IP[pi3]}): reading Lightning node ID"
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

  if channel_normal_local "$pi2_id" && channel_normal_remote pi2 "$pi3_id"; then
    log "demo channels are already CHANNELD_NORMAL"
    progress_all 99 "channels already normal"
    return
  fi

  progress_node pi1 95 "creating CLN receive address"
  progress_node pi2 95 "creating CLN receive address"
  log "pi1 (${NODE_MESH_IP[pi1]}): creating CLN receive address"
  log "pi2 (${NODE_MESH_IP[pi2]}): creating CLN receive address"
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

  progress_node pi1 96 "funding CLN wallet"
  progress_node pi2 96 "funding CLN wallet"
  log "pi1 (${NODE_MESH_IP[pi1]}): funding local CLN wallet"
  pi1_fund_txid="$(local_json "bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $(quote "$pi1_addr") 0.5")"
  log "pi2 (${NODE_MESH_IP[pi2]}): funding CLN wallet from pi1 miner"
  pi2_fund_txid="$(local_json "bitcoin-cli -regtest -rpcwallet=miner sendtoaddress $(quote "$pi2_addr") 0.5")"
  wait_mempool_tx "$pi1_fund_txid" "pi1 CLN wallet"
  wait_mempool_tx "$pi2_fund_txid" "pi2 CLN wallet"
  log "pi1 (${NODE_MESH_IP[pi1]}): mining one block to confirm CLN wallet funding"
  mine_blocks 1
  sync_lightning_to_tip pi1 pi2
  wait_cln_confirmed_funds_node pi1 "$CHANNEL_AMOUNT_MSAT"
  wait_cln_confirmed_funds_node pi2 "$CHANNEL_AMOUNT_MSAT"

  progress_all 97 "connecting peers and opening channels"
  log "pi1 (${NODE_MESH_IP[pi1]}): connecting to pi2 (${NODE_MESH_IP[pi2]})"
  run_bash "lightning-cli --regtest connect $(quote "${pi2_id}@${NODE_MESH_IP[pi2]}:9735") >/dev/null 2>&1 || true"
  log "pi2 (${NODE_MESH_IP[pi2]}): connecting to pi3 (${NODE_MESH_IP[pi3]})"
  ssh_key "${NODE_MESH_IP[pi2]}" "lightning-cli --regtest connect $(quote "${pi3_id}@${NODE_MESH_IP[pi3]}:9735") >/dev/null 2>&1 || true"

  if ! channel_exists_local "$pi2_id"; then
    log "pi1 (${NODE_MESH_IP[pi1]}): opening channel to pi2"
    if [[ "$DRY_RUN" == "1" ]]; then
      local_json "lightning-cli --regtest fundchannel id=$(quote "$pi2_id") amount=${CHANNEL_AMOUNT_SAT} mindepth=1" >/dev/null
      pi1_channel_txid="dryrun-pi1-pi2-channel-txid"
    else
      pi1_channel_json="$(local_json "lightning-cli --regtest fundchannel id=$(quote "$pi2_id") amount=${CHANNEL_AMOUNT_SAT} mindepth=1")"
      pi1_channel_txid="$(printf '%s\n' "$pi1_channel_json" | jq -r '.txid // empty')"
    fi
    opened=1
  else
    log "pi1 <-> pi2 channel already exists"
    pi1_channel_txid="$(channel_funding_txid_local "$pi2_id")"
    if ! channel_normal_local "$pi2_id"; then
      log "pi1 <-> pi2 channel is not normal yet; will mine confirmation blocks"
      opened=1
    fi
  fi

  if ! channel_exists_remote pi2 "$pi3_id"; then
    log "pi2 (${NODE_MESH_IP[pi2]}): opening channel to pi3"
    if [[ "$DRY_RUN" == "1" ]]; then
      remote_json pi2 "lightning-cli --regtest fundchannel id=$(quote "$pi3_id") amount=${CHANNEL_AMOUNT_SAT} mindepth=1" "$SSH_TIMEOUT" >/dev/null
      pi2_channel_txid="dryrun-pi2-pi3-channel-txid"
    else
      pi2_channel_json="$(remote_json pi2 "lightning-cli --regtest fundchannel id=$(quote "$pi3_id") amount=${CHANNEL_AMOUNT_SAT} mindepth=1" "$SSH_TIMEOUT")"
      pi2_channel_txid="$(printf '%s\n' "$pi2_channel_json" | jq -r '.txid // empty')"
    fi
    opened=1
  else
    log "pi2 <-> pi3 channel already exists"
    pi2_channel_txid="$(channel_funding_txid_remote pi2 "$pi3_id")"
    if ! channel_normal_remote pi2 "$pi3_id"; then
      log "pi2 <-> pi3 channel is not normal yet; will mine confirmation blocks"
      opened=1
    fi
  fi

  if [[ "$opened" == "1" ]]; then
    progress_all 98 "confirming channel funding transactions"
    wait_mempool_tx "$pi1_channel_txid" "pi1 <-> pi2 channel"
    wait_mempool_tx "$pi2_channel_txid" "pi2 <-> pi3 channel"
    log "pi1 (${NODE_MESH_IP[pi1]}): mining 6 blocks to confirm channel funding transactions"
    mine_blocks 6
    sync_lightning_to_tip pi1 pi2 pi3
  fi

  progress_all 99 "verifying CHANNELD_NORMAL"
  log "pi1 (${NODE_MESH_IP[pi1]}): waiting for pi1 <-> pi2 CHANNELD_NORMAL"
  wait_channel_normal_local "$pi2_id" || die "pi1 <-> pi2 channel did not become CHANNELD_NORMAL"
  log "pi2 (${NODE_MESH_IP[pi2]}): waiting for pi2 <-> pi3 CHANNELD_NORMAL"
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
  ensure_deferred_node_base_dependencies
  install_bitcoin_core
  install_core_lightning
  write_configs
  start_stack
  validate_stack_ready
  fund_wallets_and_open_channels
  write_state_file
  summary
}

main "$@"
