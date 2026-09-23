# Basic P4 collective straggler detector

This is the first small experiment before building the larger
collective-aware telemetry system.

## Topology

```text
                 20 ms
        h3 -------------\
                         \
h1 ---------------------- s1 ---------------- h4
                         /
h2 ---------------------/
```

Actually, all four hosts connect directly to the same P4 switch:

```text
h1 ----\
h2 -----\
h3 ------ s1
h4 -----/
```

The h3-s1 link has 20 ms delay. h1, h2 and h3 are the three
collective participants; h4 is the receiver.

## What the P4 switch does

For each `context_id`, the switch stores:

- minimum ingress timestamp
- maximum ingress timestamp
- participant that produced the minimum timestamp
- participant that produced the maximum timestamp

It computes:

    skew = max_timestamp - min_timestamp

If:

    skew > 5000 microseconds

the switch prints a `STRAGGLER` message in the BMv2 log.

## Run

This exercise is intended to live at:

    ~/tutorials/exercises/straggler-basic

Then:

    make
    make run

In the Mininet CLI, send the three packets in this order:

    h1 python3 sender.py --participant 1 --context 1
    h2 python3 sender.py --participant 2 --context 1
    h3 python3 sender.py --participant 3 --context 1

Because h3's link has 20 ms delay, the third packet should arrive much
later than the first two.

Watch the switch log from another terminal:

    tail -f logs/s1.log

You should see a message similar to:

    STRAGGLER context=1 participant=3 skew_us=...
    min_participant=1 max_participant=3

The exact timestamp is expected to vary.

## Important first-version simplification

The 20 ms delay is configured on the h3-s1 link, so every packet from
h3 is delayed. We send exactly one packet from each participant, so
there is exactly one intentionally slow packet in this experiment.

Later we will replace this with per-packet delay injection and then
move the telemetry report from the BMv2 log into an actual control-plane
or collector packet.

## Why this maps to the research idea

The larger design in the supplied paper describes:

- a shared operation context,
- switch state for active synchronization,
- minimum and maximum observed arrival timestamps,
- temporal skew,
- a configurable threshold,
- and selective reporting when the skew exceeds the threshold.

This starter experiment implements only that core detection loop.
