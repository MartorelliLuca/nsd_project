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