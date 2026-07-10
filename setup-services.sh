#!/bin/bash
# ---------------------------------------------------------------------------
# setup-services.sh  --  restore all ephemeral lab services + telemetry after
# a `containerlab destroy && deploy` (which recreates the pc/inet containers
# and wipes everything not in a startup-config).
#
# Idempotent: safe to re-run. Run inside the VM:
#     bash ~/arista/setup-services.sh
# or from the Mac:
#     limactl shell my-frr -- bash arista/setup-services.sh
#
# What persists on its own (NOT handled here):
#   - Arista OSPF + gNMI config    -> configs/*.cfg  (startup-config)
#   - telemetry docker-compose      -> ~/arista/telemetry/  (brought up below)
# What this restores (ephemeral, in-container / VM-host state):
#   - pc1 web, pc2 video stream, pc3 traffic target
#   - pc1/pc2 traffic generators
#   - inet DNAT port-forward + hairpin MASQUERADE
#   - socat relays on the VM loopback (Lima forwards them to the Mac)
#   - switch snmpd (via setup-switch-snmp.sh) + telemetry stack
# ---------------------------------------------------------------------------
set -euo pipefail
CLAB=clab-campus
HERE="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }

# ===========================================================================
say "1/8  provisioning darkhttpd into pc2, pc3 (built once in inet, which has egress)"
docker exec ${CLAB}-inet sh -c 'command -v darkhttpd >/dev/null 2>&1 || apk add --no-cache darkhttpd >/dev/null'
docker exec ${CLAB}-inet sh -c 'cp -f /usr/bin/darkhttpd /tmp/darkhttpd'
docker cp ${CLAB}-inet:/tmp/darkhttpd /tmp/darkhttpd
for c in pc2 pc3; do
  docker cp /tmp/darkhttpd ${CLAB}-$c:/usr/bin/darkhttpd
  docker exec ${CLAB}-$c sh -c 'chmod +x /usr/bin/darkhttpd'
done

# ===========================================================================
say "2/8  generating synthetic test video (ffmpeg testsrc, no third-party content)"
if [ ! -f /tmp/testvideo.mp4 ]; then
  ffmpeg -y -f lavfi -i 'testsrc=duration=10:size=640x360:rate=30' \
         -f lavfi -i 'sine=frequency=440:duration=10' \
         -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/testvideo.mp4 >/dev/null 2>&1
fi

# ===========================================================================
say "3/8  pc1 -- internal web server (busybox nc HTTP responder, :80)"
docker exec -i ${CLAB}-pc1 sh -c "cat > /root/webserver.sh" <<'PC1WEB'
#!/bin/sh
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n'
cat <<HTML
<html><head><title>pc1 Internal Web Server</title></head>
<body>
<h1>pc1 - Internal Web Server</h1>
<p>Hostname: $(hostname)</p>
<p>Served by: busybox nc (minimal HTTP responder)</p>
<p>Time: $(date)</p>
</body></html>
HTML
PC1WEB
# busybox nc has no SO_REUSEADDR, so wait for the old listener's port to clear
docker exec ${CLAB}-pc1 sh -c "chmod +x /root/webserver.sh; pkill -f 'nc -lk -p 80' 2>/dev/null; sleep 2; true"
docker exec -d ${CLAB}-pc1 sh -c "until nc -lk -p 80 -e /root/webserver.sh; do sleep 1; done"

