#!/bin/sh
set -eu

CLIENT_IP="192.168.32.10/24"
IF_DEV="eth0"
GW_IP="192.168.32.1"    # CE2 VLAN32

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

set_default_route() {
  gw="$1"

  if ip route show default 2>/dev/null | grep -q "via $gw" >/dev/null 2>&1; then
    :
  else
    ip route add default via "$gw"
  fi
}

add_ip "$CLIENT_IP" "$IF_DEV"
bring_up "$IF_DEV"
set_default_route "$GW_IP"