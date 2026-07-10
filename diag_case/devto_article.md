---
title: "The memory spike that left no trace in the logs"
published: false
description: "Debugging a phantom memory spike across four Arista cEOS routers with gNMI telemetry — where the logs said nothing, my first two guesses were wrong, and only a reproduction experiment settled it."
tags: devops, networking, observability, monitoring
cover_image: ""
# canonical_url: leave empty so this dev.to post is the canonical home,
# or point it at your GitHub write-up if you prefer that as the original.
---

A memory spike showed up on a Grafana dashboard for a small lab I run. I checked the logs. They said nothing happened.

That "nothing" turned out to be the whole clue.

This is a short detective story about network observability — and about why "just check the logs" is only half the job. I got the first two guesses wrong, which is the interesting part, so I'll leave the mistakes in.

## The setup

The lab is four **Arista cEOS** routers plus a couple of Alpine L2 switches, wired up with [containerlab](https://containerlab.dev/) and instrumented end to end:

- **routers → gNMI** streaming telemetry (OpenConfig + EOS-native), collected by `gnmic`
- **switches → SNMP** via `snmp_exporter`
- everything into **Prometheus**, visualized in **Grafana**

The spike itself was modest — about **+130 MB**, gone in **90 seconds**. Easy to ignore. But it was a perfect excuse to test the thing I actually care about: *when a graph twitches, can the stack tell you why?*

## Act 1 — First guess (wrong)

The memory metric moved on all four routers **in lockstep**. First clue: in cEOS, `/system/memory` reports the **underlying host**, not the individual device — so a "device memory spike" is often really a host-level event, and the four numbers move together because they're all reading the same VM.

I pulled per-process memory (I'd wired up gNMI's EOS-native `/Kernel/proc` tree, joined to process names in PromQL) and did a quick before/after comparison. It showed a burst of short-lived `systemctl` processes. Case closed, I said.

I was wrong.

## Act 2 — The rabbit hole

Chasing those `systemctl` processes led somewhere I didn't expect. In `/var/log/messages`:

```
rsyslog.service: Scheduled restart job, restart counter is at 2478505
rsyslog.service: Main process exited, code=exited, status=1/FAILURE
rsyslog.service: Failed with result 'exit-code'.
```

**rsyslog was crash-looping — 2.4 million restarts.** Root cause, once I dug in:

```
$ ss -lxp | grep journal/syslog
u_dgr UNCONN ... /run/systemd/journal/syslog ... users:(("systemd",pid=1,fd=88))
```

systemd (PID 1) holds `/run/systemd/journal/syslog` as a **socket-activation** listener. rsyslog's `imuxsock` wasn't consuming the passed fd — it tried to bind the socket itself, got `EADDRINUSE`, and exited. And the restart limiter was disabled:

```
Restart=on-failure
RestartUSec=100ms
StartLimitIntervalUSec=0   # rate limiting OFF -> never gives up
NRestarts=2490662
```

So it looped every 100 ms, forever. Completely harmless — EOS logs through its own database, not this rsyslog — and nobody had ever noticed, because you only see it if you run long enough *and* watch at the process level. A great bonus find.

But it was **constant background noise**, not the cause of *this* spike. Back to 13:52.

## Act 3 — What the logs said: nothing

I checked every log layer, on all four devices, at the moment of the spike:

| Layer | Command | Result at spike |
|---|---|---|
| EOS agent log | `show logging` | **no events** |
| ConfigAgent | `/var/log/agents/ConfigAgent-*` | only the boot-init line |
| Sysdb | `/var/log/agents/Sysdb-*` | last entry days earlier |
| Linux / systemd | `/var/log/messages` | **only rsyslog noise, 0 other lines** |

Zero events. Nothing logged at all.

And that "nothing" is itself a strong signal: no config change (those log `%SYS-5-CONFIG_I`), no state event, no OS event. Whatever moved the memory did so **silently**.

## Act 4 — The time series told the real story

Back to the metrics, but with discipline this time — full time series instead of a two-point comparison. The reliable signal wasn't `systemctl` at all; that count was inflated by stale series (a metric-expiry artifact). It was **ConfigAgent + Sysdb** rising together:

```
13:22 – 13:50   3182 MB   flat for 28 minutes
13:52           3236 MB   +54 MB, one sharp jump
13:54 – 14:36   3192 → 3183 MB   slow decay, never repeats
```

**+54 MB, simultaneously, across all four routers. Flat before, one jump, slow decay, one-off in three hours.**

Silent. Simultaneous. One-off. That shape points to one thing: a **read** — something querying all four devices at once. Because here's the thing:

> Config **writes** get logged. Config **reads** don't. There's an entire class of activity your logs will never show you.

## Act 5 — Then I proved it

A hypothesis you can't reproduce is just a story. So I ran a controlled experiment — record baseline, fire the command at all four in parallel, watch the metric.

**Attempt 1 — a CLI read:**

```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  docker exec clab-campus-$d Cli -c "show running-config all" &
done; done; wait
```

Result: `3183 → 3183 MB`. **No movement. Falsified.** `show running-config` is served by the CLI process itself; it never makes ConfigAgent/Sysdb allocate.

**Attempt 2 — a gNMI read:**

```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure \
    get --path 'eos_native:/Sysdb' &
done; done; wait
```

Result: `4080 → 6520 MB`, then a slow decay back toward baseline. **Same shape as the original event. Confirmed.** (The magnitude is much bigger only because I read the entire `/Sysdb` tree; the original was a small subtree.)

## Root cause & mechanism

The 13:52 spike was a **bulk gNMI read hitting all four devices** — almost certainly one of my own commands while building the telemetry.

- **CLI reads** are served by the `Cli` process; the output lives in *its* memory → the agents' RSS never moves.
- **gNMI reads** go through **Octa → Sysdb**, serializing the state tree into gNMI/protobuf buffers. Those agents use **memory pools** — they don't hand memory back to the OS immediately, they GC lazily. Hence the signature: sharp jump, slow decay, settles slightly above baseline.
- **Empty logs**, because read operations don't log. Only writes do.

Four log layers said "nothing happened." The metrics said otherwise. Both were right — the event simply lived in the blind spot of one of them.

## What I kept

- **Reads leave no trace — only writes log.** Rely on logs alone and a whole class of activity is invisible. You need metrics *and* logs *and* elimination.
- **Two-point comparisons lie. Read the time series.** My first wrong answer came from two samples; the truth was in the shape over time.
- **Know what your metric actually measures.** "Device memory" was host memory; a process count was inflated by expiry settings.
- **A hypothesis isn't a diagnosis until you reproduce it.** The experiment killed my convenient first theory and confirmed the real one.
- **Deep, long-running instrumentation surfaces things nobody looks for** — like a service that had quietly failed two million times.

None of this needed a fancy tool. It needed the willingness to be wrong on the first guess and to keep pulling the thread until the graph and the experiment agreed.

---

The whole lab and a longer bilingual write-up are open source, if you want to poke at it or reproduce the experiment:
**https://github.com/kedicat308/Arista-LLM**

What's the sneakiest *"the logs said nothing"* bug you've run into? I'd love to hear it.
