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

# Link R101 <-> R103 (10.0.11.0/30)
add_ip 10.0.11.1/30 eth0

# Link R101 <-> R102 (10.0.11.4/30)
add_ip 10.0.11.5/30 eth1

# Link R101 <-> CE1 (10.0.1.0/30)
add_ip 10.1.1.1/30 eth2

add_ip 2.255.0.101/32 lo

bring_up eth0
bring_up eth1
bring_up eth2
bring_up lo