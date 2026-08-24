#!/usr/bin/env bash
set -eu

VM_HOST="gns3@192.168.56.101"
BASE_DIR="persistent"
ROUTERS=(R101 R102 R103)

for hn in "${ROUTERS[@]}"; do
  echo
  echo "---- FRR apply on $hn ----"

  cid="$(ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do
      h=\$(sudo docker exec \$id hostname 2>/dev/null || true)
      [ \"\$h\" = \"$hn\" ] && echo \$id && break
    done")"

  if [[ -z "$cid" ]]; then
    echo "  $hn: container not found"
    continue
  fi

  ssh "$VM_HOST" "sudo docker exec $cid sh -lc 'test -f /root/frr.conf && vtysh -f /root/frr.conf && vtysh -c \"write memory\" && echo OK || (echo \"missing /root/frr.conf\"; exit 1)'"
done