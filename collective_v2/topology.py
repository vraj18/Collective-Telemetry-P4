#!/usr/bin/env python3
"""
Builds the Mininet network entirely from topology.json and pushes the
matching switch config (forwarding table, mirroring session, skew
threshold) automatically -- topology.json is the only file you edit to
add/remove hosts, change per-link delay, or change the threshold.

Run with: sudo /usr/bin/python3 topology.py
"""

import json
import os
from time import sleep

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.link import TCLink
from mininet.cli import CLI
from mininet.log import setLogLevel, info
from mininet.node import Switch

HERE = os.path.dirname(os.path.abspath(__file__))
TOPO_JSON = os.path.join(HERE, 'topology.json')
JSON_PATH = os.path.join(HERE, 'build', 'collective_telemetry.json')


class P4Switch(Switch):
    device_id = 0

    def __init__(self, name, json_path, thrift_port, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.thrift_port = thrift_port
        self.device_id = P4Switch.device_id
        P4Switch.device_id += 1

    def start(self, controllers):
        if not os.path.exists(self.json_path):
            raise RuntimeError('Compiled P4 JSON not found at %s -- run `make build` first.' % self.json_path)

        args = ['simple_switch']
        for intf in self.intfList():
            if intf.name != 'lo':
                args.extend(['-i', '%d@%s' % (self.ports[intf], intf.name)])
        args.extend(['--device-id', str(self.device_id)])
        args.extend(['--thrift-port', str(self.thrift_port)])
        args.append(self.json_path)
        args.append('> /tmp/%s.log 2>&1 &' % self.name)

        cmd = ' '.join(args)
        info('*** starting P4 switch %s: %s\n' % (self.name, cmd))
        self.cmd(cmd)
        sleep(1)

    def stop(self):
        self.cmd('kill %simple_switch 2>/dev/null')


def load_config():
    with open(TOPO_JSON) as f:
        return json.load(f)


class ConfigTopo(Topo):
    """Builds hosts + one switch straight from topology.json's 'hosts' and
    'links' lists. Link order == port order (h1's link is port 1, etc.)."""

    def build(self, cfg):
        switch_name = cfg['switch']['name']
        s1 = self.addSwitch(
            switch_name, cls=P4Switch,
            json_path=JSON_PATH, thrift_port=cfg['switch']['thrift_port'],
        )

        for link in cfg['links']:
            hname = link['host']
            hcfg = cfg['hosts'][hname]
            host = self.addHost(hname, ip=hcfg['ip'], mac=hcfg['mac'])

            link_opts = {}
            if 'delay' in link:
                link_opts['delay'] = link['delay']
            if 'bw' in link:
                link_opts['bw'] = link['bw']
            if 'loss' in link:
                link_opts['loss'] = link['loss']

            if link_opts:
                self.addLink(host, s1, cls=TCLink, **link_opts)
            else:
                self.addLink(host, s1)


def push_switch_config(cfg):
    """Auto-generate simple_switch_CLI commands straight from topology.json,
    so the JSON file stays the single source of truth."""
    thrift_port = cfg['switch']['thrift_port']
    collector = cfg['collector']

    lines = []
    port = 1
    collector_port = None
    for link in cfg['links']:
        hname = link['host']
        ip = cfg['hosts'][hname]['ip'].split('/')[0]
        lines.append('table_add MyIngress.forwarding set_egress_port %s => %d' % (ip, port))
        if hname == collector:
            collector_port = port
        port += 1

    if collector_port is None:
        raise RuntimeError('collector "%s" in topology.json is not in the links list' % collector)

    lines.append('mirroring_add 1 %d' % collector_port)
    lines.append('register_write MyIngress.regThreshold 0 %d' % cfg['threshold_us'])

    cmd_file = os.path.join(HERE, 'build', '_generated_s1_commands.txt')
    with open(cmd_file, 'w') as f:
        f.write('\n'.join(lines) + '\n')

    info('*** Generated switch config from topology.json:\n')
    for l in lines:
        info('    %s\n' % l)

    os.system('simple_switch_CLI --thrift-port %d < %s' % (thrift_port, cmd_file))


def main():
    cfg = load_config()
    os.makedirs(os.path.join(HERE, 'build'), exist_ok=True)

    net = Mininet(topo=ConfigTopo(cfg), controller=None)
    net.start()
    sleep(1)

    push_switch_config(cfg)

    info('*** Network ready.\n')
    for link in cfg['links']:
        hname = link['host']
        extra = ' (delay=%s)' % link['delay'] if 'delay' in link else ''
        info('    %s -> %s%s\n' % (hname, cfg['hosts'][hname]['ip'], extra))
    info('    collector: %s\n' % cfg['collector'])

    CLI(net)
    net.stop()


if __name__ == '__main__':
    setLogLevel('info')
    main()
