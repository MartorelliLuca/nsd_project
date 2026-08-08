set -euo pipefail

VM_HOST="gns3@192.168.56.101"
NODE_HOSTNAME="ebpf-1"
REMOTE_DST="/workspace/src"

# Find the container ID that has hostname = ebpf-1
CONTAINER_ID="$(ssh "$VM_HOST" "sudo docker ps -q | xargs -r -n1 sudo docker exec -i 2>/dev/null sh -lc 'hostname' | nl -w1 -s' ' >/dev/null" || true)"

# List (id, hostname) and filter
CONTAINER_ID="$(ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do hn=\$(sudo docker exec \$id sh -lc 'hostname' 2>/dev/null || true); [ -n \"\$hn\" ] && echo \"\$id \$hn\"; done | awk '\$2==\"$NODE_HOSTNAME\"{print \$1; exit}'")"

if [[ -z "${CONTAINER_ID}" ]]; then
  echo "I cannot find a container with hostname '$NODE_HOSTNAME' on VM ($VM_HOST)."
  echo "   Check: ssh $VM_HOST \"sudo docker ps\""
  exit 1
fi

# Create/reset the directory in the container
ssh "$VM_HOST" "sudo docker exec $CONTAINER_ID sh -lc 'rm -rf $REMOTE_DST && mkdir -p $REMOTE_DST'"

# Send ./src to the container (under /workspace/src)
tar -C "$(pwd)" -cf - src | ssh "$VM_HOST" "sudo docker exec -i $CONTAINER_ID tar -C /workspace -xf -"

echo "PUSH ok: ./src -> container($NODE_HOSTNAME):$REMOTE_DST"