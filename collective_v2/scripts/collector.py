#!/usr/bin/env python3
"""Listens for straggler reports (EtherType 0x1234). Usage: python3 collector.py [iface]"""

import struct
import sys

from scapy.all import Ether, sniff

REPORT_ETHERTYPE = 0x1234
REPORT_LEN = 30
OP_NAMES = {0: 'AllReduce', 1: 'Ring-Shift', 2: 'Gather'}


def be_int(b):
    return int.from_bytes(b, 'big')


def parse_report(payload):
    ctx_id, op_type, straggler_id = struct.unpack('!HBB', payload[0:4])
    t_fast = be_int(payload[4:10])
    t_slow = be_int(payload[10:16])
    skew = be_int(payload[16:22])
    qdepth, qdelay = struct.unpack('!II', payload[22:30])
    return {
        'context_id': ctx_id, 'op_type': op_type, 'straggler_id': straggler_id,
        't_fast': t_fast, 't_slow': t_slow, 'skew': skew,
        'queue_depth': qdepth, 'queue_delay': qdelay,
    }


def handle(pkt):
    if not pkt.haslayer(Ether) or pkt[Ether].type != REPORT_ETHERTYPE:
        return
    payload = bytes(pkt[Ether].payload)
    if len(payload) < REPORT_LEN:
        return
    r = parse_report(payload)
    op_name = OP_NAMES.get(r['op_type'], 'op%d' % r['op_type'])
    print('=' * 62)
    print('STRAGGLER ALERT  |  context %d  |  %s' % (r['context_id'], op_name))
    print('  lagging participant : %d' % r['straggler_id'])
    print('  t_fast (us)         : %d' % r['t_fast'])
    print('  t_slow (us)         : %d' % r['t_slow'])
    print('  skew delta_t (us)   : %d' % r['skew'])
    print('  switch queue depth  : %d' % r['queue_depth'])
    print('  switch queue delay  : %d us' % r['queue_delay'])
    print('=' * 62)


def main():
    iface = sys.argv[1] if len(sys.argv) > 1 else 'h5-eth0'
    print('[collector] listening on %s ...' % iface)
    sniff(iface=iface, prn=handle, store=False)


if __name__ == '__main__':
    main()
