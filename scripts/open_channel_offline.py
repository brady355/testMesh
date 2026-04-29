#!/usr/bin/env python3
from __future__ import annotations

import argparse
import time
from typing import Any

from lnmesh_common import (
    bitcoin,
    cln,
    ensure_connected,
    peer_id_for,
    print_json,
    wait_for_channel_state,
)

DEFAULT_OPEN_FEERATE_PERKW = 25000
MAX_OPEN_FEERATE_PERKW = 50000
FUNDING_START_WEIGHT = 166
MIN_WITNESS_WEIGHT = 222
UTXO_BUFFER_SAT = 50000


def choose_feerate(explicit: str | None) -> str:
    if explicit:
        return explicit
    feerates = cln("feerates", style="perkw").get("perkw", {})
    estimates = {
        int(item.get("blockcount")): int(item.get("smoothed_feerate") or item.get("feerate") or 0)
        for item in feerates.get("estimates", [])
        if item.get("blockcount")
    }
    opening = int(feerates.get("opening") or 0)
    medium_estimate = next(
        (estimates[blockcount] for blockcount in (6, 12, 100) if estimates.get(blockcount)),
        opening,
    )
    # Testnet4 miners often skip low-fee mempool entries, while short-horizon
    # estimates can spike into absurd values. Keep blind README runs brisk
    # without letting one noisy estimate consume the whole test wallet.
    chosen = max(opening, medium_estimate, DEFAULT_OPEN_FEERATE_PERKW)
    chosen = min(chosen, MAX_OPEN_FEERATE_PERKW)
    return f"{chosen}perkw"


def wait_for_lightningd(timeout: int = 120) -> None:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            cln("getinfo")
            return
        except Exception as exc:  # pragma: no cover - runtime helper
            last_error = exc
            time.sleep(2)
    if last_error:
        raise RuntimeError(f"lightningd did not recover in time: {last_error}") from last_error
    raise RuntimeError("lightningd did not recover in time")


def wallet_transactions() -> dict[str, dict[str, Any]]:
    return {
        tx["hash"]: tx
        for tx in cln("listtransactions").get("transactions", [])
        if tx.get("hash")
    }


