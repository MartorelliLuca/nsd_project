#!/bin/sh
set -eu

# verso CE2: trunk VLAN 32 e 95 "eth0"
# verso client-B1: access VLAN 32 "eth1"
# verso client-B2: access VLAN 95 "eth2"
# BRIDGE = "br0"

# Crea il bridge solo se non esiste, con VLAN filtering abilitato.
ip link show br0 >/dev/null 2>&1 ||
ip link add br0 type bridge vlan_filtering 1

# Porta up bridge.
ip link set br0 up

# Puliamo la chain gestita dal bridge,
# così non accumuliamo regole vecchie ogni volta che eseguiamo l'init.
ebtables -F

# Impostiamo la policy predefinita di FORWARD a DROP:
ebtables -P FORWARD DROP 

ebtables -P INPUT ACCEPT    #Accetta il traffico in ingresso verso il bridge.
ebtables -P OUTPUT ACCEPT   #Accetta il traffico in uscita dal bridge verso le interfacce fisiche.

# Permettiamo sempre il traffico che arriva dall'interfaccia verso il resto della rete (eth0),
# cioè verso CE2 / AS100: questo evita che la policy DROP blocchi il traffico.
ebtables -A FORWARD -i eth0 -j ACCEPT 


#Porta up tutte le interfacce.
ip link set eth0 up
ip link set eth1 up
ip link set eth2 up

# Collega le porte fisiche al bridge.
ip link set eth0 master br0 2>/dev/null || true
ip link set eth1 master br0 2>/dev/null || true
ip link set eth2 master br0 2>/dev/null || true

# Rimuove la VLAN predefinita 1 dalle porte.
bridge vlan del dev eth0 vid 1 2>/dev/null || true
bridge vlan del dev eth1 vid 1 2>/dev/null || true
bridge vlan del dev eth2 vid 1 2>/dev/null || true

# eth0: trunk, traffico VLAN 32 e VLAN 95 taggato.
bridge vlan add dev eth0 vid 32 2>/dev/null || true
bridge vlan add dev eth0 vid 95 2>/dev/null || true

# eth1: porta access non taggata nella VLAN 32.
bridge vlan add dev eth1 vid 32 pvid untagged 2>/dev/null || true

# eth2: porta access non taggata nella VLAN 95.
bridge vlan add dev eth2 vid 95 pvid untagged 2>/dev/null || true

# IP del bridge: mantengo quello dello script 2.
ip addr add 192.168.2.2/24 dev br0 2>/dev/null || true

# Rete 192.168.3.0/24 raggiungibile tramite CE2 nella VLAN 32.
ip route add 192.168.3.0/24 via 192.168.32.1 dev br0 2>/dev/null || true

# Il bridge stesso appartiene alla VLAN 32:
# può quindi ricevere traffico non taggato associandolo alla VLAN 32.
bridge vlan add dev br0 vid 32 self pvid untagged 2>/dev/null || true

# Abilita l'inoltro di EAPOL attraverso il bridge.
echo 8 > "/sys/class/net/br0/bridge/group_fwd_mask"


