#!/usr/bin/env python3
"""
Simulates one participant in a barrier-synchronized collective operation
(AllReduce / Ring-Shift / Gather) sending its contribution for one round.

The packet carries the context-shim header (version, opType, contextId,
participantId, numParticipants, seq) as raw bytes right after the UDP
header, on UDP dst port 4321 -- matching collective_telemetry.p4's parser.

Usage:
    python3 worker_send.py <iface> <dst_ip> --ctx <id> --pid <id> --n <count>
                            [--op 0|1|2] [--seq N] [--delay SECONDS]

Example (worker 4 of a 3-way gather to h1, injected as a straggler):
    python3 worker_send.py h4-eth0 10.0.0.1 --op 2 --ctx 7 --pid 4 --n 3 --delay 0.5
"""

import argparse
import struct
import time

from scapy.all import Ether, IP, UDP, Raw, sendp

COLLECTIVE_PORT = 4321

OP_NAMES = {0: 'AllReduce', 1: 'Ring-Shift', 2: 'Gather'}


def build_shim(op_type, context_id, participant_id, num_participants, seq):
    """Pack the 8-byte context-shim header: version(1) opType(1) contextId(2)
    participantId(1) numParticipants(1) seq(2), all network byte order."""
    return struct.pack('!BBHBBH', 1, op_type, context_id, participant_id, num_participants, seq)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('iface', help="host interface to send on, e.g. h2-eth0")
    ap.add_argument('dst_ip', help="destination worker IP for this round")
    ap.add_argument('--op', type=int, default=0, choices=[0, 1, 2],
                     help='0=AllReduce, 1=Ring-Shift, 2=Gather (default 0)')
    ap.add_argument('--ctx', type=int, required=True, help='operation context ID for this round')
    ap.add_argument('--pid', type=int, required=True, help='this worker\'s participant ID')
    ap.add_argument('--n', type=int, required=True, help='number of participants expected this round')
    ap.add_argument('--seq', type=int, default=0, help='sequence number within the round')
    ap.add_argument('--delay', type=float, default=0.0,
                     help='artificial delay (seconds) before sending, to emulate a straggler')
    ap.add_argument('--payload', type=int, default=64, help='extra payload bytes (default 64)')
    args = ap.parse_args()

    if args.delay > 0:
        print('[worker %d] injecting %.0f ms straggler delay ...' % (args.pid, args.delay * 1000))
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
