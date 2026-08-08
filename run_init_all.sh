#!/usr/bin/env bash
set -eu

VM_HOST="gns3@192.168.56.101"
TARGETS=(R101 R102 R103 CE1 CE2 CE3 client-A1 client-B1 client-B2 RADIUS ebpf-1)

log() {
  printf '%s\n' "$*" >&2
}

get_container_id_by_hostname() {
  local host="$1"
  ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do
      name=\$(sudo docker exec \"\$id\" sh -lc 'hostname' 2>/dev/null || true)
      if [ \"\$name\" = \"$host\" ]; then
        echo \"\$id\"
        break
      fi
    done"
}

run_init_in_container() {
  local cid="$1"
  ssh "$VM_HOST" "sudo docker exec \"$cid\" sh -lc '
      : > /root/init.log
      sh /root/init.sh >> /root/init.log 2>&1 || exit 1
      echo OK
    '"
}

print_container_network_state() {
  local cid="$1"
  ssh "$VM_HOST" "sudo docker exec \"$cid\" sh -lc '
      hostname
      ip -4 -br a | sed -n \"1,10p\"
    '"
}

log "==> Running init on ${#TARGETS[@]} nodes via $VM_HOST"

for host in "${TARGETS[@]}"; do
  echo
  log "---- $host ----"

  cid="$(get_container_id_by_hostname "$host")"

  if [ -z "$cid" ]; then
    log "  $host: container not found"
    continue
  fi

  run_init_in_container "$cid"
  print_container_network_state "$cid"
done

echo
log "bootstrap completed"