#!/usr/bin/env python3
"""
Send one UDP packet containing the 4-byte collective context shim.

Run this from a Mininet host namespace, for example:
    h1 python3 sender.py --participant 1 --context 1
"""

import argparse
import socket
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument("--participant", type=int, required=True)
parser.add_argument("--context", type=int, default=1)
parser.add_argument("--dst", default="10.0.4.4")
parser.add_argument("--port", type=int, default=9999)
parser.add_argument("--payload", default="collective-packet")
args = parser.parse_args()

# context_id (16 bits), participant_id (8 bits), flags (8 bits)
shim = struct.pack("!HBB", args.context, args.participant, 0)

payload = shim + args.payload.encode()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(payload, (args.dst, args.port))

print(
    f"sent context={args.context} "
    f"participant={args.participant} "
    f"payload_bytes={len(payload)}"
)