def decode_wallet_transaction(
    txid: str,
    tx_map: dict[str, dict[str, Any]],
    decoded_cache: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    if txid not in decoded_cache:
        rawtx = (tx_map.get(txid) or {}).get("rawtx")
        if rawtx:
            decoded_cache[txid] = bitcoin("decoderawtransaction", rawtx)
        else:
            decoded_cache[txid] = bitcoin("getrawtransaction", txid, True)
    return decoded_cache[txid]


def safe_confirmed_outputs() -> tuple[list[dict[str, Any]], bool]:
    info = cln("getinfo")
    current_height = int(info.get("blockheight") or 0)
    tx_map = wallet_transactions()
    decoded_cache: dict[str, dict[str, Any]] = {}
    outputs: list[dict[str, Any]] = []
    has_immature_coinbase = False

    for output in cln("listfunds").get("outputs", []):
        if output.get("status") != "confirmed" or output.get("reserved"):
            continue
        decoded = decode_wallet_transaction(output["txid"], tx_map, decoded_cache)
        is_coinbase = any("coinbase" in vin for vin in decoded.get("vin", []))
        blockheight = int(output.get("blockheight") or 0)
        confirmations = current_height - blockheight + 1 if blockheight else 0
        if is_coinbase and confirmations < 100:
            has_immature_coinbase = True
            continue
        outputs.append(output)

    return outputs, has_immature_coinbase


def output_sat(output: dict[str, Any]) -> int:
    return int(output.get("amount_msat", 0)) // 1000


def select_safe_utxos(amount_sat: int, available: list[dict[str, Any]]) -> list[str]:
    if not available:
        raise RuntimeError("No confirmed spendable CLN outputs are available for channel funding")

    target_sat = amount_sat + UTXO_BUFFER_SAT
    singles = sorted((output for output in available if output_sat(output) >= target_sat), key=output_sat)
    if singles:
        return [f"{singles[0]['txid']}:{singles[0]['output']}"]

    selected: list[dict[str, Any]] = []
    total_sat = 0
    for output in sorted(available, key=output_sat, reverse=True):
        selected.append(output)
        total_sat += output_sat(output)
        if total_sat >= target_sat:
            return [f"{output['txid']}:{output['output']}" for output in selected]

    raise RuntimeError(
        f"Insufficient confirmed spendable CLN outputs for {amount_sat} sat channel funding"
    )


def fund_channel_psbt(amount_sat: int, feerate: str) -> tuple[dict[str, Any], str]:
    kwargs = {
        "satoshi": f"{amount_sat}sat",
        "feerate": feerate,
        "startweight": FUNDING_START_WEIGHT,
        "excess_as_change": True,
        "min_witness_weight": MIN_WITNESS_WEIGHT,
    }

    available, has_immature_coinbase = safe_confirmed_outputs()
    if not available:
        raise RuntimeError("No confirmed spendable CLN outputs are available for channel funding")
    if any(output_sat(output) == 0 for output in available):
        raise RuntimeError("Wallet outputs contain an invalid zero-value output")
    if has_immature_coinbase:
        return cln("utxopsbt", utxos=select_safe_utxos(amount_sat, available), **kwargs), "utxopsbt"

    try:
        return cln("fundpsbt", **kwargs), "fundpsbt"
    except RuntimeError:
        wait_for_lightningd()
        available, _ = safe_confirmed_outputs()
        return cln("utxopsbt", utxos=select_safe_utxos(amount_sat, available), **kwargs), "utxopsbt"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open a CLN channel over the BATMAN mesh.")
    parser.add_argument("--peer", required=True, help="Cluster hostname or pubkey of the peer.")
    parser.add_argument("--amount-sat", required=True, type=int, help="Channel funding amount in satoshis.")
    parser.add_argument("--feerate", help="Optional CLN feerate string such as 5000perkw.")
    parser.add_argument("--announce", action="store_true")
    parser.add_argument(
        "--wait-state",
        choices=("broadcast", "lockin", "normal"),
        default="broadcast",
        help="How long to wait after broadcasting the funding transaction.",
    )
    parser.add_argument("--timeout", type=int, default=900)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    peer_id = peer_id_for(args.peer)
    ensure_connected(args.peer)
    feerate = choose_feerate(args.feerate)

    funded, funding_strategy = fund_channel_psbt(args.amount_sat, feerate)
    current = cln(
        "openchannel_init",
        id=peer_id,
        amount=f"{args.amount_sat}sat",
        initialpsbt=funded["psbt"],
        funding_feerate=feerate,
        announce=args.announce,
    )

    while not current.get("commitments_secured", False):
        current = cln(
            "openchannel_update",
            channel_id=current["channel_id"],
            psbt=current["psbt"],
        )

    signed = cln("signpsbt", psbt=current["psbt"])
    finalized = cln(
        "openchannel_signed",
        channel_id=current["channel_id"],
        signed_psbt=signed["signed_psbt"],
    )

    states = {
        "broadcast": {"DUALOPEND_AWAITING_LOCKIN", "CHANNELD_AWAITING_LOCKIN"},
        "lockin": {"DUALOPEND_AWAITING_LOCKIN", "CHANNELD_AWAITING_LOCKIN", "CHANNELD_NORMAL"},
        "normal": {"CHANNELD_NORMAL"},
    }[args.wait_state]

    channel = None
    if args.wait_state != "broadcast":
        channel = wait_for_channel_state(
            args.peer,
            states,
            timeout=args.timeout,
            channel_id=finalized["channel_id"],
        )

    print_json(
        {
            "peer_id": peer_id,
            "feerate": feerate,
            "funding_strategy": funding_strategy,
            "channel_id": finalized["channel_id"],
            "txid": finalized.get("txid"),
            "tx": finalized.get("tx"),
            "channel": channel,
        }
    )


if __name__ == "__main__":
    main()
