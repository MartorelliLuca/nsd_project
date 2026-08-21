/* SPDX-License-Identifier: GPL-2.0 */
#include <linux/bpf.h>
#include <linux/in.h>
#include <stdbool.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#include "../common/parsing_helpers.h"

/* RADIUS structure headers */
struct radius_hdr {
    __u8  code;
    __u8  identifier;
    __u16 length;              /* includes header+attrs */
    __u8  authenticator[16];
} __attribute__((packed));

struct radius_attr {
    __u8 type;
    __u8 length;               /* includes type+length+value */
} __attribute__((packed));

/* Supplicant key structure for user identity */
struct identity_key {
    char id[64];
} __attribute__((packed));

struct identity_val {
    __u8  mac[6];
    __u32 ifindex;
    __u64 ts_ns;               /* can exist even if you don't check TTL */
} __attribute__((packed));

struct mac_key {
    __u8 mac[6];
} __attribute__((packed));

struct auth_data {
    __u32 vlan_id;   /* Assigned VLAN ID */
    __u8  auth;      /* 1 = authenticated */
    __u8  enforced;  /* 1 = enforcement applied */
    __u32 ifindex;   /* where to enforce (optional but handy) */
} __attribute__((packed));

#define RADIUS_PORT 1812
#define RADIUS_CODE_ACCESS_ACCEPT 2
#define RADIUS_ATTR_USER_NAME 1
#define RADIUS_ATTR_TUNNEL_PRIVATE_GROUP_ID 81
#define RADIUS_MAX_ATTRIBUTES_NUM 64

/* identity -> {mac, ifindex, ts} learned elsewhere (EAP/EAPOL program) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct identity_key);
    __type(value, struct identity_val);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} identity_map SEC(".maps");

/* final auth decision keyed by MAC (what enforcement should use) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct mac_key);
    __type(value, struct auth_data);
    __uint(pinning, LIBBPF_PIN_BY_NAME);
} auth_map SEC(".maps");

/* Parse decimal VLAN (1..4094) */
static __always_inline bool parse_vlan_decimal(const char *p, const char *end, __u16 *out)
{
    __u32 v = 0;
    bool seen = false;

#pragma unroll
    for (int i = 0; i < 5; i++) {
        if ((void *)(p + i + 1) > (void *)end)
            break;

        char c = p[i];
        if (c < '0' || c > '9')
            break;

        seen = true;
        v = v * 10 + (c - '0');
        if (v > 4094)
            break;
    }

    if (!seen || v < 1 || v > 4094)
        return false;

    *out = (__u16)v;
    return true;
}

/* Copy User-Name into key.id safely from packet data */
static __always_inline int copy_username(struct identity_key *key, const char *src, int len, void *data_end)
{
    int n = len;
    if (n > 63) n = 63;
    if (n < 0)  n = 0;

#pragma unroll
    for (int i = 0; i < 64; i++) {
        if (i >= n) {
            key->id[i] = '\0';
            break;
        }
        if ((void *)(src + i + 1) > data_end) {
            key->id[i] = '\0';
            break;
        }
        key->id[i] = src[i];
    }
    key->id[63] = '\0';
    return n;
}

SEC("xdp")
int xdp_radius_parser(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    struct hdr_cursor nh = { .pos = data };
    struct ethhdr *eth;
    struct iphdr  *iph;
    struct udphdr *udph;

    if (parse_ethhdr(&nh, data_end, &eth) != bpf_htons(ETH_P_IP))
        return XDP_PASS;
    if (parse_iphdr(&nh, data_end, &iph) != IPPROTO_UDP)
        return XDP_PASS;
    if (parse_udphdr(&nh, data_end, &udph) < 0)
        return XDP_PASS;

    /* Access-Accept is from RADIUS server -> NAS, so source port 1812 */
    if (udph->source != bpf_htons(RADIUS_PORT))
        return XDP_PASS;

    struct radius_hdr *radius = nh.pos;
    if ((void *)(radius + 1) > data_end)
        return XDP_PASS;

    if (radius->code != RADIUS_CODE_ACCESS_ACCEPT)
        return XDP_PASS;

    /* Optional: respect radius->length to bound parsing */
    __u16 rlen = bpf_ntohs(radius->length);
    void *radius_end = (void *)((char *)radius + rlen);
    if (radius_end > data_end)
        radius_end = data_end;

    struct identity_key user_key = {};
    int  user_len = 0;
    __u16 vlan_id = 0;
    bool have_user = false, have_vlan = false;

    struct radius_attr *attr = (void *)(radius + 1);

#pragma unroll
    for (int i = 0; i < RADIUS_MAX_ATTRIBUTES_NUM; i++) {
        if ((void *)(attr + 1) > radius_end)
            break;

        /* attr->length includes the 2-byte header */
        __u8 alen_total = attr->length;
        if (alen_total < sizeof(*attr))
            break;

        void *next = (void *)((char *)attr + alen_total);
        if (next > radius_end)
            break;

        __u8 at = attr->type;
        int  al = (int)alen_total - (int)sizeof(*attr);
        char *av = (char *)(attr + 1);

        if (at == RADIUS_ATTR_USER_NAME) {
            user_len = copy_username(&user_key, av, al, data_end);
            have_user = (user_len > 0);
        } else if (at == RADIUS_ATTR_TUNNEL_PRIVATE_GROUP_ID) {
            __u16 v;
            if (parse_vlan_decimal(av, (char *)radius_end, &v)) {
                vlan_id = v;
                have_vlan = true;
            } else {
                /* malformed VLAN attribute -> stop */
                break;
            }
        }

        if (have_user && have_vlan)
            break;

        attr = next;
    }

    if (!have_user || !have_vlan)
        return XDP_PASS;

    /* Join: identity -> MAC */
    struct identity_val *iv = bpf_map_lookup_elem(&identity_map, &user_key);
    if (!iv)
        return XDP_PASS;

    struct mac_key mk = {};
    __builtin_memcpy(mk.mac, iv->mac, 6);

    struct auth_data out = {};
    out.vlan_id  = vlan_id;
    out.auth     = 1;
    out.enforced = 0;
    out.ifindex  = iv->ifindex;

    bpf_map_update_elem(&auth_map, &mk, &out, BPF_ANY);

    /* optional cleanup (single-use join) */
    bpf_map_delete_elem(&identity_map, &user_key);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";