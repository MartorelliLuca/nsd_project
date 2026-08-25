# Network and System Defense Project

## Network Topology

<p align="center">
  <img src="images/Topology.png" alt="Description">
</p>

---

## Network Deployment

For each node, run the local `deploy.sh` script to apply network settings (interfaces, routing, and services).
 

### AS100 Border Router Configuration

Given the three provider routers in AS100 (R101, R102, and R103), which operate as FRR routers configured via the **vtysh** configuration terminal, let us begin by detailing the setup for **R101**. While the specific steps below focus on R101, the same considerations and configuration logic apply analogously to the other border routers, R102 and R103.

### R101
The most critical configuration steps for R101 are presented below. Since the network topology and routing policies are consistent across the autonomous system, these procedures serve as the template for R102 and R103 as well.

###### `init.sh`

init.sh just brings interfaces up and assigns the /30 links plus the loopback address.

```sh
#!/bin/sh
set -eu

ip link set eth0 up
ip link set eth1 up
ip link set eth2 up
ip link set lo up

# Link R101 <-> R103 (10.0.11.0/30)
ip addr add 10.0.11.1/30 dev eth0

# Link R101 <-> R102 (10.0.11.4/30)
ip addr add 10.0.11.5/30 dev eth1

# Link R101 <-> CE1 (10.0.1.0/30)
ip addr add 10.1.1.1/30 dev eth2

ip addr add 2.255.0.101/32 dev lo

```

###### `frr.conf`

1. The configuration sets the router hostname to R101 and enables traditional FRR mode. It creates a stable loopback interface (lo) to serve as the permanent Router-ID.

```
!
interface lo
 ip address 2.255.0.101/32
!
```
2. The eth0 interface connects R101 to R103 through the 10.0.11.0/30 point-to-point subnet.
```
interface eth0
 ip address 10.0.11.1/30
!
```
3. The eth1 interface connects R101 to R102 through the 10.0.11.4/30 point-to-point subnet.
```
interface eth1
 ip address 10.0.11.5/30
!
```
4. The eth2 interface connects R101 to CE1 through the 10.1.1.0/30 point-to-point subnet. 
```
interface eth2
 ip address 10.1.1.1/30
!
```


5. Enables OSPF using the loopback IP as the Router-ID. It advertises all connected interfaces into Area 0, ensuring internal reachability between all routers and the customer edge within the autonomous system.
```
router ospf
 ospf router-id 2.255.0.101
 network 2.255.0.101/32 area 0
 network 10.0.11.1/30 area 0
 network 10.0.11.5/30 area 0
 network 10.1.1.1/30 area 0
!
```

6. Configures iBGP:

```
router bgp 100
 bgp router-id 2.255.0.101
 neighbor 2.255.0.102 remote-as 100
 neighbor 2.255.0.102 update-source 2.255.0.101
 neighbor 2.255.0.103 remote-as 100
 neighbor 2.255.0.103 update-source 2.255.0.101
!
 address-family ipv4 unicast
  neighbor 2.255.0.102 next-hop-self
  neighbor 2.255.0.103 next-hop-self
 exit-address-family
!
```

## VPN Site 1

VPN Site 1 has just one customer edge (**CE1**) and one LAN client (**client-A1**). Both described below.

### CE1

###### `init.sh`

```
#!/bin/sh
set -eu

# WAN: link CE1 <-> R101
ip link set eth0 up
ip addr add 10.1.1.2/30 dev eth0

# Add default route towards the provider gateway
ip route add default via 10.1.1.1

# LAN: Site 1
ip link set eth1 up
ip addr add 192.168.1.1/24 dev eth1

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
```


###### `client-CE1.conf`


The address and port of the OpenVPN server to connect to are listed here: CE1 attempts to connect to the hub (CE3 10.1.3.2) on UDP port 1194. 
```
# Lato CE3
remote 10.1.3.2 1194
```

The CA certificate verifies the VPN server, while CE1's certificate and private key identify CE1 to CE3. Together, they enable certificate-based authentication.
```
ca   /root/openvpn/keys/ca.crt
cert /root/openvpn/keys/CE1.crt
key  /root/openvpn/keys/CE1.key
```

These options keep the tunnel more stable during reconnections. AES-256-GCM encrypts and protects the VPN traffic.

```
remote-cert-tls server
persist-key
persist-tun
verb 3
cipher AES-256-GCM
```

### Client-A1

###### `init.sh`

```
#!/bin/sh
set -eu

# Enable loopback and network interface
ip link set lo up
ip link set enp0s3 up

# Remove old IP addresses and configure client-A1 address
ip addr flush dev enp0s3 scope global
ip addr add 192.168.1.2/24 dev enp0s3

# Use CE1 as default gateway
ip route del default 2>/dev/null || true
ip route replace default via 192.168.1.1 dev enp0s3

echo "[client-A1] Network configured"
```

Since client-A1 is a sensitive device, it is protected by a Mandatory Access Control (MAC) mechanism; specifically, it is a Lubuntu virtual machine on which AppArmor is enabled and configured.

A specific profile was created for the `/usr/bin/ssh` binary, that is, the OpenSSH client used by the machine to administer or connect to remote hosts. I chose ssh because it is a realistic application that is relevant from a security perspective: it communicates over the network and uses local files that may contain sensitive information, such as SSH configurations, private keys, and data related to known hosts.

The threat scenario considered is a vulnerability in the SSH client or one of its libraries that allows an attacker to trick the process into reading an arbitrary path or executing code within the process’s own context. Without containment, a compromised process can attempt to access all files for which it has Unix permissions, and if run with elevated privileges, it could even gain access to extremely sensitive files such as /etc/shadow. Even when the process is not running as root, it could still expose the user’s private data, such as files in the home directory, SSH keys, or other secrets available within its context.

###### `load_apparmor.sh`

```
#!/bin/sh
set -eu

PROFILE="/etc/apparmor.d/usr.bin.ssh"

echo "[*] Verifica che il profilo esista: $PROFILE"
if [ ! -f "$PROFILE" ]; then
	echo "[!] Profilo non trovato: $PROFILE" &2
	exit
fi

echo "[*] Parsing e (ri)carimento del profilo..."
sudo apparmor_parser -r "$PROFILE"

echo "[*] Imposto il profilo in modalità ENFORCE..."
sudo aa-enforce "$PROFILE"

echo "[*] Stato profilo:"
sudo aa-status || echo "(profilo non trovato in aa-status)"

echo "[+] Fatto."
```

This script is used to install the AppArmor profile in the /etc/apparmor.d/ directory, load it into the kernel using the apparmor_parser command, and capture the output of aa-status as evidence that AppArmor and its profile are indeed active.


###### `usr.bin.ssh`
```
#include <tunables/global>

profile /usr/bin/ssh flags=(attach_disconnected) {
  /usr/bin/ssh mr,
  /lib/** mr,
  /lib64/** mr,
  /usr/lib/** mr,
  /etc/ld.so.{cache,preload} r,
  /etc/ssl/openssl.cnf r,
  /etc/passwd r,
  /etc/group r,
  /proc/filesystems r,
  /dev/null rw,

  network inet stream,
  network inet6 stream,

  audit deny /etc/{shadow,shadow-,gshadow,gshadow-} r,
  audit deny /etc/security/** r,
  audit deny /etc/passwd w,
  
  deny owner @{HOME}/.ssh/.* rw,
  
  deny /etc/** w,
  
  deny /tmp/** x,

  deny network inet raw,
  deny network packet,
  deny network dgram,
}
```

The security objectives implemented are: 
1. Preventing the SSH client from reading operating-system credential stores such as /etc/shadow and related shadow files (1). 
2. Estricting access to sensitive user material stored in hidden files within ~/.ssh/, preventing the SSH process from modifying files under /etc/ in order to preserve system configuration integrity (2).
3. Blocking the execution of files from the world-writable /tmp/ directory (4). 


###### `test-apparmor.sh`


