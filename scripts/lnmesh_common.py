#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = ROOT / "config" / "cluster.json"
SYSTEM_CONFIG_PATH = Path("/etc/offlinemesh/cluster.json")
DEFAULT_LIGHTNING_DIR = Path("/home/meshlink/.lightning")
DEFAULT_BITCOIN_DIR = Path("/home/meshlink/.bitcoin")


def _load_cluster(config_path: Path | None = None) -> dict[str, Any]:
    configured = os.environ.get("LNMESH_CLUSTER_CONFIG")
    candidates = [Path(configured)] if configured else []
    if config_path:
        candidates.append(Path(config_path))
    candidates.extend([SYSTEM_CONFIG_PATH, DEFAULT_CONFIG_PATH])

    last_error: Exception | None = None
    for path in candidates:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return _apply_mesh_profile(data)
        except FileNotFoundError as exc:
            last_error = exc
        except json.JSONDecodeError as exc:
            last_error = exc
            break
    raise RuntimeError(f"could not load OfflineMesh cluster config: {last_error}") from last_error


def _apply_mesh_profile(data: dict[str, Any]) -> dict[str, Any]:
    mesh = data.get("mesh") or {}
    profiles = mesh.get("profiles") or {}
    profile_name = os.environ.get("OFFLINEMESH_PROFILE") or mesh.get("profile")
    if profile_name and profile_name in profiles:
        merged = dict(mesh)
        merged.update(profiles[profile_name])
        merged["profile"] = profile_name
        merged["profiles"] = profiles
        data = dict(data)
        data["mesh"] = merged
    return data


CLUSTER = _load_cluster()
CHANNEL_STATE_PRIORITY = {
    "ONCHAIN": 1000,
    "CLOSINGD_COMPLETE": 950,
    "CLOSINGD_SIGEXCHANGE": 930,
    "CHANNELD_SHUTTING_DOWN": 920,
    "CHANNELD_NORMAL": 800,
    "CHANNELD_AWAITING_LOCKIN": 700,
    "DUALOPEND_AWAITING_LOCKIN": 600,
    "DUALOPEND_OPEN_COMMITTED": 500,
    "DUALOPEND_OPEN_COMMIT_READY": 400,
    "DUALOPEND_OPEN_INIT": 300,
}
ACTIONABLE_CHANNEL_PRIORITY = {
    "CHANNELD_NORMAL": 1000,
    "CHANNELD_AWAITING_LOCKIN": 950,
    "DUALOPEND_AWAITING_LOCKIN": 900,
    "DUALOPEND_OPEN_COMMITTED": 850,
    "DUALOPEND_OPEN_COMMIT_READY": 800,
    "DUALOPEND_OPEN_INIT": 750,
    "CHANNELD_SHUTTING_DOWN": 700,
    "CLOSINGD_SIGEXCHANGE": 650,
    "CLOSINGD_COMPLETE": 600,
    "ONCHAIN": 500,
}


def mesh_settings() -> dict[str, Any]:
    return CLUSTER["mesh"]


def lightning_settings() -> dict[str, Any]:
    return CLUSTER["lightning"]


def bitcoin_settings() -> dict[str, Any]:
    return CLUSTER.get("bitcoin", {})


def local_hostname() -> str:
    return socket.gethostname().split(".")[0]


def local_mesh_name() -> str:
    return os.environ.get("OFFLINEMESH_NODE_ID") or local_hostname()


def host_entry(name: str | None = None) -> dict[str, Any]:
    hosts = CLUSTER.get("hosts", {})
    host = name or local_mesh_name()
    if host not in hosts:
        raise KeyError(f"host {host!r} is not present in cluster config")
    return hosts[host]


def role_for(name: str | None = None) -> str:
    return host_entry(name)["role"]


def peer_id_for(name_or_id: str) -> str:
    if name_or_id in CLUSTER["hosts"]:
        peer_id = CLUSTER["hosts"][name_or_id].get("cln_id")
        if not peer_id:
            raise KeyError(f"host {name_or_id!r} has no cln_id yet; run gateway discovery/setup first")
        return peer_id
    return name_or_id


