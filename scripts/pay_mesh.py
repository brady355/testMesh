#!/usr/bin/env python3
from __future__ import annotations

import argparse
import uuid

from lnmesh_common import channel_state, cln, ensure_connected, peer_id_for, preferred_channel, print_json


def auto_label() -> str:
    return f"mesh-{uuid.uuid4().hex}"


def cmd_invoice(args: argparse.Namespace) -> None:
    label = args.label or auto_label()
    result = cln(
        "invoice",
        amount_msat=f"{args.amount_msat}msat",
        label=label,
        description=args.description,
        exposeprivatechannels=True,
    )
    print_json(result)


def cmd_pay(args: argparse.Namespace) -> None:
    peer = args.peer
    if peer:
        ensure_connected(peer)
    result = cln("pay", bolt11=args.bolt11)
    payload = {"payment": result}
    if peer:
        payload["peer_id"] = peer_id_for(peer)
        payload["channel_state"] = channel_state(peer, actionable=True)
        payload["selected_channel"] = preferred_channel(peer)
    print_json(payload)


def cmd_status(args: argparse.Namespace) -> None:
    payload = {"getinfo": cln("getinfo")}
    if args.peer:
        payload["peer_id"] = peer_id_for(args.peer)
        payload["channel_state"] = channel_state(args.peer, actionable=True)
        payload["selected_channel"] = preferred_channel(args.peer)
        payload["listpeerchannels"] = cln("listpeerchannels", id=peer_id_for(args.peer))
    else:
        payload["listpeerchannels"] = cln("listpeerchannels")
    print_json(payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Invoice and payment helpers for mesh-only CLN peers.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    invoice = subparsers.add_parser("invoice", help="Create an invoice on the local node.")
    invoice.add_argument("--amount-msat", required=True, type=int)
    invoice.add_argument("--label")
    invoice.add_argument("--description", default="OfflineMesh payment")
    invoice.set_defaults(func=cmd_invoice)

    pay = subparsers.add_parser("pay", help="Pay a bolt11 invoice from the local node.")
    pay.add_argument("--bolt11", required=True)
    pay.add_argument("--peer", help="Optional direct peer to reconnect over the mesh before paying.")
    pay.set_defaults(func=cmd_pay)

    status = subparsers.add_parser("status", help="Show local payment and channel state.")
    status.add_argument("--peer")
    status.set_defaults(func=cmd_status)

    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
