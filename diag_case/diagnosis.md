# 诊断案例：一次内存尖峰的完整溯源

> 园区网 cEOS 实验中，Grafana 上出现一个内存尖峰。本文完整记录从**发现 → 初步诊断（含走偏）→ 指标+日志排查 → 再次诊断 → 复现验证 → 最终定位**的全过程，包括几次被推翻的错误假设——因为那才是这个案例真正的价值。

---

## TL;DR

| 项 | 结论 |
|----|------|
| **现象** | 13:52:15（本地 CEST）`system_memory_used` 尖峰 9923 MB，比基线 ~9790 MB 高约 **+130 MB**，~90 秒后回落 |
| **CPU** | 同期基本平坦（11–13%），**没有**配套 CPU 尖峰——这本身是个排除线索 |
| **可靠信号** | ConfigAgent + Sysdb 四台**同时** +54 MB，"猛跳 + 缓慢回落" |
| **日志** | 四台、所有层面 13:52 **零事件**（不是配置变更、不是 agent 事件、不是 OS 事件） |
| **最终根因** | 一次针对四台的 **gNMI 批量读**（自身操作），读操作**不进日志**，故日志空但指标有 |
| **验证方式** | 对照实验：`show running-config`（CLI 读）**证伪** → gNMI GET `/Sysdb` **复现**同样的形状 |

---

## 1. 现象发现

用户在 Grafana 的 `Campus gNMI Telemetry` 仪表盘上注意到 13:52 左右有一个内存尖峰，要求排查。

先对齐时间（避免时区误判）：Mac 与 VM 均为 **CEST（UTC+2）**，Grafana 按浏览器本地时间显示。因此 **13:52 本地 = 11:52 UTC**。

用 Prometheus 逐点拉出 `system_memory_state_used`（经 core1）确认尖峰真实存在：

```
13:51:45  9788 MB
13:52:00  9829 MB
13:52:15  9923 MB   ← 峰值（+130MB / +1.6%）
13:52:30  9886 MB
...
13:54:52  9712 MB   ← 已回落到基线
```

---

## 2. 初步诊断（及其偏差）

第一反应有两点判断，一对一错：

1. **✅ 对：内存指标是 VM 全局口径。** 四台路由器的 `system_memory` 曲线**完全同步**（都在 9589–9840 一起动）——因为 cEOS 是容器，`/system/memory` 报的是**底层 Lima VM** 的内存，四台共享。所以"设备内存尖峰"往往反映的是 VM 层活动，而非某台设备。

2. **❌ 走偏：过度归因于 `systemctl` 新进程。** 用每进程遥测做峰值前后的两点对比，看到峰值时刻冒出一批 NEW `systemctl` 进程，就先入为主认为是它们导致的。**这个判断后来被证明不可靠**（见 §4）。

> 教训：**两点对比容易被瞬时噪声误导**，必须看时间序列。

---

## 3. 指标 + 日志排查

### 3.1 每进程分解

用新接入的每进程遥测（gNMI EOS-native `/Kernel/proc/stat`，`event-jq` 把 `comm` 转成 `proc_info{pid,proc}` 以便 PromQL join）做峰值 vs 基线的 RSS 增量：

```
edge1  ConfigAgent   575MB -> 582MB   Δ=+7.7MB
core2  systemctl       NEW -> 8MB     Δ=+7.6MB   (新进程)
core2  ConfigAgent   573MB -> 580MB   Δ=+7.2MB
core2  Sysdb         222MB -> 227MB   Δ=+4.7MB
edge2  ConfigAgent   574MB -> 579MB   Δ=+4.7MB
core1  Sysdb / ConfigAgent ...        Δ=+4.x MB
```

看起来是"systemctl 新进程 + ConfigAgent/Sysdb 增长"的混合。

### 3.2 旁支发现：rsyslog 崩溃循环

追查那批 `systemctl` 从哪来，进入 Linux 层日志 `/var/log/messages`：

```
rsyslog.service: Scheduled restart job, restart counter is at 2478505
rsyslog.service: Main process exited, code=exited, status=1/FAILURE
```

**rsyslog 一直起不来、被 systemd 无限重启，计数达 248 万次。** 根因诊断：

