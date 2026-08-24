#!/bin/sh
set -eu

# Link R101 <-> R103 (10.0.11.0/30)
ip addr add 10.0.11.1/30 dev eth0

# Link R101 <-> R102 (10.0.11.4/30)
ip addr add 10.0.11.5/30 dev eth1

# Link R101 <-> CE1 (10.0.1.0/30)
ip addr add 10.1.1.1/30 dev eth2

ip addr add 2.255.0.101/32 dev lo

ip link set eth0 up
ip link set eth1 up
ip link set eth2 up
ip link set lo up