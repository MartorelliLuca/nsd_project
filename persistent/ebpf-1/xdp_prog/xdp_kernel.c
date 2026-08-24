// SPDX-License-Identifier: GPL-2.0
#include <linux/types.h>
#include <linux/bpf.h>
#include <stdbool.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

#include "xdp_common.h"

#define RADIUS_CODE_ACCESS_ACCEPT 2
#define RADIUS_ATTR_USER_NAME 1
#define RADIUS_ATTR_TUNNEL_PGID 81
#define RADIUS_UDP_PORT 1812
#define RADIUS_MAX_ATTRS 64

#define IDENTITY_TTL_NS (15ULL * 1000000000ULL)

struct radius_packet_hdr {
	__u8 code;
	__u8 id;
	__u16 len;
	__u8 auth[16];
} __attribute__((packed));

struct radius_tlv_hdr {
	__u8 type;
	__u8 len;
} __attribute__((packed));

/* ------------------------------------------------------------------------- */
/* Helper functions                                                          */
/* ------------------------------------------------------------------------- */

/* Extract UDP header from Ethernet+IPv4 frame. */
static __always_inline struct udphdr *extract_udp4(void *data, void *end)
{
	struct ethhdr *eth = data;
	if (!range_within(eth, end, sizeof(*eth)))
		return NULL;

	if (eth->h_proto != bpf_htons(ETH_P_IP))
		return NULL;

	struct iphdr *ip = (void *)(eth + 1);
	if (!range_within(ip, end, sizeof(*ip)))
		return NULL;

	if (ip->protocol != IPPROTO_UDP)
		return NULL;

	/* IP header length sanity (ihl in 32-bit words). */
	int ihl = ip->ihl * 4;
	if (ihl < (int)sizeof(*ip) || ihl > 60)
		return NULL;

	struct udphdr *udp = (void *)((char *)ip + ihl);
	if (!range_within(udp, end, sizeof(*udp)))
		return NULL;

	return udp;
}

/* Parse decimal VLAN from ASCII attribute value */
static __always_inline bool parse_vlan_ascii(const char *src, const char *end,
					     __u16 *out_vlan)
{
	__u32 acc = 0;
	bool got_digit = false;

	/* Read up to 5 ASCII digits (4094 max). */
	for (int i = 0; i < 5; i++) {
		const char *p = src + i;

		/* Stop if we cannot safely read one byte. */
		if (!range_within(p, end, 1)) {
			break;
		}

		char c = *p;

		/* Stop on first non-digit. */
		if (c < '0' || c > '9') {
			break;
		}

		got_digit = true;

		/* Convert digit and accumulate. */
		__u32 digit = (__u32)(c - '0');
		acc = acc * 10 + digit;

		/* Early stop on overflow beyond allowed VLAN range. */
		if (acc > 4094) {
			break;
		}
	}

	/* Must have seen at least one digit and be in [1..4094]. */
	if (!got_digit) {
		return false;
	}

	if (acc < 1 || acc > 4094) {
		return false;
	}

	*out_vlan = (__u16)acc;
	return true;
}

/*
 * Scan RADIUS attributes and extract:
 *  - User-Name -> supplicant_id_key
 *  - Tunnel-Private-Group-ID -> VLAN
 *
 * Returns true only if both values were found.
 */
static __always_inline bool radius_pull_uname_vlan(
	void *end, struct radius_packet_hdr *radius,
	struct supplicant_id_key *out_id, int *out_id_len, __u16 *out_vlan)
{
	struct supplicant_id_key id_key = {};
	int id_len = 0;
	__u16 vlan = 0;

	struct radius_tlv_hdr *attr = (void *)(radius + 1);

	for (int i = 0; i < RADIUS_MAX_ATTRS; i++) {
		if (!range_within(attr, end, sizeof(*attr)))
			break;

		/* TLV len includes (type,len). Must be >= header. */
		if (attr->len < sizeof(*attr))
			break;

		__u8 type = attr->type;
		__u8 val_len = attr->len - (int)sizeof(*attr);
		char *val = (void *)(attr + 1);

		if (type == RADIUS_ATTR_USER_NAME) {
			/* Bound length to ID_MAX-1 (+1 for '\0') */
			id_len = val_len >= ID_MAX ? ID_MAX - 1 : val_len;
			bpf_core_read_str(id_key.identity, id_len + 1, val);

		} else if (type == RADIUS_ATTR_TUNNEL_PGID) {
			if (!parse_vlan_ascii(val, end, &vlan))
				break;
		}

		if (id_len && vlan)
			break;

		/* next attribute */
		attr = (void *)((char *)attr + (int)sizeof(*attr) + val_len);
	}

	if (!id_len || !vlan)
		return false;

	*out_id = id_key;
	*out_id_len = id_len;
	*out_vlan = vlan;
	return true;
}

/*
 * Consume identity_map[identity] and update auth_map[mac] with VLAN/state=AUTH.
 * - Verifies TTL
 * - Writes decision for userspace enforcer
 * - Deletes consumed identity entry
 */
static __always_inline void radius_commit_accept(struct supplicant_id_key *id,
						 __u16 vlan)
{
	struct supplicant_claim *claim = bpf_map_lookup_elem(&identity_map, id);
	if (!claim)
		return;

	__u64 now = bpf_ktime_get_ns();
	if (now - claim->claimed_at_ns > IDENTITY_TTL_NS) {
		/* stale identity claim; ignore */
		return;
	}

	struct station_auth_decision decision = {};
	decision.assigned_vlan = vlan;
	decision.auth_state = 1;      /* Access-Accept */
	decision.enforced_flag = 0;
	decision.ingress_port_idx = claim->ingress_port_idx;
	decision.last_update_ns = now;

	bpf_map_update_elem(&auth_map, claim->sta_mac, &decision, BPF_ANY);

	/* Identity is one-shot: remove after successful commit. */
	bpf_map_delete_elem(&identity_map, id);
}

/* ------------------------------------------------------------------------- */
/* XDP entrypoint                                                             */
/* ------------------------------------------------------------------------- */

SEC("xdp")
int xdp_radius_parser(struct xdp_md *ctx)
{
    void *packet_start = (void *)(long)ctx->data;
    void *packet_end = (void *)(long)ctx->data_end;

    struct udphdr *udp_hdr = extract_udp4(packet_start, packet_end);
    if (udp_hdr == NULL || udp_hdr->source != bpf_htons(RADIUS_UDP_PORT))
        return XDP_PASS;

    struct radius_packet_hdr *radius_hdr = (void *)(udp_hdr + 1);
    if (!range_within(radius_hdr, packet_end, sizeof(*radius_hdr)))
        return XDP_PASS;

    if (radius_hdr->code != RADIUS_CODE_ACCESS_ACCEPT)
        return XDP_PASS;

    struct supplicant_id_key username = {};
    __u16 assigned_vlan = 0;
    int username_length = 0;

    bool valid_accept = radius_pull_uname_vlan(
        packet_end,
        radius_hdr,
        &username,
        &username_length,
        &assigned_vlan
    );

    if (valid_accept)
        radius_commit_accept(&username, assigned_vlan);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";