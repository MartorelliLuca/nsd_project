#!/bin/sh
set -eu

WAN_IP="10.1.3.2/30"       # CE3 lato R103
WAN_DEV="eth0"
WAN_GW="10.1.3.1"          # R103

LAN_IP="192.168.3.1/24"    # gateway LAN Site 3
LAN_DEV="eth1"

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

# WAN (verso R103/AS100)
add_ip "$WAN_IP" "$WAN_DEV"
bring_up "$WAN_DEV"

# LAN (verso RADIUS)
add_ip "$LAN_IP" "$LAN_DEV"
bring_up "$LAN_DEV"

# Routing abilitato
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Default gateway verso R103
set_default_route "$WAN_GW"