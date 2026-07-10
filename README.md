# Campus Network Lab — Arista cEOS + containerlab

**语言 / Language:** [中文](#中文) · [English](#english)

一个跑在 macOS 上 Lima 虚机里的园区网仿真实验,用 [containerlab](https://containerlab.dev/) 搭建,融合 Arista cEOS 路由器与 Alpine 二层交换机,并叠加了一整套可观测性栈:流式遥测(gNMI)、SNMP、Prometheus、Grafana。

A simulated campus network running in a Lima VM on macOS, built with
[containerlab](https://containerlab.dev/). It combines Arista cEOS routers and
Alpine L2 switches, plus a full observability stack: streaming telemetry
(gNMI), SNMP, Prometheus, and Grafana.

> ⚠️ Arista cEOS 镜像(`cEOSarm-lab-*.tar.xz`)是专有软件,**不包含**在本仓库里。部署前请自行导入你持有授权的镜像。
> The Arista cEOS image is proprietary and is **not** included. Import your own licensed image before deploying.

## Topology / 拓扑

```
                internet (inet, border NAT)
                /                     \
            edge1                     edge2      Arista cEOS, OSPF area 0
              |                         |
            core1 ==== peer-link ==== core2      Arista cEOS, OSPF area 0
              |                         |
            csw1                      csw2        Alpine L2 bridge
           /    \                    /    \
        asw1    asw2              asw3    asw4    Alpine L2 bridge
         |        |                |        |
        pc1      pc2              pc3      pc4    Alpine hosts
        10.1.0.11 .12             10.2.0.11 .12
```

---

## 中文

### 概述

- **路由:** edge1/edge2/core1/core2 之间跑单区 OSPF(area 0),边界节点向 `inet` 注入默认路由。
- **两个网段:** 10.1.0.0/24(pc1/pc2 挂在 csw1 后)和 10.2.0.0/24(pc3/pc4 挂在 csw2 后),东西向流量因此会横穿 OSPF 核心。
- **可观测性:** 路由器走 gNMI 流式遥测(OpenConfig + EOS-native),交换机走 SNMP,统一汇入一个 Prometheus,由 Grafana 展示。

### 目录结构

| 路径 | 说明 |
|------|------|
| `campus.yml` | containerlab 拓扑(节点 + 链路) |
| `configs/*.cfg` | Arista 启动配置(OSPF + gNMI + 用户) |
| `deploy.sh` | containerlab 部署脚本 |
| `Dockerfile.clab-alpine` | 交换机/主机用的 Alpine 镜像 |
| `setup-services.sh` | **一键恢复**重部署后所有临时服务 |
| `telemetry/` | gNMI 采集 + Prometheus + Grafana 栈 |
| `zabbix/` | Zabbix + 交换机 SNMP 配置 |
| `topology.html` | 渲染出的拓扑视图 |

### 快速开始

```bash
# 1. 导入你持有授权的 cEOS 镜像,然后部署实验
sudo containerlab deploy -t campus.yml

# 2. 恢复临时服务(pc 网页/视频、流量生成、NAT、遥测栈)
bash setup-services.sh
```

`setup-services.sh` 是幂等的——随时可重复运行,每次 `containerlab destroy && deploy` 之后都跑一次即可。

### 可观测性入口(从 Mac 访问)

| 地址 | 内容 |
|------|------|
| `http://localhost:3000` | Grafana — 仪表盘 *Campus gNMI Telemetry* |
| `http://localhost:9090` | Prometheus |
| `http://localhost:8082` | pc1 内部 Web 服务(经边界 DNAT) |
| `http://localhost:8092` | pc2 循环视频流(经边界 DNAT) |

仪表盘面板:各接口吞吐、核心互联链路、丢弃率、CPU/内存、链路状态(gNMI on-change)、交换机吞吐(SNMP)、每进程内存(gNMI EOS-native `/Kernel/proc`,已 join 出进程名)。

### 采集设计要点

- **路由器 → gNMI:** 两个 `gnmic` 实例。主实例流式采集接口计数(`sample`)、链路状态(`on-change`)、系统 CPU/内存;第二个(`gnmic-proc`)从 EOS-native 的 `/Kernel/proc/stat` 采每进程内存,并用 `event-jq` 处理器把每个 `comm` 叶子转成 `proc_info{pid,proc}` 序列,这样 PromQL 就能按 pid → 进程名 join。
- **交换机 → SNMP:** `snmp_exporter`(`if_mib` 模块),由 Prometheus 抓取。
- gNMI target 使用**容器名**(而非 IP),以躲开重部署时 DHCP 地址漂移。

> 配置里的口令(`admin/admin`、SNMP `public`、`zabbix/zabbix`)都是这个隔离实验环境的一次性弱口令。

---

## English

### Overview

- **Routing:** single-area OSPF (area 0) across edge1/edge2/core1/core2; edge nodes inject a default route toward `inet`.
- **Two subnets:** 10.1.0.0/24 (pc1/pc2 behind csw1) and 10.2.0.0/24 (pc3/pc4 behind csw2), so east-west traffic crosses the OSPF core.
- **Observability:** routers stream gNMI telemetry (OpenConfig + EOS-native), switches export SNMP, all into one Prometheus, visualized in Grafana.

### Layout

| Path | What |
|------|------|
| `campus.yml` | containerlab topology (nodes + links) |
| `configs/*.cfg` | Arista startup-configs (OSPF + gNMI + users) |
| `deploy.sh` | containerlab deploy helper |
| `Dockerfile.clab-alpine` | Alpine image for switches/hosts |
| `setup-services.sh` | **one-shot restore** of all ephemeral services after redeploy |
| `telemetry/` | gNMI collection + Prometheus + Grafana stack |
| `zabbix/` | Zabbix + switch SNMP setup |
| `topology.html` | rendered topology view |

### Quick start

```bash
# 1. import your licensed cEOS image, then deploy the lab
sudo containerlab deploy -t campus.yml

# 2. restore ephemeral services (pc web/video, traffic gen, NAT, telemetry)
bash setup-services.sh
```

`setup-services.sh` is idempotent — re-run it any time, and always after a
`containerlab destroy && deploy`.

### Observability endpoints (from the Mac)

| Endpoint | What |
|----------|------|
| `http://localhost:3000` | Grafana — dashboard *Campus gNMI Telemetry* |
| `http://localhost:9090` | Prometheus |
| `http://localhost:8082` | pc1 internal web server (via border DNAT) |
| `http://localhost:8092` | pc2 looping video stream (via border DNAT) |

Dashboard panels: per-interface throughput, core inter-link, discards,
CPU/memory, link status (gNMI on-change), switch throughput (SNMP), and
per-process memory (gNMI EOS-native `/Kernel/proc`, joined to process names).

### Collection design notes

- **Routers → gNMI:** two `gnmic` instances. The main one streams interface
  counters (`sample`), link status (`on-change`), and system CPU/memory. A
  second (`gnmic-proc`) streams per-process memory from the EOS-native
  `/Kernel/proc/stat` tree; an `event-jq` processor turns each `comm` leaf into
  a `proc_info{pid,proc}` series so PromQL can join pid → process name.
- **Switches → SNMP:** `snmp_exporter` (`if_mib`) scraped by Prometheus.
- gNMI targets use **container names** (not IPs) to survive DHCP address shifts
  across redeploys.

> Credentials in these configs (`admin/admin`, SNMP `public`, `zabbix/zabbix`)
> are throwaway values for this isolated lab only.
