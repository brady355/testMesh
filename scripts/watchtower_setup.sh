#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${OFFLINEMESH_ENV_FILE:-/etc/offlinemesh/env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

HOST_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
ROLE="${OFFLINEMESH_ROLE:-}"
if [[ -z "$ROLE" ]]; then
  case "$HOST_SHORT" in
    gateway*) ROLE="gateway" ;;
    node*) ROLE="node" ;;
    *) ROLE="node" ;;
  esac
fi

cluster_value() {
  local key="$1"
  local default="$2"
  /usr/bin/python3 - "${ROOT_DIR}" "$key" "$default" <<'PY'
import json
import sys
from pathlib import Path

root, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads((Path(root) / "config" / "cluster.json").read_text(encoding="utf-8"))
    value = data
    for part in key.split("."):
        value = value[part]
except Exception:
    print(default)
else:
    if isinstance(value, bool):
        print("1" if value else "0")
    else:
        print(value)
PY
}

LIGHTNING_NETWORK="$(cluster_value lightning.network testnet4)"
WATCHTOWER_ENABLED="${OFFLINEMESH_ENABLE_WATCHTOWER:-$(cluster_value watchtower.enabled 1)}"
WATCHTOWER_PROVIDER="${OFFLINEMESH_WATCHTOWER_PROVIDER:-$(cluster_value watchtower.provider teos)}"
WATCHTOWER_NETWORK="${OFFLINEMESH_WATCHTOWER_NETWORK:-$(cluster_value watchtower.network "$LIGHTNING_NETWORK")}"
WATCHTOWER_API_HOST="${OFFLINEMESH_WATCHTOWER_API_HOST:-$(cluster_value watchtower.api_host 192.168.199.1)}"
WATCHTOWER_API_PORT="${OFFLINEMESH_WATCHTOWER_API_PORT:-$(cluster_value watchtower.api_port 9814)}"
WATCHTOWER_RPC_HOST="${OFFLINEMESH_WATCHTOWER_RPC_HOST:-$(cluster_value watchtower.rpc_host 127.0.0.1)}"
WATCHTOWER_RPC_PORT="${OFFLINEMESH_WATCHTOWER_RPC_PORT:-$(cluster_value watchtower.rpc_port 8814)}"
WATCHTOWER_BTC_RPC_HOST="${OFFLINEMESH_WATCHTOWER_BTC_RPC_HOST:-$(cluster_value watchtower.btc_rpc_host 127.0.0.1)}"
WATCHTOWER_BTC_RPC_PORT="${OFFLINEMESH_WATCHTOWER_BTC_RPC_PORT:-$(cluster_value watchtower.btc_rpc_port 48332)}"
WATCHTOWER_BTC_RPC_USER="${OFFLINEMESH_WATCHTOWER_BTC_RPC_USER:-${OFFLINEMESH_BITCOIN_RPC_USER:-$(cluster_value bitcoin.rpc_user offlinemesh)}}"
WATCHTOWER_BTC_RPC_PASSWORD="${OFFLINEMESH_WATCHTOWER_BTC_RPC_PASSWORD:-${OFFLINEMESH_BITCOIN_RPC_PASSWORD:-}}"
WATCHTOWER_BTC_RPC_PASSWORD_FILE="${OFFLINEMESH_WATCHTOWER_BTC_RPC_PASSWORD_FILE:-${OFFLINEMESH_BITCOIN_RPC_PASSWORD_FILE:-$(cluster_value bitcoin.rpc_password_file /etc/offlinemesh/bitcoin-rpc-password)}}"
TEOS_SOURCE_ARCHIVE_NAME="${OFFLINEMESH_WATCHTOWER_SOURCE_ARCHIVE:-$(cluster_value watchtower.source_cache_name rust-teos.tar.gz)}"
TEOS_REF="${OFFLINEMESH_TEOS_REF:-$(cluster_value watchtower.source_ref master)}"
TEOS_REPO_URL="${OFFLINEMESH_TEOS_REPO_URL:-$(cluster_value watchtower.repo_url https://github.com/talaia-labs/rust-teos.git)}"
ALLOW_WATCHTOWER_SOURCE="${OFFLINEMESH_ALLOW_WATCHTOWER_SOURCE:-${OFFLINEMESH_ALLOW_NETWORK_SOURCE:-1}}"
PROTOC_VERSION="${OFFLINEMESH_PROTOC_VERSION:-27.3}"
PROTOC_ARCHIVE_NAME="${OFFLINEMESH_PROTOC_ARCHIVE:-protoc-${PROTOC_VERSION}-linux-aarch_64.zip}"
RUST_TOOLCHAIN_VERSION="${OFFLINEMESH_RUST_TOOLCHAIN_VERSION:-1.81.0}"
RUST_TARGET="${OFFLINEMESH_RUST_TARGET:-aarch64-unknown-linux-gnu}"
RUST_ARCHIVE_NAME="${OFFLINEMESH_RUST_ARCHIVE:-rust-${RUST_TOOLCHAIN_VERSION}-${RUST_TARGET}.tar.xz}"

