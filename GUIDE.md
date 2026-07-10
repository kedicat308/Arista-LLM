# 园区网实验 —— 完整构建与运维指导书

> 本文覆盖整个实验从零到当前状态的**所有操作**：拓扑、路由（OSPF / iBGP / eBGP）、内部服务、边界 NAT 与对外暴露、可观测性（gNMI 遥测 + SNMP + Prometheus + Grafana + 每进程内存）、一键恢复脚本、验证命令、以及一路踩过的坑和持久化边界。
>
> 环境：macOS + Lima 虚机 `my-frr` + containerlab + Docker。仓库：`kedicat308/Arista-LLM`。
> ⚠️ Arista cEOS 镜像专有，不在仓库内，需自备授权镜像。

---

## 目录

1. [架构总览](#1-架构总览)
2. [拓扑与地址规划](#2-拓扑与地址规划)
3. [部署实验](#3-部署实验)
4. [路由：OSPF](#4-路由ospf)
5. [路由：iBGP（core1/core2）](#5-路由ibgpcore1core2)
6. [路由：eBGP（边界 ↔ ISP）](#6-路由ebgp边界--isp)
7. [内部服务（pc1/pc2/pc3）](#7-内部服务)
8. [边界 NAT 与对外暴露](#8-边界-nat-与对外暴露)
9. [可观测性栈](#9-可观测性栈)
10. [每进程内存遥测](#10-每进程内存遥测)
11. [一键恢复：setup-services.sh](#11-一键恢复setup-servicessh)
12. [访问入口速查](#12-访问入口速查)
13. [验证命令速查](#13-验证命令速查)
14. [踩过的坑（重要）](#14-踩过的坑重要)
15. [持久化边界](#15-持久化边界)

---

## 1. 架构总览

```
              AS 65100 (ISP, inet/FRR)  192.168.100.1 / .5
              宣告 0.0.0.0/0 + 203.0.113.0/24 + 198.51.100.0/24
                 │ eBGP                      │ eBGP
        ┌────── edge1 ──────┐        ┌────── edge2 ──────┐   AS 65001 (园区)
        │       │ OSPF      │        │       │ OSPF      │
        │     core1 ═══iBGP(Lo)═══ core2     │           │
        │       │ OSPF      │        │       │ OSPF      │
        │      csw1         │        │      csw2         │   Alpine 二层桥
        │    asw1  asw2     │        │    asw3  asw4     │
        │    pc1   pc2      │        │    pc3   pc4      │   Alpine 主机
        └── 10.1.0.0/24 ────┘        └── 10.2.0.0/24 ────┘
```

三个平面：
- **数据面**：OSPF area 0 为 IGP；iBGP/eBGP 叠加在其上（overlay，不抢转发）。
- **管理面**：Docker bridge `campus-mgmt` 172.30.30.0/24，gNMI/SNMP/SSH 走这里。
- **可观测面**：gNMI（路由器）+ SNMP（交换机）→ Prometheus → Grafana。

---

## 2. 拓扑与地址规划

### 数据面互联

| 链路 | 一端 | 另一端 |
|---|---|---|
| inet–edge1 | inet eth1 `192.168.100.1/30` | edge1 Et1 `192.168.100.2/30` |
| inet–edge2 | inet eth2 `192.168.100.5/30` | edge2 Et1 `192.168.100.6/30` |
| edge1–core1 | edge1 Et2 `10.0.13.2/30` | core1 Et1 `10.0.13.1/30` |
| edge2–core2 | edge2 Et2 `10.0.24.2/30` | core2 Et1 `10.0.24.1/30` |
| core1–core2 | core1 Et2 `10.0.12.1/30` | core2 Et2 `10.0.12.2/30` |
| core1–csw1 | core1 Et3 `10.1.0.1/24` | csw1（二层） |
| core2–csw2 | core2 Et3 `10.2.0.1/24` | csw2（二层） |

### Loopback / router-id / 主机

| 设备 | Loopback0 | router-id | 主机段 |
|---|---|---|---|
| edge1 | — | 1.1.1.1 | — |
| edge2 | — | 2.2.2.2 | — |
| core1 | 3.3.3.3/32 | 3.3.3.3 | 10.1.0.0/24 |
| core2 | 4.4.4.4/32 | 4.4.4.4 | 10.2.0.0/24 |
| pc1 | 10.1.0.11 | | pc2 10.1.0.12 |
| pc3 | 10.2.0.11 | | pc4 10.2.0.12 |

### 管理网（campus-mgmt 172.30.30.0/24，Docker IPAM 分配，网关 .1 = VM host）

> 地址按容器启动顺序分配，**会随重部署漂移**——所以采集器用**容器名**而非 IP。
> 参考值：core2 `.6` core1 `.7` edge2 `.5` edge1 `.8` csw1 `.4` csw2 `.9` asw1 `.3` asw2 `.11` asw3 `.2` asw4 `.10` inet `.12` zbx-server `.50`

---

## 3. 部署实验

```bash
# 在 VM 内，项目目录 ~/arista/
sudo containerlab deploy -t campus.yml      # 起 15 个容器
bash setup-services.sh                       # 恢复所有临时服务（见 §11）
```

`campus.yml` 定义节点与链路；`configs/*.cfg` 是各 Arista 的 startup-config；`Dockerfile.clab-alpine` 是交换机/主机用的 Alpine 镜像。

---

## 4. 路由：OSPF

单区（area 0），edge/core 四台。核心配置（以 core1 为例，见 `configs/core1.cfg`）：

```
router ospf 1
   router-id 3.3.3.3
   network 10.0.12.0/30 area 0.0.0.0
   network 10.0.13.0/30 area 0.0.0.0
   network 10.1.0.0/24 area 0.0.0.0
   network 3.3.3.3/32 area 0.0.0.0        # 宣告 Loopback（供 iBGP 对等）
```

边界注入默认路由（edge1/edge2）：
```
ip route 0.0.0.0/0 192.168.100.1           # 静态默认指向 inet
router ospf 1
   default-information originate           # 把默认注入 OSPF，全网可用
```

验证：`show ip ospf neighbor`（应 2×FULL）、`show ip route ospf`。

---

## 5. 路由：iBGP（core1/core2）

**AS 65001，基于 Loopback 对等**（OSPF 提供 loopback 可达性）。

core1：
```
interface Loopback0
   ip address 3.3.3.3/32
router bgp 65001
   router-id 3.3.3.3
   neighbor 4.4.4.4 remote-as 65001
   neighbor 4.4.4.4 update-source Loopback0
   neighbor 4.4.4.4 next-hop-self
   network 10.1.0.0/24
```
core2 对称（4.4.4.4 ↔ 3.3.3.3，宣告 10.2.0.0/24）。

**设计要点**：iBGP 管理距离 200 > OSPF 110 → 纯叠加，转发仍走 OSPF，不影响连通性。
验证：`show ip bgp summary`（Established）、`show ip bgp`。

---

## 6. 路由：eBGP（边界 ↔ ISP）

用 **FRR** 把 inet 变成 ISP 路由器（AS 65100），和两台 edge 建 eBGP。

### inet 侧（FRR，`/etc/frr/frr.conf`）
```
router bgp 65100
 bgp router-id 192.168.100.1
 no bgp ebgp-requires-policy          # 关掉 FRR 8.x 的 RFC8212 默认拒绝（lab 用）
 neighbor 192.168.100.2 remote-as 65001
 neighbor 192.168.100.6 remote-as 65001
 address-family ipv4 unicast
  network 203.0.113.0/24              # 假互联网前缀（RFC5737 测试网段）
  network 198.51.100.0/24
  neighbor 192.168.100.2 default-originate
  neighbor 192.168.100.6 default-originate
!
ip route 203.0.113.0/24 blackhole     # 让 network 语句有 RIB 可宣告
ip route 198.51.100.0/24 blackhole
```
安装与启动：
```bash
apk add --no-cache frr frr-openrc
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
/usr/lib/frr/frrinit.sh start
```

### edge 侧（EOS，以 edge1 为例）
```
router bgp 65001
   router-id 1.1.1.1
   neighbor 192.168.100.1 remote-as 65100
   network 10.1.0.0/24
   network 10.2.0.0/24
```
edge2 对称（neighbor 192.168.100.5）。

**设计要点**：保留 edge 的静态默认 → 转发不变（叠加安全）；ISP 的假前缀是新路由，会真正装进 edge RIB（`B E`），直观演示"从 ISP 收到互联网路由"。EOS 的 **eBGP 管理距离是 200**（不是 Cisco 的 20）。
验证：`show ip bgp summary`、`show ip route bgp`（`B E 203.0.113.0/24`）。

---

## 7. 内部服务

| 主机 | 服务 | 起法 |
|---|---|---|
| pc1 `10.1.0.11` | 内部 Web（busybox nc HTTP，:80） | `nc -lk -p 80 -e /root/webserver.sh` |
| pc2 `10.1.0.12` | 循环视频流（darkhttpd，:5555） | `darkhttpd /root/www --port 5555` |
| pc3 `10.2.0.11` | 流量目标（darkhttpd，:80） | `darkhttpd /root/www --port 80` |
| pc1, pc2 | 流量生成器 → pc3 | `/root/trafficgen.sh`（随机 0.1–1.0s 打 http://10.2.0.11/） |

- **darkhttpd**：单二进制静态服务器，支持 `Content-Length` + HTTP Range（视频拖动必需）；在 inet 里 `apk add` 后拷进 pc2/pc3。
- **视频**：ffmpeg 合成 `testsrc` 彩条（无版权）：`ffmpeg -f lavfi -i 'testsrc=...' ... testvideo.mp4`。

---

## 8. 边界 NAT 与对外暴露

目标：本机（模拟"互联网"）访问园区内部服务。

```bash
# inet 上：DNAT 端口转发
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.1.0.11:80
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8091 -j DNAT --to-destination 10.1.0.12:5555
# inet 上：hairpin MASQUERADE（关键，见 §14）
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE

# VM 上：socat 中转（Lima 自动把 127.0.0.1 端口转发到 Mac）
socat TCP-LISTEN:8082,bind=127.0.0.1,fork,reuseaddr TCP:<inet-mgmt-ip>:8080   # pc1 web
socat TCP-LISTEN:8092,bind=127.0.0.1,fork,reuseaddr TCP:<inet-mgmt-ip>:8091   # pc2 video
```
链路：`Mac :8082/:8092 → VM 127.0.0.1（socat）→ inet DNAT → edge/core → pc`。

---

## 9. 可观测性栈

栈目录 `~/arista/telemetry/`，`docker compose up -d` 管理。容器：`gnmic`、`gnmic-proc`、`prometheus`、`grafana`、`snmp-exporter`，全部在 `campus-mgmt` 单网（避免多宿主 DNS 歧义）。

### 9.1 设备侧开 gNMI（core/edge，已在 configs/*.cfg）
```
username admin privilege 15 role network-admin secret 0 admin
management api gnmi
   transport grpc default
   provider eos-native          # 解锁 EOS-native 路径（Octa）
```
gRPC 明文跑在 `:6030`，认证走 EOS AAA（admin/admin）。

### 9.2 gnmic 主采集（telemetry/gnmic.yaml）
- targets 用**容器名** `clab-campus-core1:6030` 等（抗 DHCP 漂移）
- 订阅：接口计数 `sample 5s`、oper/admin-status `on-change`、CPU/内存 `sample 10s`
- 输出 prometheus `:9804`，`expiration: 6h`
- 处理器：`oper-status-str2num`（UP/DOWN→"1"/"0"）+ `oper-status-toint`（转 int，字段名是 `values:` 不是 `value-names:`）

### 9.3 交换机 SNMP
- `snmp-exporter`（官方镜像自带 `if_mib`，`public_v2` auth，数字 OID）
- Prometheus job `snmp-switches`，relabel 把交换机 IP 作 param 传给 exporter，`alias` 标签把 instance 显示成 csw1/asw2…
- 交换机 snmpd 由 `zabbix/setup-switch-snmp.sh` 装（inet 里 `apk add net-snmp` 再拷进 6 台）

### 9.4 Prometheus / Grafana
- Prometheus scrape：`gnmic:9804`、`gnmic-proc:9805`、`snmp-switches`
- Grafana provisioning：datasource（uid `prometheus`）+ dashboard `Campus gNMI Telemetry`
- 面板：接口吞吐、核心互联链路、丢弃率、CPU、内存、链路状态（on-change 时间线）、交换机吞吐、每进程内存

---

## 10. 每进程内存遥测

**难点**：EOS-native `/Kernel/proc/stat/{pid}/...` 按 pid 索引（pid 不可读），且 gnmic 把每个叶子拆成独立单值 event（`event-value-tag` 无法跨事件把进程名转成标签）。

**解法**：独立容器 `gnmic-proc`（避免处理器污染主输出），用 **`event-jq`** 自包含地把每个 `comm` 事件转成 `proc_info{pid,proc}=1` 信息指标：
```yaml
processors:
  proc-extract-pid:                     # 把 pid 从值名提成标签
    event-extract-tags:
      value-names: ["^eos_native:/Kernel/proc/stat/(?P<pid>\\d+)/"]
  proc-comm-to-info:                    # comm 值 → proc_info{pid,proc}=1
    event-jq:
      expression: >
        map(if any(.values|keys[]; endswith("/comm")) then
          {name:.name, timestamp:.timestamp,
           tags:(.tags + {proc:([.values|to_entries[]|select(.key|endswith("/comm"))|.value][0])}),
           values:{"proc_info":1}} else . end)
  proc-rename:                          # 去掉值名里的 /pid/
    event-strings: { value-names:[".*"], transforms:[{replace:{apply-on:name, old:"/stat/[0-9]+/", new:"/stat/"}}] }
  proc-allow:
    event-allow: { value-names:["rss$","vsize$","cpuUtilization$","proc_info$"] }
```
**PromQL join 出带名字的每进程内存**：
```
eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc) proc_info * 4096
```

---

## 11. 一键恢复：setup-services.sh

幂等，重部署后一条命令恢复所有临时状态（VM 内运行）：
```bash
bash ~/arista/setup-services.sh
```
8 步：darkhttpd 装进 pc2/pc3 → ffmpeg 生成视频 → pc1 web（busybox nc，pkill 后 `sleep 2` + `until` 重试，绕开 TIME_WAIT）→ pc2 视频 → pc3 目标 → pc1/pc2 流量生成器 → inet DNAT+hairpin + socat（inet mgmt IP 动态解析）→ 交换机 snmpd + 遥测栈 `docker compose up -d`。

> ⚠️ 当前 `setup-services.sh` **尚未包含** inet 的 FRR 安装/配置（eBGP 部分）——重部署后 ISP 需手动重建，见 §15。

---

## 12. 访问入口速查

| 入口（从 Mac） | 内容 | 认证 |
|---|---|---|
| http://localhost:3000 | Grafana → 仪表盘 Campus gNMI Telemetry | admin/admin |
| http://localhost:9090 | Prometheus | — |
| http://localhost:8082 | pc1 内部 Web（经边界 DNAT） | — |
| http://localhost:8092 | pc2 循环视频流（经边界 DNAT） | — |
| http://localhost:8081 | Zabbix Web | — |

---

## 13. 验证命令速查

```bash
# 路由
docker exec clab-campus-core1 Cli -c "show ip ospf neighbor"
docker exec clab-campus-core1 Cli -c "show ip bgp summary"
docker exec clab-campus-inet  vtysh -c "show ip bgp summary"

# 遥测（权威口径：查 Prometheus，别 raw wget 刚重启的 gnmic）
curl -s 'http://localhost:9090/api/v1/targets?state=active'
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=up'

# 每进程内存 top（含 Octa/Sysdb/Bgp-main 等）
# PromQL: topk(15, eos_native_Kernel_proc_stat_rss * on(pid,source) group_left(proc) proc_info * 4096)

# 三层日志
docker exec clab-campus-core1 Cli -c "show logging"              # EOS agent 层
docker exec clab-campus-core1 cat /var/log/agents/ConfigAgent-*  # 单 agent
docker exec clab-campus-core1 cat /var/log/messages             # Linux/systemd 层

# 连通性
docker exec clab-campus-pc1 ping -c2 10.2.0.11                  # 园区东西向
docker exec clab-campus-pc1 ping -c2 1.1.1.1                    # 经 inet NAT 出网
```

---

## 14. 踩过的坑（重要）

1. **Hairpin NAT / 非对称路由**：只做 DNAT 不做 SNAT 时，回程包从 core1 的 Management0（与 VM 同 172.30.30/24 网段、同 default VRF）"抄近道"绕开 inet，conntrack 对不上 → 连接超时。解法：对转发流量再 MASQUERADE 一次，强制回程原路经 inet。
2. **rsyslog 崩溃循环（248 万次）**：cEOS 容器里 systemd 用 socket-activation 持有 `/run/systemd/journal/syslog`，rsyslog 的 imuxsock 又去自己 bind → EADDRINUSE 退出；`StartLimitIntervalUSec=0` 关了限流 → 每 100ms 重启不止。无害（EOS 日志走 Sysdb），但会制造 systemctl 进程 churn。详见 `diag_case/diagnosis.md`。
3. **FRR RFC 8212**：FRR 8.x 起 eBGP 不配 route-map 就默认不收发路由（显示 `(Policy)`）。lab 用 `no bgp ebgp-requires-policy`；生产应保留它。
4. **EOS eBGP 管理距离 = 200**（不是 Cisco 的 20）——所以 BGP 天然叠加、不抢 OSPF（110）。
5. **读操作不进日志**：只有配置**写**才记 `%SYS-5-CONFIG_I`；gNMI/CLI 的**读**会让 Octa/Sysdb 分配内存却不留日志——这是"内存动了但日志全空"的根因。
6. **busybox nc 无 SO_REUSEADDR**：pkill 旧监听后端口 TIME_WAIT，新 nc 绑定失败。解法：`sleep 2` + `until` 重试。
7. **gnmic event-value-tag 需同一 event**：无 key 的 native 路径每叶子独立 event，跨事件 join 失败；改用 `event-jq` 自包含转换。
8. **proc_info 6h 过期 + pid churn = 基数泄漏**：rsyslog 疯狂 spawn systemctl/sleep 短命 pid，每 pid 一条序列且赖 6h → Prometheus 序列从 ~400 涨到数千、内存翻倍。这是当前唯一的真慢性泄漏（在监控栈，不在路由器）。
9. **DHCP 地址漂移**：管理网 IP 按启动顺序分配，重部署会变 → gnmic target 用容器名。
10. **后台进程随 SSH 会话被杀**：`limactl shell -- ... &` 里的进程在会话结束时死；用 `nohup setsid ... </dev/null >/dev/null 2>&1 &` 或跑成容器。
11. **Prometheus 按名抓 gnmic 刚重启时返回 0**：是跨容器名解析的时序假象，权威数据查 Prometheus API，别 raw wget。

---

## 15. 持久化边界

| 内容 | 容器重启 | `containerlab destroy/deploy` | 恢复方式 |
|---|---|---|---|
| OSPF / gNMI / 用户 | ✅ | ✅（在 `configs/*.cfg`） | 自动 |
| **iBGP / eBGP（EOS）** | ✅（`write mem`） | ❌ **未写入 configs/*.cfg** | ⚠️ 需固化到 .cfg |
| **inet FRR（ISP）** | ✅（frr.conf） | ❌ apk 装的，全丢 | ⚠️ 需写进 setup-services.sh |
| 遥测栈（compose） | ✅ | ✅（磁盘文件） | `docker compose up -d` |
| pc 服务 / NAT / socat | ❌ | ❌ | `setup-services.sh` |
| 交换机 snmpd | ❌ | ❌ | `setup-switch-snmp.sh` |

**待办（TODO）**：
- 把 iBGP/eBGP 配置写进 `configs/core*.cfg` / `configs/edge*.cfg`；
- 把 inet 的 FRR 安装+配置加进 `setup-services.sh`；
- 修每进程遥测的基数泄漏（gnmic-proc 只保留真实 EOS agent 进程、缩短 expiration）。

---

*相关文档：`README.md`（项目总览，中英双语）、`diag_case/diagnosis.md`（幻影内存尖峰完整溯源）、`diag_case/devto_article.md`（可发布文章版）。*
