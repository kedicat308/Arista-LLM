# 诊断案例：一次内存尖峰的完整溯源 / Diagnosis Case: Root-Causing a Memory Peak

**语言 / Language:** [中文](#中文) · [English](#english)

> 园区网 cEOS 实验中，Grafana 上出现一个内存尖峰。本文完整记录从**发现 → 初步诊断（含走偏）→ 指标+日志排查 → 再次诊断 → 复现验证 → 最终定位**的全过程，包括几次被推翻的错误假设——那才是这个案例真正的价值。
>
> In a campus cEOS lab, a memory peak showed up in Grafana. This document records the full path — **discovery → initial (partly wrong) diagnosis → metrics + logs → re-diagnosis → controlled reproduction → final root cause** — including the hypotheses that got falsified along the way, which is where the real value is.

---

## 中文

### TL;DR

| 项 | 结论 |
|----|------|
| **现象** | 13:52:15（本地 CEST）`system_memory_used` 尖峰 9923 MB，比基线 ~9790 MB 高约 **+130 MB**，~90 秒后回落 |
| **CPU** | 同期基本平坦（11–13%），**没有**配套 CPU 尖峰——这本身是个排除线索 |
| **可靠信号** | ConfigAgent + Sysdb 四台**同时** +54 MB，"猛跳 + 缓慢回落" |
| **日志** | 四台、所有层面 13:52 **零事件**（不是配置变更、不是 agent 事件、不是 OS 事件） |
| **最终根因** | 一次针对四台的 **gNMI 批量读**（自身操作），读操作**不进日志**，故日志空但指标有 |
| **验证方式** | 对照实验：`show running-config`（CLI 读）**证伪** → gNMI GET `/Sysdb` **复现**同样的形状 |

### 1. 现象发现

用户在 Grafana 的 `Campus gNMI Telemetry` 仪表盘上注意到 13:52 左右有一个内存尖峰。

先对齐时间（避免时区误判）：Mac 与 VM 均为 **CEST（UTC+2）**，Grafana 按浏览器本地时间显示，因此 **13:52 本地 = 11:52 UTC**。用 Prometheus 逐点确认尖峰真实存在：

```
13:51:45  9788 MB
13:52:15  9923 MB   ← 峰值（+130MB / +1.6%）
13:54:52  9712 MB   ← 已回落到基线
```

### 2. 初步诊断（及其偏差）

- **✅ 对：内存指标是 VM 全局口径。** 四台路由器 `system_memory` 曲线**完全同步**——cEOS 是容器，`/system/memory` 报的是底层 Lima VM 的内存，四台共享。所以"设备内存尖峰"往往反映 VM 层活动，而非某台设备。
- **❌ 走偏：过度归因于 `systemctl` 新进程。** 用两点对比看到峰值时刻冒出一批 NEW `systemctl` 进程就先入为主——后来被证明不可靠。

> 教训：**两点对比容易被瞬时噪声误导，必须看时间序列。**

### 3. 指标 + 日志排查

**3.1 每进程分解**（gNMI EOS-native `/Kernel/proc/stat`，`event-jq` 把 `comm` 转成 `proc_info{pid,proc}` 供 PromQL join）：峰值 vs 基线的 RSS 增量显示"systemctl 新进程 + ConfigAgent/Sysdb 增长"的混合。

**3.2 旁支发现：rsyslog 崩溃循环。** 追查 `systemctl` 来源进入 `/var/log/messages`：

```
rsyslog.service: Scheduled restart job, restart counter is at 2478505
rsyslog.service: Main process exited, code=exited, status=1/FAILURE
```

rsyslog 一直起不来、被 systemd 无限重启 **248 万次**。根因：`imuxsock` 默认要绑 `/run/systemd/journal/syslog`，但 `ss -lxp` 证实该套接字**被 systemd 本尊（pid=1, fd=88）持有**（socket-activation 监听套接字）；rsyslog 没消费传入的 fd 而自己去 bind → **EADDRINUSE**（那句 "Permission denied" 是笼统措辞）→ 退出；`RestartUSec=100ms` + **`StartLimitIntervalUSec=0`（限流被关）** → 每 100ms 重启、永不放弃。这是**容器里 systemd 做 PID 1 时 socket-activation 与 rsyslog 直接绑定套接字冲突**的经典坑。它无害（EOS 日志走 Sysdb），所以没人发现。**注意：它是持续背景（~20 次/分），不是 13:52 尖峰的专有原因。**

**3.3 日志：决定性的"什么都没有"。**

| 检查 | 结果 |
|------|------|
| `show logging`（EOS agent 层） | 13:52 **无事件** |
| `/var/log/agents/ConfigAgent-*` | 只有开机初始化一行 |
| `/var/log/agents/Sysdb-*` | 停在 Jul 8 09:08 |
| `/var/log/messages`（四台，11:52，剔除 rsyslog） | **非 rsyslog 行数 = 0** |

内存涨了 +54MB 却一个字都没记，直接排除：❌ 配置变更、❌ Sysdb 事件、❌ OS/systemd 事件。

**3.4 时间序列：一次性、非周期。**

```
13:22 ─ 13:50   3182 MB   ← 28 分钟死平
13:52           3236 MB   ← 突跳 +54MB（唯一尖峰）
13:54 ─ 14:36   3192 → 3183   ← 缓慢滑回
```

3 小时只出现一次 → 排除周期性动作。`gnmic`/`gnmic-proc` 容器 11:20 启动、`Restarts=0`、无重连 → 排除采集器重连。

### 4. 再次诊断（修正）

- **推翻"systemctl 主导"**：`systemctl` 计数是单调爬升（陈旧序列因 `proc_info` 6h expiration 未清），是测量假象；唯一干净可信的信号是 pid 稳定的 **ConfigAgent+Sysdb**。
- **新假设**：一次**一次性、无日志、同时打到四台**的操作。ConfigAgent（管配置）+ Sysdb（管状态）会为**读请求**分配序列化缓冲，而**读不写日志**。

### 5. 复现验证（对照实验）

**5.1 证伪：CLI 读**
```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  docker exec clab-campus-$d Cli -c "show running-config all" & done; done; wait
```
结果：**3183 → 3183 MB，纹丝不动。** 原因：`show running-config` 由 **Cli 进程**服务，不让 ConfigAgent/Sysdb 分配内存。

**5.2 证实：gNMI 读**
```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure get --path 'eos_native:/Sysdb' & done; done; wait
```
结果（含 Octa）：`基线 4080 → GET 后 6520（+2440）→ 缓慢回落 → 逐步回基线`。**形状一致**（猛跳+缓慢回落），量级差异只因读了整个 `/Sysdb` 巨树。

### 6. 最终定位与机制

**13:52 尖峰 = 一次针对四台的 gNMI 批量读**（搭遥测/排查期间自身操作）。机制：

- **CLI 读**由 Cli 进程服务，输出在自己进程里 → agent rss 不动。
- **gNMI 读**走 **Octa → Sysdb**，序列化状态树、分配缓冲；用**内存池**，用完不立即还给 OS，缓慢 GC → "猛跳 + 缓慢回落 + 停在略高平台"。
- **日志为空**：读操作不产生日志，只有配置**写**才记 `%SYS-5-CONFIG_I`。

### 7. 可观测性启示

1. **读不留痕，只有写才记日志**——日志会误以为"什么都没发生"，须指标 + 日志交叉 + 排除法。
2. **两点对比会骗人，要看时间序列。**
3. **注意指标口径**（`system_memory` 是 VM 全局；`proc_info` 6h expiration 会让计数类聚合灌水）。
4. **假设必须能复现**——CLI 读被实验证伪，换 gNMI 读才复现。
5. **要连"读"也能追溯**：需开 **AAA command accounting**。

---

## English

### TL;DR

| Item | Finding |
|------|---------|
| **Symptom** | At 13:52:15 (local CEST) `system_memory_used` peaked at 9923 MB, ~**+130 MB** over the ~9790 MB baseline, recovering in ~90 s |
| **CPU** | Essentially flat (11–13%) — **no** matching CPU spike, itself a ruling-out clue |
| **Reliable signal** | ConfigAgent + Sysdb rose +54 MB **simultaneously across all 4 routers**, "sharp jump + slow decay" |
| **Logs** | **Zero events** at 13:52 on all 4 devices, at every layer (not a config change, not an agent event, not an OS event) |
| **Root cause** | A **bulk gNMI read** against all 4 devices (self-inflicted); reads **don't log**, hence empty logs but a real metric bump |
| **Validation** | Controlled experiment: `show running-config` (CLI read) **falsified** → gNMI GET `/Sysdb` **reproduced** the same shape |

### 1. Discovery

A memory peak around 13:52 appeared in the `Campus gNMI Telemetry` dashboard.

First, align time zones: Mac and VM are both **CEST (UTC+2)**, and Grafana displays browser-local time, so **13:52 local = 11:52 UTC**. Confirm the peak is real via Prometheus:

```
13:51:45  9788 MB
13:52:15  9923 MB   ← peak (+130MB / +1.6%)
13:54:52  9712 MB   ← back to baseline
```

### 2. Initial diagnosis (and where it went wrong)

- **✅ Right: the memory metric is VM-wide.** All 4 routers' `system_memory` curves move in lockstep — cEOS is a container, and `/system/memory` reports the underlying Lima VM's memory, shared by all four. So a "device memory peak" usually reflects VM-level activity, not one device.
- **❌ Wrong turn: over-attributing to NEW `systemctl` processes.** A two-point comparison caught a batch of NEW `systemctl` processes at the peak and jumped to conclusions — later shown unreliable.

> Lesson: **two-point comparisons are fooled by transient noise; look at the time series.**

### 3. Investigation via metrics + logs

**3.1 Per-process decomposition** (gNMI EOS-native `/Kernel/proc/stat`, with an `event-jq` processor turning each `comm` into `proc_info{pid,proc}` for PromQL joins): the peak-vs-baseline RSS delta showed a mix of "NEW systemctl + ConfigAgent/Sysdb growth."

**3.2 Side-finding: rsyslog crash loop.** Chasing where `systemctl` came from led into `/var/log/messages`:

```
rsyslog.service: Scheduled restart job, restart counter is at 2478505
rsyslog.service: Main process exited, code=exited, status=1/FAILURE
```

rsyslog can't start and is restarted by systemd **2.4 million times**. Root cause: `imuxsock` defaults to binding `/run/systemd/journal/syslog`, but `ss -lxp` proves that socket is **held by systemd itself (pid=1, fd=88)** — the socket-activation listener. rsyslog doesn't consume the passed fd and instead tries to bind it → **EADDRINUSE** (the "Permission denied" wording is rsyslog's generic message) → exits; `RestartUSec=100ms` + **`StartLimitIntervalUSec=0` (rate limiting disabled)** → restarts every 100 ms forever. This is the classic **systemd-as-PID-1-in-a-container socket-activation vs direct-bind conflict**. It's harmless (EOS logging goes through Sysdb), so nobody noticed. **Note: it's a constant background (~20/min), NOT the specific cause of the 13:52 peak.**

**3.3 Logs: the decisive "nothing there."**

| Check | Result |
|-------|--------|
| `show logging` (EOS agent layer) | **no events** at 13:52 |
| `/var/log/agents/ConfigAgent-*` | only the boot-init line |
| `/var/log/agents/Sysdb-*` | stops at Jul 8 09:08 |
| `/var/log/messages` (all 4, 11:52, minus rsyslog) | **non-rsyslog lines = 0** |

Memory rose +54 MB with **not a single log line** — which rules out: ❌ config change, ❌ Sysdb event, ❌ OS/systemd event.

**3.4 Time series: one-off, not periodic.**

```
13:22 ─ 13:50   3182 MB   ← dead flat for 28 min
13:52           3236 MB   ← +54MB jump (the only spike)
13:54 ─ 14:36   3192 → 3183   ← slow drift back
```

One occurrence in 3 hours → rules out periodic housekeeping. `gnmic`/`gnmic-proc` containers started at 11:20, `Restarts=0`, no reconnect → rules out collector reconnection.

### 4. Re-diagnosis (correction)

- **Overturn "systemctl-driven"**: the `systemctl` count climbs monotonically (stale series lingering due to `proc_info`'s 6h expiration) — a measurement artifact; the only clean, reliable signal is the stable-pid **ConfigAgent+Sysdb**.
- **New hypothesis**: a **one-off, unlogged operation hitting all 4 devices simultaneously**. ConfigAgent (config) + Sysdb (state) allocate serialization buffers to serve **read requests**, and **reads don't log**.

### 5. Controlled reproduction

**5.1 Falsify: CLI read**
```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  docker exec clab-campus-$d Cli -c "show running-config all" & done; done; wait
```
Result: **3183 → 3183 MB, no movement.** Because `show running-config` is served by the **Cli process** and never makes ConfigAgent/Sysdb allocate.

**5.2 Confirm: gNMI read**
```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure get --path 'eos_native:/Sysdb' & done; done; wait
```
Result (incl. Octa): `baseline 4080 → after GET 6520 (+2440) → slow decay → back toward baseline`. **Same shape** (jump + slow decay); the larger magnitude is only because I read the entire `/Sysdb` tree.

### 6. Final root cause & mechanism

**The 13:52 peak = a bulk gNMI read against all 4 devices** (self-inflicted during telemetry setup/investigation). Mechanism:

- **CLI reads** are served by the Cli process, output stays in its own process → agent RSS unchanged.
- **gNMI reads** go **Octa → Sysdb**, serialize the state tree and allocate buffers; these agents use **memory pools**, don't return memory to the OS immediately, and GC slowly → "sharp jump + slow decay + settles slightly above baseline."
- **Empty logs**: read operations produce no log; only config **writes** log `%SYS-5-CONFIG_I`.

### 7. Observability takeaways

1. **Reads leave no trace — only writes log.** Logs alone say "nothing happened"; you need metrics + logs + elimination.
2. **Two-point comparisons mislead; read the time series.**
3. **Mind the metric semantics** (`system_memory` is VM-wide; `proc_info`'s 6h expiration inflates count-style aggregations).
4. **A hypothesis must be reproducible** — the CLI-read theory was falsified by experiment; only gNMI read reproduced it.
5. **To trace reads too**, enable **AAA command accounting** — an extra probe layer.

---

## 附录 / Appendix：关键命令与查询 / Key commands & queries

**逐点内存 / point-by-point memory**
```
curl -s 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=system_memory_state_used{source=~".*core1.*"}' \
  --data-urlencode 'start=...' --data-urlencode 'end=...' --data-urlencode 'step=15'
```

**每进程内存（join 进程名）/ per-process memory (join names)**
```
eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc) proc_info * 4096
```

**ConfigAgent+Sysdb 合计（可靠信号）/ ConfigAgent+Sysdb sum (reliable signal)**
```
sum(eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc)
    proc_info{proc=~"ConfigAgent|Sysdb"}) * 4096
```

**三层日志 / three log layers**
```
docker exec clab-campus-core2 Cli -c "show logging"              # EOS agent layer
docker exec clab-campus-core2 cat /var/log/agents/ConfigAgent-*  # single agent
docker exec clab-campus-core2 cat /var/log/messages             # Linux/systemd layer
```

**rsyslog 根因取证 / rsyslog forensics**
```
docker exec clab-campus-core2 ss -lxp | grep journal/syslog     # who holds the socket
docker exec clab-campus-core2 systemctl show rsyslog.service \
  -p Restart -p RestartUSec -p StartLimitIntervalUSec -p NRestarts
```

**复现实验 / reproduction**
```
# 证伪 / falsify: CLI read (no change)
docker exec clab-campus-$d Cli -c "show running-config all"
# 证实 / confirm: gNMI read (reproduces the peak)
gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure get --path 'eos_native:/Sysdb'
```
