#!/usr/bin/env bash
set -eu

VM_HOST="gns3@192.168.56.101"

echo
echo "==> OpenVPN PKI + start (hub CE3, spokes CE1/CE2)"

# Trova l'ID del container per hostname
get_cid() {
  local hn="$1"

  ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do
    name=\$(sudo docker exec \"\$id\" hostname 2>/dev/null || true)
    if [ \"\$name\" = \"$hn\" ]; then
      echo \"\$id\"
      break
    fi
  done"
}

CE1_CID="$(get_cid CE1)"
CE2_CID="$(get_cid CE2)"
CE3_CID="$(get_cid CE3)"

if [ -z "$CE1_CID" ] || [ -z "$CE2_CID" ] || [ -z "$CE3_CID" ]; then
  echo "  ERROR: missing CE1/CE2/CE3 container"
  exit 1
fi

# Controllo presenza file chiave/cert
has_file() {
  local cid="$1"
  local path="$2"
  ssh "$VM_HOST" "sudo docker exec $cid sh -lc 'test -f \"$path\"'"
}

CE3_OK=0
CE1_OK=0
CE2_OK=0

if has_file "$CE3_CID" "/root/openvpn/keys/ca.crt" \
 && has_file "$CE3_CID" "/root/openvpn/keys/dh.pem" \
 && has_file "$CE3_CID" "/root/openvpn/keys/CE3.crt" \
 && has_file "$CE3_CID" "/root/openvpn/keys/CE3.key"; then
  CE3_OK=1
fi

if has_file "$CE1_CID" "/root/openvpn/keys/ca.crt" \
 && has_file "$CE1_CID" "/root/openvpn/keys/CE1.crt" \
 && has_file "$CE1_CID" "/root/openvpn/keys/CE1.key"; then
  CE1_OK=1
fi

if has_file "$CE2_CID" "/root/openvpn/keys/ca.crt" \
 && has_file "$CE2_CID" "/root/openvpn/keys/CE2.crt" \
 && has_file "$CE2_CID" "/root/openvpn/keys/CE2.key"; then
  CE2_OK=1
fi

# Se manca qualcosa, rigenera PKI su CE3 e copia bundle verso CE1/CE2
if [ "$CE3_OK" -ne 1 ] || [ "$CE1_OK" -ne 1 ] || [ "$CE2_OK" -ne 1 ]; then
  echo "  Keys missing somewhere -> run pki_gen on CE3 and copy files"

  ssh "$VM_HOST" "sudo docker exec $CE3_CID sh -lc '
    chmod +x /root/pki_gen.sh
    /root/pki_gen.sh
  '"

  echo "  Copy CE1 bundle (CE3 export -> CE1 keys)"
  ssh "$VM_HOST" "sudo docker exec $CE3_CID sh -lc '
    tar -C /root/openvpn/export/CE1 -cf - .
  ' " | ssh "$VM_HOST" "sudo docker exec -i $CE1_CID sh -lc '
    mkdir -p /root/openvpn/keys
    tar -C /root/openvpn/keys -xf -
  '"

  echo "  Copy CE2 bundle (CE3 export -> CE2 keys)"
  ssh "$VM_HOST" "sudo docker exec $CE3_CID sh -lc '
    tar -C /root/openvpn/export/CE2 -cf - .
  ' " | ssh "$VM_HOST" "sudo docker exec -i $CE2_CID sh -lc '
    mkdir -p /root/openvpn/keys
    tar -C /root/openvpn/keys -xf -
  '"
else
  echo "  All keys already present -> skip PKI/export"
fi

# Funzione per avviare OpenVPN se non è già in esecuzione
start_ovpn() {
  local cid="$1"
  local conf="$2"
  local name="$3"

  # se openvpn è già in esecuzione, non rilancio
  if ssh "$VM_HOST" "sudo docker exec $cid sh -lc 'pgrep -x openvpn >/dev/null 2>&1'"; then
    echo "  $name: openvpn already running"
    return 0
  fi

  ssh "$VM_HOST" "sudo docker exec $cid sh -lc '
    if [ ! -f \"$conf\" ]; then
      echo \"missing $conf\"
      exit 1
    fi
    openvpn --config \"$conf\" --daemon --log /root/openvpn/openvpn.log
  '"

  echo "  $name: openvpn started"
}

# Avvia server e client
start_ovpn "$CE3_CID" "/root/openvpn/server.conf" "CE3 (hub)"
start_ovpn "$CE1_CID" "/root/openvpn/client-CE1.conf" "CE1 (spoke)"
start_ovpn "$CE2_CID" "/root/openvpn/client-CE2.conf" "CE2 (spoke)"

echo "==> OpenVPN bootstrap completed"