MESH_USER="${OFFLINEMESH_LIGHTNING_USER:-meshlink}"
MESH_GROUP="${OFFLINEMESH_LIGHTNING_GROUP:-meshlink}"
SOURCE_CACHE_PORT="${OFFLINEMESH_SOURCE_CACHE_PORT:-19737}"
SOURCE_CACHE_DIR="/var/lib/offlinemesh/src-cache"
SOURCE_CACHE_ARCHIVE="${SOURCE_CACHE_DIR}/${TEOS_SOURCE_ARCHIVE_NAME}"
PROTOC_CACHE_ARCHIVE="${SOURCE_CACHE_DIR}/${PROTOC_ARCHIVE_NAME}"
RUST_CACHE_ARCHIVE="${SOURCE_CACHE_DIR}/${RUST_ARCHIVE_NAME}"
WATCHTOWER_INFO_FILE="${SOURCE_CACHE_DIR}/watchtower.json"
TEOS_SRC_DIR="${OFFLINEMESH_TEOS_SOURCE_DIR:-/home/${MESH_USER}/src/offlinemesh-rust-teos}"
TEOS_DATA_DIR="${OFFLINEMESH_TEOS_DATA_DIR:-/var/lib/offlinemesh/watchtower}"
TEOS_BIN_DIR="/home/${MESH_USER}/.cargo/bin"
RUST_INSTALL_DIR="/home/${MESH_USER}/.local/offlinemesh/rust-${RUST_TOOLCHAIN_VERSION}"
PROTOC_INSTALL_DIR="/home/${MESH_USER}/.local/offlinemesh/protoc-${PROTOC_VERSION}"
TOOLCHAIN_PATH="${RUST_INSTALL_DIR}/bin:/home/${MESH_USER}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ACTIVE_PROTOC_BIN=""
ACTIVE_CC=""
TEOSD_BIN="${TEOS_BIN_DIR}/teosd"
TEOS_CLI_BIN="${TEOS_BIN_DIR}/teos-cli"
WT_CLIENT_BIN="${TEOS_BIN_DIR}/watchtower-client"
WT_PLUGIN_DIR="/home/${MESH_USER}/.lightning/plugins"
WT_PLUGIN_LINK="${WT_PLUGIN_DIR}/watchtower-client"
WT_CLIENT_DATA_DIR="${OFFLINEMESH_WATCHTOWER_CLIENT_DATA_DIR:-/home/${MESH_USER}/.watchtower}"
BTC_RPC_COOKIE="${OFFLINEMESH_WATCHTOWER_BTC_RPC_COOKIE:-/home/${MESH_USER}/.bitcoin/${WATCHTOWER_NETWORK}/.cookie}"

log() {
  printf '[watchtower] %s\n' "$*"
}

die() {
  printf '[watchtower] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "$1 must run as root"
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

ensure_enabled() {
  [[ "$WATCHTOWER_ENABLED" == "1" ]] || {
    log "watchtower disabled by configuration"
    exit 0
  }
  [[ "$WATCHTOWER_PROVIDER" == "teos" ]] || die "unsupported watchtower provider: ${WATCHTOWER_PROVIDER}"
}

run_as_meshlink() {
  runuser -u "$MESH_USER" -- bash -lc "$*"
}

install_watchtower_packages() {
  local packages=(
    build-essential
    ca-certificates
    curl
    git
    libssl-dev
    pkg-config
    python3
    tar
  )
  local missing=()

  mapfile -t missing < <(missing_packages "${packages[@]}")
  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "required watchtower packages are already installed; skipping apt"
    return 0
  fi

  if ! apt_get_update_with_retries; then
    log "apt-get update failed; checking whether watchtower dependencies are already installed"
  fi

  if ! apt-get install -y "${packages[@]}"; then
    mapfile -t missing < <(missing_packages "${packages[@]}")
    if [[ "${#missing[@]}" -gt 0 ]]; then
      die "required watchtower packages are missing after apt failure: ${missing[*]}"
    fi
    log "apt-get install failed, but required watchtower packages are already present; continuing"
  fi
}

rust_toolchain_ok() {
  local version
  version="$(
    runuser -u "$MESH_USER" -- bash -lc \
      "export PATH='${TOOLCHAIN_PATH}'; command -v rustc >/dev/null 2>&1 && rustc --version" \
      2>/dev/null
  )" || return 1
  /usr/bin/python3 - "$version" <<'PY'
import re
import sys
m = re.search(r"rustc (\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if m and tuple(map(int, m.groups())) >= (1, 81, 0) else 1)
PY
}

install_rust_from_archive() {
  local archive="$1"
  local tmp_dir
  local extracted

  tmp_dir="$(mktemp -d)"
  tar -xJf "$archive" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name "rust-${RUST_TOOLCHAIN_VERSION}-*" -print -quit)"
  if [[ -z "${extracted:-}" || ! -x "${extracted}/install.sh" ]]; then
    rm -rf "$tmp_dir"
    die "could not find install.sh in Rust archive ${archive}"
  fi

  rm -rf "$RUST_INSTALL_DIR"
  mkdir -p "$RUST_INSTALL_DIR"
  bash "${extracted}/install.sh" --prefix="$RUST_INSTALL_DIR" --disable-ldconfig --verbose
  chown -R "$MESH_USER:$MESH_GROUP" "$RUST_INSTALL_DIR"
  rm -rf "$tmp_dir"
  rust_toolchain_ok || die "Rust archive install did not provide rustc ${RUST_TOOLCHAIN_VERSION}+"
}