def name_for_peer_id(peer_id: str) -> str | None:
    for name, entry in CLUSTER["hosts"].items():
        if entry.get("cln_id") == peer_id:
            return name
    return None


def mesh_host(name_or_host: str) -> str:
    if "." in name_or_host:
        return name_or_host
    if name_or_host in CLUSTER["hosts"]:
        return f"{name_or_host}.{mesh_settings().get('domain', 'local.test')}"
    return name_or_host


def mesh_port() -> int:
    return int(lightning_settings()["bind_port"])


def gateway_host() -> str:
    return mesh_settings()["gateway_ip"]


def configured_mesh_ip(name_or_id: str) -> str | None:
    if name_or_id in CLUSTER["hosts"]:
        return CLUSTER["hosts"][name_or_id].get("mesh_ip")
    peer_name = name_for_peer_id(name_or_id)
    if peer_name:
        return CLUSTER["hosts"][peer_name].get("mesh_ip")
    return None


def _skip_dns_name(payload: bytes, offset: int) -> int:
    while True:
        length = payload[offset]
        if length & 0xC0 == 0xC0:
            return offset + 2
        if length == 0:
            return offset + 1
        offset += 1 + length


def _resolve_via_gateway_dns(target: str) -> str:
    labels = target.rstrip(".").split(".")
    question = b"".join(len(label).to_bytes(1, "big") + label.encode("ascii") for label in labels) + b"\x00"
    query_id = int.from_bytes(os.urandom(2), "big")
    packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + question + struct.pack("!HH", 1, 1)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2.0)
        sock.sendto(packet, (gateway_host(), 53))
        response, _ = sock.recvfrom(512)

    resp_id, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", response[:12])
    if resp_id != query_id or (flags & 0x000F) != 0:
        raise socket.gaierror(f"gateway DNS lookup failed for {target}")

    offset = 12
    for _ in range(qdcount):
        offset = _skip_dns_name(response, offset)
        offset += 4

    for _ in range(ancount):
        offset = _skip_dns_name(response, offset)
        rtype, rclass, _, rdlength = struct.unpack("!HHIH", response[offset:offset + 10])
        offset += 10
        rdata = response[offset:offset + rdlength]
        offset += rdlength
        if rtype == 1 and rclass == 1 and rdlength == 4:
            return socket.inet_ntoa(rdata)

    raise socket.gaierror(f"gateway DNS lookup returned no A record for {target}")


