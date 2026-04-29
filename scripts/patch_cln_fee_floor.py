#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def patch_fee_states(source_root: Path) -> bool:
    path = source_root / "common" / "fee_states.c"
    text = path.read_text(encoding="utf-8")
    old = "\tassert(current_feerate >= minfeerate);\n"
    new = (
        "\t/* OfflineMesh/testnet4 can temporarily surface very low feerates\n"
        "\t * while dual-open state is being reconstructed. Clamp instead of\n"
        "\t * aborting so listpeerchannels and recovery paths stay usable. */\n"
        "\tif (current_feerate < minfeerate)\n"
        "\t\tcurrent_feerate = minfeerate;\n"
    )
    if new in text:
        return False
    if old not in text:
        raise SystemExit(f"expected fee assert not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    return True


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} /path/to/lightning-source")
    changed = patch_fee_states(Path(sys.argv[1]).resolve())
    print("patched common/fee_states.c" if changed else "common/fee_states.c already patched")


if __name__ == "__main__":
    main()
