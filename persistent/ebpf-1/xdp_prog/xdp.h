#pragma once

#include <stdbool.h>
#include <linux/types.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>


/* ============================================================
 * COSTANTI
 * ============================================================ */

/* Lunghezza massima della identity 802.1X/EAP. */
#define ID_MAX 64


/* ============================================================
 * STRUTTURE DATI
 * ============================================================ */

/*
 * Stato di autenticazione di una station/client.
 *
 * Questa struttura viene salvata in auth_map.
 * La chiave della mappa è il MAC address del client.
 */
struct station_auth_decision {
    /* VLAN assegnata da RADIUS: Tunnel-Private-Group-ID */
    __u16 assigned_vlan;

    /* Stato: 1 = autenticato, 0 = deautenticato */
    __u8 auth_state;

    /*
     * Stato dell'enforcement:
     * 0 = la policy non è stata ancora applicata
     * 1 = userspace ha applicato la VLAN/policy
     */
    __u8 enforced_flag;

    /* ifindex della porta access da cui è arrivato il client */
    __u32 ingress_port_idx;

    /* Timestamp dell'ultimo aggiornamento, in nanosecondi */
    __u64 last_update_ns;
};


/*
 * Chiave della identity_map.
 *
 * La chiave è la EAP Identity dichiarata dal supplicant/client.
 * Esempio: "client-B1".
 */
struct supplicant_id_key {
    char identity[ID_MAX];
};


/*
 * Informazioni associate a una EAP Identity.
 *
 * Permette di collegare una identity alla station che l'ha
 * presentata recentemente.
 */
struct supplicant_claim {
    /* MAC address del supplicant */
    __u8 sta_mac[ETH_ALEN];

    /* Porta di accesso del client */
    __u32 ingress_port_idx;

    /* Momento in cui il client ha dichiarato questa identity */
    __u64 claimed_at_ns;
};


/* ============================================================
 * MAPPE BPF
 * ============================================================ */

/*
 * identity_map
 *
 * Chiave:
 *     identity EAP, ad esempio "client-B1"
 *
 * Valore:
 *     MAC del client, ifindex della porta e timestamp.
 *
 * Essendo una LRU hash, se supera max_entries, il kernel rimuove
 * automaticamente l'entry meno usata di recente.
 *
 * Il pinning per nome la rende disponibile in:
 *     /sys/fs/bpf/identity_map
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);

    __type(key, struct supplicant_id_key);
    __type(value, struct supplicant_claim);
} identity_map SEC(".maps");


/*
 * auth_map
 *
 * Chiave:
 *     MAC address del supplicant.
 *
 * Valore:
 *     VLAN RADIUS, stato auth/deauth, flag enforcement,
 *     porta di ingresso e timestamp.
 *
 * Il pinning per nome la rende disponibile in:
 *     /sys/fs/bpf/auth_map
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 1024);
    __uint(pinning, LIBBPF_PIN_BY_NAME);

    __type(key, __u8[ETH_ALEN]);
    __type(value, struct station_auth_decision);
} auth_map SEC(".maps");


/* ============================================================
 * HELPER PER PROGRAMMI XDP
 * ============================================================ */

/*
 * Verifica che sia sicuro leggere "size" byte a partire da "ptr".
 *
 * In XDP non puoi leggere dati del pacchetto senza verificare
 * che siano entro data_end: il verifier eBPF lo richiede.
 *
 * Ritorna:
 *   true  -> intervallo valido
 *   false -> tentativo di accesso oltre la fine del pacchetto
 */
static __always_inline bool
range_within(const void *ptr, const void *data_end, __u64 size)
{
    const void *end;

    /* Nessun byte da leggere: sicuro. */
    if (size == 0)
        return true;

    /* Calcola l'indirizzo immediatamente dopo la regione da leggere. */
    end = (const void *)((const char *)ptr + size);

    /* La regione termina oltre il pacchetto. */
    if (end > data_end)
        return false;

    return true;
}


/*
 * Copia un MAC address di ETH_ALEN byte.
 *
 * Il loop è a dimensione costante, quindi è accettabile
 * dal verifier eBPF.
 */
static __always_inline void
mac_copy(__u8 dst[ETH_ALEN], const __u8 src[ETH_ALEN])
{
    for (int i = 0; i < ETH_ALEN; i++)
        dst[i] = src[i];
}


/*
 * Confronta due MAC address.
 *
 * Evita di usare memcmp(), che può creare problemi con il verifier
 * o con la compilazione BPF in alcuni contesti.
 */
static __always_inline bool
mac_equal(const __u8 a[ETH_ALEN], const __u8 b[ETH_ALEN])
{
    for (int i = 0; i < ETH_ALEN; i++) {
        if (a[i] != b[i])
            return false;
    }

    return true;
}