```
#!/bin/sh
set -eu

LOG_CMD='sudo journalctl -k | grep "apparmor=\"DENIED\"" | tail -n 10'

sep() {
  echo "------------------------------------------------------------"
}

run_allowed() {
  desc="$1"
  shift
  echo
  sep
  echo "[ALLOWED] $desc"
  echo "[CMD] $*"
  if "$@"; then
    echo "[OK] Comando terminato con successo (nessun blocco evidente)."
  else
    echo "[WARN] Comando terminato con errore."
  fi
}

run_forbidden() {
  desc="$1"
  shift
  echo
  sep
  echo "[FORBIDDEN] $desc"
  echo "[CMD] $*"
  if "$@"; then
    echo "[WARN] Comando è andato a buon fine, ma mi aspettavo un blocco."
  else
    echo "[OK] Comando fallito come previsto (possibile blocco AppArmor)."
  fi
  echo "[LOG] Ultimi DENIED da AppArmor:"
  eval "$LOG_CMD" || true
}

echo "== Test AppArmor per /usr/bin/ssh =="

# Test preliminare: verifica che il profilo sia caricato
echo
sep
echo "[INFO] Profili AppArmor attivi per ssh:"
if command -v aa-status >/dev/null 2>&1; then
  sudo aa-status | grep ssh || echo "  (nessun profilo ssh trovato in aa-status)"
else
  echo "  (aa-status non disponibile)"
fi

# Test ALLOWED 1: stampa versione ssh
run_allowed "ssh -V (versione client SSH)" ssh -V

# Test ALLOWED 2: elenco cipher supportati
run_allowed "ssh -Q cipher (elenco cipher supportati)" ssh -Q cipher

# Test FORBIDDEN 1: lettura credential store di sistema (/etc/shadow)
run_forbidden "Tentativo di usare /etc/shadow come file di config" \
  sudo ssh -F /etc/shadow localhost

# Test FORBIDDEN 2: accesso a materiale sensibile in ~/.ssh (fake_config)
mkdir -p "$HOME/.ssh"
echo "Host 127.0.0.1" > "$HOME/.ssh/fake_config"

run_forbidden "Tentativo di usare ~/.ssh/fake_config come file di config" \
  ssh -F "$HOME/.ssh/fake_config" localhost

# Test FORBIDDEN 3: esecuzione di payload da /tmp via ProxyCommand
cat >/tmp/payload.sh <<'EOF'
#!/bin/sh
echo "PWNED from /tmp" >&2
exit 0
EOF
chmod +x /tmp/payload.sh

run_forbidden "Tentativo di eseguire /tmp/payload.sh tramite ProxyCommand" \
  ssh -v -o ProxyCommand=/tmp/payload.sh localhost 2>&1

echo
sep
echo "[DONE] Test AppArmor completati."

```

The permitted tests show that the AppArmor profile does not block legitimate use of the SSH client. The `ssh -V` command verifies that the confined binary starts correctly and that essential dependencies are loaded. The `ssh -Q cipher` command also verifies that OpenSSH can initialize its cryptographic component and query the supported algorithms. Both commands return a success code, demonstrating that the confinement is selective: it restricts only unauthorized operations rather than preventing the program from functioning.

Three negative tests were then performed. In the first, the command `sudo ssh -F /etc/shadow localhost` was used: SSH attempts to use `/etc/shadow` as a configuration file, but the profile denies access to the file. In the second test, ~/.ssh/fake_config was created and `ssh -F ~/.ssh/fake_config localhost` was executed: the command fails, and the journal logs a read denial on the specified path, associated with the /usr/bin/ssh profile. In the third test, an attempt was made to execute `/tmp/payload.sh` using the ProxyCommand option. Since the profile prohibits execution from /tmp, the payload is not executed and the SSH command fails. 

## VPN Site 2


### CE2

###### `init.sh`

```#!/bin/sh
set -eu


# WAN interface:
ip link set eth0 up
ip addr add 10.1.2.2/30 dev eth0

# Default route:
# Traffic for remote networks is sent to R103.
ip route add default via 10.1.2.1

# Enable IPv4 forwarding:
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Physical LAN interface:
ip link set eth1 up
ip addr add 192.168.2.1/24 dev eth1

# VLAN 32:
ip link add link eth1 name eth1.32 type vlan id 32 2>/dev/null || true
ip link set eth1.32 up
ip addr add 192.168.32.1/24 dev eth1.32

# VLAN 95:
ip link add link eth1 name eth1.95 type vlan id 95 2>/dev/null || true
ip link set eth1.95 up
ip addr add 192.168.95.1/24 dev eth1.95
```

###### `client-CE2.conf`

```
client
dev tun
proto udp

# stesso server CE3
remote 10.1.3.2 1194

ca   /root/openvpn/keys/ca.crt
cert /root/openvpn/keys/CE2.crt
key  /root/openvpn/keys/CE2.key

remote-cert-tls server
persist-key
persist-tun
verb 3
cipher AES-256-GCM
```

CE2 connects the WAN to the internal network: on the eth0 interface, it uses the address 10.1.2.2/30 and reaches R103, which is configured as the default gateway with the address 10.1.2.1. CE2 acts as a spoke for CE3 and is therefore also configured as an OpenVPN client using the file `client-CE2.conf` file.

On the internal side, eth1 is connected to ebpf-1 on the 192.168.2.0/24 network, in addition, the subinterfaces eth1.32 and eth1.95 are created, which act as gateways for VLAN 32 (network 192.168.32.0/24 with client-B1) and VLAN 95 (network 192.168.95.0/24 with client-B2), respectively.


### eBPF-1

## eBPF-Switch Configuration

The eBPF-Switch is configured to perform Layer 2 switching, IEEE 802.1X authentication, VLAN segmentation, and dynamic network access control.

At the MAC layer, the node applies `ebtables` rules to prevent indiscriminate frame forwarding. Specifically, the default policy of the `FORWARD` chain is set to `DROP`, so access ports connected to clients cannot freely forward traffic. Traffic coming from the uplink to the router, on the other hand, is handled via specific rules. After authentication, the Layer 2 rules are dynamically updated based on the client’s MAC address, allowing traffic only to authorized devices.

For the IP layer and network segmentation, a Linux bridge named `br0` is created with VLAN filtering enabled. The bridge connects the uplink and the access ports to the clients, allowing each port to be associated with the appropriate VLAN. Additionally, `group_fwd_mask` is configured to allow the forwarding of EAPOL frames required for the exchange of 802.1X messages between clients and the authenticator.

`hostapd` is configured as an IEEE 802.1X authenticator and a RADIUS client. It receives EAPOL requests from clients, forwards them to the FreeRADIUS server, and receives the corresponding authentication decision. When FreeRADIUS sends an `Access-Accept` response, it may contain attributes that identify the VLAN to be assigned to the client, for example, VLAN 32 for `client-B1` and VLAN 95 for `client-B2`.

The BPF/XDP component implements dynamic access control. An XDP program associated with the access ports intercepts EAPOL frames and establishes a mapping between the client’s identity, its MAC address, and the physical port of origin. A second XDP program, associated with the uplink, intercepts the `Access-Accept` RADIUS responses, extracts the VLAN identifier, and constructs the final `MAC → VLAN` mapping.

The decisions are stored in a BPF map that is also made available in user space. A user-space process reads this map and applies the necessary configuration: it assigns or removes the VLAN on the bridge using commands such as `bridge vlan add` and `bridge vlan del`, then updates the `ebtables` rules to authorize or revoke Layer 2 forwarding based on the client’s MAC address.


###### `init.sh`


```
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
```




