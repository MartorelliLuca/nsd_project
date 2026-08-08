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

# Link R103 <-> R101 (10.0.11.0/30)
add_ip 10.0.11.2/30 eth0

# Link R103 <-> R102 (10.0.11.8/30)
add_ip 10.0.11.10/30 eth1

# Link R103 <-> CE3 (10.0.3.0/30)
add_ip 10.0.3.1/30 eth2

bring_up eth0
bring_up eth1
bring_up eth2