publish_rust_cache() {
  local archive="$1"
  if [[ "$ROLE" == "gateway" && -f "$archive" ]]; then
    mkdir -p "$SOURCE_CACHE_DIR"
    cp -a "$archive" "$RUST_CACHE_ARCHIVE"
    chown "$MESH_USER:$MESH_GROUP" "$RUST_CACHE_ARCHIVE"
  fi
}

try_install_rust_archive() {
  local archive
  local candidates=()

  if [[ "$ROLE" != "gateway" ]]; then
    archive="/home/${MESH_USER}/src/${RUST_ARCHIVE_NAME}"
    if run_as_meshlink "mkdir -p '/home/${MESH_USER}/src' && curl --fail --location --retry 12 --retry-delay 3 --output '${archive}' 'http://${WATCHTOWER_API_HOST}:${SOURCE_CACHE_PORT}/${RUST_ARCHIVE_NAME}'"; then
      install_rust_from_archive "$archive"
      return 0
    fi
  fi

  if [[ -n "${OFFLINEMESH_RUST_ARCHIVE_PATH:-}" ]]; then
    candidates+=("$OFFLINEMESH_RUST_ARCHIVE_PATH")
  fi
  candidates+=(
    "${ROOT_DIR}/sources/${RUST_ARCHIVE_NAME}"
    "/home/${MESH_USER}/src/${RUST_ARCHIVE_NAME}"
    "$RUST_CACHE_ARCHIVE"
  )

  for archive in "${candidates[@]}"; do
    if [[ -f "$archive" ]]; then
      log "using Rust toolchain archive: ${archive}"
      install_rust_from_archive "$archive"
      publish_rust_cache "$archive"
      return 0
    fi
  done

  return 1
}

ensure_rust_toolchain() {
  if rust_toolchain_ok; then
    return 0
  fi

  if try_install_rust_archive; then
    return 0
  fi

  if [[ "$ALLOW_WATCHTOWER_SOURCE" != "1" ]]; then
    die "Rust ${RUST_TOOLCHAIN_VERSION}+ is required for rust-teos; seed ${ROOT_DIR}/sources/${RUST_ARCHIVE_NAME}, install Rust, or allow watchtower source/toolchain fetches"
  fi

  log "installing Rust ${RUST_TOOLCHAIN_VERSION} for ${MESH_USER}"
  run_as_meshlink "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_TOOLCHAIN_VERSION}"
  rust_toolchain_ok || die "Rust toolchain install did not provide rustc ${RUST_TOOLCHAIN_VERSION}+"
}

install_protoc_from_archive() {
  local archive="$1"
  rm -rf "$PROTOC_INSTALL_DIR"
  mkdir -p "$PROTOC_INSTALL_DIR"
  /usr/bin/python3 - "$archive" "$PROTOC_INSTALL_DIR" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1])
target = Path(sys.argv[2])
with zipfile.ZipFile(archive) as zf:
    zf.extractall(target)
protoc = target / "bin" / "protoc"
if not protoc.is_file():
    raise SystemExit(f"protoc not found in {archive}")
protoc.chmod(0o755)
PY
  chown -R "$MESH_USER:$MESH_GROUP" "$PROTOC_INSTALL_DIR"
  ACTIVE_PROTOC_BIN="${PROTOC_INSTALL_DIR}/bin/protoc"
}

publish_protoc_cache() {
  local archive="$1"
  if [[ "$ROLE" == "gateway" && -f "$archive" ]]; then
    mkdir -p "$SOURCE_CACHE_DIR"
    cp -a "$archive" "$PROTOC_CACHE_ARCHIVE"
    chown "$MESH_USER:$MESH_GROUP" "$PROTOC_CACHE_ARCHIVE"
  fi
}

download_protoc_archive() {
  local target="$1"
  [[ "$ALLOW_WATCHTOWER_SOURCE" == "1" ]] || return 1
  run_as_meshlink "mkdir -p '/home/${MESH_USER}/src' && curl --fail --location --retry 5 --retry-delay 3 --output '${target}' 'https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/${PROTOC_ARCHIVE_NAME}'"
}

