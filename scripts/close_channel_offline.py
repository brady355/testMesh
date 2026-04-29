#!/usr/bin/env python3
from __future__ import annotations

import argparse

from lnmesh_common import cln, ensure_connected, list_peerchannels, peer_id_for, preferred_channel, print_json


CLOSE_STATES = {
    "CHANNELD_SHUTTING_DOWN",
    "CLOSINGD_SIGEXCHANGE",
    "CLOSINGD_COMPLETE",
    "ONCHAIN",
}

ESCALATABLE_CLOSE_STATES = {
    "CHANNELD_SHUTTING_DOWN",
    "CLOSINGD_SIGEXCHANGE",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Close a CLN channel over the mesh.")
    parser.add_argument("--peer", required=True, help="Cluster hostname or peer pubkey.")
    parser.add_argument(
        "--mode",
        choices=("cooperative", "force", "auto"),
        default="auto",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Seconds to wait before allowing unilateral close in auto/force mode.",
    )
    parser.add_argument("--channel-id", help="Optional explicit channel id to close.")
    parser.add_argument("--destination", help="Optional on-chain close destination.")
    return parser


def call_close(target_id: str, *, timeout: int, destination: str | None) -> dict:
    kwargs = {"id": target_id, "unilateraltimeout": timeout}
    if destination:
        kwargs["destination"] = destination
    return cln("close", **kwargs)


def close_target_id(peer_id: str, channel: dict | None, explicit_channel_id: str | None) -> str:
    if explicit_channel_id:
        return explicit_channel_id
    if channel:
        return channel.get("short_channel_id") or channel.get("channel_id") or peer_id
    return peer_id


def main() -> None:
    args = build_parser().parse_args()
    peer_id = peer_id_for(args.peer)
    channel = preferred_channel(peer_id, channel_id=args.channel_id)
    target_id = close_target_id(peer_id, channel, args.channel_id)
    result = None

    try:
        ensure_connected(args.peer)
    except Exception:
        if args.mode == "cooperative":
            raise

    if channel and channel.get("state") in CLOSE_STATES:
        if args.mode != "cooperative" and channel.get("state") in ESCALATABLE_CLOSE_STATES:
            result = call_close(target_id, timeout=max(1, args.timeout), destination=args.destination)
        else:
            result = {"status": "already-closing", "state": channel.get("state")}
    elif args.mode == "cooperative":
        result = call_close(target_id, timeout=0, destination=args.destination)
    elif args.mode == "force":
        result = call_close(target_id, timeout=max(1, args.timeout), destination=args.destination)
    else:
        try:
            result = call_close(target_id, timeout=args.timeout, destination=args.destination)
        except Exception as exc:
            latest = preferred_channel(peer_id, channel_id=args.channel_id or (channel or {}).get("channel_id"))
            if latest and latest.get("state") in CLOSE_STATES:
                if latest.get("state") in ESCALATABLE_CLOSE_STATES:
                    result = call_close(target_id, timeout=1, destination=args.destination)
                else:
                    result = {
                        "status": "already-closing",
                        "state": latest.get("state"),
                        "close_error": str(exc),
                    }
            else:
                result = call_close(target_id, timeout=1, destination=args.destination)

    selected_after = preferred_channel(peer_id, channel_id=args.channel_id or (channel or {}).get("channel_id"))

    print_json(
        {
            "target_id": target_id,
            "selected_channel": channel,
            "selected_channel_after": selected_after,
            "close_result": result,
            "channels_after": list_peerchannels(peer_id),
        }
    )


if __name__ == "__main__":
    main()
