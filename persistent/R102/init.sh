#!/bin/sh
set -eu

add_ip() {
  ipcidr="$1"
  dev="$2"
  if ip -br addr show dev "$dev" 2>/dev/null | grep -qF "$ipcidr"; then
    :
  else
    ip addr add "$ipcidr" dev "$dev"
  fi
}

bring_up() {
  dev="$1"
  ip link set "$dev" up 2>/dev/null || true
}

# Link R102 <-> R101 (10.0.11.4/30)
add_ip 10.0.11.6/30 eth0

# Link R102 <-> R103 (10.0.11.8/30)
add_ip 10.0.11.9/30 eth1

# Link R102 <-> CE2 (10.0.2.0/30)
add_ip 10.1.3.1/30 eth2

# Loopback /32 (R102 router‑ID)
add_ip 2.255.0.102/32 lo

bring_up eth0
bring_up eth1
bring_up eth2
bring_up lo