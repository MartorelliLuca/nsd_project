set -euo pipefail

VM_HOST="gns3@192.168.56.101"
NODE_HOSTNAME="ebpf-1"
REMOTE_SRC="/workspace/src"

CONTAINER_ID="$(ssh "$VM_HOST" "sudo docker ps -q | while read -r id; do hn=\$(sudo docker exec \$id sh -lc 'hostname' 2>/dev/null || true); [ -n \"\$hn\" ] && echo \"\$id \$hn\"; done | awk '\$2==\"$NODE_HOSTNAME\"{print \$1; exit}'")"


if [[ -z "${CONTAINER_ID}" ]]; then
  echo "I cannot find a container with hostname '$NODE_HOSTNAME' on VM ($VM_HOST)."
  exit 1
fi

rm -rf src
mkdir -p src

ssh "$VM_HOST" "sudo docker exec $CONTAINER_ID tar -C $REMOTE_SRC -cf - ." | tar -C src -xf -

echo "PULL ok: container($NODE_HOSTNAME):$REMOTE_SRC -> ./src"