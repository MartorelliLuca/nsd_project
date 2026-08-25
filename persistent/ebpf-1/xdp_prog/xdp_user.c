#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <bpf/bpf.h>

#define MAX_VLAN_MAP 64
#define MAX_IFACE_LEN 16

#define LOG_ERROR 0
#define LOG_WARN  1
#define LOG_INFO  2
#define LOG_DEBUG 3

struct authentication {
    uint16_t vlan_id;
    uint8_t state;
    uint8_t enforced;
    uint32_t ifindex;
    uint64_t last_seen_ns;
} __attribute__((packed));

struct vlan_mapping {
    uint16_t vlan_id;
    char iface[MAX_IFACE_LEN];
};

struct config {
    char bridge[MAX_IFACE_LEN];
    char gateway_iface[MAX_IFACE_LEN];
    char map_path[256];
    uint64_t interval_ms;
    int log_level;

    struct vlan_mapping vlan_map[MAX_VLAN_MAP];
    int vlan_map_count;
};

static struct config cfg;

#define log(level, fmt, ...)                                              \
    do {                                                                  \
        if (cfg.log_level >= (level)) {                                   \
            time_t now = time(NULL);                                      \
            char timestamp[32];                                           \
            strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S",  \
                     localtime(&now));                                    \
            fprintf(stderr, "[%s] " fmt "\n", timestamp, ##__VA_ARGS__); \
        }                                                                 \
    } while (0)

static int execute(char *const args[])
{
    pid_t pid;
    int status;

    log(LOG_DEBUG, "exec: %s", args[0]);

    pid = fork();
    if (pid < 0) {
        log(LOG_ERROR, "fork failed: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        execvp(args[0], args);
        fprintf(stderr, "cannot execute %s: %s\n", args[0], strerror(errno));
        _exit(127);
    }

    if (waitpid(pid, &status, 0) < 0) {
        log(LOG_ERROR, "waitpid failed: %s", strerror(errno));
        return -1;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        log(LOG_ERROR, "command failed: %s", args[0]);
        return -1;
    }

    return 0;
}

static void mac_to_string(const uint8_t mac[6], char out[18])
{
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static const char *interface_for_vlan(uint16_t vlan_id)
{
    for (int i = 0; i < cfg.vlan_map_count; i++) {
        if (cfg.vlan_map[i].vlan_id == vlan_id)
            return cfg.vlan_map[i].iface;
    }

    return NULL;
}

static int configure_bridge(void)
{
    char *args[] = {
        "ip", "link", "set", "dev", cfg.bridge,
        "type", "bridge", "vlan_filtering", "1", NULL
    };

    log(LOG_INFO, "enable VLAN filtering on bridge %s", cfg.bridge);
    execute(args);
    return 0;
}

static int add_vlan_to_ports(const char *client_iface, uint16_t vlan_id)
{
    char vlan[8];
    snprintf(vlan, sizeof(vlan), "%u", vlan_id);

    char *client_args[] = {
        "bridge", "vlan", "add", "dev", (char *)client_iface,
        "vid", vlan, "pvid", "untagged", NULL
    };

    char *trunk_args[] = {
        "bridge", "vlan", "add", "dev", cfg.gateway_iface,
        "vid", vlan, NULL
    };

    if (execute(client_args) != 0)
        return -1;

    return execute(trunk_args);
}

static void remove_vlan_from_trunk(uint16_t vlan_id)
{
    char vlan[8];
    snprintf(vlan, sizeof(vlan), "%u", vlan_id);

    char *args[] = {
        "bridge", "vlan", "del", "dev", cfg.gateway_iface,
        "vid", vlan, NULL
    };

    execute(args);
}

static int add_mac_rules(const uint8_t mac[6], const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    char *ingress_args[] = {
        "ebtables", "-A", "FORWARD", "-i", (char *)client_iface,
        "-s", mac_text, "-j", "ACCEPT", NULL
    };

    char *egress_args[] = {
        "ebtables", "-A", "FORWARD", "-o", (char *)client_iface,
        "-d", mac_text, "-j", "ACCEPT", NULL
    };

    if (execute(ingress_args) != 0)
        return -1;

    return execute(egress_args);
}

static void delete_mac_rules(const uint8_t mac[6], const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    char *ingress_args[] = {
        "ebtables", "-D", "FORWARD", "-i", (char *)client_iface,
        "-s", mac_text, "-j", "ACCEPT", NULL
    };

    char *egress_args[] = {
        "ebtables", "-D", "FORWARD", "-o", (char *)client_iface,
        "-d", mac_text, "-j", "ACCEPT", NULL
    };

    execute(ingress_args);
    execute(egress_args);
}

static int apply_policy(const uint8_t mac[6],
                        struct authentication *decision,
                        const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    log(LOG_INFO, "ACCEPT %s: VLAN %u on %s",
        mac_text, decision->vlan_id, client_iface);

    if (add_vlan_to_ports(client_iface, decision->vlan_id) != 0)
        return -1;

    if (add_mac_rules(mac, client_iface) != 0)
        return -1;

    decision->enforced = 1;
    return 0;
}

static void remove_policy(const uint8_t mac[6],
                          const struct authentication *decision,
                          const char *client_iface)
{
    char mac_text[18];
    mac_to_string(mac, mac_text);

    log(LOG_INFO, "REVOKE %s: VLAN %u on %s",
        mac_text, decision->vlan_id, client_iface);

    delete_mac_rules(mac, client_iface);
    remove_vlan_from_trunk(decision->vlan_id);
}

static int parse_vlan_map(const char *text)
{
    char *copy = strdup(text);
    char *entry;
    char *saveptr = NULL;

    if (copy == NULL)
        return -1;

    cfg.vlan_map_count = 0;
    entry = strtok_r(copy, ",", &saveptr);

    while (entry != NULL) {
        char *separator = strchr(entry, ':');

        if (separator == NULL || cfg.vlan_map_count >= MAX_VLAN_MAP) {
            log(LOG_ERROR, "invalid VLAN map entry: %s", entry);
            free(copy);
            return -1;
        }

        *separator = '\0';

        long vlan = strtol(entry, NULL, 10);
        const char *iface = separator + 1;

        if (vlan < 1 || vlan > 4094 ||
            iface[0] == '\0' ||
            strlen(iface) >= MAX_IFACE_LEN) {
            log(LOG_ERROR, "invalid VLAN map entry: %s:%s", entry, iface);
            free(copy);
            return -1;
        }

        cfg.vlan_map[cfg.vlan_map_count].vlan_id = (uint16_t)vlan;
        snprintf(cfg.vlan_map[cfg.vlan_map_count].iface,
                 MAX_IFACE_LEN, "%s", iface);

        cfg.vlan_map_count++;
        entry = strtok_r(NULL, ",", &saveptr);
    }

    free(copy);
    return cfg.vlan_map_count > 0 ? 0 : -1;
}

static void print_usage(const char *program)
{
    fprintf(stderr, "Usage: %s [options]\n", program);
    fprintf(stderr, "  --bridge BRIDGE         default: br0\n");
    fprintf(stderr, "  --gateway-iface IFACE   default: eth0\n");
    fprintf(stderr, "  --vlan-map MAP          example: 32:eth1,95:eth2\n");
    fprintf(stderr, "  --map-path PATH         default: /sys/fs/bpf/auth_map\n");
    fprintf(stderr, "  --interval-ms MS        default: 200\n");
    fprintf(stderr, "  --log-level LEVEL       error|warn|info|debug or 0-3\n");
}

static int read_options(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bridge") == 0 && i + 1 < argc) {
            snprintf(cfg.bridge, sizeof(cfg.bridge), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--gateway-iface") == 0 && i + 1 < argc) {
            snprintf(cfg.gateway_iface, sizeof(cfg.gateway_iface), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--vlan-map") == 0 && i + 1 < argc) {
            if (parse_vlan_map(argv[++i]) != 0)
                return -1;
        } else if (strcmp(argv[i], "--map-path") == 0 && i + 1 < argc) {
            snprintf(cfg.map_path, sizeof(cfg.map_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--interval-ms") == 0 && i + 1 < argc) {
            cfg.interval_ms = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--log-level") == 0 && i + 1 < argc) {
            const char *level = argv[++i];

            if (strcmp(level, "error") == 0) cfg.log_level = LOG_ERROR;
            else if (strcmp(level, "warn") == 0) cfg.log_level = LOG_WARN;
            else if (strcmp(level, "info") == 0) cfg.log_level = LOG_INFO;
            else if (strcmp(level, "debug") == 0) cfg.log_level = LOG_DEBUG;
            else cfg.log_level = atoi(level);
        } else {
            return -1;
        }
    }

    return 0;
}

static void process_entry(int map_fd,
                          const uint8_t mac[6],
                          struct authentication *decision)
{
    const char *client_iface = interface_for_vlan(decision->vlan_id);
    char mac_text[18];

    mac_to_string(mac, mac_text);

    if (client_iface == NULL) {
        log(LOG_WARN, "no interface for VLAN %u (MAC %s)",
            decision->vlan_id, mac_text);
        return;
    }

    if (decision->state == 1 && decision->enforced == 0) {
        if (apply_policy(mac, decision, client_iface) == 0) {
            if (bpf_map_update_elem(map_fd, mac, decision, BPF_ANY) != 0) {
                log(LOG_ERROR, "cannot update auth_map for %s: %s",
                    mac_text, strerror(errno));
            }
        }
        return;
    }

    if (decision->state == 0 && decision->enforced == 1) {
        remove_policy(mac, decision, client_iface);

        if (bpf_map_delete_elem(map_fd, mac) != 0) {
            log(LOG_WARN, "cannot delete auth_map entry for %s: %s",
                mac_text, strerror(errno));
        }

        return;
    }

    log(LOG_DEBUG, "no action for %s: state=%u enforced=%u VLAN=%u",
        mac_text, decision->state, decision->enforced, decision->vlan_id);
}

static void process_auth_map(int map_fd)
{
    uint8_t current_key[6];
    uint8_t next_key[6];
    struct authentication decision;
    int has_current_key = 0;

    while (1) {
        int result = bpf_map_get_next_key(
            map_fd,
            has_current_key ? current_key : NULL,
            next_key
        );

        if (result != 0)
            break;

        memcpy(current_key, next_key, sizeof(current_key));
        has_current_key = 1;

        if (bpf_map_lookup_elem(map_fd, current_key, &decision) != 0) {
            log(LOG_WARN, "cannot read an auth_map entry: %s", strerror(errno));
            continue;
        }

        process_entry(map_fd, current_key, &decision);
    }
}

int main(int argc, char **argv)
{
    snprintf(cfg.bridge, sizeof(cfg.bridge), "%s", "br0");
    snprintf(cfg.gateway_iface, sizeof(cfg.gateway_iface), "%s", "eth0");
    snprintf(cfg.map_path, sizeof(cfg.map_path), "%s", "/sys/fs/bpf/auth_map");
    cfg.interval_ms = 200;
    cfg.log_level = LOG_INFO;

    if (read_options(argc, argv) != 0 || cfg.vlan_map_count == 0) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }

    if (geteuid() != 0) {
        log(LOG_ERROR, "this program must run as root");
        return EXIT_FAILURE;
    }

    if (access(cfg.map_path, F_OK) != 0) {
        log(LOG_ERROR, "pinned map not found: %s", cfg.map_path);
        return EXIT_FAILURE;
    }

    configure_bridge();

    int map_fd = bpf_obj_get(cfg.map_path);
    if (map_fd < 0) {
        log(LOG_ERROR, "cannot open pinned map %s: %s",
            cfg.map_path, strerror(errno));
        return EXIT_FAILURE;
    }

    log(LOG_INFO, "started: bridge=%s trunk=%s map=%s poll=%lums",
        cfg.bridge, cfg.gateway_iface, cfg.map_path, cfg.interval_ms);

    while (1) {
        process_auth_map(map_fd);
        usleep(cfg.interval_ms * 1000);
    }

    close(map_fd);
    return EXIT_SUCCESS;
}