#!/bin/sh
set -eu

# WAN: link CE1 <-> R101
VM_WAN_IP="10.0.1.2/30"     # IP di CE1 su eth0
VM_WAN_DEV="eth0"
VM_DEFAULT_GW="10.0.1.1"    # IP di R101 su quel link

# LAN: Site 1 (client-A1)
VM_LAN_IP="192.168.1.1/24"  # gateway della LAN 192.168.1.0/24
VM_LAN_DEV="eth1"

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

# Configura indirizzi
add_ip "$VM_WAN_IP" "$VM_WAN_DEV"
add_ip "$VM_LAN_IP" "$VM_LAN_DEV"

# Porta su le interfacce
bring_up "$VM_WAN_DEV"
bring_up "$VM_LAN_DEV"

# Abilita l'IP forwarding IPv4
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Imposta default gateway verso R101
set_default_route "$VM_DEFAULT_GW"