#!/bin/sh
set -eu

CLIENT_IP="192.168.1.2/24"
IF_DEV="enp0s3"
GW_IP="192.168.1.1"

ip link set lo up
ip link set "$IF_DEV" up

# Evita IP duplicati o residui da configurazioni precedenti.
ip addr flush dev "$IF_DEV" scope global
ip addr add "$CLIENT_IP" dev "$IF_DEV"

# Rimuove la default route precedente e usa CE1 come gateway.
ip route del default 2>/dev/null || true
ip route replace default via "$GW_IP" dev "$IF_DEV"

echo "[client-A1] Configurato: $CLIENT_IP su $IF_DEV, gateway $GW_IP"