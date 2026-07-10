#!/bin/bash
# Install and start snmpd inside the campus-mgmt Alpine switch containers
# (csw1, csw2, asw1-4). These containers have no internet egress
# (campus-mgmt external-access: false), so snmpd is built once inside
# clab-campus-inet (which does have egress) and copied over.
#
# Re-run this after `containerlab destroy/deploy` recreates the switch
# containers, since the manually-installed snmpd does not persist.
set -euo pipefail

SWITCHES=(csw1 csw2 asw1 asw2 asw3 asw4)
SNMP_COMMUNITY=public
PKG=/tmp/snmpd-pkg.tar.gz
CONF=/tmp/snmpd.conf

docker exec clab-campus-inet sh -c 'apk add --no-cache net-snmp net-snmp-tools >/dev/null'
docker exec clab-campus-inet sh -c "tar -C / -czf /tmp/snmpd-pkg.tar.gz \
  usr/sbin/snmpd \
  usr/lib/libnetsnmp.so.45 usr/lib/libnetsnmp.so.45.0.0 \
  usr/lib/libnetsnmpagent.so.45 usr/lib/libnetsnmpagent.so.45.0.0 \
  usr/lib/libnetsnmpmibs.so.45 usr/lib/libnetsnmpmibs.so.45.0.0 \
  usr/lib/libnetsnmphelpers.so.45 usr/lib/libnetsnmphelpers.so.45.0.0"
docker cp clab-campus-inet:/tmp/snmpd-pkg.tar.gz "$PKG"

cat > "$CONF" <<EOF
rocommunity $SNMP_COMMUNITY
sysLocation campus-lab
sysContact fanwei
EOF

for c in "${SWITCHES[@]}"; do
  cid=clab-campus-$c
  docker exec "$cid" sh -c "pkill -9 snmpd 2>/dev/null; mkdir -p /etc/snmp"
  docker cp "$PKG" "$cid:/tmp/snmpd-pkg.tar.gz"
  docker exec "$cid" sh -c "tar -C / -xzf /tmp/snmpd-pkg.tar.gz && rm /tmp/snmpd-pkg.tar.gz"
  docker cp "$CONF" "$cid:/etc/snmp/snmpd.conf"
  docker exec -d "$cid" /usr/sbin/snmpd -Lo -p /run/snmpd.pid
  echo "$c: snmpd started"
done