###### `ebpf_loader.sh`
```
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURAZIONE
# ============================================================

# Interfacce
TRUNK_IF="eth0"      # Parser RADIUS
CLIENT1_IF="eth1"    # Parser EAPOL
CLIENT2_IF="eth2"    # Parser EAPOL

# File BPF compilati da "make"
RADIUS_OBJ="xdp_kernel.o"
EAPOL_OBJ="xdp_eap.o"

# Nomi delle funzioni/programmi eBPF dentro i file .o.
# Devono coincidere con i nomi definiti nei rispettivi file C.
RADIUS_PROG="xdp_radius_parser"
EAPOL_PROG="xdp_eap_parser"

# Directory delle mappe pinnate.
BPF_DIR="/sys/fs/bpf"

# Programma userspace da avviare.
USER_PROGRAM="./xdp_user"

# Parametri del programma userspace.
VLAN_MAP="${VLAN_MAP:-32:eth1,95:eth2}"
BRIDGE="${BRIDGE:-br0}"
GATEWAY_IFACE="${GATEWAY_IFACE:-eth0}"
MAP_PATH="${MAP_PATH:-/sys/fs/bpf/auth_map}"
INTERVAL_MS="${INTERVAL_MS:-200}"
LOG_LEVEL="${LOG_LEVEL:-2}"


# ============================================================
# SUDO
# ============================================================

# Nei container potresti essere già root e sudo potrebbe non esistere.
SUDO=""

if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi


# ============================================================
# COMPILAZIONE
# ============================================================

echo "[1/6] Compilazione programmi XDP..."
make


# ============================================================
# FILESYSTEM eBPF E DEBUG
# ============================================================

echo "[2/6] Controllo bpffs..."

$SUDO mkdir -p "$BPF_DIR"

# Monta bpffs soltanto se /sys/fs/bpf non è già un filesystem BPF.
if [ "$(stat -f -c %T "$BPF_DIR" 2>/dev/null || true)" != "bpf_fs" ]; then
    echo "      Monto bpffs su $BPF_DIR..."

    $SUDO umount "$BPF_DIR" 2>/dev/null || true
    $SUDO mount -t bpf bpf "$BPF_DIR"
fi

echo "      bpffs pronto: $BPF_DIR"


# debugfs serve solo per vedere bpf_printk() tramite trace_pipe.
if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
    echo "      Monto debugfs su /sys/kernel/debug..."
    $SUDO mkdir -p /sys/kernel/debug
    $SUDO mount -t debugfs none /sys/kernel/debug
fi


# ============================================================
# CONTROLLI FILE
# ============================================================

echo "[3/6] Controllo file compilati..."

if [ ! -f "$RADIUS_OBJ" ]; then
    echo "ERRORE: file mancante: $RADIUS_OBJ" >&2
    exit 1
fi

if [ ! -f "$EAPOL_OBJ" ]; then
    echo "ERRORE: file mancante: $EAPOL_OBJ" >&2
    exit 1
fi

if [ ! -x "./xdp_loader" ]; then
    echo "ERRORE: xdp_loader non esiste o non è eseguibile." >&2
    exit 1
fi

if [ ! -x "$USER_PROGRAM" ]; then
    echo "ERRORE: programma userspace non trovato: $USER_PROGRAM" >&2
    exit 1
fi


# ============================================================
# PULIZIA STATO PRECEDENTE
# ============================================================

echo "[4/6] Pulizia programmi XDP e mappe precedenti..."

# Rimuove eventuali programmi XDP già collegati.
# "xdp off" stacca il programma XDP dall'interfaccia. [200]
$SUDO ip link set dev "$TRUNK_IF" xdp off 2>/dev/null || true
$SUDO ip link set dev "$CLIENT1_IF" xdp off 2>/dev/null || true
$SUDO ip link set dev "$CLIENT2_IF" xdp off 2>/dev/null || true

# Rimuove vecchie mappe pinnate.
# I pin sono riferimenti nel bpffs; rimuovendoli, una mappa non più
# referenziata può essere rilasciata dal kernel. [210][213]
$SUDO rm -f \
    "$BPF_DIR/identity_map" \
    "$BPF_DIR/auth_map" \
    2>/dev/null || true


# ============================================================
# ATTACH XDP
# ============================================================

echo "[5/6] Collegamento programmi XDP..."

echo "      eth0: parser RADIUS"
$SUDO ./xdp_loader \
    --dev "$TRUNK_IF" \
    --filename "$RADIUS_OBJ" \
    --progname "$RADIUS_PROG"

echo "      eth1: parser EAPOL"
$SUDO ./xdp_loader \
    --dev "$CLIENT1_IF" \
    --filename "$EAPOL_OBJ" \
    --progname "$EAPOL_PROG"

echo "      eth2: parser EAPOL"
$SUDO ./xdp_loader \
    --dev "$CLIENT2_IF" \
    --filename "$EAPOL_OBJ" \
    --progname "$EAPOL_PROG"


# ============================================================
# USER SPACE
# ============================================================

echo "[6/6] Avvio programma userspace..."

echo "      VLAN map:       $VLAN_MAP"
echo "      Bridge:         $BRIDGE"
echo "      Gateway iface:  $GATEWAY_IFACE"
echo "      Auth map:       $MAP_PATH"
echo "      Intervallo:     ${INTERVAL_MS} ms"
echo "      Log level:      $LOG_LEVEL"

exec $SUDO "$USER_PROGRAM" \
    --vlan-map "$VLAN_MAP" \
    --bridge "$BRIDGE" \
    --gateway-iface "$GATEWAY_IFACE" \
    --map-path "$MAP_PATH" \
    --interval-ms "$INTERVAL_MS" \
    --log-level "$LOG_LEVEL"
```

The script actually does the following things

1) eBPF operations require administrative privileges: loading BPF programs, XDP attachment, mounting `bpffs`, and modifying bridges and `ebtables`. For compatibility, `sudo` is used if available; in containers where root privileges are already available, the commands are executed directly.

Additionally, both the eBPF objects and the user-space binaries are recompiled before attachment. This prevents the use of an outdated version of the parser following any code changes.

2) `bpffs`, the BPF filesystem, is set up. The BPF filesystem allows maps in the kernel to be pinned using a pathname. In this way, kernel programs and the user-space process share the same state. The XDP parser writes to `auth_map`, while the user-space process opens the same map and applies enforcement.


3) The following components are checked for:

| File | Role |
|---|---|
| `xdp_kernel.o` | XDP parser for RADIUS |
| `xdp_eap.o` | XDP parser for EAPOL |
| `xdp_loader` | Loading and linking XDP programs |
| `xdp_user` | Application of VLANs and `ebtables` |

If a component is missing, execution is terminated with an error, preventing a demo that is only partially functional from starting.

4) **Reset to Previous State**

This step is necessary to make the demo repeatable. Any previously attached parsers and old maps are removed to prevent `client-B1` from being authorized based on a RADIUS decision received during a previous test.

5) **XDP Attach**

- The `xdp_radius_parser` is attached to the `eth0` uplink. RADIUS packets returning from the server to `hostapd` are received on this interface. The parser examines the `Access-Accept` responses, extracts the `User-Name` and `Tunnel-Private-Group-ID`, and then adds the MAC address, VLAN, and status to the `auth_map`.

- The EAPOL parser is connected to the `eth1` and `eth2` interfaces. EAP Identity responses from the supplicant are intercepted on these ports; the identity is extracted and associated with the source MAC address and the `ifindex` of the port on which the frame is received.

6) **Starting `xdp_user`**

In the final step, the user-space process is started, which remains listening to `auth_map`. The `exec` command is used to replace the script with the enforcement process; this way, the `ACCEPT` and `REVOKE` logs are displayed directly in the terminal, and closing the terminal causes the process to stop.

##### `xdp_eap.c`

