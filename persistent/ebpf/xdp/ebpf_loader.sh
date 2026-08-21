#!/bin/sh
set -eu

# Compila loader e programmi eBPF/XDP.
make

# Directory per oggetti eBPF pinning.
# Monta bpffs solo se non è già montato.
if ! mountpoint -q /sys/fs/bpf; then
    mount -t bpf bpf /sys/fs/bpf
fi

# Directory debug/tracing usata per leggere bpf_printk().
# Monta debugfs solo se non è già montato.
if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs none /sys/kernel/debug
fi

# Collega il parser XDP alla trunk verso CE2/Site3.
# Qui transitano le RADIUS Access-Accept/Access-Reject dirette verso hostapd.
./xdp_loader \
    --dev eth0 \
    --filename xdp_prog_kern.o \
    --progname xdp_radius_parser

# Collega le ACL XDP alle porte access dei client.
# Applica il filtering per VLAN.
#
# ./xdp_loader \
#     --dev eth1 \
#     --filename xdp_prog_kern.o \
#     --progname xdp_enforce_vlan32
#
# ./xdp_loader \
#     --dev eth2 \
#     --filename xdp_prog_kern.o \
#     --progname xdp_enforce_vlan95

echo "[ebpf-1] Programmi XDP collegati correttamente."
echo "[ebpf-1] Debug: cat /sys/kernel/debug/tracing/trace_pipe"