ensure_protoc() {
  local archive
  local candidates=()

  if [[ -n "${OFFLINEMESH_PROTOC_BIN:-}" && -x "${OFFLINEMESH_PROTOC_BIN}" ]]; then
    ACTIVE_PROTOC_BIN="$OFFLINEMESH_PROTOC_BIN"
    return 0
  fi

  if command -v protoc >/dev/null 2>&1; then
    ACTIVE_PROTOC_BIN="$(command -v protoc)"
    return 0
  fi

  if [[ "$ROLE" != "gateway" ]]; then
    archive="/home/${MESH_USER}/src/${PROTOC_ARCHIVE_NAME}"
    if run_as_meshlink "mkdir -p '/home/${MESH_USER}/src' && curl --fail --location --retry 12 --retry-delay 3 --output '${archive}' 'http://${WATCHTOWER_API_HOST}:${SOURCE_CACHE_PORT}/${PROTOC_ARCHIVE_NAME}'"; then
      install_protoc_from_archive "$archive"
      return 0
    fi
  fi

  if [[ -n "${OFFLINEMESH_PROTOC_ARCHIVE_PATH:-}" ]]; then
    candidates+=("$OFFLINEMESH_PROTOC_ARCHIVE_PATH")
  fi
  candidates+=(
    "${ROOT_DIR}/sources/${PROTOC_ARCHIVE_NAME}"
    "/home/${MESH_USER}/src/${PROTOC_ARCHIVE_NAME}"
    "$PROTOC_CACHE_ARCHIVE"
  )

  for archive in "${candidates[@]}"; do
    if [[ -f "$archive" ]]; then
      log "using protoc archive: ${archive}"
      install_protoc_from_archive "$archive"
      publish_protoc_cache "$archive"
      return 0
    fi
  done

  archive="/home/${MESH_USER}/src/${PROTOC_ARCHIVE_NAME}"
  if download_protoc_archive "$archive"; then
    install_protoc_from_archive "$archive"
    publish_protoc_cache "$archive"
    return 0
  fi

  die "protoc is required for rust-teos; seed ${ROOT_DIR}/sources/${PROTOC_ARCHIVE_NAME}, install protoc, or enable watchtower source access"
}

ensure_c_compiler() {
  local candidate

  for candidate in /usr/bin/cc /usr/bin/gcc /usr/bin/aarch64-linux-gnu-gcc; do
    if [[ -x "$candidate" ]]; then
      ACTIVE_CC="$candidate"
      return 0
    fi
  done

  for candidate in cc gcc aarch64-linux-gnu-gcc; do
    if command -v "$candidate" >/dev/null 2>&1; then
      ACTIVE_CC="$(command -v "$candidate")"
      return 0
    fi
  done

  die "C compiler not found; install gcc/build-essential or restore /usr/bin/cc before building rust-teos"
}

is_teos_source_dir() {
  local path="$1"
  [[ -d "$path" && -f "${path}/teos/Cargo.toml" && -f "${path}/watchtower-plugin/Cargo.toml" ]]
}

copy_teos_source_dir() {
  local source_dir="$1"
  rm -rf "$TEOS_SRC_DIR"
  mkdir -p "$(dirname "$TEOS_SRC_DIR")"
  cp -a "$source_dir" "$TEOS_SRC_DIR"
  chown -R "$MESH_USER:$MESH_GROUP" "$TEOS_SRC_DIR"
}

extract_teos_source_archive() {
  local archive="$1"
  local tmp_dir
  local plugin_dir
  local extracted_dir

  tmp_dir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp_dir"
  plugin_dir="$(find "$tmp_dir" -type f -path '*/watchtower-plugin/Cargo.toml' -printf '%h\n' | head -n 1)"
  if [[ -z "${plugin_dir:-}" ]]; then
    rm -rf "$tmp_dir"
    die "could not find a rust-teos source tree inside ${archive}"
  fi
  extracted_dir="$(dirname "$plugin_dir")"
  copy_teos_source_dir "$extracted_dir"
  rm -rf "$tmp_dir"
}