```
// SPDX-License-Identifier: GPL-2.0
#include <linux/types.h>
#include <linux/bpf.h>
#include <stdbool.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

#include "xdp_common.h"

#define ETHER_TYPE_EAPOL 0x888E
#define EAPOL_PKT_EAP 0
#define EAPOL_PKT_LOGOFF 2

#define EAP_CODE_RESPONSE 2
#define EAP_TYPE_IDENTITY 1

struct eapol_frame_hdr {
	__u8 ver, type;
	__be16 len;
} __attribute__((packed));

struct eap_msg_hdr {
	__u8 code, id;
	__be16 len;
} __attribute__((packed));

struct eap_identity_type {
	__u8 type; /* 1 = Identity */
} __attribute__((packed));


/* Ensure Ethernet header is present and EtherType is EAPOL */
static __always_inline struct ethhdr *eth_get_eapol(void *data, void *end)
{
	struct ethhdr *eth = data;
	if (!range_within(eth, end, sizeof(*eth)))
		return NULL;

	if (eth->h_proto != bpf_htons(ETHER_TYPE_EAPOL))
		return NULL;

	return eth;
}

/* Handle EAPOL-Logoff: mark station as deauthorized in auth_map */
static __always_inline void process_eapol_logoff(struct ethhdr *eth)
{
	struct station_auth_decision *dec =
	    bpf_map_lookup_elem(&auth_map, eth->h_source);
	if (dec) {
		dec->auth_state = 0;
		dec->last_update_ns = bpf_ktime_get_ns();
		bpf_map_update_elem(&auth_map, eth->h_source, dec, BPF_ANY);
	}
}

/*
 * Try to parse an EAP Identity Response:
 * Returns true if identity extracted into out_id.
 */
static __always_inline bool eap_extract_identity_response(
	void *end, struct eapol_frame_hdr *eol, struct supplicant_id_key *out_id)
{
	if (eol->type != EAPOL_PKT_EAP)
		return false;

	struct eap_msg_hdr *eap = (void *)(eol + 1);
	if (!range_within(eap, end, sizeof(*eap)))
		return false;

	/* Only EAP Response */
	if (eap->code != EAP_CODE_RESPONSE)
		return false;

	struct eap_identity_type *eid = (void *)(eap + 1);
	if (!range_within(eid, end, sizeof(*eid)))
		return false;

	/* Only Identity type */
	if (eid->type != EAP_TYPE_IDENTITY)
		return false;

	__u16 eap_len = bpf_ntohs(eap->len);
	int id_len = (int)eap_len - (int)sizeof(*eap) - 1;
	if (id_len <= 0)
		return false;

	unsigned char *id_ptr = (unsigned char *)(eid + 1);

	/* Bound identity length */
	id_len = id_len >= ID_MAX ? ID_MAX - 1 : id_len;

	struct supplicant_id_key key = {};
	bpf_core_read_str(key.identity, id_len + 1, id_ptr);

	*out_id = key;
	return true;
}

/*
 * Update identity_map
 * Keep first claimant for 10s to avoid rapid flipping across ports.
 */
static __always_inline void identity_claim_update(struct xdp_md *ctx,
						  struct ethhdr *eth,
						  struct supplicant_id_key *id)
{
	__u64 now = bpf_ktime_get_ns();
	__u64 threshold = 10ULL * 1000000000ULL;
	struct supplicant_claim *old = bpf_map_lookup_elem(&identity_map, id);
	if (old) {
		if (now - old->claimed_at_ns < threshold)
			return;
	}

	struct supplicant_claim claim = {};
	claim.ingress_port_idx = (__u32)ctx->ingress_ifindex;
	claim.claimed_at_ns = now;

	/*copy MAC address*/
	for (int i = 0; i < ETH_ALEN; i++) {
		claim.sta_mac[i] = eth->h_source[i];
	}

	bpf_map_update_elem(&identity_map, id, &claim, BPF_ANY);
}

SEC("xdp")
int xdp_eap_parser(struct xdp_md *ctx)
{
	void *data = (void *)(long)ctx->data;
	void *end = (void *)(long)ctx->data_end;

	/* 1) Parse only EAPOL frames */
	struct ethhdr *eth = eth_get_eapol(data, end);
	if (!eth)
		return XDP_PASS;

	/* 2) Parse EAPOL header */
	struct eapol_frame_hdr *eol = (void *)(eth + 1);
	if (!range_within(eol, end, sizeof(*eol)))
		return XDP_PASS;

	/* 3) Logoff => revoke */
	if (eol->type == EAPOL_PKT_LOGOFF) {
		process_eapol_logoff(eth);		//setta auth_state=0 e aggiorna last_update_ns
		return XDP_PASS;
	}

	/* 4) Identity Response => cache identity->(mac,ifindex) */
	struct supplicant_id_key id = {};
	if (!eap_extract_identity_response(end, eol, &id))
		return XDP_PASS;

	identity_claim_update(ctx, eth, &id);

	return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

The XDP program is installed on **client-dedicated access ports** and analyzes only EAPOL traffic.

- **Detection of EAPOL Traffic**
  - `eth_get_eapol()` examines the Ethernet header of the incoming frame.
  - Checking the EtherType allows EAPOL packets to be distinguished from the rest of the traffic.
  - Only frames belonging to EAPOL are subjected to further processing.

- **Retrieving the Client’s Identity**
  - `eap_extract_identity_response()` identifies **EAP Response / Identity** messages.
  - When it finds such a response, it retrieves the identity provided by the supplicant, which typically corresponds to the EAP username.
  - The value is copied within the `ID_MAX` limit, ensuring that no data beyond the expected size is read or stored.

- **Association Between Identity and Station**
  - `identity_claim_update()` records in the `identity_map` the information needed to link the received identity to the device that declared it.
  - For each identifier, the following are then stored:
    - the EAP identity;
    - the station’s MAC address;
    - the index of the interface from which the frame arrived;
    - the time of detection.
  - In this way, the identity observed via EAPOL can subsequently be associated with the corresponding RADIUS request or response.

- **Handling Disconnection via Logoff**
  - Receiving an **EAPOL Logoff** frame indicates that the client has terminated its session.
  - In this case, the station’s MAC address is identified, and the corresponding entry in the `auth_map` is updated by setting `auth_state = 0`.
  - The userspace process can use this information to revoke the client’s access to the network.

At the end of this phase, the `identity_map` temporarily maintains the associations between the observed EAP identities and the devices from which they originate:

**Identity → MAC + ingress interface + timestamp**


##### `xdp_common.h`
```
#pragma once
#include <linux/types.h>
#include <stdbool.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>
#define ID_MAX 64

/*
 * Shared structs used by XDP programs.
 */

/* Decision stored by radius parser for the userspace enforcer */
struct station_auth_decision {
	__u16 assigned_vlan;     //VLAN assegnata da RADIUS, ad esempio 32 o 95
	__u8 auth_state;         // 1 = autorizzato, 0 = revocato/non autorizzato
	__u8 enforced_flag;      // 0 = decisione non ancora applicata; 1 = VLAN ed ebtables già applicati
	__u32 ingress_port_idx;  // ifindex della porta da cui è arrivato il supplicant
	__u64 last_update_ns;    // timestamp kernel della decisione
};

/* Supplicant Identity key */
struct supplicant_id_key {
	char identity[ID_MAX];
};

/* Mapping id <-> mac from supplicant */
struct supplicant_claim {
	__u8 sta_mac[6];
	__u32 ingress_port_idx;
	__u64 claimed_at_ns;
};

/*
 * Shared maps used by XDP programs.
 */

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__type(key, struct supplicant_id_key);
	__type(value, struct supplicant_claim);
	__uint(max_entries, 1024);
	__uint(pinning, LIBBPF_PIN_BY_NAME); 
} identity_map SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_LRU_HASH);
	__type(key, __u8[6]);
	__type(value, struct station_auth_decision);
	__uint(max_entries, 1024);
	__uint(pinning, LIBBPF_PIN_BY_NAME); 
} auth_map SEC(".maps");


static __always_inline bool range_within(const void *ptr,
					 const void *data_end,
					 __u64 size)
{
	const void *limit;

	if (size == 0)
		return true;

	/* Compute end pointer for the region. */
	limit = (const void *)((const char *)ptr + size);

	/* If limit would exceed data_end, region is not safe. */
	if (limit > data_end)
		return false;

	return true;
}
```

This file defines the **data structures and shared BPF maps** between the two XDP programs and the userspace process.

#### Data Structures

- **`station_auth_decision`**
  - Represents the authentication decision associated with a specific station, identified by its MAC address.
  - Contains:
    - **`assigned_vlan`**: VLAN assigned by the RADIUS server.
    - **`auth_state`**: station authorization status:
      - `1` = authorized
      - `0` = revoked
    - **`enforced_flag`**: Flag used to indicate the enforcement status, managed by the userspace process.
    - **`ingress_port_idx`**: Index of the ingress interface or port on which the station was detected, useful for debugging and tracing.
    - **`last_update_ns`**: timestamp of the last update, expressed in nanoseconds.

- **`supplicant_id_key`**
  - Represents the key used to identify the supplicant via its identity.
  - It is based on the `identity[ID_MAX]` field, i.e., the EAP username.
  - The maximum length of the identity is defined by `ID_MAX = 64`.

- **`supplicant_claim`**
  - Associates an EAP identity with a specific station and the ingress port on which it was detected.
  - Contains:
    - **`sta_mac`**: the station’s MAC address.
    - **`ingress_port_idx`**: Index of the port on which the identity was observed.
    - **`claimed_at_ns`**: Timestamp, in nanoseconds, of when the association was made.

#### BPF Maps

- **`identity_map`**
  - It is an `LRU hash` map with:
    - key = EAP identity
    - value = `supplicant_claim`
  - It temporarily stores the relationship **Identity → MAC + port + timestamp**.
  - It is used to correlate events received via **EAPOL** with those subsequently received via **RADIUS**.
  - It is a `BPF_MAP_TYPE_LRU_HASH`: when available memory is under pressure, the least recently used entries are automatically removed.
  - It is **pinned** via `LIBBPF_PIN_BY_NAME` within `bpffs`, so it can be used simultaneously by different BPF programs and the userspace process.

- **`auth_map`**
  - Uses:
    - key = MAC address
    - value = `station_auth_decision`
  - Contains the final authentication decision in the form **MAC → VLAN + status + timestamp**.
  - This is the map used by the userspace process to enforce the authentication decision.
  - This map is also of the **LRU** type and is **pinned** in `bpffs`.

#### Security Helpers for the Verifier

- **`range_within(ptr, data_end, size)`**
  - Verifies that a given memory area of the packet remains within the valid bounds `[data, data_end)`.
  - In practice, it ensures that the program does not attempt to read data beyond the end of the packet.
  - It is essential in XDP/eBPF programs because it allows for:
    - avoiding **out-of-bounds** reads;
    - satisfying the security checks of the **eBPF verifier**.

##### `xdp_kernel.c`


```
// SPDX-License-Identifier: GPL-2.0
#include <linux/types.h>
#include <linux/bpf.h>
#include <stdbool.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

