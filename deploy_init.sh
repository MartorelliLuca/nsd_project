#!/usr/bin/env bash
set -eu

VM_HOST="gns3@192.168.56.101"
BASE_DIR="persistent"

TARGETS=(R101 R102 R103 CE1 CE2 CE3 client-A1 client-B1 client-B2 RADIUS ebpf-1)

log() {
  printf '%s\n' "$*" >&2
}

node_src_dir() {
  local host="$1"

  if [ "$host" = "ebpf-1" ]; then
    printf '%s\n' "${BASE_DIR}/ebpf"
  else
    printf '%s\n' "${BASE_DIR}/${host}"
  fi
}

find_container_id() {
  local host="$1"

  ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do
      name=\$(sudo docker exec \"\$id\" sh -lc 'hostname' 2>/dev/null || true)
      if [ \"\$name\" = \"$host\" ]; then
        echo \"\$id\"
        break
      fi
    done"
}

deploy_to_container() {
  local cid="$1"
  local src_dir="$2"

  tar -C "$src_dir" -cf - . \
    | ssh "$VM_HOST" "sudo docker exec -i \"$cid\" sh -lc '
         tar -C /root -xf - &&
         chmod +x /root/init.sh || true
       '"
}

for host in "${TARGETS[@]}"; do
  src_dir="$(node_src_dir "$host")"

  log ""
  log "==> Deploy on $host"

  if [ ! -d "$src_dir" ]; then
    log "   WARN: directory not found: $src_dir (skipping)"
    continue
  fi

  if [ ! -f "$src_dir/init.sh" ]; then
    log "   WARN: missing $src_dir/init.sh (skipping)"
    continue
  fi

  cid="$(find_container_id "$host")"

  if [ -z "$cid" ]; then
    log "   No container found for hostname $host"
    continue
  fi

  deploy_to_container "$cid" "$src_dir"
  log "   OK (container id: $cid)"
done

log ""
log "Deploy completed."