- `module(load="imuxsock")` 默认要绑 `/run/systemd/journal/syslog`；
- 但 `ss -lxp` 证实该套接字**被 systemd 本尊（pid=1, fd=88）持有**——它是 socket-activation 的监听套接字（`syslog.socket` → `Triggers: rsyslog.service`）；
- rsyslog 没消费 systemd 传入的 fd，自己去 bind → **EADDRINUSE**（那句 "Permission denied" 是 rsyslog 的笼统措辞，底层是地址已占用）→ 退出；
- `Restart=on-failure` + `RestartUSec=100ms` + **`StartLimitIntervalUSec=0`（限流被关）** → 每 100ms 重启一次、永不放弃。

这是**容器里 systemd 做 PID 1 时 socket-activation 与 rsyslog 直接绑定套接字冲突**的经典坑（参见 rsyslog#4896、docker-rsyslog#25）。它无害（EOS 日志走 Sysdb，不依赖它），因此没人发现——需要"长时间运行 + 主动进程级监控"才会暴露，这套实验恰好凑齐了这两个条件。

> **注意**：rsyslog 崩溃循环是**持续背景**（11:45 和 11:52 都是 ~20 次/分），是内存底噪的来源之一，但**不是** 13:52 尖峰的专有原因。

### 3.3 日志：决定性的"什么都没有"

回到 13:52 本身，查四台的三层日志：

| 检查 | 结果 |
|------|------|
| `show logging`（EOS agent 层，Sysdb） | 13:52 **无事件**（最后一条停在 Jul 8 改 gNMI 配置那次） |
| `/var/log/agents/ConfigAgent-*` | 只有开机初始化一行，之后**再无** |
| `/var/log/agents/Sysdb-*` | 停在 Jul 8 09:08 |
| `/var/log/messages`（四台，11:52，剔除 rsyslog） | **非 rsyslog 行数 = 0** |

**内存涨了 +54MB 却一个字都没记**——这个"什么都没有"本身就是强证据，直接排除：

- ❌ 不是配置变更（会记 `%SYS-5-CONFIG_I`）
- ❌ 不是 Sysdb 结构性事件（会进 Sysdb 日志）
- ❌ 不是 OS/systemd 事件（messages 除 rsyslog 空空如也）

### 3.4 时间序列：一次性、非周期

把 ConfigAgent+Sysdb 合计拉到 3 小时窗口：

```
13:22 ─ 13:50   3182 MB   ← 28 分钟死平
13:52           3236 MB   ← 突跳 +54MB（唯一尖峰）
13:54           3192 MB   ← 回落但略高于基线
13:54 ─ 14:36   3192 → 3183   ← 缓慢滑回
```

**整个 3 小时只出现一次**，前平后不复现 → 排除周期性内部动作（housekeeping/checkpoint）。

同时确认 `gnmic`/`gnmic-proc` 容器 11:20 启动、`Restarts=0`、11:52 无重连日志 → 排除采集器重连。

---

## 4. 再次诊断（修正）

综合上述，修正 §2 的错误判断：

- **推翻"systemctl 新进程主导"**：时间序列显示 `systemctl` 计数是单调爬升（陈旧序列因 `proc_info` 的 6h expiration 未清），是测量假象，不能用；`allproc` 总和同样被灌水。**唯一干净可信的信号是 pid 稳定的 ConfigAgent+Sysdb**，它清晰地"尖峰-回落"。
- **确立新假设**：一次**一次性、无日志、同时打到四台**的操作。ConfigAgent（管配置）+ Sysdb（管状态）会为**服务读请求**分配序列化缓冲，而**读操作按设计不写日志**（只有写才记）。"四台同时"符合"一个读同时打到四台"。

---

## 5. 复现验证（对照实验）

假设必须能复现才算数。做两组对照，各先记基线、并行发命令、再连续采样。

### 5.1 证伪：CLI 读

```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  docker exec clab-campus-$d Cli -c "show running-config all" & done; done; wait
```

结果：ConfigAgent+Sysdb **3183 → 3183 MB，纹丝不动**。
→ **"CLI 读"假设证伪。** 原因：`show running-config` 由 **Cli 进程**从 Sysdb 读、在它自己进程里拼输出，不会让 ConfigAgent/Sysdb 分配并保留内存。

