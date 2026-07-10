# Campus Network Lab — Arista cEOS + containerlab

A simulated campus network running in a Lima VM on macOS, built with
[containerlab](https://containerlab.dev/). It combines Arista cEOS routers and
Alpine L2 switches, and layers on a full observability stack: streaming
telemetry (gNMI), SNMP, Prometheus, and Grafana.

> **Note:** the Arista cEOS image (`cEOSarm-lab-*.tar.xz`) is proprietary and is
> **not** included in this repo. Import your own licensed image before deploying.

## Topology

```
                internet (inet, border NAT)
                /                     \
            edge1                     edge2      (Arista cEOS, OSPF area 0)
              |                         |
            core1 ==== peer-link ==== core2      (Arista cEOS, OSPF area 0)
              |                         |
            csw1                      csw2        (Alpine L2 bridge)
           /    \                    /    \
        asw1    asw2              asw3    asw4    (Alpine L2 bridge)
         |        |                |        |
        pc1      pc2              pc3      pc4    (Alpine hosts)
        10.1.0.11 .12             10.2.0.11 .12
```

- **Routing:** single-area OSPF (area 0) across edge1/edge2/core1/core2;
  edge nodes inject a default route toward `inet`.
- **Two subnets:** 10.1.0.0/24 (pc1/pc2 behind csw1) and 10.2.0.0/24
  (pc3/pc4 behind csw2), so east-west traffic crosses the OSPF core.

## Layout

| Path | What |
|------|------|
| `campus.yml` | containerlab topology (nodes + links) |
| `configs/*.cfg` | Arista startup-configs (OSPF + gNMI + users) |
| `deploy.sh` | containerlab deploy helper |
| `Dockerfile.clab-alpine` | Alpine image used for switches/hosts |
| `setup-services.sh` | **one-shot restore** of all ephemeral services after redeploy |
| `telemetry/` | gNMI collection + Prometheus + Grafana stack |
| `zabbix/` | Zabbix + switch SNMP setup |
| `topology.html` | rendered topology view |

## Quick start

```bash
# 1. import your licensed cEOS image, then deploy the lab
sudo containerlab deploy -t campus.yml

# 2. restore ephemeral services (pc web/video, traffic gen, NAT, telemetry)
bash setup-services.sh
```

`setup-services.sh` is idempotent — re-run it any time, and always after a
`containerlab destroy && deploy`.

## Observability

Streaming telemetry (gNMI/OpenConfig + EOS-native) from the routers and SNMP
from the switches feed a single Prometheus, visualized in Grafana.

| Endpoint (from the Mac) | What |
|-------------------------|------|
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
