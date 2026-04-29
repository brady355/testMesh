#!/usr/bin/env python3
"""Patch rust-teos so the OfflineMesh testnet4 tower can start cleanly."""

from __future__ import annotations

import argparse
from pathlib import Path


def patch_config(config_path: Path) -> bool:
    original = config_path.read_text(encoding="utf-8")
    lines = []

    for line in original.splitlines():
        line = line.replace(
            "Either mainnet, testnet, signet or regtest",
            "Either mainnet, testnet, testnet4, signet or regtest",
        )
        line = line.replace(
            "to either bitcoin, testnet, signet or regtest",
            "to either bitcoin, testnet, testnet4, signet or regtest",
        )
        line = line.replace(
            "Expected {mainnet, testnet, signet, regtest}",
            "Expected {mainnet, testnet, testnet4, signet, regtest}",
        )
        lines.append(line)
        if '"test" => 18332,' in line and '"testnet4" => 48332' not in original:
            indent = line[: len(line) - len(line.lstrip())]
            lines.append(f'{indent}"testnet4" => 48332,')

    updated = "\n".join(lines)
    if original.endswith("\n"):
        updated += "\n"

    if '"testnet4" => 48332' not in updated and '"test" => 18332,' not in updated:
        raise RuntimeError(f"Could not find TEOS default RPC port match arm in {config_path}")

    if "testnet4" not in updated or "48332" not in updated:
        raise RuntimeError(f"TEOS testnet4 patch verification failed for {config_path}")

    if updated != original:
        config_path.write_text(updated, encoding="utf-8")
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, help="rust-teos source directory")
    args = parser.parse_args()

    source_dir = args.source_dir.expanduser().resolve()
    config_path = source_dir / "teos" / "src" / "config.rs"
    if not config_path.is_file():
        raise SystemExit(f"Missing rust-teos config file: {config_path}")

    changed = patch_config(config_path)
    print(f"{'patched' if changed else 'already patched'} {config_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
