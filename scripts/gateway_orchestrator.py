#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import posixpath
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "cluster.json"
SYSTEM_CONFIG = Path("/etc/offlinemesh/cluster.json")
STATE_DIR = Path("/var/lib/offlinemesh")
STATE_FILE = STATE_DIR / "gateway-state.json"
GENERATED_CLUSTER = STATE_DIR / "cluster.generated.json"
FUNDING_REQUEST = STATE_DIR / "funding-request.json"
DEMO_STATE = STATE_DIR / "demo-state.json"
FUNDING_WALLET = ROOT / "config" / "funding_wallet.json"
REMOTE_ROOT = Path("/opt/offlinemesh")
DEFAULT_USER = "meshlink"
DEFAULT_PASSWORD = "1111"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def log(message: str) -> None:
    print(f"[gateway] {message}", flush=True)


def run(
    cmd: list[str],
    *,
    check: bool = True,
    capture: bool = True,
    input_text: str | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        check=False,
        capture_output=capture,
        text=True,
        input=input_text,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        detail = ""
        if capture:
            detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{detail}")
    return proc


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def apply_mesh_profile(config: dict[str, Any]) -> dict[str, Any]:
    mesh = config.get("mesh", {})
    profile = os.environ.get("OFFLINEMESH_PROFILE") or mesh.get("profile")
    profiles = mesh.get("profiles") or {}
    if profile in profiles:
        merged = dict(mesh)
        merged.update(profiles[profile])
        merged["profile"] = profile
        merged["profiles"] = profiles
        config = dict(config)
        config["mesh"] = merged
    return config


def load_config() -> dict[str, Any]:
    path = SYSTEM_CONFIG if SYSTEM_CONFIG.exists() else DEFAULT_CONFIG
    return apply_mesh_profile(json.loads(path.read_text(encoding="utf-8")))


def strip_json(raw: str) -> Any:
    raw = raw.strip()
    if not raw:
        return {}
    decoder = json.JSONDecoder()
    for index, char in enumerate(raw):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(raw[index:])
            return value
        except json.JSONDecodeError:
            continue
    raise ValueError(f"unable to parse JSON from output: {raw}")


def sat_to_btc(amount_sat: int) -> str:
    return format(Decimal(amount_sat) / Decimal(100_000_000), "f")


def windows_command_hints(wallet_config: dict[str, Any], requests: list[dict[str, Any]], network: str) -> list[str]:
    main_machine = wallet_config.get("main_machine") if isinstance(wallet_config.get("main_machine"), dict) else {}
    bitcoin_cli = main_machine.get("bitcoin_cli", "bitcoin-cli")
    datadir = main_machine.get("datadir")
    wallet_name = wallet_config.get("wallet_name")
    hints: list[str] = []
    for request in requests:
        address = request.get("address") or "<address>"
        amount_btc = request.get("amount_btc") or sat_to_btc(int(request.get("amount_sat") or 0))
        parts = [f'"{bitcoin_cli}"', f"-{network}"]
        if datadir:
            parts.append(f'-datadir="{datadir}"')
        if wallet_name:
            parts.append(f"-rpcwallet={wallet_name}")
        parts.extend(["-named", "sendtoaddress", f"address={address}", f"amount={amount_btc}"])
        hints.append(" ".join(parts))
    return hints


@dataclass
class Node:
    hostname: str
    ip: str
    mac: str = ""
    system_hostname: str = ""
    ssh_ok: bool = False
    cln_id: str = ""
    installed: bool = False
    last_seen: str = ""


def node_from_payload(payload: dict[str, Any]) -> Node:
    return Node(
        hostname=str(payload.get("hostname") or ""),
        ip=str(payload.get("ip") or ""),
        mac=str(payload.get("mac") or ""),
        system_hostname=str(payload.get("system_hostname") or ""),
        ssh_ok=bool(payload.get("ssh_ok")),
        cln_id=str(payload.get("cln_id") or ""),
        installed=bool(payload.get("installed")),
        last_seen=str(payload.get("last_seen") or ""),
    )


class Gateway:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.config = load_config()
        self.mesh = self.config["mesh"]
        self.user = args.user
        self.password = args.password
        self.bat_iface = self.mesh.get("bat_iface", "bat0")
        self.gateway_name = self.mesh.get("gateway_name", "gateway01")
        self.node_name_prefix = self.mesh.get("node_name_prefix", "node")
        self.node_name_digits = int(self.mesh.get("node_name_digits", 2))
        self.gateway_ip = self.mesh.get("gateway_ip", "192.168.199.1")
        self.domain = self.mesh.get("domain", "local.test")
        self.state = load_json(STATE_FILE, {"nodes": {}, "history": []})
        ssh_dir = Path(f"/home/{self.user}/.ssh")
        ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        if os.geteuid() == 0:
            run(["chown", f"{self.user}:{self.user}", str(ssh_dir)], check=False)

    def ssh_base(self, target: str) -> list[str]:
        ssh = [
            "ssh",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"UserKnownHostsFile=/home/{self.user}/.ssh/known_hosts",
            "-o",
            "ConnectTimeout=8",
        ]
        if shutil.which("sshpass"):
            ssh = ["sshpass", "-p", self.password] + ssh
        ssh.append(f"{self.user}@{target}")
        return ssh

    def scp_base(self) -> list[str]:
        scp = [
            "scp",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"UserKnownHostsFile=/home/{self.user}/.ssh/known_hosts",
            "-o",
            "ConnectTimeout=8",
            "-r",
        ]
        if shutil.which("sshpass"):
            scp = ["sshpass", "-p", self.password] + scp
        return scp

    def ssh(self, target: str, command: str, *, check: bool = True, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
        return run(self.ssh_base(target) + [command], check=check, timeout=timeout)

    def sudo(self, target: str, command: str, *, check: bool = True, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
        quoted = shlex.quote(command)
        remote = f"printf '%s\\n' {shlex.quote(self.password)} | sudo -S bash -lc {quoted}"
        return self.ssh(target, remote, check=check, timeout=timeout)

    def local_sudo(self, command: str, *, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            return run(["bash", "-lc", command], timeout=timeout)
        return run(["sudo", "bash", "-lc", command], timeout=timeout)

    def record_history(self, event: str, payload: dict[str, Any]) -> None:
        self.state.setdefault("history", []).append({"event": event, "at": now_iso(), **payload})
        save_json(STATE_FILE, self.state)

    def dnsmasq_leases(self) -> list[dict[str, str]]:
        leases: list[dict[str, str]] = []
        for path in (Path("/var/lib/misc/dnsmasq.leases"), Path("/var/lib/dnsmasq/dnsmasq.leases")):
            if not path.exists():
                continue
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                parts = line.split()
                if len(parts) < 4:
                    continue
                _, mac, ip, hostname = parts[:4]
                if ip == self.gateway_ip:
                    continue
                leases.append(
                    {
                        "ip": ip,
                        "mac": mac,
                        "system_hostname": "" if hostname == "*" else hostname,
                    }
                )
        return leases

    def ip_neigh_candidates(self) -> dict[str, str]:
        proc = run(["ip", "neigh", "show", "dev", self.bat_iface], check=False)
        candidates: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            parts = line.split()
            if not parts:
                continue
            ip = parts[0]
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                return
            mac = ""
            if "lladdr" in parts:
                idx = parts.index("lladdr")
                if idx + 1 < len(parts):
                    mac = parts[idx + 1]
            candidates[ip] = mac
        return candidates

    def batctl_macs(self) -> set[str]:
        if not shutil.which("batctl"):
            return set()
        proc = run(["batctl", "originators"], check=False)
        macs: set[str] = set()
        for line in proc.stdout.splitlines():
            for match in re.findall(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", line):
                macs.add(match.lower())
        return macs

    def state_nodes(self) -> list[Node]:
        return [node_from_payload(payload) for payload in (self.state.get("nodes") or {}).values()]

    def next_node_name(self, reserved: set[str]) -> str:
        index = 1
        while True:
            name = f"{self.node_name_prefix}{index:0{self.node_name_digits}d}"
            if name not in reserved:
                reserved.add(name)
                return name
            index += 1

    def probe_system_hostname(self, ip: str) -> str:
        try:
            host = socket.gethostbyaddr(ip)[0].split(".")[0]
            if host:
                return host
        except OSError:
            pass
        proc = self.ssh(ip, "hostname -s", check=False)
        if proc.returncode == 0:
            host = proc.stdout.strip().splitlines()[-1].strip()
            if host:
                return host
        return ""

    def probe_ssh(self, node: Node) -> Node:
        proc = self.ssh(node.ip, "hostname -s", check=False)
        node.ssh_ok = proc.returncode == 0
        if node.ssh_ok:
            reported = proc.stdout.strip().splitlines()[-1].strip()
            if reported:
                node.system_hostname = reported
        node.last_seen = now_iso()
        return node

    def discover_nodes(self) -> list[Node]:
        known = {node.hostname: node for node in self.state_nodes() if node.hostname}
        reserved = set(known)
        by_mac = {node.mac.lower(): node for node in known.values() if node.mac}
        by_ip = {node.ip: node for node in known.values() if node.ip}
        by_system_hostname = {
            key: node
            for node in known.values()
            for key in {node.system_hostname, node.hostname}
            if key
        }
        candidates: dict[str, dict[str, str]] = {}

        def add_candidate(ip: str, mac: str = "", system_hostname: str = "") -> None:
            if ip == self.gateway_ip:
                return
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                return
            entry = candidates.setdefault(ip, {"ip": ip, "mac": "", "system_hostname": ""})
            if mac:
                entry["mac"] = mac
            if system_hostname:
                entry["system_hostname"] = system_hostname

        for lease in self.dnsmasq_leases():
            add_candidate(lease["ip"], lease.get("mac", ""), lease.get("system_hostname", ""))
        for ip, mac in self.ip_neigh_candidates().items():
            add_candidate(ip, mac)

        discovered: list[Node] = []
        discovered_by_name: dict[str, Node] = {}
        for candidate in sorted(candidates.values(), key=lambda item: ipaddress.ip_address(item["ip"])):
            ip = candidate["ip"]
            mac = candidate.get("mac", "")
            mac_key = mac.lower()
            system_hostname = candidate.get("system_hostname", "")
            if not system_hostname:
                system_hostname = self.probe_system_hostname(ip)
            node = known.get(system_hostname) if system_hostname in known else None
            if node is None and system_hostname:
                node = by_system_hostname.get(system_hostname)
            if node is None:
                node = by_mac.get(mac_key) if mac_key else None
            if node is None:
                ip_match = by_ip.get(ip)
                if ip_match and (not ip_match.mac or not mac):
                    node = ip_match
            if node is None and not system_hostname:
                log(f"mesh neighbor at {ip} has no reachable SSH hostname yet; skipping")
                continue
            if node is None:
                node = Node(hostname=self.next_node_name(reserved), ip=ip, mac=mac, last_seen=now_iso())
                known[node.hostname] = node
                by_system_hostname[node.hostname] = node
            candidate_node = Node(
                hostname=node.hostname,
                ip=ip,
                mac=node.mac,
                system_hostname=node.system_hostname,
                ssh_ok=node.ssh_ok,
                cln_id=node.cln_id,
                installed=node.installed,
                last_seen=node.last_seen,
            )
            if mac:
                candidate_node.mac = mac
            if system_hostname:
                candidate_node.system_hostname = system_hostname
            self.probe_ssh(candidate_node)
            if not candidate_node.ssh_ok and not candidate_node.system_hostname:
                log(f"mesh neighbor at {ip} has no reachable SSH hostname yet; skipping")
                continue
            previous = discovered_by_name.get(candidate_node.hostname)
            if previous is None or (candidate_node.ssh_ok and not previous.ssh_ok):
                discovered_by_name[candidate_node.hostname] = candidate_node
                known[candidate_node.hostname] = candidate_node
                if candidate_node.system_hostname:
                    by_system_hostname[candidate_node.system_hostname] = candidate_node

        discovered = sorted(discovered_by_name.values(), key=lambda n: n.hostname)
        self.state["nodes"] = {node.hostname: asdict(node) for node in discovered}
        save_json(STATE_FILE, self.state)
        return discovered

    def copy_payload(self, node: Node) -> None:
        remote_tmp = f"/home/{self.user}/offlinemesh-upload"
        self.ssh(node.ip, f"rm -rf {shlex.quote(remote_tmp)} && mkdir -p {shlex.quote(remote_tmp)}")
        entries = [str(path) for path in ROOT.iterdir() if path.name not in {".git", "state", "sources"}]
        run(self.scp_base() + entries + [f"{self.user}@{node.ip}:{remote_tmp}/"], timeout=1800)
        self.sudo(
            node.ip,
            f"rm -rf {REMOTE_ROOT} && mkdir -p {REMOTE_ROOT} && cp -a {remote_tmp}/. {REMOTE_ROOT}/ && chown -R {self.user}:{self.user} {REMOTE_ROOT}",
            timeout=600,
        )

    def copy_rpc_secret(self, node: Node) -> None:
        secret = Path("/etc/offlinemesh/bitcoin-rpc-password")
        if not secret.exists():
            raise RuntimeError("gateway RPC password is missing; run install-gateway first")
        remote_secret = f"/home/{self.user}/bitcoin-rpc-password"
        run(self.scp_base() + [str(secret), f"{self.user}@{node.ip}:{remote_secret}"])
        self.sudo(
            node.ip,
            f"mkdir -p /etc/offlinemesh && install -o root -g {self.user} -m 0640 {remote_secret} /etc/offlinemesh/bitcoin-rpc-password && rm -f {remote_secret}",
        )

    def install_gateway(self) -> None:
        log("installing gateway stack")
        self.local_sudo(f"bash {shlex.quote(str(ROOT / 'scripts' / 'install_stack.sh'))} gateway", timeout=7200)
        self.refresh_gateway_cln_id()
        self.record_history("install-gateway", {"status": "ok"})

    def install_nodes(self, nodes: list[Node], *, force: bool = False) -> list[Node]:
        installed: list[Node] = []
        for node in nodes:
            if not node.ssh_ok:
                log(f"skipping {node.hostname} ({node.ip}); SSH not reachable")
                continue
            if node.installed and not force:
                log(f"skipping {node.hostname} ({node.ip}); already installed")
                continue
            log(f"installing {node.hostname} at {node.ip}")
            self.copy_payload(node)
            self.copy_rpc_secret(node)
            self.sudo(
                node.ip,
                f"OFFLINEMESH_NODE_ID={shlex.quote(node.hostname)} bash {REMOTE_ROOT}/scripts/install_stack.sh node",
                timeout=7200,
            )
            node.installed = True
            try:
                node.cln_id = self.remote_cln_id(node)
            except Exception as exc:
                log(f"could not collect CLN id for {node.hostname}: {exc}")
            installed.append(node)
            self.state.setdefault("nodes", {})[node.hostname] = asdict(node)
            save_json(STATE_FILE, self.state)
        self.generate_cluster(nodes)
        self.distribute_cluster(nodes)
        self.record_history("install-nodes", {"nodes": [node.hostname for node in installed]})
        return installed

    def refresh_gateway_cln_id(self) -> None:
        try:
            proc = run(["lightning-cli", f"--lightning-dir=/home/{self.user}/.lightning", "--network", self.config["lightning"]["network"], "getinfo"], check=False)
            if proc.returncode == 0:
                info = strip_json(proc.stdout)
                self.config.setdefault("hosts", {}).setdefault(self.gateway_name, {"role": "gateway"})["cln_id"] = info.get("id", "")
        except Exception:
            pass

    def remote_cln_id(self, node: Node) -> str:
        proc = self.ssh(
            node.ip,
            f"lightning-cli --lightning-dir=/home/{self.user}/.lightning --network={self.config['lightning']['network']} getinfo",
            timeout=60,
        )
        return strip_json(proc.stdout)["id"]

    def collect_ids(self, nodes: list[Node], distribute: bool) -> list[Node]:
        collected: list[Node] = []
        self.refresh_gateway_cln_id()
        for node in nodes:
            if not node.ssh_ok:
                node = self.probe_ssh(node)
            if not node.ssh_ok:
                log(f"skipping CLN id collection for {node.hostname}; SSH not reachable")
                continue
            try:
                node.cln_id = self.remote_cln_id(node)
                node.last_seen = now_iso()
                collected.append(node)
                self.state.setdefault("nodes", {})[node.hostname] = asdict(node)
            except Exception as exc:
                log(f"could not collect CLN id for {node.hostname}: {exc}")
        save_json(STATE_FILE, self.state)
        self.generate_cluster(collected)
        if distribute:
            self.distribute_cluster(collected)
        print(json.dumps([asdict(node) for node in collected], indent=2, sort_keys=True))
        return collected

    def generate_cluster(self, nodes: list[Node]) -> dict[str, Any]:
        data = load_config()
        hosts = data.setdefault("hosts", {})
        gateway = hosts.setdefault(self.gateway_name, {"role": "gateway"})
        gateway["role"] = "gateway"
        gateway["mesh_ip"] = self.gateway_ip
        for node in nodes:
            entry = hosts.setdefault(node.hostname, {})
            entry.update(
                {
                    "role": "node",
                    "mesh_ip": node.ip,
                    "wlan_mac": node.mac,
                    "system_hostname": node.system_hostname,
                    "cln_id": node.cln_id,
                }
            )
        save_json(GENERATED_CLUSTER, data)
        save_json(SYSTEM_CONFIG, data)
        self.config = data
        return data

    def distribute_cluster(self, nodes: list[Node]) -> None:
        for node in nodes:
            if not node.ssh_ok:
                continue
            remote_cluster = f"/home/{self.user}/cluster.generated.json"
            run(self.scp_base() + [str(GENERATED_CLUSTER), f"{self.user}@{node.ip}:{remote_cluster}"])
            env_patch = (
                "if grep -q '^OFFLINEMESH_NODE_ID=' /etc/offlinemesh/env; then "
                f"sed -i {shlex.quote(f's/^OFFLINEMESH_NODE_ID=.*/OFFLINEMESH_NODE_ID={node.hostname}/')} /etc/offlinemesh/env; "
                "else "
                f"printf '\\nOFFLINEMESH_NODE_ID=%s\\n' {shlex.quote(node.hostname)} >> /etc/offlinemesh/env; "
                "fi"
            )
            self.sudo(
                node.ip,
                f"install -o root -g root -m 0644 {remote_cluster} /etc/offlinemesh/cluster.json && cp -a {remote_cluster} {REMOTE_ROOT}/config/cluster.json && chown {self.user}:{self.user} {REMOTE_ROOT}/config/cluster.json && {env_patch} && systemctl restart lightningd.service && systemctl restart lnmesh-watchtower-register.service || true",
                timeout=300,
            )

    def verify(self, nodes: list[Node]) -> None:
        log("verifying gateway")
        self.local_sudo(f"bash {shlex.quote(str(ROOT / 'scripts' / 'verify_cycle.sh'))}", timeout=600)
        for node in nodes:
            if not node.ssh_ok:
                continue
            log(f"verifying {node.hostname}")
            self.sudo(node.ip, f"bash {REMOTE_ROOT}/scripts/verify_cycle.sh", timeout=600)

    def funding_request(self, nodes: list[Node], amount_sat: int, names: list[str]) -> dict[str, Any]:
        selected = [node for node in nodes if not names or node.hostname in names]
        requests = []
        for node in selected:
            proc = self.ssh(
                node.ip,
                f"lightning-cli --lightning-dir=/home/{self.user}/.lightning --network={self.config['lightning']['network']} newaddr bech32",
                timeout=60,
            )
            payload = strip_json(proc.stdout)
            requests.append(
                {
                    "node": node.hostname,
                    "mesh_ip": node.ip,
                    "cln_id": node.cln_id,
                    "address": payload.get("bech32") or payload.get("p2tr"),
                    "amount_sat": amount_sat,
                    "amount_btc": sat_to_btc(amount_sat),
                }
            )
        wallet_config = load_json(FUNDING_WALLET, {})
        network = wallet_config.get("network") or self.config["lightning"]["network"]
        output = {
            "kind": "offlinemesh-node-address-request",
            "version": 1,
            "funding_model": "windows-normal-wallet-send",
            "network": network,
            "created_at": now_iso(),
            "wallet": wallet_config,
            "requests": requests,
            "windows_command_hint": windows_command_hints(wallet_config, requests, network),
        }
        save_json(FUNDING_REQUEST, output)
        print(json.dumps(output, indent=2, sort_keys=True))
        return output

    def wait_funds(self, nodes: list[Node], names: list[str], timeout: int) -> None:
        selected = [node for node in nodes if not names or node.hostname in names]
        for node in selected:
            log(f"waiting for CLN funds on {node.hostname}")
            self.ssh(node.ip, f"python3 {REMOTE_ROOT}/scripts/lnmesh_common.py wait-funds --timeout {timeout}", timeout=timeout + 60)

    def demo_open(self, nodes: list[Node], source: str, target: str, amount_sat: int, wait_state: str = "lockin") -> dict[str, Any]:
        by_name = {node.hostname: node for node in nodes}
        if source not in by_name or target not in by_name:
            raise SystemExit(f"demo nodes must be discovered; have {sorted(by_name)}")
        src = by_name[source]
        log(f"opening {amount_sat} sat channel {source} -> {target}")
        open_proc = self.ssh(
            src.ip,
            f"python3 {REMOTE_ROOT}/scripts/open_channel_offline.py --peer {shlex.quote(target)} --amount-sat {amount_sat} --wait-state {shlex.quote(wait_state)}",
            timeout=1800,
        )
        open_payload = strip_json(open_proc.stdout)
        demo_state = load_json(DEMO_STATE, {})
        demo_state.update(
            {
                "source": source,
                "target": target,
                "channel_id": open_payload.get("channel_id"),
                "opened_at": now_iso(),
                "open": open_payload,
            }
        )
        save_json(DEMO_STATE, demo_state)
        print(json.dumps(open_payload, indent=2, sort_keys=True))
        return open_payload

    def demo_pay(self, nodes: list[Node], payer: str, invoice_node: str, invoice_msat: int) -> dict[str, Any]:
        by_name = {node.hostname: node for node in nodes}
        if payer not in by_name or invoice_node not in by_name:
            raise SystemExit(f"demo nodes must be discovered; have {sorted(by_name)}")
        src = by_name[payer]
        dst = by_name[invoice_node]
        log(f"creating invoice on {invoice_node}")
        invoice_proc = self.ssh(
            dst.ip,
            f"python3 {REMOTE_ROOT}/scripts/pay_mesh.py invoice --amount-msat {invoice_msat} --description 'OfflineMesh gateway demo'",
            timeout=120,
        )
        invoice_payload = strip_json(invoice_proc.stdout)
        bolt11 = invoice_payload["bolt11"]
        log(f"paying invoice from {payer}")
        pay_proc = self.ssh(src.ip, f"python3 {REMOTE_ROOT}/scripts/pay_mesh.py pay --peer {shlex.quote(invoice_node)} --bolt11 {shlex.quote(bolt11)}", timeout=300)
        pay_payload = strip_json(pay_proc.stdout)
        output = {"invoice": invoice_payload, "payment": pay_payload}
        demo_state = load_json(DEMO_STATE, {})
        demo_state.update(
            {
                "payer": payer,
                "invoice_node": invoice_node,
                "bolt11": bolt11,
                "paid_at": now_iso(),
                "pay": output,
            }
        )
        save_json(DEMO_STATE, demo_state)
        print(json.dumps(output, indent=2, sort_keys=True))
        return output

    def demo_close(self, nodes: list[Node], source: str, target: str, channel_id: str | None, mode: str = "auto", timeout: int = 300) -> dict[str, Any]:
        by_name = {node.hostname: node for node in nodes}
        if source not in by_name or target not in by_name:
            raise SystemExit(f"demo nodes must be discovered; have {sorted(by_name)}")
        src = by_name[source]
        demo_state = load_json(DEMO_STATE, {})
        channel_id = channel_id or demo_state.get("channel_id")
        if not channel_id:
            raise SystemExit("channel id is required; pass --channel-id or run demo-open first")
        log(f"closing channel {channel_id}")
        close_proc = self.ssh(
            src.ip,
            f"python3 {REMOTE_ROOT}/scripts/close_channel_offline.py --peer {shlex.quote(target)} --channel-id {shlex.quote(channel_id)} --mode {shlex.quote(mode)} --timeout {timeout}",
            timeout=timeout + 300,
        )
        close_payload = strip_json(close_proc.stdout)
        demo_state.update({"closed_at": now_iso(), "close": close_payload})
        save_json(DEMO_STATE, demo_state)
        print(json.dumps(close_payload, indent=2, sort_keys=True))
        return close_payload

    def demo(self, nodes: list[Node], source: str, target: str, amount_sat: int, invoice_msat: int) -> None:
        open_payload = self.demo_open(nodes, source, target, amount_sat)
        self.demo_pay(nodes, source, target, invoice_msat)
        self.demo_close(nodes, source, target, open_payload["channel_id"], timeout=300)
        self.record_history("demo", {"source": source, "target": target, "channel_id": open_payload["channel_id"]})

    def return_funds(self, nodes: list[Node]) -> None:
        for node in nodes:
            if node.ssh_ok:
                log(f"checking/returning funds on {node.hostname}")
                self.sudo(node.ip, f"bash {REMOTE_ROOT}/scripts/return_funds_to_funder.sh --yes", timeout=600)

    def reset_nodes(self, nodes: list[Node], skip_check: bool) -> None:
        for node in nodes:
            if not node.ssh_ok:
                continue
            args = "--skip-fund-return-check" if skip_check else ""
            log(f"resetting {node.hostname}")
            self.sudo(node.ip, f"bash {REMOTE_ROOT}/scripts/reset_preserve_wallet.sh {args}", timeout=900)


def selected_nodes(gw: Gateway, names: list[str] | None = None, *, refresh: bool = False) -> list[Node]:
    state_nodes = gw.state.get("nodes") or {}
    nodes = [node_from_payload(payload) for payload in state_nodes.values()]
    if refresh or not nodes:
        nodes = gw.discover_nodes()
    if names:
        wanted = set(names)
        nodes = [
            node
            for node in nodes
            if node.hostname in wanted or node.system_hostname in wanted or node.ip in wanted
        ]
    return sorted(nodes, key=lambda n: n.hostname)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Gateway-owned OfflineMesh orchestration.")
    parser.add_argument("--user", default=DEFAULT_USER)
    parser.add_argument("--password", default=os.environ.get("OFFLINEMESH_NODE_PASSWORD", DEFAULT_PASSWORD))
    sub = parser.add_subparsers(dest="command", required=True)

    discover = sub.add_parser("discover", help="Discover mesh Pis over bat0 and assign logical node names.")
    discover.set_defaults(func=lambda gw, args: print(json.dumps([asdict(n) for n in gw.discover_nodes()], indent=2, sort_keys=True)))

    install_gateway = sub.add_parser("install-gateway", help="Install gateway stack locally.")
    install_gateway.set_defaults(func=lambda gw, args: gw.install_gateway())

    install_nodes = sub.add_parser("install-nodes", help="Install new discovered mesh nodes, or named nodes when provided.")
    install_nodes.add_argument("--force", action="store_true", help="Reinstall selected nodes even if they were already installed.")
    install_nodes.add_argument("nodes", nargs="*")
    install_nodes.set_defaults(func=lambda gw, args: gw.install_nodes(selected_nodes(gw, args.nodes, refresh=True), force=args.force or bool(args.nodes)))

    collect_ids = sub.add_parser("collect-ids", help="Collect CLN node IDs and regenerate runtime cluster state.")
    collect_ids.add_argument("nodes", nargs="*")
    collect_ids.add_argument("--no-distribute", action="store_true")
    collect_ids.set_defaults(func=lambda gw, args: gw.collect_ids(selected_nodes(gw, args.nodes, refresh=True), not args.no_distribute))

    setup = sub.add_parser("setup", help="Install gateway, discover nodes, install nodes, and verify.")
    setup.add_argument("nodes", nargs="*")
    setup.set_defaults(func=lambda gw, args: (gw.install_gateway(), gw.install_nodes(selected_nodes(gw, args.nodes, refresh=True), force=True), gw.verify(selected_nodes(gw, args.nodes))))

    verify = sub.add_parser("verify", help="Run gateway and node verification.")
    verify.add_argument("nodes", nargs="*")
    verify.set_defaults(func=lambda gw, args: gw.verify(selected_nodes(gw, args.nodes, refresh=True)))

    funding = sub.add_parser("funding-request", help="Ask nodes for CLN receive addresses for normal Windows wallet funding.")
    funding.add_argument("nodes", nargs="*")
    funding.add_argument("--amount-sat", type=int, default=150000)
    funding.set_defaults(func=lambda gw, args: gw.funding_request(selected_nodes(gw, args.nodes), args.amount_sat, args.nodes))

    wait_funds = sub.add_parser("wait-funds", help="Wait until selected nodes see CLN funds.")
    wait_funds.add_argument("nodes", nargs="*")
    wait_funds.add_argument("--timeout", type=int, default=7200)
    wait_funds.set_defaults(func=lambda gw, args: gw.wait_funds(selected_nodes(gw, args.nodes), args.nodes, args.timeout))

    demo = sub.add_parser("demo", help="Open, pay, and close a channel between two nodes.")
    demo.add_argument("--source", default="node02")
    demo.add_argument("--target", default="node01")
    demo.add_argument("--channel-amount-sat", type=int, default=50000)
    demo.add_argument("--invoice-msat", type=int, default=1000)
    demo.set_defaults(func=lambda gw, args: gw.demo(selected_nodes(gw), args.source, args.target, args.channel_amount_sat, args.invoice_msat))

    demo_open = sub.add_parser("demo-open", help="Open the demo channel and remember its channel_id.")
    demo_open.add_argument("--source", default="node02")
    demo_open.add_argument("--target", default="node01")
    demo_open.add_argument("--channel-amount-sat", type=int, default=50000)
    demo_open.add_argument("--wait-state", default="lockin")
    demo_open.set_defaults(func=lambda gw, args: gw.demo_open(selected_nodes(gw), args.source, args.target, args.channel_amount_sat, args.wait_state))

    demo_pay = sub.add_parser("demo-pay", help="Create an invoice on the target node and pay from the source node.")
    demo_pay.add_argument("--source", default="node02")
    demo_pay.add_argument("--target", default="node01")
    demo_pay.add_argument("--invoice-msat", type=int, default=1000)
    demo_pay.set_defaults(func=lambda gw, args: gw.demo_pay(selected_nodes(gw), args.source, args.target, args.invoice_msat))

    demo_close = sub.add_parser("demo-close", help="Close the remembered or explicitly provided demo channel.")
    demo_close.add_argument("--source", default="node02")
    demo_close.add_argument("--target", default="node01")
    demo_close.add_argument("--channel-id")
    demo_close.add_argument("--mode", choices=("auto", "cooperative", "force"), default="auto")
    demo_close.add_argument("--timeout", type=int, default=300)
    demo_close.set_defaults(func=lambda gw, args: gw.demo_close(selected_nodes(gw), args.source, args.target, args.channel_id, args.mode, args.timeout))

    ret = sub.add_parser("return-funds", help="Ask nodes to return spendable funds to the Windows test wallet return address.")
    ret.add_argument("nodes", nargs="*")
    ret.set_defaults(func=lambda gw, args: gw.return_funds(selected_nodes(gw, args.nodes)))

    reset = sub.add_parser("reset-nodes", help="Reset node OfflineMesh software after fund checks.")
    reset.add_argument("nodes", nargs="*")
    reset.add_argument("--skip-fund-return-check", action="store_true")
    reset.set_defaults(func=lambda gw, args: gw.reset_nodes(selected_nodes(gw, args.nodes), args.skip_fund_return_check))

    reinstall = sub.add_parser("reinstall-pass", help="Return funds, reset, reinstall nodes, and verify.")
    reinstall.add_argument("nodes", nargs="*")
    reinstall.set_defaults(
        func=lambda gw, args: (
            gw.return_funds(selected_nodes(gw, args.nodes)),
            gw.reset_nodes(selected_nodes(gw, args.nodes), False),
            gw.install_nodes(gw.discover_nodes() if not args.nodes else selected_nodes(gw, args.nodes, refresh=True), force=True),
            gw.verify(selected_nodes(gw, args.nodes)),
        )
    )

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    gw = Gateway(args)
    args.func(gw, args)


if __name__ == "__main__":
    main()