seed_teos_source_from_candidates() {
  local archive
  local source_dir
  local archive_candidates=()
  local source_candidates=()

  if [[ -n "${OFFLINEMESH_TEOS_SOURCE_ARCHIVE:-}" ]]; then
    archive_candidates+=("$OFFLINEMESH_TEOS_SOURCE_ARCHIVE")
  fi
  archive_candidates+=(
    "${ROOT_DIR}/sources/${TEOS_SOURCE_ARCHIVE_NAME}"
    "/home/${MESH_USER}/src/${TEOS_SOURCE_ARCHIVE_NAME}"
    "$SOURCE_CACHE_ARCHIVE"
  )

  for archive in "${archive_candidates[@]}"; do
    if [[ -f "$archive" ]]; then
      log "using rust-teos source archive: ${archive}"
      extract_teos_source_archive "$archive"
      return 0
    fi
  done

  if [[ -n "${OFFLINEMESH_TEOS_SOURCE_DIR:-}" ]]; then
    source_candidates+=("$OFFLINEMESH_TEOS_SOURCE_DIR")
  fi
  source_candidates+=(
    "${ROOT_DIR}/sources/rust-teos"
    "/home/${MESH_USER}/src/rust-teos"
    "/home/${MESH_USER}/src/rust-teos-${TEOS_REF}"
  )

  for source_dir in "${source_candidates[@]}"; do
    if [[ "$source_dir" != "$TEOS_SRC_DIR" ]] && is_teos_source_dir "$source_dir"; then
      log "using rust-teos source tree: ${source_dir}"
      copy_teos_source_dir "$source_dir"
      return 0
    fi
  done

  return 1
}

network_clone_teos_source() {
  if [[ "$ALLOW_WATCHTOWER_SOURCE" != "1" ]]; then
    return 1
  fi
  rm -rf "$TEOS_SRC_DIR"
  run_as_meshlink "git clone --depth 1 --branch '${TEOS_REF}' '${TEOS_REPO_URL}' '${TEOS_SRC_DIR}'"
}

clean_teos_source_tree() {
  if ! is_teos_source_dir "$TEOS_SRC_DIR"; then
    die "rust-teos source tree is incomplete: ${TEOS_SRC_DIR}"
  fi

  if [[ -d "${TEOS_SRC_DIR}/.git" ]]; then
    if ! run_as_meshlink "git -C '${TEOS_SRC_DIR}' rev-parse --verify '${TEOS_REF}^{commit}' >/dev/null 2>&1"; then
      [[ "$ALLOW_WATCHTOWER_SOURCE" == "1" ]] || die "rust-teos ref ${TEOS_REF} is not present and network fallback is disabled"
      run_as_meshlink "git -C '${TEOS_SRC_DIR}' fetch --tags origin"
    fi
    run_as_meshlink "git -C '${TEOS_SRC_DIR}' checkout -f '${TEOS_REF}'"
    run_as_meshlink "git -C '${TEOS_SRC_DIR}' reset --hard '${TEOS_REF}'"
    run_as_meshlink "git -C '${TEOS_SRC_DIR}' clean -fdx"
  fi
}

patch_teos_source() {
  /usr/bin/python3 "${ROOT_DIR}/scripts/patch_teos_testnet4.py" "$TEOS_SRC_DIR"
  chown -R "$MESH_USER:$MESH_GROUP" "$TEOS_SRC_DIR"
}

publish_teos_source_cache() {
  mkdir -p "$SOURCE_CACHE_DIR"
  tar -czf "$SOURCE_CACHE_ARCHIVE" -C "$(dirname "$TEOS_SRC_DIR")" "$(basename "$TEOS_SRC_DIR")"
  chown -R "$MESH_USER:$MESH_GROUP" "$SOURCE_CACHE_DIR"
}

prepare_teos_source_gateway() {
  mkdir -p "/home/${MESH_USER}/src"
  chown -R "$MESH_USER:$MESH_GROUP" "/home/${MESH_USER}/src"

  if ! is_teos_source_dir "$TEOS_SRC_DIR"; then
    if ! seed_teos_source_from_candidates && ! network_clone_teos_source; then
      die "no rust-teos source found; seed ${ROOT_DIR}/sources/${TEOS_SOURCE_ARCHIVE_NAME}, set OFFLINEMESH_TEOS_SOURCE_DIR, or enable watchtower source access"
    fi
  fi
  clean_teos_source_tree
  patch_teos_source
  publish_teos_source_cache
}

prepare_teos_source_node() {
  mkdir -p "/home/${MESH_USER}/src"
  chown -R "$MESH_USER:$MESH_GROUP" "/home/${MESH_USER}/src"
  rm -rf "$TEOS_SRC_DIR"
  rm -f "/home/${MESH_USER}/src/${TEOS_SOURCE_ARCHIVE_NAME}"

  if run_as_meshlink "curl --fail --location --retry 12 --retry-delay 3 --output '/home/${MESH_USER}/src/${TEOS_SOURCE_ARCHIVE_NAME}' 'http://${WATCHTOWER_API_HOST}:${SOURCE_CACHE_PORT}/${TEOS_SOURCE_ARCHIVE_NAME}'"; then
    extract_teos_source_archive "/home/${MESH_USER}/src/${TEOS_SOURCE_ARCHIVE_NAME}"
  elif ! seed_teos_source_from_candidates && ! network_clone_teos_source; then
    die "could not fetch rust-teos source from gateway and no local source was found"
  fi
  clean_teos_source_tree
  patch_teos_source
}

