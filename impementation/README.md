# Collective-Aware In-Switch Telemetry — BMv2 Prototype

Implementation of the design described in the project report and PPT:
an in-switch, collective-aware telemetry aggregation framework for
barrier-synchronized collective operations (AllReduce, Ring-Shift,
Gather), built in P4_16 for the BMv2 software switch.

## How this maps to the design (PPT slide 14)

| Design step         | Where it lives                                                        |
|----------------------|------------------------------------------------------------------------|
| 1. Parse            | `parse_shim` state in `MyParser` — extracts context-shim header       |
| 2. Lookup           | `ctxIndex = hdr.shim.contextId[9:0]` — maps context ID to register slot|
| 3. Update           | `regTFast` / `regTSlow` min/max update in `update_and_check_skew()`   |
| 4. Calculate        | `skew = tslow - tfast` — plain register subtraction, no division/float|
| 5. Decide           | `skew > theta` → `clone3(...)`; otherwise forward with no overhead    |
| Report enrichment   | `MyEgress` — adds queue depth/delay only to the cloned report packet   |

Only the **skew-exceeding packet** triggers a clone; every other packet in
the round only touches local register state and is forwarded normally —
this is the "Collect → Aggregate → Report" principle from the last slide,
as opposed to per-packet Collect → Report.

## Files

```
p4src/collective_telemetry.p4   the P4 program (parser, context-shim,
                                 registers, skew logic, report generation)
topology.py                     Mininet topology: h1-h4 workers + h5 collector
                                 around one BMv2 switch s1
s1-commands.txt                 simple_switch_CLI setup: forwarding rules,
                                 mirroring session, skew threshold theta
scripts/worker_send.py          scapy sender: emits one context-shim-tagged
                                 packet, with optional injected delay
scripts/collector.py            scapy sniffer: decodes straggler reports
scripts/run_demo.sh             reference commands for a demo round
Makefile                        build / run / clean targets
```

## Prerequisites (already on the standard P4/BMv2 tutorial VM)

- `p4c` (P4_16 compiler, bmv2 backend)
- `simple_switch`, `simple_switch_CLI` (BMv2)
- `mininet`
- Python 3 + `scapy` (`pip3 install scapy` if missing)

## Build

```bash
cd collective_telemetry_project
make build
```

This compiles `p4src/collective_telemetry.p4` to
`build/collective_telemetry.json`. If your VM's `p4c` doesn't accept
`--target bmv2 --arch v1model` (older installs use a dedicated binary
instead), compile manually with:

```bash
p4c-bm2-ss -o build/collective_telemetry.json p4src/collective_telemetry.p4
```

## Run

```bash
sudo make run
```

This starts Mininet with the topology below and pushes `s1-commands.txt`
(forwarding table, mirroring session, skew threshold) into the switch.

```
h1(10.0.0.1) h2(10.0.0.2) h3(10.0.0.3) h4(10.0.0.4)
        \        \          |          /
                    [ s1 ]  <- collective_telemetry.p4
                      |
                    h5(10.0.0.5)  <- collector
```

You'll land on the `mininet>` prompt.

## Demo: a Gather round with one straggler

In one terminal (or via `xterm h5` from the Mininet CLI), start the
collector:

```
mininet> h5 python3 scripts/collector.py h5-eth0 &
```

Then run a 3-participant Gather to root `h1` (context ID 7), with
worker `h4` delayed by 500 ms to emulate a straggler:

```
mininet> h2 python3 scripts/worker_send.py h2-eth0 10.0.0.1 --op 2 --ctx 7 --pid 2 --n 3 --seq 1 &
mininet> h3 python3 scripts/worker_send.py h3-eth0 10.0.0.1 --op 2 --ctx 7 --pid 3 --n 3 --seq 1 &
mininet> h4 python3 scripts/worker_send.py h4-eth0 10.0.0.1 --op 2 --ctx 7 --pid 4 --n 3 --seq 1 --delay 0.5 &
```

With the default threshold theta = 300 ms (`s1-commands.txt`), the
switch computes skew ≈ 500 ms > theta, and h5's terminal prints:

```
==============================================================
STRAGGLER ALERT  |  context 7  |  Gather
  lagging participant : 4
  t_fast   (us)       : ...
  t_slow   (us)       : ...
  skew delta_t (us)   : ~500000
  switch queue depth  : ...
  switch queue delay  : ... us
==============================================================
```

Re-run the same three commands with `--delay 0` on all three workers:
no report should appear — confirming that normal (non-straggling)
rounds generate zero telemetry, per the event-driven design.

### Sanity-check the switch state directly

From another terminal on the VM:

```bash
simple_switch_CLI --thrift-port 9090
RuntimeCmd: register_read MyIngress.regTFast 7
RuntimeCmd: register_read MyIngress.regTSlow 7
RuntimeCmd: register_read MyIngress.regSlowPid 7
```

(Index `7` here is the context ID itself, since `CTX_TABLE_SIZE` = 1024
> 7 so the low-10-bit mapping is the identity for small IDs.)

## Tuning

- **Threshold theta**: `register_write MyIngress.regThreshold 0 <microseconds>`
  via `simple_switch_CLI`, or edit `s1-commands.txt` before `make run`.
- **Context table size**: `CTX_TABLE_SIZE` in the `.p4` file. Must stay a
  power of two — the context ID is mapped to a slot by bit-slicing its
  low bits (`hdr.shim.contextId[9:0]` for 1024 slots), since the P4
  data plane has no division/modulo. Larger tables reduce the chance
  of two concurrent operations aliasing to the same slot.
- **Traffic patterns**: `worker_send.py --op` takes `0=AllReduce`,
  `1=Ring-Shift`, `2=Gather` purely as a label carried in the report —
  the switch's skew logic is identical across all three, since (as
  the report argues) the correlation problem is the same regardless
  of which collective pattern generated the flows.

## Design notes / honest limitations (worth stating in your evaluation)

- **Wording**: per the PPT, this detects a *potential* collective
  straggler based on abnormal synchronization skew — it does not
  *guarantee* straggler identification (e.g., two genuinely
  concurrent-but-legitimate arrival times can still exceed theta under
  a badly tuned threshold).
- **Queue state on the report is the switch's state at report time**,
  sampled at the mirror port during the clone's own egress pass — it
  is a live snapshot of switch congestion, not a per-flow queue trace
  for the original packet (the same simplification STRAGFLOW's
  egress-side `deq_timedelta` reasoning makes).
- **Context-ID aliasing**: with a 1024-slot table, two operation
  contexts that collide on the low 10 bits will share state. This is
  a memory/accuracy tradeoff (challenge #4 in the PPT) — fine for a
  prototype, but worth mentioning as future work (e.g., a
  match-action table indexed by full context ID instead of a fixed
  register array, if TCAM budget allows).
- **No division/floating point anywhere** in the data plane, as
  required — skew is subtraction, context-slot mapping is bit-slicing,
  threshold comparison is a plain register compare.
- **Round reset**: state for a context is cleared once `numParticipants`
  packets have been seen, so the same context ID can be reused for the
  next synchronization round (e.g., successive AllReduce steps in a
  training loop) without needing a new ID every time.

## What's intentionally out of scope here

Full P4Runtime/gRPC control plane, table-based per-operation thresholds,
and a control-plane telemetry-analysis dashboard are not implemented —
the prototype uses `simple_switch_CLI` for static configuration, matching
the "implementation not yet started beyond early BMv2 experimentation"
status noted in the PPT's timeline slide. These are natural next steps
for Month 4 ("Mininet Testbed + Control Plane") in your six-month plan.
