#!/bin/sh
set -eu

bring_up() {
  dev="$1"
  ip link set "$dev" up 2>/dev/null || true
}

bring_up eth0   # verso CE2
bring_up eth1   # verso client-B1
bring_up eth2   # verso client-B2