cargo_install_teos_server() {
  local cargo_flags=(--locked)
  ensure_rust_toolchain
  ensure_protoc
  ensure_c_compiler
  if [[ -d "${TEOS_SRC_DIR}/vendor" ]]; then
    cargo_flags+=(--offline)
  fi
  run_as_meshlink "export PATH='${TOOLCHAIN_PATH}'; export PROTOC='${ACTIVE_PROTOC_BIN}'; export CC='${ACTIVE_CC}'; cd '${TEOS_SRC_DIR}' && cargo install ${cargo_flags[*]} --path teos"
  install -m 0755 "$TEOSD_BIN" /usr/local/bin/teosd
  install -m 0755 "$TEOS_CLI_BIN" /usr/local/bin/teos-cli
}

cargo_install_watchtower_client() {
  local cargo_flags=(--locked)
  ensure_rust_toolchain
  ensure_protoc
  ensure_c_compiler
  if [[ -d "${TEOS_SRC_DIR}/vendor" ]]; then
    cargo_flags+=(--offline)
  fi
  run_as_meshlink "export PATH='${TOOLCHAIN_PATH}'; export PROTOC='${ACTIVE_PROTOC_BIN}'; export CC='${ACTIVE_CC}'; cd '${TEOS_SRC_DIR}' && cargo install ${cargo_flags[*]} --path watchtower-plugin"
  mkdir -p "$WT_PLUGIN_DIR" "$WT_CLIENT_DATA_DIR"
  ln -sfn "$WT_CLIENT_BIN" "$WT_PLUGIN_LINK"
  chown -R "$MESH_USER:$MESH_GROUP" "$WT_PLUGIN_DIR" "$WT_CLIENT_DATA_DIR"
}

write_teos_config() {
  mkdir -p "$TEOS_DATA_DIR" "$SOURCE_CACHE_DIR"
  chown -R "$MESH_USER:$MESH_GROUP" "$TEOS_DATA_DIR" "$SOURCE_CACHE_DIR"
  chmod 750 "$TEOS_DATA_DIR"

  if [[ -z "$WATCHTOWER_BTC_RPC_PASSWORD" && -n "$WATCHTOWER_BTC_RPC_PASSWORD_FILE" && -f "$WATCHTOWER_BTC_RPC_PASSWORD_FILE" ]]; then
    WATCHTOWER_BTC_RPC_PASSWORD="$(tr -d '\r\n' <"$WATCHTOWER_BTC_RPC_PASSWORD_FILE")"
  fi

  cat >"${TEOS_DATA_DIR}/teos.toml" <<EOF
# OfflineMesh gateway watchtower configuration.
api_bind = "${WATCHTOWER_API_HOST}"
api_port = ${WATCHTOWER_API_PORT}
rpc_bind = "${WATCHTOWER_RPC_HOST}"
rpc_port = ${WATCHTOWER_RPC_PORT}
btc_network = "${WATCHTOWER_NETWORK}"
btc_rpc_connect = "${WATCHTOWER_BTC_RPC_HOST}"
btc_rpc_port = ${WATCHTOWER_BTC_RPC_PORT}
subscription_slots = 10000
subscription_duration = 4320
expiry_delta = 6
min_to_self_delay = 20
polling_delta = 60
internal_api_bind = "127.0.0.1"
internal_api_port = 50051
debug = false
deps_debug = false
overwrite_key = false
force_update = false
tor_support = false
tor_control_port = 9051
onion_hidden_service_port = ${WATCHTOWER_API_PORT}
EOF
  if [[ -n "$WATCHTOWER_BTC_RPC_USER" && -n "$WATCHTOWER_BTC_RPC_PASSWORD" ]]; then
    {
      printf 'btc_rpc_user = "%s"\n' "$WATCHTOWER_BTC_RPC_USER"
      printf 'btc_rpc_password = "%s"\n' "$WATCHTOWER_BTC_RPC_PASSWORD"
    } >>"${TEOS_DATA_DIR}/teos.toml"
  else
    printf 'btc_rpc_cookie = "%s"\n' "$BTC_RPC_COOKIE" >>"${TEOS_DATA_DIR}/teos.toml"
  fi
  chown "$MESH_USER:$MESH_GROUP" "${TEOS_DATA_DIR}/teos.toml"
  chmod 640 "${TEOS_DATA_DIR}/teos.toml"
}