#include "xdp_common.h"

#define RADIUS_CODE_ACCESS_ACCEPT 2
#define RADIUS_ATTR_USER_NAME 1
#define RADIUS_ATTR_TUNNEL_PGID 81
#define RADIUS_UDP_PORT 1812
#define RADIUS_MAX_ATTRS 64

#define IDENTITY_TTL_NS (15ULL * 1000000000ULL)

struct radius_packet_hdr {
	__u8 code;
	__u8 id;
	__u16 len;
	__u8 auth[16];
} __attribute__((packed));

struct radius_tlv_hdr {
	__u8 type;
	__u8 len;
} __attribute__((packed));

/* ------------------------------------------------------------------------- */
/* Helper functions                                                          */
/* ------------------------------------------------------------------------- */

/* Extract UDP header from Ethernet+IPv4 frame. */
static __always_inline struct udphdr *extract_udp4(void *data, void *end)
{
	struct ethhdr *eth = data;
	if (!range_within(eth, end, sizeof(*eth)))
		return NULL;

	if (eth->h_proto != bpf_htons(ETH_P_IP))
		return NULL;

	struct iphdr *ip = (void *)(eth + 1);
	if (!range_within(ip, end, sizeof(*ip)))
		return NULL;

	if (ip->protocol != IPPROTO_UDP)
		return NULL;

	/* IP header length sanity (ihl in 32-bit words). */
	int ihl = ip->ihl * 4;
	if (ihl < (int)sizeof(*ip) || ihl > 60)
		return NULL;

	struct udphdr *udp = (void *)((char *)ip + ihl);
	if (!range_within(udp, end, sizeof(*udp)))
		return NULL;

	return udp;
}

/* Parse decimal VLAN from ASCII attribute value */
static __always_inline bool parse_vlan_ascii(const char *src, const char *end,
					     __u16 *out_vlan)
{
	__u32 acc = 0;
	bool got_digit = false;

	/* Read up to 5 ASCII digits (4094 max). */
	for (int i = 0; i < 5; i++) {
		const char *p = src + i;

		/* Stop if we cannot safely read one byte. */
		if (!range_within(p, end, 1)) {
			break;
		}

		char c = *p;

		/* Stop on first non-digit. */
		if (c < '0' || c > '9') {
			break;
		}

		got_digit = true;

		/* Convert digit and accumulate. */
		__u32 digit = (__u32)(c - '0');
		acc = acc * 10 + digit;

		/* Early stop on overflow beyond allowed VLAN range. */
		if (acc > 4094) {
			break;
		}
	}

	/* Must have seen at least one digit and be in [1..4094]. */
	if (!got_digit) {
		return false;
	}

	if (acc < 1 || acc > 4094) {
		return false;
	}

	*out_vlan = (__u16)acc;
	return true;
}

/*
 * Scan RADIUS attributes and extract:
 *  - User-Name -> supplicant_id_key
 *  - Tunnel-Private-Group-ID -> VLAN
 *
 * Returns true only if both values were found.
 */
static __always_inline bool radius_pull_uname_vlan(
	void *end, struct radius_packet_hdr *radius,
	struct supplicant_id_key *out_id, int *out_id_len, __u16 *out_vlan)
{
	struct supplicant_id_key id_key = {};
	int id_len = 0;
	__u16 vlan = 0;

	struct radius_tlv_hdr *attr = (void *)(radius + 1);

	for (int i = 0; i < RADIUS_MAX_ATTRS; i++) {
		if (!range_within(attr, end, sizeof(*attr)))
			break;

		/* TLV len includes (type,len). Must be >= header. */
		if (attr->len < sizeof(*attr))
			break;

		__u8 type = attr->type;
		__u8 val_len = attr->len - (int)sizeof(*attr);
		char *val = (void *)(attr + 1);

		if (type == RADIUS_ATTR_USER_NAME) {
			/* Bound length to ID_MAX-1 (+1 for '\0') */
			id_len = val_len >= ID_MAX ? ID_MAX - 1 : val_len;
			bpf_core_read_str(id_key.identity, id_len + 1, val);

		} else if (type == RADIUS_ATTR_TUNNEL_PGID) {
			if (!parse_vlan_ascii(val, end, &vlan))
				break;
		}

		if (id_len && vlan)
			break;

		/* next attribute */
		attr = (void *)((char *)attr + (int)sizeof(*attr) + val_len);
	}

	if (!id_len || !vlan)
		return false;

	*out_id = id_key;
	*out_id_len = id_len;
	*out_vlan = vlan;
	return true;
}

/*
 * Consume identity_map[identity] and update auth_map[mac] with VLAN/state=AUTH.
 * - Verifies TTL
 * - Writes decision for userspace enforcer
 * - Deletes consumed identity entry
 */
static __always_inline void radius_commit_accept(struct supplicant_id_key *id,
						 __u16 vlan)
{
	struct supplicant_claim *claim = bpf_map_lookup_elem(&identity_map, id);
	if (!claim)
		return;

	__u64 now = bpf_ktime_get_ns();
	if (now - claim->claimed_at_ns > IDENTITY_TTL_NS) {
		/* stale identity claim; ignore */
		return;
	}

	struct station_auth_decision decision = {};
	decision.assigned_vlan = vlan;
	decision.auth_state = 1;      /* Access-Accept */
	decision.enforced_flag = 0;
	decision.ingress_port_idx = claim->ingress_port_idx;
	decision.last_update_ns = now;

	bpf_map_update_elem(&auth_map, claim->sta_mac, &decision, BPF_ANY);

	/* Identity is one-shot: remove after successful commit. */
	bpf_map_delete_elem(&identity_map, id);
}

/* ------------------------------------------------------------------------- */
/* XDP entrypoint                                                             */
/* ------------------------------------------------------------------------- */

