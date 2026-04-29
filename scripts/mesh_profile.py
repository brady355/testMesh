#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "cluster.json"
SYSTEM_CONFIG = Path("/etc/offlinemesh/cluster.json")
ENV_FILE = Path("/etc/offlinemesh/env")


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def save_config(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    tmp.replace(path)


def apply_profile(data: dict[str, Any], profile: str) -> dict[str, Any]:
    mesh = data.setdefault("mesh", {})
    profiles = mesh.setdefault("profiles", {})
    if profile not in profiles:
        raise SystemExit(f"unknown profile {profile!r}; known profiles: {', '.join(sorted(profiles))}")
    merged = dict(mesh)
    merged.update(profiles[profile])
    merged["profile"] = profile
    merged["profiles"] = profiles
    data["mesh"] = merged

    gateway_name = merged.get("gateway_name", "gateway01")
    gateway = data.setdefault("hosts", {}).setdefault(gateway_name, {"role": "gateway"})
    gateway["role"] = "gateway"
    gateway["mesh_ip"] = mesh_value(data, "gateway_ip")
    data.setdefault("bitcoin", {})["rpc_host"] = mesh_value(data, "gateway_ip")
    if data.get("watchtower"):
        data["watchtower"]["api_host"] = mesh_value(data, "gateway_ip")
    return data


def mesh_value(data: dict[str, Any], key: str) -> Any:
    return data.get("mesh", {}).get(key)


def validate_profile(data: dict[str, Any], profile: str) -> None:
    profile_data = data.get("mesh", {}).get("profiles", {}).get(profile)
    if not isinstance(profile_data, dict):
        raise SystemExit(f"profile {profile!r} is not defined")
    subnet = ipaddress.ip_network(profile_data["subnet"], strict=False)
    gateway_ip = ipaddress.ip_address(profile_data["gateway_ip"])
    dhcp_start = ipaddress.ip_address(profile_data["dhcp_start"])
    dhcp_end = ipaddress.ip_address(profile_data["dhcp_end"])
    for label, value in (("gateway_ip", gateway_ip), ("dhcp_start", dhcp_start), ("dhcp_end", dhcp_end)):
        if value not in subnet:
            raise SystemExit(f"{label}={value} is outside subnet {subnet}")
    if int(dhcp_start) > int(dhcp_end):
        raise SystemExit("dhcp_start must be less than or equal to dhcp_end")


def active_network(data: dict[str, Any]) -> ipaddress.IPv4Network | ipaddress.IPv6Network:
    return ipaddress.ip_network(data["mesh"]["subnet"], strict=False)


def current_role() -> str:
    if not ENV_FILE.exists():
        return ""
    for line in ENV_FILE.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("OFFLINEMESH_ROLE="):
            return line.split("=", 1)[1].strip()
    return ""


def write_env_patch(data: dict[str, Any]) -> None:
    if not ENV_FILE.exists():
        return
    mesh = data["mesh"]
    network = active_network(data)
    replacements = {
        "OFFLINEMESH_PROFILE": mesh["profile"],
        "OFFLINEMESH_ESSID": mesh["essid"],
        "OFFLINEMESH_CHANNEL": str(mesh["channel"]),
        "OFFLINEMESH_WIFI_FREQ": str(mesh["wifi_freq"]),
        "OFFLINEMESH_SUBNET": mesh["subnet"],
        "OFFLINEMESH_GATEWAY_CIDR": f"{mesh['gateway_ip']}/{network.prefixlen}",
        "OFFLINEMESH_DHCP_START": mesh["dhcp_start"],
        "OFFLINEMESH_DHCP_END": mesh["dhcp_end"],
        "OFFLINEMESH_DOMAIN": mesh["domain"],
        "OFFLINEMESH_GATEWAY_IP": mesh["gateway_ip"],
        "OFFLINEMESH_GATEWAY_HOST": mesh["gateway_ip"],
        "OFFLINEMESH_BITCOIN_RPC_CONNECT": mesh["gateway_ip"],
        "OFFLINEMESH_WATCHTOWER_API_HOST": mesh["gateway_ip"],
    }
    lines = ENV_FILE.read_text(encoding="utf-8").splitlines()
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        if "=" not in line or line.startswith("#"):
            output.append(line)
            continue
        key, _ = line.split("=", 1)
        if key in replacements:
            output.append(f"{key}={replacements[key]}")
            seen.add(key)
        else:
            output.append(line)
    for key, value in replacements.items():
        if key not in seen:
            output.append(f"{key}={value}")
    ENV_FILE.write_text("\n".join(output) + "\n", encoding="utf-8")


def write_dnsmasq_patch(data: dict[str, Any]) -> None:
    if current_role() == "node":
        return
    dnsmasq_conf = Path("/etc/dnsmasq.conf")
    if not dnsmasq_conf.exists():
        return
    mesh = data["mesh"]
    network = active_network(data)
    text = f"""interface={mesh.get("bat_iface", "bat0")}
domain-needed
local=/{mesh["domain"]}/
domain={mesh["domain"]}
expand-hosts
dhcp-range={mesh["dhcp_start"]},{mesh["dhcp_end"]},{network.netmask},12h
dhcp-option=option:router,{mesh["gateway_ip"]}
dhcp-option=option:dns-server,{mesh["gateway_ip"]}
no-resolv
server=8.8.8.8
server=8.8.4.4
"""
    dnsmasq_conf.write_text(text, encoding="utf-8")


def run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def restart_services() -> None:
    if os.geteuid() != 0:
        print("Profile saved. Re-run the explicit gateway/node mesh setup script or restart services as root to apply runtime changes.", file=sys.stderr)
        return
    role = current_role()
    services = ["batman-adv.service", "lightningd.service"]
    if role == "gateway":
        services.extend(["dnsmasq.service", "lnmesh-watchtower.service", "lnmesh-watchtower-info.service"])
    elif role == "node":
        services.extend(["mesh-dhcp.service", "lnmesh-watchtower-register.service"])
    else:
        services.extend(["dnsmasq.service", "mesh-dhcp.service", "lnmesh-watchtower.service", "lnmesh-watchtower-info.service", "lnmesh-watchtower-register.service"])
    for service in services:
        run(["systemctl", "try-restart", service])


def cmd_list(args: argparse.Namespace) -> None:
    data = load_config(args.config)
    active = data.get("mesh", {}).get("profile")
    for name, profile in sorted((data.get("mesh", {}).get("profiles") or {}).items()):
        marker = "*" if name == active else " "
        print(f"{marker} {name}: essid={profile.get('essid')} channel={profile.get('channel')} subnet={profile.get('subnet')}")


def cmd_set(args: argparse.Namespace) -> None:
    data = load_config(args.config)
    validate_profile(data, args.profile)
    data = apply_profile(data, args.profile)
    save_config(args.config, data)
    if args.system:
        if os.geteuid() != 0:
            raise SystemExit("--system requires root")
        if args.config != SYSTEM_CONFIG:
            save_config(SYSTEM_CONFIG, data)
        write_env_patch(data)
        write_dnsmasq_patch(data)
    if args.restart:
        restart_services()
    print(json.dumps({"profile": args.profile, "mesh": data["mesh"]}, indent=2, sort_keys=True))


def cmd_add(args: argparse.Namespace) -> None:
    data = load_config(args.config)
    subnet = ipaddress.ip_network(args.subnet, strict=False)
    gateway_ip = ipaddress.ip_address(args.gateway_ip)
    if gateway_ip not in subnet:
        raise SystemExit("gateway IP must be inside subnet")
    profile = {
        "essid": args.essid,
        "channel": args.channel,
        "wifi_freq": args.wifi_freq,
        "subnet": str(subnet),
        "gateway_ip": str(gateway_ip),
        "dhcp_start": args.dhcp_start,
        "dhcp_end": args.dhcp_end,
        "domain": args.domain,
    }
    data.setdefault("mesh", {}).setdefault("profiles", {})[args.name] = profile
    validate_profile(data, args.name)
    save_config(args.config, data)
    print(json.dumps({"added": args.name, "profile": profile}, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage OfflineMesh full mesh profiles.")
    parser.add_argument("--config", type=Path, default=SYSTEM_CONFIG if SYSTEM_CONFIG.exists() else DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)

    list_cmd = sub.add_parser("list", help="List configured mesh profiles.")
    list_cmd.set_defaults(func=cmd_list)

    set_cmd = sub.add_parser("set", help="Select and apply a mesh profile.")
    set_cmd.add_argument("profile")
    set_cmd.add_argument("--system", action="store_true", help="Also write /etc/offlinemesh/cluster.json and env.")
    set_cmd.add_argument("--restart", action="store_true", help="Try to restart mesh/CLN services after saving.")
    set_cmd.set_defaults(func=cmd_set)

    add_cmd = sub.add_parser("add", help="Add a full mesh profile.")
    add_cmd.add_argument("name")
    add_cmd.add_argument("--essid", required=True)
    add_cmd.add_argument("--channel", type=int, required=True)
    add_cmd.add_argument("--wifi-freq", type=int, required=True)
    add_cmd.add_argument("--subnet", required=True)
    add_cmd.add_argument("--gateway-ip", required=True)
    add_cmd.add_argument("--dhcp-start", required=True)
    add_cmd.add_argument("--dhcp-end", required=True)
    add_cmd.add_argument("--domain", required=True)
    add_cmd.set_defaults(func=cmd_add)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
