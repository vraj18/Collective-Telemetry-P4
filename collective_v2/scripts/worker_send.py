#!/usr/bin/env python3
"""
Sends one collective-communication packet tagged with the context-shim
header. Straggler delay is normally injected declaratively via
topology.json (per-link "delay"), not here -- that's what actually
delays the packet's arrival at the switch, which is what the P4
program measures. --delay is kept only for quick ad-hoc tests without
touching the topology.

Usage:
    python3 worker_send.py <iface> <dst_ip> --ctx <id> --pid <id> --n <count>

Example (3-way Gather to h1, context 7):
    h2: python3 worker_send.py h2-eth0 10.0.0.1 --op 2 --ctx 7 --pid 2 --n 3
    h3: python3 worker_send.py h3-eth0 10.0.0.1 --op 2 --ctx 7 --pid 3 --n 3
    h4: python3 worker_send.py h4-eth0 10.0.0.1 --op 2 --ctx 7 --pid 4 --n 3
        (h4's link has 50ms delay in topology.json -> h4 is the straggler)
"""

import argparse
import struct
import time

from scapy.all import Ether, IP, UDP, Raw, sendp

COLLECTIVE_PORT = 4321
OP_NAMES = {0: 'AllReduce', 1: 'Ring-Shift', 2: 'Gather'}


def build_shim(op_type, context_id, participant_id, num_participants, seq):
    return struct.pack('!BBHBBH', 1, op_type, context_id, participant_id, num_participants, seq)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('iface')
    ap.add_argument('dst_ip')
    ap.add_argument('--op', type=int, default=0, choices=[0, 1, 2])
    ap.add_argument('--ctx', type=int, required=True)
    ap.add_argument('--pid', type=int, required=True)
    ap.add_argument('--n', type=int, required=True)
    ap.add_argument('--seq', type=int, default=0)
    ap.add_argument('--delay', type=float, default=0.0,
                     help='optional extra sleep before sending (ad-hoc testing only)')
    ap.add_argument('--payload', type=int, default=64)
    args = ap.parse_args()

    if args.delay > 0:
        time.sleep(args.delay)

    shim = build_shim(args.op, args.ctx, args.pid, args.n, args.seq)
    pkt = (
        Ether()
        / IP(dst=args.dst_ip)
        / UDP(dport=COLLECTIVE_PORT, sport=5000 + args.pid)
        / Raw(load=shim + b'D' * args.payload)
    )
    sendp(pkt, iface=args.iface, verbose=False)
    print('[worker %d] sent %s ctx=%d seq=%d -> %s' %
          (args.pid, OP_NAMES.get(args.op, 'op%d' % args.op), args.ctx, args.seq, args.dst_ip))


if __name__ == '__main__':
    main()
