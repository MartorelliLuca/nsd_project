#!/bin/sh
set -eu

# WAN: link CE2 <-> R102
WAN_IP="10.1.2.2/30"
WAN_DEV="eth0"
WAN_GW="10.1.2.1"

# LAN fisica verso ebpf-1
LAN_DEV="eth1"
VLAN_IP="192.168.2.1/24"

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

  ip addr add "$ipcidr" dev "$dev"
}

bring_up() {
  dev="$1"

  ip link set "$dev" up
}

set_default_route() {
  gw="$1"

  ip route add default via "$gw"
}

create_vlan() {
  parent="$1"
  vlan_dev="$2"
  vlan_id="$3"

  ip link add link "$parent" name "$vlan_dev" type vlan id "$vlan_id"
}

# WAN verso R102 / AS100
bring_up "$WAN_DEV"
add_ip "$WAN_IP" "$WAN_DEV"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

set_default_route "$WAN_GW"

# LAN verso ebpf-1
bring_up "$LAN_DEV"
add_ip "$VLAN_IP" "$LAN_DEV"

# Creazione delle sub-interfacce VLAN
create_vlan "$LAN_DEV" "$VLAN32_DEV" "$VLAN32_ID"
create_vlan "$LAN_DEV" "$VLAN95_DEV" "$VLAN95_ID"

# Attivazione VLAN e indirizzi gateway
bring_up "$VLAN32_DEV"
bring_up "$VLAN95_DEV"

add_ip "$VLAN32_IP" "$VLAN32_DEV"
add_ip "$VLAN95_IP" "$VLAN95_DEV"