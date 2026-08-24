#!/usr/bin/env bash
set -euo pipefail

# GNS3 VM che ospita i container Docker dei nodi.
VM_HOST="gns3@192.168.56.101"

# Directory locale contenente la configurazione persistente.
PERSISTENT_DIR="${1:-./persistent}"

# Nodo target e percorsi sorgente/destinazione.
NODE_NAME="ebpf-1"
XDP_SOURCE_DIR="$PERSISTENT_DIR/$NODE_NAME/xdp_prog"
XDP_DEST_DIR="/workspace/xdp-tutorial/xdp_prog"


log() {
    printf '%s\n' "$*" >&2
}


# Cerca l'ID del container Docker il cui hostname interno è ebpf-1.
find_container_id() {
    local hostname_to_find="$1"

    ssh "$VM_HOST" "
        sudo docker ps -q | while read -r container_id; do
            container_hostname=\$(sudo docker exec \"\$container_id\" hostname 2>/dev/null || true)

            if [ \"\$container_hostname\" = \"$hostname_to_find\" ]; then
                echo \"\$container_id\"
                break
            fi
        done
    "
}


# Controlla che la directory XDP locale esista.
if [ ! -d "$XDP_SOURCE_DIR" ]; then
    log "ERRORE: directory XDP non trovata:"
    log "  $XDP_SOURCE_DIR"
    exit 1
fi


log "==> Deploy del progetto XDP"
log "    Sorgente:    $XDP_SOURCE_DIR"
log "    Destinazione: $XDP_DEST_DIR"
log "    GNS3 VM:     $VM_HOST"


# Trova il container ebpf-1 in esecuzione.
CONTAINER_ID="$(find_container_id "$NODE_NAME")"

if [ -z "$CONTAINER_ID" ]; then
    log "ERRORE: il container '$NODE_NAME' non è stato trovato."
    log "Avvia il nodo ebpf-1 in GNS3 e riesegui questo script."
    exit 1
fi


# Copia i file, non la directory contenitore xdp_prog.
# Il tar stream conserva gerarchia, permessi e file nascosti.
tar -C "$XDP_SOURCE_DIR" -cf - . |
    ssh "$VM_HOST" "
        sudo docker exec -i \"$CONTAINER_ID\" sh -lc '
            mkdir -p \"$XDP_DEST_DIR\"
            tar -C \"$XDP_DEST_DIR\" -xf -
        '
    "


log "==> Copy completata correttamente."
log "    Container: $CONTAINER_ID\n\n"