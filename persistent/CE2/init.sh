#!/bin/sh
set -eu

# WAN: link CE2 <-> R102
WAN_IP="10.1.2.2/30"      # indirizzo di CE2 su eth0
WAN_DEV="eth0"
WAN_GW="10.1.2.1"         # next-hop: R102

# LAN fisica verso ebpf-1 (switch/bridge)
LAN_DEV="eth1"

# VLAN per i client B1/B2
VLAN32_DEV="eth1.32"
VLAN32_ID=32
VLAN32_IP="192.168.32.1/24"

VLAN95_DEV="eth1.95"
VLAN95_ID=95
VLAN95_IP="192.168.95.1/24"

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

create_vlan_if_missing() {
  parent="$1"
  vlan_dev="$2"
  vlan_id="$3"

  if ip link show "$vlan_dev" >/dev/null 2>&1; then
    :
  else
    ip link add link "$parent" name "$vlan_dev" type vlan id "$vlan_id"
  fi
}

# WAN (verso AS100)
add_ip "$WAN_IP" "$WAN_DEV"
bring_up "$WAN_DEV"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
set_default_route "$WAN_GW"

# LAN/VLAN (verso ebpf-1 e client B1/B2)
bring_up "$LAN_DEV"

create_vlan_if_missing "$LAN_DEV" "$VLAN32_DEV" "$VLAN32_ID"
create_vlan_if_missing "$LAN_DEV" "$VLAN95_DEV" "$VLAN95_ID"

add_ip "$VLAN32_IP" "$VLAN32_DEV"
add_ip "$VLAN95_IP" "$VLAN95_DEV"

bring_up "$VLAN32_DEV"
bring_up "$VLAN95_DEV"