SEC("xdp")
int xdp_radius_parser(struct xdp_md *ctx)
{
    void *packet_start = (void *)(long)ctx->data;
    void *packet_end = (void *)(long)ctx->data_end;

    struct udphdr *udp_hdr = extract_udp4(packet_start, packet_end);
    if (udp_hdr == NULL || udp_hdr->source != bpf_htons(RADIUS_UDP_PORT))
        return XDP_PASS;

    struct radius_packet_hdr *radius_hdr = (void *)(udp_hdr + 1);
    if (!range_within(radius_hdr, packet_end, sizeof(*radius_hdr)))
        return XDP_PASS;

    if (radius_hdr->code != RADIUS_CODE_ACCESS_ACCEPT)
        return XDP_PASS;

    struct supplicant_id_key username = {};
    __u16 assigned_vlan = 0;
    int username_length = 0;

    bool valid_accept = radius_pull_uname_vlan(
        packet_end,
        radius_hdr,
        &username,
        &username_length,
        &assigned_vlan
    );

    if (valid_accept)
        radius_commit_accept(&username, assigned_vlan);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

The `xdp_kernel.c` program analyzes the **RADIUS responses from the server** on the uplink interface and uses the received information to determine the client's authorization and the assigned VLAN.

- **Traffic Filtering**
  - The parser processes only **IPv4/UDP** packets.
  - It checks that the source UDP port is `1812`, thereby identifying RADIUS responses.
  - Other packets are allowed to pass with `XDP_PASS`.

- **Handling Access-Accept Responses**
  - Only **RADIUS Access-Accept** responses are processed.
  - `Access-Reject` and `Access-Challenge` responses are ignored and do not result in authorization.

- **Extracting Information**
  - The `radius_pull_uname_vlan()` function searches for:
    - **`User-Name`**: identifies the authenticated client.
    - **`Tunnel-Private-Group-ID`**: contains the VLAN assigned by the RADIUS server.
  - The username is used to link the RADIUS response to the identity previously detected via EAPOL.

- **VLAN Validation**
  - The VLAN ID is verified, and only values between **1 and 4094** are accepted.
  - Invalid values are discarded.

- **Authorization Commit**
  - The `radius_commit_accept()` function searches for the username in the `identity_map`.
  - If it finds a valid claim, it retrieves:
    - the **station’s MAC address**;
    - the **incoming port**;
    - the timestamp associated with the identity.
  - The claim must have been recorded within the last **15 seconds**.
  - A `station_auth_decision` is then constructed with:
    - Assigned VLAN;
    - `auth_state = 1`;
    - ingress port;
    - update timestamp.
  - The decision is written to the `auth_map`, indexed by the station’s MAC address.
  - After the commit, the entry used is removed from the `identity_map`.

The parser completes the correlation between the EAPOL authentication and the RADIUS response:

**Username → `identity_map` → MAC + port → `radius_commit_accept()` → `auth_map` → VLAN + authorization**



##### `xdp_user.c`

```
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <bpf/bpf.h>

#define MAX_VLAN_MAP 64
#define MAX_IFACE_LEN 16

#define LOG_ERROR 0
#define LOG_WARN  1
#define LOG_INFO  2
#define LOG_DEBUG 3

struct authentication {
    uint16_t vlan_id;
    uint8_t state;
    uint8_t enforced;
    uint32_t ifindex;
    uint64_t last_seen_ns;
} __attribute__((packed));

struct vlan_mapping {
    uint16_t vlan_id;
    char iface[MAX_IFACE_LEN];
};

struct config {
    char bridge[MAX_IFACE_LEN];
    char gateway_iface[MAX_IFACE_LEN];
    char map_path[256];
    uint64_t interval_ms;
    int log_level;

    struct vlan_mapping vlan_map[MAX_VLAN_MAP];
    int vlan_map_count;
};

static struct config cfg;

#define log(level, fmt, ...)                                              \
    do {                                                                  \
        if (cfg.log_level >= (level)) {                                   \
            time_t now = time(NULL);                                      \
            char timestamp[32];                                           \
            strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S",  \
                     localtime(&now));                                    \
            fprintf(stderr, "[%s] " fmt "\n", timestamp, ##__VA_ARGS__); \
        }                                                                 \
    } while (0)

static int execute(char *const args[])
{
    pid_t pid;
    int status;

    log(LOG_DEBUG, "exec: %s", args[0]);

    pid = fork();
    if (pid < 0) {
        log(LOG_ERROR, "fork failed: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        execvp(args[0], args);
        fprintf(stderr, "cannot execute %s: %s\n", args[0], strerror(errno));
        _exit(127);
    }

    if (waitpid(pid, &status, 0) < 0) {
        log(LOG_ERROR, "waitpid failed: %s", strerror(errno));
        return -1;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        log(LOG_ERROR, "command failed: %s", args[0]);
        return -1;
    }

    return 0;
}

static void mac_to_string(const uint8_t mac[6], char out[18])
{
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static const char *interface_for_vlan(uint16_t vlan_id)
{
    for (int i = 0; i < cfg.vlan_map_count; i++) {
        if (cfg.vlan_map[i].vlan_id == vlan_id)
            return cfg.vlan_map[i].iface;
    }

    return NULL;
}

static int configure_bridge(void)
{
    char *args[] = {
        "ip", "link", "set", "dev", cfg.bridge,
        "type", "bridge", "vlan_filtering", "1", NULL
    };

    log(LOG_INFO, "enable VLAN filtering on bridge %s", cfg.bridge);
    execute(args);
    return 0;
}

static int add_vlan_to_ports(const char *client_iface, uint16_t vlan_id)
{
    char vlan[8];
    snprintf(vlan, sizeof(vlan), "%u", vlan_id);

    char *client_args[] = {
        "bridge", "vlan", "add", "dev", (char *)client_iface,
        "vid", vlan, "pvid", "untagged", NULL
    };

    char *trunk_args[] = {
        "bridge", "vlan", "add", "dev", cfg.gateway_iface,
        "vid", vlan, NULL
    };

    if (execute(client_args) != 0)
        return -1;

    return execute(trunk_args);
}

static void remove_vlan_from_trunk(uint16_t vlan_id)
{
    char vlan[8];
    snprintf(vlan, sizeof(vlan), "%u", vlan_id);

    char *args[] = {
        "bridge", "vlan", "del", "dev", cfg.gateway_iface,
        "vid", vlan, NULL
    };

    execute(args);
}

static int add_mac_rules(const uint8_t mac[6], const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    char *ingress_args[] = {
        "ebtables", "-A", "FORWARD", "-i", (char *)client_iface,
        "-s", mac_text, "-j", "ACCEPT", NULL
    };

    char *egress_args[] = {
        "ebtables", "-A", "FORWARD", "-o", (char *)client_iface,
        "-d", mac_text, "-j", "ACCEPT", NULL
    };

    if (execute(ingress_args) != 0)
        return -1;

    return execute(egress_args);
}

static void delete_mac_rules(const uint8_t mac[6], const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    char *ingress_args[] = {
        "ebtables", "-D", "FORWARD", "-i", (char *)client_iface,
        "-s", mac_text, "-j", "ACCEPT", NULL
    };

    char *egress_args[] = {
        "ebtables", "-D", "FORWARD", "-o", (char *)client_iface,
        "-d", mac_text, "-j", "ACCEPT", NULL
    };

    execute(ingress_args);
    execute(egress_args);
}

static int apply_policy(const uint8_t mac[6],
                        struct authentication *decision,
                        const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    log(LOG_INFO, "ACCEPT %s: VLAN %u on %s",
        mac_text, decision->vlan_id, client_iface);

    if (add_vlan_to_ports(client_iface, decision->vlan_id) != 0)
        return -1;

    if (add_mac_rules(mac, client_iface) != 0)
        return -1;

    decision->enforced = 1;
    return 0;
}

static void remove_policy(const uint8_t mac[6],
                          const struct authentication *decision,
                          const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    log(LOG_INFO, "REVOKE %s: VLAN %u on %s",
        mac_text, decision->vlan_id, client_iface);

    delete_mac_rules(mac, client_iface);
    remove_vlan_from_trunk(decision->vlan_id);
}

static int parse_vlan_map(const char *text)
{
    char *copy = strdup(text);
    char *entry;
    char *saveptr = NULL;

    if (copy == NULL)
        return -1;

    cfg.vlan_map_count = 0;
    entry = strtok_r(copy, ",", &saveptr);

    while (entry != NULL) {
        char *separator = strchr(entry, ':');

        if (separator == NULL || cfg.vlan_map_count >= MAX_VLAN_MAP) {
            log(LOG_ERROR, "invalid VLAN map entry: %s", entry);
            free(copy);
            return -1;
        }

        *separator = '\0';

        long vlan = strtol(entry, NULL, 10);
        const char *iface = separator + 1;

        if (vlan < 1 || vlan > 4094 ||
            iface[0] == '\0' ||
            strlen(iface) >= MAX_IFACE_LEN) {
            log(LOG_ERROR, "invalid VLAN map entry: %s:%s", entry, iface);
            free(copy);
            return -1;
        }

        cfg.vlan_map[cfg.vlan_map_count].vlan_id = (uint16_t)vlan;
        snprintf(cfg.vlan_map[cfg.vlan_map_count].iface,
                 MAX_IFACE_LEN, "%s", iface);

        cfg.vlan_map_count++;
        entry = strtok_r(NULL, ",", &saveptr);
    }

    free(copy);
    return cfg.vlan_map_count > 0 ? 0 : -1;
}

static void print_usage(const char *program)
{
    fprintf(stderr, "Usage: %s [options]\n", program);
    fprintf(stderr, "  --bridge BRIDGE         default: br0\n");
    fprintf(stderr, "  --gateway-iface IFACE   default: eth0\n");
    fprintf(stderr, "  --vlan-map MAP          example: 32:eth1,95:eth2\n");
    fprintf(stderr, "  --map-path PATH         default: /sys/fs/bpf/auth_map\n");
    fprintf(stderr, "  --interval-ms MS        default: 200\n");
    fprintf(stderr, "  --log-level LEVEL       error|warn|info|debug or 0-3\n");
}

static int read_options(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bridge") == 0 && i + 1 < argc) {
            snprintf(cfg.bridge, sizeof(cfg.bridge), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--gateway-iface") == 0 && i + 1 < argc) {
            snprintf(cfg.gateway_iface, sizeof(cfg.gateway_iface), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--vlan-map") == 0 && i + 1 < argc) {
            if (parse_vlan_map(argv[++i]) != 0)
                return -1;
        } else if (strcmp(argv[i], "--map-path") == 0 && i + 1 < argc) {
            snprintf(cfg.map_path, sizeof(cfg.map_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--interval-ms") == 0 && i + 1 < argc) {
            cfg.interval_ms = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--log-level") == 0 && i + 1 < argc) {
            const char *level = argv[++i];

            if (strcmp(level, "error") == 0) cfg.log_level = LOG_ERROR;
            else if (strcmp(level, "warn") == 0) cfg.log_level = LOG_WARN;
            else if (strcmp(level, "info") == 0) cfg.log_level = LOG_INFO;
            else if (strcmp(level, "debug") == 0) cfg.log_level = LOG_DEBUG;
            else cfg.log_level = atoi(level);
        } else {
            return -1;
        }
    }

    return 0;
}

static void process_entry(int map_fd,
                          const uint8_t mac[6],
                          struct authentication *decision)
{
    const char *client_iface = interface_for_vlan(decision->vlan_id);
    char mac_text[18];

    mac_to_string(mac, mac_text);

    if (client_iface == NULL) {
        log(LOG_WARN, "no interface for VLAN %u (MAC %s)",
            decision->vlan_id, mac_text);
        return;
    }

    if (decision->state == 1 && decision->enforced == 0) {
        if (apply_policy(mac, decision, client_iface) == 0) {
            if (bpf_map_update_elem(map_fd, mac, decision, BPF_ANY) != 0) {
                log(LOG_ERROR, "cannot update auth_map for %s: %s",
                    mac_text, strerror(errno));
            }
        }
        return;
    }

    if (decision->state == 0 && decision->enforced == 1) {
        remove_policy(mac, decision, client_iface);

        if (bpf_map_delete_elem(map_fd, mac) != 0) {
            log(LOG_WARN, "cannot delete auth_map entry for %s: %s",
                mac_text, strerror(errno));
        }

        return;
    }

    log(LOG_DEBUG, "no action for %s: state=%u enforced=%u VLAN=%u",
        mac_text, decision->state, decision->enforced, decision->vlan_id);
}

static void process_auth_map(int map_fd)
{
    uint8_t current_key[6];
    uint8_t next_key[6];
    struct authentication decision;
    int has_current_key = 0;

    while (1) {
        int result = bpf_map_get_next_key(
            map_fd,
            has_current_key ? current_key : NULL,
            next_key
        );

        if (result != 0)
            break;

        memcpy(current_key, next_key, sizeof(current_key));
        has_current_key = 1;

        if (bpf_map_lookup_elem(map_fd, current_key, &decision) != 0) {
            log(LOG_WARN, "cannot read an auth_map entry: %s", strerror(errno));
            continue;
        }

        process_entry(map_fd, current_key, &decision);
    }
}

int main(int argc, char **argv)
{
    snprintf(cfg.bridge, sizeof(cfg.bridge), "%s", "br0");
    snprintf(cfg.gateway_iface, sizeof(cfg.gateway_iface), "%s", "eth0");
    snprintf(cfg.map_path, sizeof(cfg.map_path), "%s", "/sys/fs/bpf/auth_map");
    cfg.interval_ms = 200;
    cfg.log_level = LOG_INFO;

    if (read_options(argc, argv) != 0 || cfg.vlan_map_count == 0) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }

    if (geteuid() != 0) {
        log(LOG_ERROR, "this program must run as root");
        return EXIT_FAILURE;
    }

    if (access(cfg.map_path, F_OK) != 0) {
        log(LOG_ERROR, "pinned map not found: %s", cfg.map_path);
        return EXIT_FAILURE;
    }

    configure_bridge();

    int map_fd = bpf_obj_get(cfg.map_path);
    if (map_fd < 0) {
        log(LOG_ERROR, "cannot open pinned map %s: %s",
            cfg.map_path, strerror(errno));
        return EXIT_FAILURE;
    }

    log(LOG_INFO, "started: bridge=%s trunk=%s map=%s poll=%lums",
        cfg.bridge, cfg.gateway_iface, cfg.map_path, cfg.interval_ms);

    while (1) {
        process_auth_map(map_fd);
        usleep(cfg.interval_ms * 1000);
    }

    close(map_fd);
    return EXIT_SUCCESS;
}
```


The userspace program actually enforces the authentication decisions generated by the XDP programs. It reads the `auth_map` pinned in `bpffs` using `bpf_obj_get()` and, at regular intervals, checks the entries to determine whether they should be applied or revoked.

- **Reading the `auth_map`**
  - Opens the BPF map specified by `--map-path`.
  - Periodically scans all entries in the map.
  - For each MAC, it reads the VLAN, authentication status, and enforcement status.

- **Granting Access**
  - When an entry has `state = 1` and `enforced = 0`, the authorization policy is applied.
  - The program:
    - associates the VLAN with the client port;
    - enables the same VLAN on the gateway interface;
    - adds `ebtables` rules to allow traffic from the authorized MAC.
  - After successful application, it sets `enforced = 1` in the `auth_map`.

- **Revoking Access**
  - When an entry has `state = 0` and `enforced = 1`, the previously applied policy is removed.
  - The program:
    - deletes the `ebtables` rules associated with the MAC;
    - removes the VLAN from the gateway interface;
    - deletes the entry from the `auth_map`.
  - This allows access to be revoked when, for example, an EAPOL Logoff is received.

  The userspace program actually enforces the authentication decisions generated by the XDP programs. It reads the `auth_map` pinned in `bpffs` using `bpf_obj_get()` and, at regular intervals, checks the entries to determine whether they should be applied or revoked.

- **Main Parameters**

  - **`--bridge`**
    - Specifies the bridge to use.

  - **`--gateway-iface`**
    - Specifies the gateway/trunk interface on which VLANs are configured.

  - **`--vlan-map`**
    - Defines the association between VLANs and client interfaces.

  - **`--map-path`**
    - Specifies the path to the pinned `auth_map`.

  - **`--interval-ms`**
    - Determines how often, in milliseconds, the program checks the `auth_map`.

  - **`--log-level`**
    - Controls the level of detail in the logs.
    - Supports `error`, `warn`, `info`, `debug`, or values from `0` to `3`.

The userspace process is therefore the point where the decision made by the XDP programs is transformed into an **actual network policy**:

**`auth_map` → grant/revoke → VLAN + MAC rules → client access**.

### Client-B1

##### `init.sh`
```
#!/bin/sh

ip addr add 192.168.32.2/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.32.1
```

##### `supplicant.sh`
```
wpa_supplicant -B -D wired -i eth0 -c /root/wpa_supplicant.conf -C /run/wpa_supplicant
```


##### `wpa_supplicant.conf`
```
# /etc/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
ap_scan=0

network={
    key_mgmt=IEEE8021X
    eap=MD5
    identity="idclientb1"
    password="pwclientb1"
}
```

The wpa_supplicant.conf file stores the 802.1X authentication settings used by the client device. Through EAPOL, the supplicant provides its credentials to the switch, which acts as the authenticator and forwards the authentication request to the RADIUS server for verification.

### Client-B2

##### `init.sh`
```
#!/bin/sh

ip addr add 192.168.95.2/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.95.1
```

##### `supplicant.sh`
```
wpa_supplicant -B -D wired -i eth0 -c /root/wpa_supplicant.conf -C /run/wpa_supplicant
```


##### `wpa_supplicant.conf`
```
# /etc/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
ap_scan=0

network={
    key_mgmt=IEEE8021X
    eap=MD5
    identity="idclientb2"
    password="pwclientb2"
}
```


## VPN Site 3

VPN Site 3 has one customer edge (**CE3**) and one Radius server, configured to serve Access Requests from Site 3 supplicants (**client-B1**, **client-B2**).

### CE3

###### `init.sh`

```
#!/bin/sh
set -eu

# WAN interface:
ip link set eth0 up
ip addr replace 10.1.3.2/30 dev eth0

# Default route:
ip route replace default via 10.1.3.1

# LAN interface:
ip link set eth1 up
ip addr replace 192.168.3.1/24 dev eth1

# IPv4 forwarding:
sysctl -w net.ipv4.ip_forward=1 >/dev/null
```


###### `pki_gen.sh`
```
#!/bin/sh
set -eu

CA_CN="${CA_CN:-NSD_project}"
EASYRSA_DIR="/usr/share/easy-rsa"
OPENVPN_BASE="/root/openvpn"
SERVER_NAME="CE3"
CLIENTS="CE1 CE2"

PKI_DIR="${EASYRSA_DIR}/pki"

cd "${EASYRSA_DIR}"

pki_complete() {
  [ -d "${PKI_DIR}" ] \
    && [ -f "${PKI_DIR}/ca.crt" ] \
    && [ -f "${PKI_DIR}/issued/${SERVER_NAME}.crt" ] \
    && [ -f "${PKI_DIR}/private/${SERVER_NAME}.key" ]
}

if pki_complete; then
  echo "PKI already present, skipping generation"
else
  export EASYRSA_BATCH=1
  export EASYRSA_REQ_CN="${CA_CN}"

  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa build-server-full "${SERVER_NAME}" nopass

  for c in ${CLIENTS}; do
    ./easyrsa build-client-full "${c}" nopass
  done

  ./easyrsa gen-dh
fi

# Directory di destinazione
mkdir -p \
  "${OPENVPN_BASE}/keys" \
  "${OPENVPN_BASE}/export/CE1" \
  "${OPENVPN_BASE}/export/CE2"

# Server (CE3)
cp -f "${PKI_DIR}/ca.crt"              "${OPENVPN_BASE}/keys/ca.crt"
cp -f "${PKI_DIR}/dh.pem"              "${OPENVPN_BASE}/keys/dh.pem"
cp -f "${PKI_DIR}/issued/${SERVER_NAME}.crt"  "${OPENVPN_BASE}/keys/${SERVER_NAME}.crt"
cp -f "${PKI_DIR}/private/${SERVER_NAME}.key" "${OPENVPN_BASE}/keys/${SERVER_NAME}.key"

# Export client
for c in ${CLIENTS}; do
  mkdir -p "${OPENVPN_BASE}/export/${c}"
  cp -f "${PKI_DIR}/ca.crt"             "${OPENVPN_BASE}/export/${c}/ca.crt"
  cp -f "${PKI_DIR}/issued/${c}.crt"    "${OPENVPN_BASE}/export/${c}/${c}.crt"
  cp -f "${PKI_DIR}/private/${c}.key"   "${OPENVPN_BASE}/export/${c}/${c}.key"
done

echo "PKI ready. Exports in ${OPENVPN_BASE}/export/"
```

This script controls the creation and management of the OpenVPN Public Key Infrastructure. It first checks whether the PKI and the certificates required for the CE3 server already exist, avoiding unnecessary regeneration when they are already available. If the PKI is missing, the script initializes Easy-RSA, creates the Certificate Authority named NSD_project, generates the certificate and private key for the OpenVPN server CE3, creates client certificates and private keys for CE1 and CE2, and generates the Diffie-Hellman parameters used by the server.

Finally, it creates the required destination directories, copies the CA certificate, Diffie-Hellman parameters, server certificate, and server private key into the CE3 key directory, and exports the CA certificate together with the corresponding certificate and private key for each client, CE1 and CE2, into separate directories ready to be transferred to the respective VPN spokes.



###### `server.conf`
```
port 1194
proto udp
dev tun

ca   /root/openvpn/keys/ca.crt
cert /root/openvpn/keys/CE3.crt
key  /root/openvpn/keys/CE3.key
dh   /root/openvpn/keys/dh.pem

server 192.168.100.0 255.255.255.0

push "route 192.168.1.0 255.255.255.0"    # Site 1
push "route 192.168.2.0 255.255.255.0"    # Site 2
push "route 192.168.32.0 255.255.255.0"   # VLAN 32
push "route 192.168.95.0 255.255.255.0"   # VLAN 95
push "route 192.168.3.0 255.255.255.0"    # Site 3

client-to-client

client-config-dir /root/openvpn/ccd

route 192.168.1.0 255.255.255.0
route 192.168.2.0 255.255.255.0
route 192.168.32.0 255.255.255.0
route 192.168.95.0 255.255.255.0

keepalive 10 120
persist-key
persist-tun
verb 3
cipher AES-256-GCM
```
This section explains how the OpenVPN hub is configured. Known the configurations of both the spokes, CE1 and CE2, CE3 receives VPN connections from them, provides them with addresses from the VPN tunnel network, and distributes the appropriate routing information so that the LANs located behind each client can communicate through the tunnel.

CE3 uses the `client-config-dir` directive to load a specific configuration for every connected VPN client:

```conf
client-config-dir /root/openvpn/ccd
```

When a client connects, OpenVPN reads the Common Name (CN) from its certificate and automatically loads the matching file from:

```text
/root/openvpn/ccd/<CN>
```

This mechanism allows CE3 to associate each remote LAN with the correct VPN spoke.

The `route` directives configured in `server.conf` add the remote networks to CE3’s routing table. Instead, the `iroute` rules inside the CCD files tell OpenVPN which client tunnel must receive traffic for each network. Therefore, `route` makes CE3 aware of a remote subnet, while `iroute` associates that subnet with CE1 or CE2.

**CE1**

The file `/root/openvpn/ccd/CE1` contains:

```conf
iroute 192.168.1.0 255.255.255.0
```

This rule tells CE3 that the network `192.168.1.0/24` is located behind CE1, so traffic addressed to this subnet must be forwarded through the CE1 VPN tunnel.

**CE2**

The file `/root/openvpn/ccd/CE2` contains:

```conf
iroute 192.168.2.0 255.255.255.0
iroute 192.168.32.0 255.255.255.0
iroute 192.168.95.0 255.255.255.0
```

These rules associate the networks `192.168.2.0/24`, `192.168.32.0/24`, and `192.168.95.0/24` with CE2. As a result, CE3 forwards all traffic destined for these LANs through the VPN tunnel established with CE2.

### RADIUS

###### `init.sh`
```
#!/bin/sh
set -eu

# Network configuration
ip addr add 192.168.3.2/24 dev eth0 2>/dev/null || true
ip link set eth0 up
ip route add default via 192.168.3.1 2>/dev/null || true

# FreeRADIUS configuration
RDIR="/etc/freeradius/3.0"
SRC_DIR="/root/freeradius"

mkdir -p "$RDIR/mods-config/files"

cp "$SRC_DIR/clients.conf" "$RDIR/clients.conf"
cp "$SRC_DIR/users.conf" "$RDIR/mods-config/files/authorize"
cp "$SRC_DIR/users.conf" "$RDIR/users.conf"

# Restart FreeRADIUS
pkill -x freeradius 2>/dev/null || true
pkill -x radiusd 2>/dev/null || true

LOGFILE="/root/radius.log"

if command -v freeradius >/dev/null 2>&1; then
  nohup freeradius -f -l "$LOGFILE" >/dev/null 2>&1 &
else
  nohup radiusd -f -l "$LOGFILE" >/dev/null 2>&1 &
fi

sleep 1

echo "RADIUS listening on UDP port 1812:"
ss -lunp | grep ':1812' || echo "WARNING: nothing is listening yet"

echo "Last FreeRADIUS log lines:"
tail -n 30 "$LOGFILE" 2>/dev/null || true
```

###### `clients.conf`
```
client ebpf_switch {
    ipaddr = 192.168.2.2
    secret = donttellit
    shortname = ebpf
}
```

The `clients.conf` file defines the RADIUS clients that are authorized to send authentication requests to the FreeRADIUS server.
The `ipaddr` field identifies the eBPF switch by its IP address. The `secret` field specifies the shared secret used to authenticate and protect communication between `hostapd` on the eBPF switch and the FreeRADIUS server. The `shortname` field provides a shorter, human-readable name that can be used in logs and diagnostic output. Only a device matching the configured IP address and shared secret is allowed to submit RADIUS Access-Request messages to the server.



###### `users.conf`
```
idclientb1	Cleartext-Password := "pwclientb1"
			Service-Type = Framed-User,
			Tunnel-Type = 13,
			Tunnel-Medium-Type = 6,
			Tunnel-Private-Group-ID = 32
		
idclientb2	Cleartext-Password := "pwclientb2"
			Service-Type = Framed-User,
			Tunnel-Type = 13,
			Tunnel-Medium-Type = 6,
			Tunnel-Private-Group-ID = 95
```

The `users.conf` file defines the users accepted by FreeRADIUS, their authentication credentials, and the authorization attributes returned after successful authentication.

`idclientb1` and `idclientb2` are the identities used by the two 802.1X clients. The `Cleartext-Password` attribute specifies the password that FreeRADIUS checks during authentication. If authentication succeeds, FreeRADIUS returns an `Access-Accept` response.