### 5.2 证实：gNMI 读

```bash
for r in 1 2 3; do for d in core1 core2 edge1 edge2; do
  gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure get --path 'eos_native:/Sysdb' & done; done; wait
```

结果（含 Octa）：

```
基线            4080 MB
GET 后          6520 MB   ← +2440MB
+2min           6181 MB
+3min           5612 MB   ← 缓慢回落，停在平台
（数分钟后）    4486 MB → 逐步回基线
```

→ **"gNMI 读"假设证实。** 且**形状一致**：猛跳 → 缓慢回落 → 停在略高于基线的平台。量级差异（+2440MB vs 原始 +54MB）只因我读了整个 `/Sysdb` 巨树，原始事件读的是小子树。

---

## 6. 最终定位与机制

**13:52 的 +130MB VM 内存尖峰 = 一次针对四台的 gNMI 批量读**（几乎肯定是搭建遥测/排查期间自身发出的某条 `gnmic get`）。其中可靠归因的部分是 ConfigAgent+Sysdb 的 +54MB，其余为 VM 级噪声。

**机制**：

- **CLI 读**（`show running-config`）：由 Cli 进程服务，输出在 Cli 自己进程里 → agent rss 不动。
- **gNMI 读**（`gnmic get`）：走 **Octa → Sysdb**，把状态树序列化成 gNMI/protobuf，**在这条链上分配缓冲**；Octa/Sysdb 用**内存池**，用完不立即还给 OS，**缓慢 GC** → 表现为"猛跳 + 缓慢回落 + 停在略高平台"。

**为什么日志是空的**：gNMI/CLI 的**读**操作**不产生日志**，只有配置**写**才记 `%SYS-5-CONFIG_I`。因此四台日志全空、但内存指标抓到了——完全自洽。

---

## 7. 可观测性启示

1. **配置的"读"不留痕，只有"写"才记日志。** 光看日志会误以为"什么都没发生"；光看指标只见尖峰不知因由；**两者交叉 + 排除法**才能推断出"是一次没记日志的读"。
2. **两点对比会骗人，要看时间序列。** 初诊被瞬时噪声（systemctl）带偏，时间序列才暴露真正的稳定信号（ConfigAgent+Sysdb）。
3. **注意指标口径。** `system_memory` 是 VM 全局；`proc_info` 的 6h expiration 会让"计数类"聚合被陈旧序列灌水。
4. **假设必须能复现。** "CLI 读"被实验直接证伪，换"gNMI 读"才复现——不做实验会停在错误结论上。
5. **要连"读"也能追溯**：需开 **AAA command accounting**（记录每条管理命令），那是额外一层探针。

---

## 附录：关键命令与查询

**定位峰值 / 逐点内存**
```
curl -s 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=system_memory_state_used{source=~".*core1.*"}' \
  --data-urlencode 'start=...' --data-urlencode 'end=...' --data-urlencode 'step=15'
```

**每进程内存（join 出进程名）**
```
eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc) proc_info * 4096
```

**ConfigAgent+Sysdb 合计（可靠信号）**
```
sum(eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc)
    proc_info{proc=~"ConfigAgent|Sysdb"}) * 4096
```

**三层日志**
```
docker exec clab-campus-core2 Cli -c "show logging"            # EOS agent 层
docker exec clab-campus-core2 cat /var/log/agents/ConfigAgent-*  # 单 agent
docker exec clab-campus-core2 cat /var/log/messages           # Linux/systemd 层
```

**rsyslog 根因取证**
```
docker exec clab-campus-core2 ss -lxp | grep journal/syslog    # 谁持有套接字
docker exec clab-campus-core2 systemctl show rsyslog.service \
  -p Restart -p RestartUSec -p StartLimitIntervalUSec -p NRestarts
```

**复现实验**
```
# 证伪：CLI 读（无变化）
docker exec clab-campus-$d Cli -c "show running-config all"
# 证实：gNMI 读（复现尖峰）
gnmic -a clab-campus-$d:6030 -u admin -p admin --insecure get --path 'eos_native:/Sysdb'
```
