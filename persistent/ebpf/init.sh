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

#Porta up tutte le interfacce.
ip link set eth0 up
ip link set eth1 up
ip link set eth2 up

# Collega le porte fisiche al bridge.
ip link set eth0 master br0
ip link set eth1 master br0
ip link set eth2 master br0


# IP del bridge: mantengo quello dello script 2.
ip addr add 192.168.2.2/24 dev br0
ip route add default via 192.168.20.1

# Il bridge stesso appartiene alla VLAN 32:
# può quindi ricevere traffico non taggato associandolo alla VLAN 32.
bridge vlan add dev br0 vid 32 self pvid untagged 

# Abilita l'inoltro di EAPOL attraverso il bridge.
echo 8 > "/sys/class/net/br0/bridge/group_fwd_mask"


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

# Avvia hostapd come authenticator 802.1X wired, se disponibile.
HOSTAPD_BIN="$(command -v hostapd || true)"
HOSTAPD_CONF="/root/hostapd/hostapd.conf"
HOSTAPD_RUN_DIR="/var/run/hostapd"

if [ -z "$HOSTAPD_BIN" ]; then
    echo "[ebpf-1] Errore: hostapd non è installato o non è nel PATH." >&2

elif pgrep -x hostapd >/dev/null 2>&1; then
    echo "[ebpf-1] hostapd è già in esecuzione."

elif [ ! -f "$HOSTAPD_CONF" ]; then
    echo "[ebpf-1] Errore: configurazione non trovata: $HOSTAPD_CONF" >&2

else
    mkdir -p "$HOSTAPD_RUN_DIR"
    "$HOSTAPD_BIN" -B "$HOSTAPD_CONF"
    echo "[ebpf-1] hostapd avviato con $HOSTAPD_CONF."
fi

echo "[ebpf-1] bridge e VLAN configurati."


