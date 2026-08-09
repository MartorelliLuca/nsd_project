#!/usr/bin/env bash
set -eu

VM_HOST="gns3@192.168.56.101"

NODES=(R101 R102 R103 CE1 CE2 CE3 client-A1 client-B1 client-B2 RADIUS ebpf-1)

log() {
  printf '%s\n' "$*" >&2
}

find_container_by_hostname() {
  local host="$1"

  ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do
      name=\$(sudo docker exec \"\$id\" sh -lc 'hostname' 2>/dev/null || true)
      if [ \"\$name\" = \"$host\" ]; then
        echo \"\$id\"
        break
      fi
    done"
}

run_init_script() {
  local cid="$1"

  ssh "$VM_HOST" "sudo docker exec \"$cid\" sh -lc '
      : > /root/init.log
      sh /root/init.sh >> /root/init.log 2>&1 || exit 1
      echo OK
    '"
}

show_ipv4_state() {
  local cid="$1"

  ssh "$VM_HOST" "sudo docker exec \"$cid\" sh -lc '
      hostname
      ip -4 -br a | sed -n \"1,10p\"
    '"
}

bootstrap_pki_if_missing() {
  local ce1_name="CE1"
  local ce2_name="CE2"
  local ce3_name="CE3"

  local ce1_cid ce2_cid ce3_cid

  ce1_cid="$(find_container_by_hostname "$ce1_name")"
  ce2_cid="$(find_container_by_hostname "$ce2_name")"
  ce3_cid="$(find_container_by_hostname "$ce3_name")"

  if [ -z "$ce1_cid" ] || [ -z "$ce2_cid" ] || [ -z "$ce3_cid" ]; then
    log "  ERROR: missing CE1/CE2/CE3 container"
    return 1
  fi

  # 1) Se la PKI su CE3 manca, la generiamo
  if ssh "$VM_HOST" "sudo docker exec \"$ce3_cid\" sh -lc '
        test -f /root/openvpn/keys/CE3.key &&
        test -f /root/openvpn/keys/ca.crt &&
        test -f /root/openvpn/keys/dh.pem
      '"; then
    log "  PKI already present on CE3"
  else
    log "  PKI missing -> generating on CE3"
    ssh "$VM_HOST" "sudo docker exec \"$ce3_cid\" sh -lc '
      chmod +x /root/pki_gen.sh
      /root/pki_gen.sh
    '"
  fi

  # 2) In ogni caso, copiamo i bundle CE1/CE2 verso i rispettivi nodi
  log "  Copy CE1 bundle (CE3 export -> CE1 keys)"
  ssh "$VM_HOST" "sudo docker exec \"$ce3_cid\" sh -lc '
        tar -C /root/openvpn/export/CE1 -cf - .
      ' " \
  | ssh "$VM_HOST" "sudo docker exec -i \"$ce1_cid\" sh -lc '
        mkdir -p /root/openvpn/keys
        tar -C /root/openvpn/keys -xf -
      '"

  log "  Copy CE2 bundle (CE3 export -> CE2 keys)"
  ssh "$VM_HOST" "sudo docker exec \"$ce3_cid\" sh -lc '
        tar -C /root/openvpn/export/CE2 -cf - .
      ' " \
  | ssh "$VM_HOST" "sudo docker exec -i \"$ce2_cid\" sh -lc '
        mkdir -p /root/openvpn/keys
        tar -C /root/openvpn/keys -xf -
      '"
}

log "==> Running init.sh on ${#NODES[@]} nodes via $VM_HOST"

for host in "${NODES[@]}"; do
  log ""
  log "---- $host ----"

  cid="$(find_container_by_hostname "$host")"

  if [ -z "$cid" ]; then
    log "  $host: container not found"
    continue
  fi

  run_init_script "$cid"
  show_ipv4_state "$cid"
done

log ""
log "==> OpenVPN PKI bootstrap (hub-and-spoke), only if missing"

bootstrap_pki_if_missing

log ""
log "bootstrap completed"