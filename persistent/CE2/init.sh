#!/bin/sh
set -eu


# WAN interface:
ip link set eth0 up
ip addr add 10.1.2.2/30 dev eth0

# Default route:
# Traffic for remote networks is sent to R103.
ip route add default via 10.1.2.1

# Enable IPv4 forwarding:
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Physical LAN interface:
ip link set eth1 up
ip addr add 192.168.2.1/24 dev eth1

# VLAN 32:
ip link add link eth1 name eth1.32 type vlan id 32 2>/dev/null || true
ip link set eth1.32 up
ip addr add 192.168.32.1/24 dev eth1.32

# VLAN 95:
ip link add link eth1 name eth1.95 type vlan id 95 2>/dev/null || true
ip link set eth1.95 up
ip addr add 192.168.95.1/24 dev eth1.95