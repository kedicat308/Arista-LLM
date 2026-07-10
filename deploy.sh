#!/usr/bin/env bash
# Wrapper around `containerlab deploy` that also enforces mgmt-network
# isolation from the internet, while keeping the `inet` NAT box online.
#
# Why this exists: clab's `mgmt.external-access: false` (v0.75) only
# changes the bridge gateway-mode and does NOT remove docker's automatic
# MASQUERADE rule for the mgmt subnet. So we patch iptables ourselves.
set -euo pipefail
cd "$(dirname "$0")"

sudo containerlab deploy -t campus.yml "$@"

MGMT_ID=$(sudo docker network inspect campus-mgmt --format '{{.Id}}')
MGMT_BR="br-${MGMT_ID:0:12}"
INET_IP=$(sudo docker inspect clab-campus-inet \
            --format '{{(index .NetworkSettings.Networks "campus-mgmt").IPAddress}}')

# Replace the blanket mgmt-subnet MASQUERADE with one that only NATs
# the `inet` container, so the other routers/switches lose their
# unintended internet path via mgmt.
sudo iptables -t nat -D POSTROUTING -s 172.30.30.0/24 \
              ! -o "$MGMT_BR" -j MASQUERADE 2>/dev/null || true
if ! sudo iptables -t nat -C POSTROUTING -s "${INET_IP}/32" \
              ! -o "$MGMT_BR" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -I POSTROUTING -s "${INET_IP}/32" \
                  ! -o "$MGMT_BR" -j MASQUERADE
fi

echo
echo "Mgmt isolation applied: only inet ($INET_IP) reaches the internet via mgmt."