# ===========================================================================
say "4/8  pc2 -- streaming server (darkhttpd + looping video page, :5555)"
docker exec ${CLAB}-pc2 sh -c "mkdir -p /root/www"
docker cp /tmp/testvideo.mp4 ${CLAB}-pc2:/root/www/testvideo.mp4
docker exec -i ${CLAB}-pc2 sh -c "cat > /root/www/index.html" <<'PC2HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>pc2 Streaming Server</title>
<style>body{font-family:sans-serif;background:#111;color:#eee;text-align:center;padding:2em}
video{max-width:90%;border:1px solid #444;border-radius:8px}</style></head>
<body>
<h1>pc2 &mdash; Internal Streaming Server</h1>
<p>Synthetic ffmpeg test pattern, served by darkhttpd from an Alpine container, looped in-browser.</p>
<video autoplay loop muted controls playsinline width="640" height="360">
  <source src="testvideo.mp4" type="video/mp4">
</video>
<p style="color:#888">DNAT via inet border node &rarr; edge2 &rarr; core2 &rarr; pc2 (10.1.0.12)</p>
</body></html>
PC2HTML
docker exec ${CLAB}-pc2 sh -c "pkill -f darkhttpd 2>/dev/null; true"
docker exec -d ${CLAB}-pc2 sh -c "darkhttpd /root/www --port 5555 --addr 0.0.0.0"

# ===========================================================================
say "5/8  pc3 -- HTTP service (traffic-gen target, :80)"
docker exec ${CLAB}-pc3 sh -c "mkdir -p /root/www"
docker exec -i ${CLAB}-pc3 sh -c "cat > /root/www/index.html" <<'PC3HTML'
<html><body><h1>pc3 - Internal Service (10.2.0.11)</h1><p>traffic-gen target</p></body></html>
PC3HTML
docker exec ${CLAB}-pc3 sh -c "pkill -f darkhttpd 2>/dev/null; true"
docker exec -d ${CLAB}-pc3 sh -c "darkhttpd /root/www --port 80 --addr 0.0.0.0"

# ===========================================================================
say "6/8  traffic generators on pc1, pc2 -> pc3 (random 0.1-1.0s interval)"
for c in pc1 pc2; do
  docker exec -i ${CLAB}-$c sh -c "cat > /root/trafficgen.sh" <<'TGEN'
#!/bin/sh
# Traffic generator: hit pc3's HTTP service at random 0.1-1.0s intervals.
TARGET="http://10.2.0.11/"
N=0; OK=0
while true; do
  if wget -q -O /dev/null -T 2 "$TARGET" 2>/dev/null; then OK=$((OK+1)); R=ok; else R=ERR; fi
  N=$((N+1))
  echo "sent=$N ok=$OK last=$R at=$(date +%H:%M:%S) src=$(hostname)" > /root/trafficgen.status
  ms=$((RANDOM % 901 + 100))
  sleep "$(printf '%d.%03d' $((ms/1000)) $((ms%1000)))"
done
TGEN
  docker exec ${CLAB}-$c sh -c "chmod +x /root/trafficgen.sh; pkill -f trafficgen.sh 2>/dev/null; true"
  docker exec -d ${CLAB}-$c sh -c "/root/trafficgen.sh"
done

# ===========================================================================
say "7/8  inet border NAT: DNAT port-forward + hairpin MASQUERADE"
ipt() {  # idempotent add: only append if the exact rule is absent
  docker exec ${CLAB}-inet sh -c "iptables -t nat -C $* 2>/dev/null || iptables -t nat -A $*"
}
ipt "PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.1.0.11:80"
ipt "PREROUTING -i eth0 -p tcp --dport 8091 -j DNAT --to-destination 10.1.0.12:5555"
ipt "POSTROUTING -o eth1 -j MASQUERADE"   # hairpin: force pc replies back through inet
ipt "POSTROUTING -o eth2 -j MASQUERADE"

# socat relays on the VM loopback (Lima auto-forwards 127.0.0.1 ports to the Mac).
# inet's campus-mgmt IP can shift on redeploy, so resolve it dynamically.
INET_MGMT=$(docker inspect ${CLAB}-inet --format '{{(index .NetworkSettings.Networks "campus-mgmt").IPAddress}}')
pkill -f 'TCP-LISTEN:8082' 2>/dev/null || true
pkill -f 'TCP-LISTEN:8092' 2>/dev/null || true
nohup setsid socat TCP-LISTEN:8082,bind=127.0.0.1,fork,reuseaddr TCP:${INET_MGMT}:8080 </dev/null >/dev/null 2>&1 &
nohup setsid socat TCP-LISTEN:8092,bind=127.0.0.1,fork,reuseaddr TCP:${INET_MGMT}:8091 </dev/null >/dev/null 2>&1 &
echo "  relays: Mac localhost:8082 -> pc1 web,  localhost:8092 -> pc2 video  (via inet ${INET_MGMT})"

# ===========================================================================
say "8/8  switch snmpd + telemetry stack (gnmic/gnmic-proc/prometheus/grafana/snmp-exporter)"
if [ -x "${HERE}/zabbix/setup-switch-snmp.sh" ]; then
  bash "${HERE}/zabbix/setup-switch-snmp.sh" || echo "  (switch snmp setup reported an issue; continuing)"
else
  echo "  skip: ${HERE}/zabbix/setup-switch-snmp.sh not found"
fi
( cd "${HERE}/telemetry" && docker compose up -d )

say "done. Endpoints from the Mac:"
cat <<EOF
  pc1 web        : http://localhost:8082/
  pc2 video      : http://localhost:8092/
  Prometheus     : http://localhost:9090/
  Grafana        : http://localhost:3000/   (dashboard: Campus gNMI Telemetry)
EOF
