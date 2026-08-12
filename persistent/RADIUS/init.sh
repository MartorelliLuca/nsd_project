#!/bin/sh
set -eu

CLIENT_IP="192.168.3.2/24"
IF_DEV="eth0"
GW_IP="192.168.3.1"   # CE3

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

add_ip "$CLIENT_IP" "$IF_DEV"
bring_up "$IF_DEV"
set_default_route "$GW_IP"

# ---- FreeRADIUS ----

RDIR="/etc/freeradius/3.0"
SRC_DIR="/root/freeradius"

mkdir -p "$RDIR/mods-config/files"

CLIENTS_SRC="$SRC_DIR/clients.conf"
USERS_SRC="$SRC_DIR/users.conf"

if [ ! -f "$CLIENTS_SRC" ]; then
  echo "ERROR: $CLIENTS_SRC missing"
  exit 1
fi

if [ ! -f "$USERS_SRC" ]; then
  echo "ERROR: $USERS_SRC missing"
  exit 1
fi

# Install clients.conf and users.conf
cp "$CLIENTS_SRC" "$RDIR/clients.conf"
cp "$USERS_SRC"   "$RDIR/mods-config/files/authorize"

# Install users.conf
cp "$USERS_SRC" "$RDIR/users.conf"

# ---- Start (or restart) FreeRADIUS ----

pkill -x freeradius >/dev/null 2>&1 || true
pkill -x radiusd    >/dev/null 2>&1 || true

LOGFILE="/root/radius.log"

if command -v freeradius >/dev/null 2>&1; then
  nohup freeradius -f -l "$LOGFILE" >/dev/null 2>&1 &
else
  nohup radiusd   -f -l "$LOGFILE" >/dev/null 2>&1 &
fi

# ---- Status output ----
sleep 1

echo "RADIUS: listening sockets (UDP 1812):"
ss -lunp | grep -E ':1812\b' || echo "WARN: nothing listening on 1812/udp yet"

echo "RADIUS: last log lines:"
tail -n 30 "$LOGFILE" 2>/dev/null || true