write_gateway_units() {
  cat >/etc/systemd/system/lnmesh-watchtower.service <<EOF
[Unit]
Description=OfflineMesh TEOS watchtower
After=bitcoind.service batman-adv.service dnsmasq.service
Requires=bitcoind.service
Wants=batman-adv.service dnsmasq.service

[Service]
User=${MESH_USER}
Group=${MESH_GROUP}
Environment=HOME=/home/${MESH_USER}
ExecStart=/bin/bash ${ROOT_DIR}/scripts/watchtower_setup.sh run-gateway
Restart=on-failure
RestartSec=10
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/lnmesh-watchtower-info.service <<EOF
[Unit]
Description=Publish OfflineMesh watchtower metadata
After=lnmesh-watchtower.service lnmesh-source-cache.service
Requires=lnmesh-watchtower.service
Wants=lnmesh-source-cache.service

[Service]
Type=oneshot
User=${MESH_USER}
Group=${MESH_GROUP}
Environment=HOME=/home/${MESH_USER}
ExecStart=/bin/bash ${ROOT_DIR}/scripts/watchtower_setup.sh publish-info
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_node_units() {
  mkdir -p /etc/systemd/system/lightningd.service.d
  cat >/etc/systemd/system/lightningd.service.d/watchtower.conf <<EOF
[Service]
Environment=TOWERS_DATA_DIR=${WT_CLIENT_DATA_DIR}
EOF

  cat >/etc/systemd/system/lnmesh-watchtower-register.service <<EOF
[Unit]
Description=Register Core Lightning with the OfflineMesh watchtower
After=lightningd.service mesh-dhcp.service batman-adv.service
Requires=lightningd.service
Wants=mesh-dhcp.service batman-adv.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
User=${MESH_USER}
Group=${MESH_GROUP}
Environment=HOME=/home/${MESH_USER}
Environment=TOWERS_DATA_DIR=${WT_CLIENT_DATA_DIR}
ExecStart=/bin/bash ${ROOT_DIR}/scripts/watchtower_setup.sh register-node
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

run_gateway() {
  [[ -x "$TEOSD_BIN" ]] || die "teosd is not installed at ${TEOSD_BIN}"
  exec "$TEOSD_BIN" --datadir="$TEOS_DATA_DIR"
}

teos_cli_gettowerinfo() {
  local cli="$TEOS_CLI_BIN"
  [[ -x "$cli" ]] || cli="$(command -v teos-cli || true)"
  [[ -n "$cli" ]] || return 1
  "$cli" --datadir="$TEOS_DATA_DIR" gettowerinfo
}

publish_info() {
  mkdir -p "$SOURCE_CACHE_DIR"
  local info_json=""
  local attempt

  for attempt in $(seq 1 60); do
    if info_json="$(teos_cli_gettowerinfo 2>/dev/null)"; then
      break
    fi
    sleep 2
  done

  [[ -n "$info_json" ]] || die "teos-cli could not read tower info"

  TEOS_INFO_JSON="$info_json" /usr/bin/python3 - "$WATCHTOWER_INFO_FILE" "$WATCHTOWER_API_HOST" "$WATCHTOWER_API_PORT" "$WATCHTOWER_NETWORK" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

target = Path(sys.argv[1])
api_host = sys.argv[2]
api_port = int(sys.argv[3])
network = sys.argv[4]
raw = json.loads(os.environ["TEOS_INFO_JSON"])
tower_id = raw.get("tower_id") or raw.get("towerId") or raw.get("id")
if not tower_id:
    raise SystemExit(f"tower id not found in teos-cli output: {raw}")

payload = {
    "provider": "teos",
    "tower_id": tower_id,
    "api_host": api_host,
    "api_port": api_port,
    "uri": f"{tower_id}@{api_host}:{api_port}",
    "network": network,
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
}
tmp = target.with_suffix(target.suffix + ".tmp")
tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
tmp.replace(target)
PY

  if [[ "${EUID}" -eq 0 ]]; then
    chown "$MESH_USER:$MESH_GROUP" "$WATCHTOWER_INFO_FILE"
  fi
  log "published ${WATCHTOWER_INFO_FILE}"
}

lightning_cli() {
  /usr/local/bin/lightning-cli --lightning-dir=/home/"${MESH_USER}"/.lightning --network="$WATCHTOWER_NETWORK" "$@"
}

wait_for_watchtower_plugin() {
  local attempt
  for attempt in $(seq 1 90); do
    if lightning_cli help 2>/dev/null | grep -q "registertower"; then
      return 0
    fi
    sleep 2
  done
  lightning_cli plugin list >&2 || true
  die "watchtower-client plugin did not expose registertower"
}

fetch_watchtower_info() {
  local target="$1"
  curl --fail --silent --show-error --location --retry 12 --retry-delay 3 \
    --output "$target" \
    "http://${WATCHTOWER_API_HOST}:${SOURCE_CACHE_PORT}/watchtower.json"
}

parse_watchtower_info() {
  local path="$1"
  /usr/bin/python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = ["tower_id", "api_host", "api_port", "uri"]
missing = [key for key in required if key not in data]
if missing:
    raise SystemExit(f"watchtower info missing keys: {missing}")
print(data["tower_id"])
print(data["uri"])
PY
}

tower_is_registered() {
  local tower_id="$1"
  local list_json
  list_json="$(lightning_cli listtowers 2>/dev/null || true)"
  TOWERS_JSON="$list_json" /usr/bin/python3 - "$tower_id" <<'PY'
import json
import os
import sys

tower_id = sys.argv[1]
try:
    data = json.loads(os.environ.get("TOWERS_JSON") or "{}")
except json.JSONDecodeError:
    raise SystemExit(1)

found = False
if isinstance(data, dict):
    found = tower_id in data
    towers = data.get("towers")
    if isinstance(towers, list):
        found = found or any(t.get("tower_id") == tower_id or t.get("id") == tower_id for t in towers if isinstance(t, dict))
elif isinstance(data, list):
    found = any(isinstance(t, dict) and (t.get("tower_id") == tower_id or t.get("id") == tower_id) for t in data)

raise SystemExit(0 if found else 1)
PY
}

register_node() {
  wait_for_watchtower_plugin
  local tmp
  local tower_id
  local tower_uri
  tmp="$(mktemp)"
  fetch_watchtower_info "$tmp"
  mapfile -t parsed < <(parse_watchtower_info "$tmp")
  rm -f "$tmp"
  tower_id="${parsed[0]}"
  tower_uri="${parsed[1]}"

  if tower_is_registered "$tower_id"; then
    log "tower ${tower_id} is already registered"
    lightning_cli pingtower "$tower_id" >/dev/null 2>&1 || lightning_cli retrytower "$tower_id" >/dev/null 2>&1 || true
    return 0
  fi

  log "registering CLN with tower ${tower_uri}"
  lightning_cli registertower "$tower_uri"
}

node_tower_status_is_reachable() {
  local tower_id="$1"
  local info_json
  info_json="$(lightning_cli gettowerinfo "$tower_id" 2>/dev/null || true)"
  TOWER_INFO_JSON="$info_json" /usr/bin/python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("TOWER_INFO_JSON") or "{}")
except json.JSONDecodeError:
    raise SystemExit(1)
raise SystemExit(0 if data.get("status") == "reachable" else 1)
PY
}

status_gateway() {
  systemctl is-active --quiet lnmesh-watchtower.service || {
    systemctl status --no-pager -l lnmesh-watchtower.service >&2 || true
    return 1
  }
  if systemctl is-failed --quiet lnmesh-watchtower-info.service; then
    systemctl status --no-pager -l lnmesh-watchtower-info.service >&2 || true
    return 1
  fi
  publish_info
  /usr/bin/python3 - "$WATCHTOWER_INFO_FILE" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in ("provider", "tower_id", "api_host", "api_port", "uri", "network"):
    if key not in data:
        raise SystemExit(f"missing {key} in watchtower.json")
print(json.dumps(data, sort_keys=True))
PY
}

status_node() {
  wait_for_watchtower_plugin
  local tmp
  local tower_id
  tmp="$(mktemp)"
  fetch_watchtower_info "$tmp"
  mapfile -t parsed < <(parse_watchtower_info "$tmp")
  rm -f "$tmp"
  tower_id="${parsed[0]}"

  if ! tower_is_registered "$tower_id"; then
    register_node
  fi

  if ! node_tower_status_is_reachable "$tower_id"; then
    lightning_cli pingtower "$tower_id" >/dev/null 2>&1 || true
    lightning_cli retrytower "$tower_id" >/dev/null 2>&1 || true
  fi

  node_tower_status_is_reachable "$tower_id" || die "tower ${tower_id} is not reachable from this node"
  lightning_cli gettowerinfo "$tower_id"
}

install_gateway() {
  require_root "install-gateway"
  ensure_enabled
  install_watchtower_packages
  prepare_teos_source_gateway
  cargo_install_teos_server
  write_teos_config
  write_gateway_units
  systemctl daemon-reload
  systemctl enable lnmesh-watchtower.service lnmesh-watchtower-info.service
  log "gateway watchtower installed"
}

install_node() {
  require_root "install-node"
  ensure_enabled
  install_watchtower_packages
  prepare_teos_source_node
  cargo_install_watchtower_client
  write_node_units
  systemctl daemon-reload
  systemctl enable lnmesh-watchtower-register.service
  log "node watchtower client installed"
}

status() {
  ensure_enabled
  if [[ "$ROLE" == "gateway" ]]; then
    status_gateway
  else
    status_node
  fi
}

case "${1:-}" in
  install-gateway)
    install_gateway
    ;;
  install-node)
    install_node
    ;;
  publish-info)
    ensure_enabled
    publish_info
    ;;
  register-node)
    ensure_enabled
    register_node
    ;;
  run-gateway)
    ensure_enabled
    run_gateway
    ;;
  status)
    status
    ;;
  *)
    cat >&2 <<EOF
Usage: $0 {install-gateway|install-node|publish-info|register-node|run-gateway|status}
EOF
    exit 2
    ;;
esac
