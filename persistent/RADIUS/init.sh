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