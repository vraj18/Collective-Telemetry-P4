#!/usr/bin/env python3
"""
Mininet topology for the Collective-Aware In-Switch Telemetry prototype.

Star topology matching the PPT diagram:

        h1  h2  h3  h4          (distributed workers)
          \\  \\  |  /
              [ s1 ]  <- BMv2 P4 switch running collective_telemetry.p4
              /
            h5                  (telemetry collector, receives mirrored
                                 straggler reports on a dedicated port)

Run with:  sudo python3 topology.py
"""

import os
from time import sleep

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.cli import CLI
from mininet.log import setLogLevel, info
from mininet.node import Switch


JSON_PATH = os.path.join(os.path.dirname(__file__), 'build', 'collective_telemetry.json')
THRIFT_PORT = 9090
CLI_COMMANDS_FILE = os.path.join(os.path.dirname(__file__), 's1-commands.txt')


class P4Switch(Switch):
    """A Mininet Switch node backed by the BMv2 'simple_switch' software target."""

    device_id = 0

    def __init__(self, name, json_path, thrift_port, pcap_dump=False, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.thrift_port = thrift_port
        self.pcap_dump = pcap_dump
        self.device_id = P4Switch.device_id
        P4Switch.device_id += 1

    def start(self, controllers):
        if not os.path.exists(self.json_path):
            raise RuntimeError(
                'Compiled P4 JSON not found at %s -- run `make build` first.' % self.json_path
            )

        args = ['simple_switch']
        for intf in self.intfList():
            if intf.name != 'lo':
                args.extend(['-i', '%d@%s' % (self.ports[intf], intf.name)])
        args.extend(['--device-id', str(self.device_id)])
        args.extend(['--thrift-port', str(self.thrift_port)])
        if self.pcap_dump:
            args.append('--pcap')
        args.append(self.json_path)
        args.append('> /tmp/%s.log 2>&1 &' % self.name)

        cmd = ' '.join(args)
        info('*** starting P4 switch %s: %s\n' % (self.name, cmd))
        self.cmd(cmd)
        sleep(1)

    def stop(self):
        self.cmd('kill %simple_switch 2>/dev/null')

    def describe(self):
        print('%s -> thrift port %d, json %s' % (self.name, self.thrift_port, self.json_path))


class CollectiveTopo(Topo):
    """4 worker hosts + 1 collector host, all attached to a single P4 switch.

    Ports are assigned in link-creation order: h1->1, h2->2, h3->3, h4->4,
    h5(collector)->5. This must match s1-commands.txt.
    """

    def build(self):
        s1 = self.addSwitch('s1', cls=P4Switch, json_path=JSON_PATH, thrift_port=THRIFT_PORT)

        for i in range(1, 5):
            host = self.addHost(
                'h%d' % i,
                ip='10.0.0.%d/24' % i,
                mac='00:00:00:00:00:0%d' % i,
            )
            self.addLink(host, s1)

        collector = self.addHost('h5', ip='10.0.0.5/24', mac='00:00:00:00:00:05')
        self.addLink(collector, s1)


def main():
    topo = CollectiveTopo()
    net = Mininet(topo=topo, controller=None)
    net.start()

    sleep(1)

    info('*** Pushing switch configuration (forwarding rules, mirroring session, threshold)\n')
    os.system('simple_switch_CLI --thrift-port %d < %s' % (THRIFT_PORT, CLI_COMMANDS_FILE))

    info('*** Network ready.\n')
    info('    Workers   : h1 (10.0.0.1) h2 (10.0.0.2) h3 (10.0.0.3) h4 (10.0.0.4)\n')
    info('    Collector : h5 (10.0.0.5) -- run scripts/collector.py here\n')

    CLI(net)
    net.stop()


if __name__ == '__main__':
    setLogLevel('info')
    main()
