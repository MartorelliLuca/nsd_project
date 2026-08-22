#!/bin/sh
set -eu

# Site2 "switch" node (ebpf-1):
# - Linux bridge with VLAN filtering (trunk to CE2, access ports to clients)
# - ebtables baseline policy (allow EAPOL, allow trunk)
# - start hostapd (wired 802.1X authenticator) -> talks to RADIUS behind CE3 over VPN Site3

TRUNK_IF="eth0"     # uplink to CE2 (VLAN trunk)
ACC_IF_1="eth1"     # access port -> client-B1 (VLAN 32 after auth)
ACC_IF_2="eth2"     # access port -> client-B2 (VLAN 95 after auth)
BR="br0"

# Bring loopback up
ip link set lo up 

# Create bridge
ip link add name "$BR" type bridge vlan_filtering 1

# Enslave ports to bridge 
ip link set "$TRUNK_IF" master "$BR"
ip link set "$ACC_IF_1" master "$BR"
ip link set "$ACC_IF_2" master "$BR"

# Bring up interfaces
ip link set "$TRUNK_IF" up
ip link set "$ACC_IF_1" up
ip link set "$ACC_IF_2" up
ip link set "$BR" up

# Enable EAPoL fwd
echo 8 > /sys/class/net/"$BR"/bridge/group_fwd_mask

# Management IP for ebpf-1
ip addr add 192.168.2.2/24 dev "$BR" 
ip route add default via 192.168.2.1

# Configure default ACL policies
ebtables -F
ebtables -P FORWARD DROP
ebtables -P INPUT ACCEPT
ebtables -P OUTPUT ACCEPT

# Port towards the router is enabled
ebtables -A FORWARD -i eth0 -j ACCEPT

# Start hostapd (802.1X authenticator)
if ! pgrep -x hostapd >/dev/null 2>&1; then
  mkdir -p /var/run/hostapd
  hostapd -B /root/hostapd/hostapd.conf
fi

echo "[ebpf-1] bridge/VLAN/hostapd ready"