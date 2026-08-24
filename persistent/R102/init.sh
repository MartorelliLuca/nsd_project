#!/bin/sh
set -eu

# Enable interfaces
ip link set eth0 up
ip link set eth1 up
ip link set eth2 up
ip link set lo up

# Link R102 <-> R101
ip addr replace 10.0.11.6/30 dev eth0

# Link R102 <-> R103
ip addr replace 10.0.11.9/30 dev eth1

# Link R102 <-> CE2
ip addr replace 10.1.3.1/30 dev eth2

# Loopback / router-id R102
ip addr replace 2.255.0.102/32 dev lo

