#!/bin/sh
set -eu

# Enable loopback and network interface
ip link set lo up
ip link set enp0s3 up

# Remove old IP addresses and configure client-A1 address
ip addr flush dev enp0s3 scope global
ip addr add 192.168.1.2/24 dev enp0s3

# Use CE1 as default gateway
ip route del default 2>/dev/null || true
ip route replace default via 192.168.1.1 dev enp0s3

echo "[client-A1] Network configured"