#!/bin/sh
set -eu

# WAN interface:
ip link set eth0 up
ip addr replace 10.1.3.2/30 dev eth0

# Default route:
ip route replace default via 10.1.3.1

# LAN interface:
ip link set eth1 up
ip addr replace 192.168.3.1/24 dev eth1

# IPv4 forwarding:
sysctl -w net.ipv4.ip_forward=1 >/dev/null