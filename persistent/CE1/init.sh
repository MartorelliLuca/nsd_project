#!/bin/sh
set -eu

# WAN: link CE1 <-> R101
ip link set eth0 up
ip addr add 10.1.1.2/30 dev eth0

# Add default route towards the provider gateway
ip route add default via 10.1.1.1

# LAN: Site 1
ip link set eth1 up
ip addr add 192.168.1.1/24 dev eth1

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
