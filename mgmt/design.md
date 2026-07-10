# 设计:资源清单与操作管理 / Design: Inventory & Action Management

**语言 / Language:** [中文](#中文) · [English](#english)

> 多个 agent 同时读写这套 cEOS/Alpine 仿真设备,查询与配置动作**无人管理**,导致对现象(如 Grafana 上的指标异常)的分析**难以闭环**;同时缺少一份**资源清单(inventory)**。本文给出补全这两项管理的设计,暂不含实现代码。
>
> Multiple agents concurrently read and reconfigure this cEOS/Alpine lab. Those query/config actions are **unmanaged**, so analyzing an observed phenomenon (e.g. a metric anomaly in Grafana) **can't be closed to a root cause**; there is also no **inventory**. This document designs both, without implementation code yet.

---

## 中文

### 0. 问题的本质(来自 `diag_case` 的教训)

上一次内存尖峰排查的最终根因是"**我们自己的一次 gNMI 批量读**"。之所以难,是因为一条硬约束:

> **读操作不进设备日志。** 设备侧(syslog / AAA / 抓包)天然无法完整捕获查询类动作。

推论:**审计必须在"发起端(agent 侧)"做**。指望从设备那头把多个 agent 的行为反推出来,是死路。

而现在 3 个 agent 各自直连设备(`gnmic` / `docker exec` / eAPI / SNMP),**没有汇聚点**。没有汇聚点,就既做不了审计,也做不了清单——两者其实是同一个"接入层"的两面:清单是它"朝设备看"的视图,审计是它"朝 agent 看"的视图。

**前提(已确认):三个 agent 都是我方可控的 Claude/MCP agent。** 因此 choke point 用**自愿收敛**即可——共享一个 MCP server,不需要强制代理与凭据封闭(那是留给"存在不可控外部进程"场景的升级项,见 §7)。

### 1. 设计原则

1. **单一接入层(single choke point)。** 所有设备 I/O 走同一个 MCP server;它同时是清单来源、审计落点、协调点。
2. **发起端审计(client-side audit)。** 读写都在 agent 发起处记录,不依赖设备日志。
3. **设备侧兜底(defense in depth)。** 再加一个 config-hash 哨兵,捕获一切写操作——无论出自哪个 agent、走的哪条路,即使有人绕过接入层也能被发现。
4. **清单由实况对账生成,不手写。** 从 `containerlab inspect` 生成 + 静态元数据叠加,解决 DHCP 地址漂移。
5. **可闭环。** 审计事件要能叠加到 Grafana 指标时间轴上,让"异常 → 动作"变成一次查询。
6. **最小侵入。** 文件优先(YAML/NDJSON/锁文件),不引入数据库等重组件。

### 2. 总体架构

```
   agent-1 ─┐
   agent-2 ─┼──▶  campus-mcp (接入层)  ──▶  设备 (gNMI / eAPI / SSH / SNMP)
   agent-3 ─┘          │
                       ├─ inventory.yml    ← 真相源(资源管理)
                       ├─ audit.ndjson     ← 谁/何时/对谁/读还是写(操作管理)
                       ├─ leases/*.lock    ← 设备租约(协调,防互相踩)
                       └─ snapshots/        ← 写操作前后配置快照 + diff

   兜底: config-hash 哨兵 ──▶ audit(记为 drift / 未归属变更)
   闭环: audit ──▶ Loki ──▶ Grafana annotations(叠加在指标上)
```

**部署位置。** containerlab 跑在 Lima VM 内,gNMI target 用的是容器名(`clab-campus-core1:6030`),只在 VM 内可解析。因此 **campus-mcp 与哨兵都运行在 VM 内**;Mac 上的 agent 通过它间接访问,凭据(`admin/admin`、SNMP `public`)也收在 VM 内一处。

### 3. 管理一:资源清单 (Inventory)

**生成方式:** `containerlab inspect -f json` 给出实况(容器名、mgmt IP、kind、状态),再叠加一层静态元数据(角色、接入方式、采集口径)。每次 `destroy && deploy` 后跑一次 `sync-inventory` 对账——这顺带解决了 README 里提到的 DHCP 漂移。

**每台设备一条记录(字段):**

| 字段 | 示例 | 作用 |
|------|------|------|
| `name` | core1 | 逻辑名 |
| `clab_name` | clab-campus-core1 | gNMI/审计用的真实容器名 |
| `kind` | ceos / linux | 类型 |
| `role` | edge / core / csw / asw / pc / inet | 角色 |
| `zone` | 10.1.0.0/24 | 网段归属 |
| `mgmt_ip` | 172.30.30.x(对账刷新) | 可达性 |
| `access` | `{gnmi:6030, eapi:443, ssh:…, snmp:public}` | 接入方式与端口 |
| `cred_ref` | `admin-lab`(句柄,**不存明文**) | 凭据引用 |
| `telemetry` | gNMI 路径集 / snmp `if_mib` | 采集口径 |
| `managed_by` | (当前持租约的 agent 或空) | 归属 |
| `state` | running / down | 生命周期 |
| `config_hash` | sha256(running-config) | 漂移检测锚点 |
| `last_seen` | 时间戳 | 对账时间 |

**产物:** `inventory.yml`(人读 + 机读的真相源)+ `sync-inventory` 脚本。MCP 工具 `inv.list` / `inv.get` 对外暴露它,任何 agent 想"知道有哪些设备、怎么连"都查这一处,不再各自硬编码。

### 4. 管理二:操作管理 (Audit + 协调)

#### 4.1 审计日志

**append-only NDJSON,一行一动作:**

```json
{
  "ts": "2026-07-10T11:52:07Z",
  "correlation_id": "c-8f3a…",
  "agent_id": "agent-2",
  "device": "core1",
  "plane": "read",              // read | write | exec
  "method": "gnmi",             // gnmi | eapi | ssh | snmp | cli
  "target": "GET /Sysdb",       // 路径 / 命令
  "params_summary": "encoding=json_ietf",
  "result": "ok",              // ok | err
  "duration_ms": 143,
  "cfg_hash_before": "…",       // 仅 write
  "cfg_hash_after": "…",        // 仅 write
  "diff_ref": "snapshots/core1/2026-07-10T115207.diff"  // 仅 write
}
```

三个关键点:
- **归属(attribution):** 每个 agent 带 `agent_id`(在 MCP 会话建立时声明);`correlation_id` 把"一个任务里的多台设备操作"串起来(那次尖峰就是一个 correlation 下 4 台 GET)。
- **读也记:** `plane:read` 同样落盘——这正是设备日志缺失的那一半,也是闭环的关键。
- **写留痕:** 写前后各存一份 running-config 快照,生成 diff,`diff_ref` 指过去,可回滚、可追责。

#### 4.2 协调(设备租约)

**advisory lease,防止两个 agent 同时改同一台:**
- `lease.acquire(device, ttl)` → 写操作前拿排他租约(锁文件 `leases/core1.lock`,含 agent_id + 到期时间);`inventory` 的 `managed_by` 同步反映。
- `lease.release(device)` 或 TTL 到期自动释放。
- 读操作不需要租约(读不冲突);写操作**无租约则拒绝**。
- 冲突时 `dev.write` 返回"core1 当前被 agent-3 持有,到期 T",让发起 agent 自行退避。

#### 4.3 MCP 工具面(替代裸 `gnmic` / `docker exec`)

| 工具 | 作用 | 是否记审计 |
|------|------|-----------|
| `inv.list` / `inv.get` | 查清单 | 否(或轻量) |
| `dev.read(device, method, path)` | 读(gNMI GET / show / snmp get) | ✅ read |
| `dev.write(device, config)` | 写(需持租约,自动快照+diff) | ✅ write |
| `dev.exec(device, cmd)` | CLI / shell 执行 | ✅ exec |
| `lease.acquire / release(device)` | 租约 | ✅ |
| `audit.query(since, device, agent)` | 查审计(闭环用) | 否 |

原则:**agent 不再直接持有 gnmic/docker/凭据的用法,一切经工具**。因为三个 agent 都可控,靠约定(CLAUDE.md/系统提示 + 只经此层)即可收敛,无需强制。

#### 4.4 读的限流 / 配额 —— agent 层的 CoPP

**动机:读不是无害的旁观。** 在真实网络里,读消耗的恰是最稀缺、最共享的**控制平面 CPU/内存**——SNMP walk 大表、`show tech`、gNMI 过订阅都能把控制平面打满,进而**饿死**同在其上的 BGP/OSPF/BFD keepalive,导致邻居 flap 乃至断网。业界为此专门有 **CoPP(Control Plane Policing)** 限速打向控制平面的管理流量。`diag_case` 的 +130MB 尖峰就是这个现象的最小样本;多个 agent 无节制并发读同一批设备,本质是一次**自制的轮询风暴**。

因此接入层除了记账,还要给**读**加一层"软件版 CoPP":

- **批量读串行 / 限速:** 同一 `correlation_id` 内对多台设备的批量 GET **不并发**,或按令牌桶限速(如 ≤ N 台/秒),避免四台同时被拉。
- **每设备读配额:** 单位时间内对同一设备的读次数/数据量上限;超限则排队或拒绝并回明确原因。
- **高频/高开销路径管控:** 大表类读(全路由表、全 MAC/ARP、`show tech`)标记为 `heavy`,单独更严的配额;**能走遥测的,禁止 agent 主动拉**——看 Prometheus 里的现成序列,而不是再对设备发 GET。
- **全局读预算:** 跨所有 agent 的总读速率上限(真正的 CoPP 是设备全局的,这里对齐这个语义),防止三个 agent 各自"合规"但叠加起来压垮设备。
- **配额事件也记审计:** 被限流/拒绝的读同样落 `audit.ndjson`(`result:"throttled"`),既可复盘,也能在 Grafana 上看到"读压力"本身。

> 这层的价值不止防护:它把"读的成本"显式化,让闭环分析里能区分"异常是设备自身的,还是被我们的读打出来的"。

### 5. 兜底:config-hash 哨兵

一个独立的轮询器(cron 或 `/loop`),**与 MCP 层解耦**:
- 每 N 秒对每台 cEOS 取 `show running-config` 的哈希;
- 与 `inventory.config_hash` 比对,变了就:存快照 + 生成 diff + 写一条 `plane:write, agent_id:"unattributed"` 的审计事件,并更新清单哈希。

价值:**它捕获一切写操作,无论出自哪个 agent、是否绕过了接入层。** 这是设备侧唯一可靠的写审计(呼应 §0:读虽抓不到,但写一定改变 running-config)。读操作仍只能靠 §4 的发起端审计。

### 6. 闭环:接到 Grafana

`audit.ndjson` → Promtail/Loki → Grafana **annotations**,叠加在现有 `Campus gNMI Telemetry` 仪表盘的时间轴上。

**效果:** `diag_case` 那次排查从"发现→走偏→复现验证"的半天,变成一次查询——对 `[13:51:30, 13:53:00]` 查 audit → 直接看到 `agent-2 · gnmi · GET /Sysdb · core1/core2/edge1/edge2`(同一 correlation_id)→ 收工。**这就是"闭环"。**

### 7. 分阶段落地

| 阶段 | 内容 | 新组件 | 收益 |
|------|------|--------|------|
| **P0** | `inventory.yml` + `sync-inventory` + config-hash 哨兵 | 无(脚本+cron) | 当天可用;立刻捕获所有写操作 |
| **P1** | `campusctl read\|write\|exec --agent <id>` 薄封装 + audit.ndjson + 锁文件租约 | 一个 CLI | 读写都归属;三 agent 改走它 |
| **P2** | 把封装升级为 **MCP server**;audit → Loki → Grafana annotations | MCP server + Loki | LLM 原生调用;指标↔动作可视闭环 |
| **P3(可选)** | 凭据封闭 + 强制代理 | — | 仅当将来出现不可控外部 agent 时才需要(见 §0 前提) |

### 8. 待定问题

- **哨兵频率 vs 负载:** N 取多少?(尖峰案例说明频繁 `show running-config` 本身也会扰动指标,需权衡。)
- **交换机侧:** Alpine 交换机的"配置"是 `ip link` 命令,无 running-config 概念——写审计对它靠 `dev.exec` 记录即可,哨兵不覆盖。
- **审计留存:** NDJSON 轮转策略(按天/按大小)。
- **agent 身份可信度:** 自愿模式下 `agent_id` 是自声明的;若将来要防抵赖,再引入 P3 的令牌。

---

## English

### 0. The core problem (lesson from `diag_case`)

The last memory-spike investigation root-caused to "**our own gNMI batch read**." It was hard because of one hard constraint:

> **Reads never hit device logs.** The device side (syslog / AAA / packet capture) fundamentally cannot capture query actions completely.

Corollary: **audit must happen client-side (at the agent).** Trying to reconstruct multi-agent behavior from the device side is a dead end.

Today the 3 agents each connect directly (`gnmic` / `docker exec` / eAPI / SNMP) with **no convergence point**. Without one, you can build neither audit nor inventory — they are two faces of the same **access layer**: inventory is its device-facing view, audit is its agent-facing view.

**Premise (confirmed): all three agents are our own controllable Claude/MCP agents.** So the choke point can be **voluntary** — a shared MCP server — with no need for an enforcing proxy or credential enclosure (that's the upgrade for an "uncontrolled external process" scenario, see §7).

### 1. Principles

1. **Single choke point** — all device I/O through one MCP server; it is simultaneously inventory source, audit sink, and coordinator.
2. **Client-side audit** — record reads and writes where the agent initiates them, not from device logs.
3. **Device-side backstop** — a config-hash sentinel captures every write regardless of which agent made it or whether it bypassed the layer.
4. **Inventory generated by reconciliation**, not hand-written — from `containerlab inspect` plus static metadata; solves DHCP drift.
5. **Closeable loop** — audit events overlay onto the Grafana metric timeline, turning "anomaly → action" into a single query.
6. **Minimal footprint** — files first (YAML/NDJSON/lockfiles); no heavyweight DB.

### 2. Architecture

```
   agent-1 ─┐
   agent-2 ─┼──▶  campus-mcp (access layer)  ──▶  devices (gNMI / eAPI / SSH / SNMP)
   agent-3 ─┘          │
                       ├─ inventory.yml    ← source of truth (inventory)
                       ├─ audit.ndjson     ← who / when / what / read-or-write (actions)
                       ├─ leases/*.lock    ← device leases (coordination)
                       └─ snapshots/        ← pre/post config snapshots + diff

   backstop: config-hash sentinel ──▶ audit (as drift / unattributed change)
   loop:     audit ──▶ Loki ──▶ Grafana annotations (overlaid on metrics)
```

**Placement.** containerlab runs inside the Lima VM and gNMI targets use container names (`clab-campus-core1:6030`) resolvable only inside the VM. So **campus-mcp and the sentinel run inside the VM**; the Mac-side agents reach devices through it, and credentials (`admin/admin`, SNMP `public`) are held in one place inside the VM.

### 3. Management #1: Inventory

**Generation:** `containerlab inspect -f json` gives live facts (container name, mgmt IP, kind, state); layer static metadata on top (role, access methods, telemetry scope). Run `sync-inventory` after each `destroy && deploy` — this also fixes the DHCP drift noted in the README.

**One record per device (fields):**

| Field | Example | Purpose |
|-------|---------|---------|
| `name` | core1 | logical name |
| `clab_name` | clab-campus-core1 | real container name for gNMI/audit |
| `kind` | ceos / linux | type |
| `role` | edge / core / csw / asw / pc / inet | role |
| `zone` | 10.1.0.0/24 | subnet membership |
| `mgmt_ip` | 172.30.30.x (refreshed) | reachability |
| `access` | `{gnmi:6030, eapi:443, ssh:…, snmp:public}` | methods & ports |
| `cred_ref` | `admin-lab` (handle, **no plaintext**) | credential reference |
| `telemetry` | gNMI paths / snmp `if_mib` | collection scope |
| `managed_by` | (agent holding lease, or empty) | ownership |
| `state` | running / down | lifecycle |
| `config_hash` | sha256(running-config) | drift anchor |
| `last_seen` | timestamp | reconcile time |

**Artifacts:** `inventory.yml` (human- and machine-readable source of truth) + a `sync-inventory` script. MCP tools `inv.list` / `inv.get` expose it; any agent that needs to know "what devices exist and how to reach them" queries this one place instead of hard-coding.

### 4. Management #2: Actions (audit + coordination)

#### 4.1 Audit log

**Append-only NDJSON, one line per action** (schema mirrors the 中文 example above): `ts, correlation_id, agent_id, device, plane(read|write|exec), method(gnmi|eapi|ssh|snmp|cli), target, params_summary, result, duration_ms, cfg_hash_before/after, diff_ref`.

Three keys:
- **Attribution** — each agent carries `agent_id` (declared at MCP session setup); `correlation_id` ties together multi-device actions of one task (the spike was 4 GETs under one correlation).
- **Reads recorded too** — `plane:read` is persisted; this is exactly the half device logs miss, and the key to closing the loop.
- **Writes leave a trail** — a running-config snapshot before and after each write, with a diff; `diff_ref` points to it for rollback and accountability.

#### 4.2 Coordination (device leases)

Advisory leases prevent two agents from editing the same device:
- `lease.acquire(device, ttl)` before a write — exclusive lease (lockfile `leases/core1.lock` with agent_id + expiry); inventory's `managed_by` reflects it.
- `lease.release(device)` or automatic TTL expiry.
- Reads need no lease (reads don't conflict); a write **without a lease is rejected**.
- On conflict, `dev.write` returns "core1 held by agent-3 until T" so the caller can back off.

#### 4.3 MCP tool surface (replaces raw `gnmic` / `docker exec`)

| Tool | Purpose | Audited |
|------|---------|---------|
| `inv.list` / `inv.get` | query inventory | no (or light) |
| `dev.read(device, method, path)` | read (gNMI GET / show / snmp get) | ✅ read |
| `dev.write(device, config)` | write (needs lease; auto snapshot+diff) | ✅ write |
| `dev.exec(device, cmd)` | CLI / shell exec | ✅ exec |
| `lease.acquire / release(device)` | leases | ✅ |
| `audit.query(since, device, agent)` | query audit (for closing loops) | no |

Principle: **agents no longer hold gnmic/docker/credentials directly — everything goes through tools.** Since all three agents are ours, convention (CLAUDE.md / system prompt + "only via this layer") is enough; no enforcement needed.

#### 4.4 Read throttling / quotas — CoPP at the agent layer

**Motivation: reads are not harmless observation.** In real networks, reads consume the scarcest, most-shared resource — **control-plane CPU/memory**. An SNMP walk of a large table, a `show tech`, or gNMI over-subscription can saturate the control plane and thereby **starve** the BGP/OSPF/BFD keepalives running on it, causing adjacency flaps or outright outages. The industry built **CoPP (Control Plane Policing)** precisely to rate-limit management traffic hitting the control plane. The `diag_case` +130MB spike is the smallest instance of this; multiple agents reading the same devices without restraint is a self-inflicted polling storm.

So beyond accounting, the access layer must apply a "software CoPP" to **reads**:

- **Serialize / rate-limit batch reads:** batch GETs across devices under one `correlation_id` do **not** run concurrently, or are token-bucket rate-limited (e.g. ≤ N devices/sec), so four devices aren't pulled at once.
- **Per-device read quota:** cap read count/data volume per device per unit time; over the cap, queue or reject with a clear reason.
- **Govern heavy/high-frequency paths:** large-table reads (full routing table, full MAC/ARP, `show tech`) are tagged `heavy` with a stricter quota; **anything available via telemetry is off-limits to agent pulls** — read the existing Prometheus series instead of issuing a fresh GET.
- **Global read budget:** a total read-rate ceiling across all agents (real CoPP is device-global; mirror that semantic) so three individually-compliant agents can't collectively overwhelm a device.
- **Throttle events are audited too:** throttled/rejected reads also land in `audit.ndjson` (`result:"throttled"`), both for review and to make "read pressure" itself visible in Grafana.

> The value here isn't only protection: it makes the cost of reads explicit, so loop-closing analysis can distinguish "the anomaly is the device's own" from "the anomaly was induced by our reads."

### 5. Backstop: config-hash sentinel

A standalone poller (cron or `/loop`), **decoupled from the MCP layer**:
- every N seconds, hash each cEOS `show running-config`;
- compare to `inventory.config_hash`; on change, store a snapshot + diff, write an audit event with `plane:write, agent_id:"unattributed"`, and update the inventory hash.

Value: **it captures every write regardless of which agent made it or whether it bypassed the access layer.** This is the only reliable device-side write audit (echoing §0: reads can't be caught, but a write always mutates running-config). Reads still rely on the client-side audit in §4.

### 6. Closing the loop: into Grafana

`audit.ndjson` → Promtail/Loki → Grafana **annotations**, overlaid on the existing `Campus gNMI Telemetry` timeline.

**Effect:** the `diag_case` investigation collapses from a half-day (discover → wrong turn → reproduce) into a single query — look up audit for `[13:51:30, 13:53:00]` → see `agent-2 · gnmi · GET /Sysdb · core1/core2/edge1/edge2` (one correlation_id) → done. **That is "closing the loop."**

### 7. Phased rollout

| Phase | Content | New component | Payoff |
|-------|---------|---------------|--------|
| **P0** | `inventory.yml` + `sync-inventory` + config-hash sentinel | none (scripts + cron) | usable same-day; instantly captures every write |
| **P1** | `campusctl read\|write\|exec --agent <id>` thin wrapper + audit.ndjson + lockfile leases | one CLI | reads & writes attributed; agents switch to it |
| **P2** | promote wrapper to an **MCP server**; audit → Loki → Grafana annotations | MCP server + Loki | native LLM tool calls; visual metric↔action loop |
| **P3 (optional)** | credential enclosure + enforcing proxy | — | only if an uncontrolled external agent ever appears (see §0 premise) |

### 8. Open questions

- **Sentinel frequency vs load** — what N? (The spike case shows frequent `show running-config` itself perturbs metrics; trade-off needed.)
- **Switch side** — Alpine switch "config" is `ip link` commands, no running-config; write audit for them relies on `dev.exec` records, sentinel doesn't cover them.
- **Audit retention** — NDJSON rotation policy (by day / size).
- **Agent identity trust** — under the voluntary model `agent_id` is self-declared; if non-repudiation is ever needed, introduce P3 tokens.
