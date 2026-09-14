#!/bin/bash
# Reference commands for a demo round -- run these from the Mininet CLI
# (paste each `mininet> ...` line one at a time, or use `source` inside
# the mininet CLI is not supported, so just copy/paste manually).
#
# Scenario: a 3-way Gather to root h1 (context 7), with h4 delayed
# by 500 ms to emulate a straggler. Threshold (s1-commands.txt) is
# 300 ms, so this round should trigger exactly one telemetry report
# naming participant 4.

cat <<'EOF'
Paste the following into the `mininet>` prompt (topology.py must already
be running):

  h5 python3 scripts/collector.py h5-eth0 &

  h2 python3 scripts/worker_send.py h2-eth0 10.0.0.1 --op 2 --ctx 7 --pid 2 --n 3 --seq 1 &
  h3 python3 scripts/worker_send.py h3-eth0 10.0.0.1 --op 2 --ctx 7 --pid 3 --n 3 --seq 1 &
  h4 python3 scripts/worker_send.py h4-eth0 10.0.0.1 --op 2 --ctx 7 --pid 4 --n 3 --seq 1 --delay 0.5 &

Expected: h5's terminal prints exactly one "STRAGGLER ALERT" naming
participant 4, with skew delta_t just over 500000 us.

To confirm the baseline (no straggler) case, run again with all three
delays at 0 -- no report should appear.
EOF
