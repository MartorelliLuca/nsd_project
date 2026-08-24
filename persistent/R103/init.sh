#!/bin/sh
set -eu

# Enable interfaces
ip link set eth0 up
ip link set eth1 up
ip link set eth2 up
ip link set lo up

# Link R103 <-> R101
ip addr replace 10.0.11.2/30 dev eth0

# Link R103 <-> R102
ip addr replace 10.0.11.10/30 dev eth1

# Link R103 <-> CE3
ip addr replace 10.1.2.1/30 dev eth2

# Loopback / router-id R103
ip addr replace 2.255.0.103/32 dev lo