def _resolve_via_getent(target: str) -> str | None:
    try:
        lookup = subprocess.run(
            ["getent", "hosts", target],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None

    for line in lookup.stdout.splitlines():
        parts = line.split()
        if parts:
            return parts[0]
    return None


def resolve_mesh_host(name_or_host: str, port: int | None = None) -> str:
    peer_name = name_or_host if name_or_host in CLUSTER["hosts"] else name_for_peer_id(name_or_host)
    configured_ip = configured_mesh_ip(name_or_host)
    target = mesh_host(peer_name or name_or_host)
    if configured_ip and target.endswith(".local.test"):
        try:
            return _resolve_via_gateway_dns(target)
        except OSError:
            return configured_ip
    try:
        resolved = socket.getaddrinfo(target, port or 0, type=socket.SOCK_STREAM)
        return resolved[0][4][0]
    except socket.gaierror:
        lookup = _resolve_via_getent(target)
        if lookup:
            return lookup
        return _resolve_via_gateway_dns(target)


def encode_cli_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


def run(
    cmd: list[str],
    *,
    capture_json: bool = True,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> Any:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    proc = subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        env=merged_env,
    )
    if check and proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{detail}")
    if not capture_json:
        return proc.stdout.strip()
    if not proc.stdout.strip():
        return {}
    return parse_json_output(proc.stdout)


def parse_json_output(raw: str) -> Any:
    payload = raw.strip()
    if not payload:
        return {}

    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        pass

    lines = payload.splitlines()
    for index in range(len(lines)):
        candidate = "\n".join(lines[index:]).strip()
        if not candidate or candidate[0] not in "[{":
            continue
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    decoder = json.JSONDecoder()
    last_value: Any | None = None
    for index, char in enumerate(payload):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(payload[index:])
        except json.JSONDecodeError:
            continue
        last_value = value

    if last_value is not None:
        return last_value
    raise ValueError(f"Unable to parse JSON output: {payload}")


def cln_base_args(
    *,
    lightning_dir: Path | str = DEFAULT_LIGHTNING_DIR,
    network: str | None = None,
) -> list[str]:
    return [
        "lightning-cli",
        f"--lightning-dir={lightning_dir}",
        f"--network={network or lightning_settings()['network']}",
    ]


def cln(
    method: str,
    *positional: Any,
    lightning_dir: Path | str = DEFAULT_LIGHTNING_DIR,
    network: str | None = None,
    check: bool = True,
    capture_json: bool = True,
    **kwargs: Any,
) -> Any:
    cmd = cln_base_args(lightning_dir=lightning_dir, network=network)
    if kwargs:
        cmd.extend(["-k", method])
        for key, value in kwargs.items():
            cmd.append(f"{key}={encode_cli_value(value)}")
    else:
        cmd.append(method)
        cmd.extend(encode_cli_value(value) for value in positional)
    return run(cmd, capture_json=capture_json, check=check)


def bitcoin(
    *args: Any,
    datadir: Path | str = DEFAULT_BITCOIN_DIR,
    capture_json: bool = True,
    check: bool = True,
) -> Any:
    settings = bitcoin_settings()
    network = os.environ.get("OFFLINEMESH_BITCOIN_NETWORK") or settings.get("network") or "testnet4"
    cmd = ["bitcoin-cli", f"-{network}"]

    rpc_host = os.environ.get("OFFLINEMESH_BITCOIN_RPC_CONNECT") or settings.get("rpc_host")
    rpc_port = os.environ.get("OFFLINEMESH_BITCOIN_RPC_PORT") or settings.get("rpc_port")
    rpc_user = os.environ.get("OFFLINEMESH_BITCOIN_RPC_USER") or settings.get("rpc_user")
    rpc_password = os.environ.get("OFFLINEMESH_BITCOIN_RPC_PASSWORD")
    rpc_password_file = os.environ.get("OFFLINEMESH_BITCOIN_RPC_PASSWORD_FILE") or settings.get("rpc_password_file")

    if rpc_password is None and rpc_password_file:
        try:
            rpc_password = Path(rpc_password_file).read_text(encoding="utf-8").strip()
        except OSError:
            rpc_password = None

    if rpc_host:
        cmd.append(f"-rpcconnect={rpc_host}")
    if rpc_port:
        cmd.append(f"-rpcport={rpc_port}")
    if rpc_user:
        cmd.append(f"-rpcuser={rpc_user}")
    if rpc_password:
        cmd.append(f"-rpcpassword={rpc_password}")
    elif not rpc_host:
        cmd.append(f"-datadir={datadir}")

    cmd.extend(encode_cli_value(arg) for arg in args)
    return run(cmd, capture_json=capture_json, check=check)


def connected_peer(peer_id: str) -> dict[str, Any] | None:
    for peer in cln("listpeers", id=peer_id).get("peers", []):
        if peer.get("connected"):
            return peer
    return None


def already_connected_payload(peer_id: str, peer: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": peer_id,
        "connected": True,
        "already_connected": True,
        "peer": peer,
    }


def ensure_connected(peer: str, *, attempts: int = 5, retry_delay: float = 2.0) -> dict[str, Any]:
    peer_id = peer_id_for(peer)
    current_peer = connected_peer(peer_id)
    if current_peer:
        return already_connected_payload(peer_id, current_peer)

    peer_name = name_for_peer_id(peer_id) or peer
    peer_host = resolve_mesh_host(peer_name, mesh_port())
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return cln(
                "connect",
                id=peer_id,
                host=peer_host,
                port=mesh_port(),
            )
        except RuntimeError as exc:
            last_error = exc
            current_peer = connected_peer(peer_id)
            if current_peer:
                return already_connected_payload(peer_id, current_peer)
            if attempt < attempts:
                time.sleep(retry_delay)

    if last_error:
        raise last_error
    raise RuntimeError(f"Unable to connect to peer {peer}")


def list_peerchannels(peer: str | None = None) -> list[dict[str, Any]]:
    response = cln("listpeerchannels", id=peer_id_for(peer) if peer else None) if peer else cln("listpeerchannels")
    return response.get("channels", [])


def _channel_timestamp(channel: dict[str, Any]) -> int:
    state_changes = channel.get("state_changes") or []
    if not state_changes:
        return -1
    raw_timestamp = state_changes[-1].get("timestamp")
    try:
        return int(raw_timestamp)
    except (TypeError, ValueError):
        pass
    if not isinstance(raw_timestamp, str):
        return -1
    try:
        return int(datetime.fromisoformat(raw_timestamp.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return -1


def _channel_sort_key(
    channel: dict[str, Any],
    *,
    priority_map: dict[str, int] | None = None,
) -> tuple[int, int, str]:
    state = channel.get("state") or ""
    priorities = priority_map or CHANNEL_STATE_PRIORITY
    return (
        priorities.get(state, 0),
        _channel_timestamp(channel),
        channel.get("channel_id", ""),
    )


def _channel_has_lifecycle_evidence(channel: dict[str, Any]) -> bool:
    if channel.get("state_changes"):
        return True
    if channel.get("short_channel_id"):
        return True
    if channel.get("last_stable_connection"):
        return True
    if channel.get("in_payments_offered") or channel.get("out_payments_offered"):
        return True
    if channel.get("in_payments_fulfilled") or channel.get("out_payments_fulfilled"):
        return True
    return False


def _is_low_confidence_open(channel: dict[str, Any]) -> bool:
    if (channel.get("state") or "") != "DUALOPEND_OPEN_COMMITTED":
        return False
    return not _channel_has_lifecycle_evidence(channel)


def first_channel(
    peer: str,
    *,
    states: set[str] | None = None,
    channel_id: str | None = None,
) -> dict[str, Any] | None:
    channels = list_peerchannels(peer)
    if channel_id:
        channels = [channel for channel in channels if channel.get("channel_id") == channel_id]
    if states:
        channels = [channel for channel in channels if channel.get("state") in states]
    if not channels:
        return None
    return sorted(channels, key=_channel_sort_key, reverse=True)[0]


def preferred_channel(
    peer: str,
    *,
    states: set[str] | None = None,
    channel_id: str | None = None,
) -> dict[str, Any] | None:
    channels = list_peerchannels(peer)
    if channel_id:
        channels = [channel for channel in channels if channel.get("channel_id") == channel_id]
    if states:
        channels = [channel for channel in channels if channel.get("state") in states]
    if not channels:
        return None
    actionable = [
        channel for channel in channels if (channel.get("state") or "") in ACTIONABLE_CHANNEL_PRIORITY
    ]
    pool = actionable or channels
    evidence_pool = [channel for channel in pool if _channel_has_lifecycle_evidence(channel)]
    if evidence_pool and any(_is_low_confidence_open(channel) for channel in pool):
        pool = [channel for channel in pool if not _is_low_confidence_open(channel)] or evidence_pool

    def sort_key(channel: dict[str, Any]) -> tuple[int, int, int, int, str]:
        timestamp = _channel_timestamp(channel)
        state = channel.get("state") or ""
        return (
            1 if _channel_has_lifecycle_evidence(channel) else 0,
            1 if timestamp >= 0 else 0,
            timestamp,
            ACTIONABLE_CHANNEL_PRIORITY.get(state, 0),
            channel.get("channel_id", ""),
        )

    return sorted(
        pool,
        key=sort_key,
        reverse=True,
    )[0]


def channel_state(
    peer: str,
    *,
    channel_id: str | None = None,
    actionable: bool = False,
) -> str | None:
    channel = preferred_channel(peer, channel_id=channel_id) if actionable else first_channel(peer, channel_id=channel_id)
    return channel.get("state") if channel else None


def wait_for(
    description: str,
    predicate: Callable[[], Any],
    *,
    timeout: int = 300,
    interval: float = 2.0,
) -> Any:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except Exception as exc:  # pragma: no cover - runtime-only helper
            last_error = exc
        time.sleep(interval)
    if last_error:
        raise TimeoutError(f"timed out waiting for {description}: {last_error}") from last_error
    raise TimeoutError(f"timed out waiting for {description}")


def wait_for_channel_state(
    peer: str,
    states: set[str],
    *,
    timeout: int = 600,
    channel_id: str | None = None,
) -> dict[str, Any]:
    peer_id = peer_id_for(peer)

    def predicate() -> dict[str, Any] | None:
        return first_channel(peer_id, states=states, channel_id=channel_id)

    return wait_for(f"channel state in {sorted(states)}", predicate, timeout=timeout, interval=5.0)


def wait_for_funds(*, timeout: int = 3600) -> dict[str, Any]:
    def predicate() -> dict[str, Any] | None:
        result = cln("listfunds")
        return result if result.get("outputs") else None

    return wait_for("wallet funds", predicate, timeout=timeout, interval=10.0)


def wait_for_cln_sync(*, timeout: int = 3600, max_lag: int = 2) -> dict[str, Any]:
    def predicate() -> dict[str, Any] | None:
        info = cln("getinfo")
        blockheight = int(info.get("blockheight") or 0)
        chain_height = 0
        try:
            chain_height = int(bitcoin("getblockcount", capture_json=False))
        except Exception:
            chain_height = blockheight
        warning_keys = [key for key in info if key.startswith("warning_")]
        lag = chain_height - blockheight
        if lag <= max_lag and "warning_lightningd_sync" not in warning_keys:
            return {"cln": info, "chain_height": chain_height, "lag": lag}
        return None

    return wait_for("CLN to catch up to Bitcoin Core", predicate, timeout=timeout, interval=10.0)


def print_json(payload: Any) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))


def _cmd_local_info(_: argparse.Namespace) -> None:
    role = role_for()
    cln_info = cln("getinfo")
    actual_mesh_ip = host_entry().get("mesh_ip")
    for key in ("binding", "address"):
        entries = cln_info.get(key) or []
        if entries:
            actual_mesh_ip = entries[0].get("address", actual_mesh_ip)
            break
    payload = {
        "hostname": local_hostname(),
        "mesh_name": local_mesh_name(),
        "role": role,
        "mesh_ip": actual_mesh_ip,
        "cln": cln_info,
    }
    print_json(payload)


def _cmd_wait_funds(args: argparse.Namespace) -> None:
    print_json(wait_for_funds(timeout=args.timeout))


def _cmd_wait_sync(args: argparse.Namespace) -> None:
    print_json(wait_for_cln_sync(timeout=args.timeout, max_lag=args.max_lag))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Shared OfflineMesh helpers.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    local_info = subparsers.add_parser("local-info", help="Print local role and CLN info.")
    local_info.set_defaults(func=_cmd_local_info)

    wait_funds = subparsers.add_parser("wait-funds", help="Wait until CLN sees confirmed or unconfirmed funds.")
    wait_funds.add_argument("--timeout", type=int, default=3600)
    wait_funds.set_defaults(func=_cmd_wait_funds)

    wait_sync = subparsers.add_parser("wait-sync", help="Wait until local CLN is caught up to Bitcoin Core.")
    wait_sync.add_argument("--timeout", type=int, default=3600)
    wait_sync.add_argument("--max-lag", type=int, default=2)
    wait_sync.set_defaults(func=_cmd_wait_sync)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
