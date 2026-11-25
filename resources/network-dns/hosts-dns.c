/* Minimal DNS: answer from /etc/hosts, forward the rest. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static char forward_host[64] = "1.1.1.1";
static int forward_port = 53;
static const char *hosts_path = "/etc/hosts";
static volatile sig_atomic_t stop_flag = 0;
/* Closed from the signal handler so a blocked recvfrom returns and the DNS child can exit. */
static volatile sig_atomic_t dns_sock = -1;

static void on_signal(int sig) {
    (void)sig;
    stop_flag = 1;
    int fd = (int)dns_sock;
    if (fd >= 0) {
        dns_sock = -1;
        close(fd);
    }
}

static int read_name(const uint8_t *buf, int len, int off, char *out, int outlen) {
    int pos = off, hops = 0, wrote = 0;
    while (pos < len && hops++ < 32) {
        uint8_t lab = buf[pos];
        if (lab == 0) { if (wrote < outlen) out[wrote] = 0; return pos + 1 - off; }
        if ((lab & 0xC0) == 0xC0) {
            if (pos + 1 >= len) return -1;
            int ptr = ((lab & 0x3F) << 8) | buf[pos + 1];
            if (read_name(buf, len, ptr, out + wrote, outlen - wrote) < 0) return -1;
            return pos + 2 - off;
        }
        pos++;
        if (lab == 0 || pos + lab > len) return -1;
        if (wrote && wrote < outlen - 1) out[wrote++] = '.';
        if (wrote + lab >= outlen) return -1;
        memcpy(out + wrote, buf + pos, lab);
        /* lowercase */
        for (int i = 0; i < lab; i++) out[wrote + i] = (char)tolower((unsigned char)out[wrote + i]);
        wrote += lab;
        pos += lab;
    }
    return -1;
}

static int lookup_hosts(const char *name, char *ip, int iplen) {
    FILE *f = fopen(hosts_path, "r");
    if (!f) return 0;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p == '#' || *p == 0) continue;
        char *save = NULL;
        char *tok = strtok_r(p, " \t\r\n", &save);
        if (!tok) continue;
        char *addr = tok;
        int matched = 0;
        while ((tok = strtok_r(NULL, " \t\r\n", &save)) != NULL) {
            if (tok[0] == '#') break;
            /* compare case-insensitive */
            const char *a = tok, *b = name;
            while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
            if (*a == 0 && *b == 0) { matched = 1; break; }
        }
        if (matched) {
            /* only IPv4 for A answers */
            struct in_addr ina;
            if (inet_pton(AF_INET, addr, &ina) == 1) {
                snprintf(ip, iplen, "%s", addr);
                fclose(f);
                return 1;
            }
        }
    }
    fclose(f);
    return 0;
}

static int append_name(uint8_t *out, int cap, int off, const char *name) {
    /* emit uncompressed labels from dotted name already in question; use pointer to qname at 12 */
    if (off + 2 > cap) return -1;
    out[off] = 0xC0;
    out[off + 1] = 0x0C;
    return off + 2;
}

static int build_a_response(const uint8_t *req, int reqlen, const char *ip, uint8_t *out, int cap) {
    if (reqlen < 12 || cap < reqlen + 16) return -1;
    memcpy(out, req, reqlen);
    out[2] = 0x81; out[3] = 0x80; /* response, recursion available */
    out[6] = 0; out[7] = 1; /* ancount */
    out[8] = 0; out[9] = 0;
    out[10] = 0; out[11] = 0;
    int off = reqlen;
    off = append_name(out, cap, off, NULL);
    if (off < 0 || off + 10 + 4 > cap) return -1;
    out[off++] = 0; out[off++] = 1; /* type A */
    out[off++] = 0; out[off++] = 1; /* class IN */
    out[off++] = 0; out[off++] = 0; out[off++] = 0; out[off++] = 30; /* ttl */
    out[off++] = 0; out[off++] = 4;
    struct in_addr ina;
    if (inet_pton(AF_INET, ip, &ina) != 1) return -1;
    memcpy(out + off, &ina, 4);
    off += 4;
    return off;
}

static int build_nodata(const uint8_t *req, int reqlen, uint8_t *out, int cap) {
    if (reqlen < 12 || cap < reqlen) return -1;
    memcpy(out, req, reqlen);
    out[2] = 0x81; out[3] = 0x80;
    out[6] = 0; out[7] = 0;
    out[8] = 0; out[9] = 0;
    out[10] = 0; out[11] = 0;
    return reqlen;
}

static int build_nx(const uint8_t *req, int reqlen, uint8_t *out, int cap) {
    if (reqlen < 12 || cap < reqlen) return -1;
    memcpy(out, req, reqlen);
    out[2] = 0x81; out[3] = 0x83; /* NXDOMAIN */
    out[6] = 0; out[7] = 0;
    out[8] = 0; out[9] = 0;
    out[10] = 0; out[11] = 0;
    return reqlen;
}

static int forward_query(const uint8_t *req, int reqlen, uint8_t *out, int cap) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons(forward_port);
    if (inet_pton(AF_INET, forward_host, &dst.sin_addr) != 1) { close(fd); return -1; }
    if (sendto(fd, req, reqlen, 0, (struct sockaddr *)&dst, sizeof dst) < 0) { close(fd); return -1; }
    ssize_t n = recvfrom(fd, out, cap, 0, NULL, NULL);
    close(fd);
    return (int)n;
}

static void serve_loop(int sock) {
    uint8_t req[512], resp[512];
    while (!stop_flag) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof peer;
        ssize_t n = recvfrom(sock, req, sizeof req, 0, (struct sockaddr *)&peer, &plen);
        if (n < 0) {
            if (stop_flag || errno == EINTR || errno == EBADF) break;
            continue;
        }
        if (n < 12) continue;
        char qname[256];
        int qoff = read_name(req, (int)n, 12, qname, sizeof qname);
        if (qoff < 0 || 12 + qoff + 4 > n) continue;
        int type = (req[12 + qoff] << 8) | req[12 + qoff + 1];
        char ip[64];
        int rlen = -1;
        if (type == 1) { /* A */
            if (lookup_hosts(qname, ip, sizeof ip))
                rlen = build_a_response(req, (int)n, ip, resp, sizeof resp);
            else
                rlen = forward_query(req, (int)n, resp, sizeof resp);
        } else if (type == 28) { /* AAAA */
            if (lookup_hosts(qname, ip, sizeof ip))
                rlen = build_nodata(req, (int)n, resp, sizeof resp); /* NODATA for musl */
            else
                rlen = forward_query(req, (int)n, resp, sizeof resp);
        } else {
            rlen = forward_query(req, (int)n, resp, sizeof resp);
        }
        if (rlen < 0) rlen = build_nx(req, (int)n, resp, sizeof resp);
        if (rlen > 0) sendto(sock, resp, rlen, 0, (struct sockaddr *)&peer, plen);
    }
}

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s [--hosts path] [--listen ip] [--forward ip[:port]] -- cmd...\n", argv0);
}

int main(int argc, char **argv) {
    const char *listen_ip = "127.0.0.1";
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { i++; break; }
        if (!strcmp(argv[i], "--hosts") && i + 1 < argc) { hosts_path = argv[++i]; continue; }
        if (!strcmp(argv[i], "--listen") && i + 1 < argc) { listen_ip = argv[++i]; continue; }
        if (!strcmp(argv[i], "--forward") && i + 1 < argc) {
            const char *f = argv[++i];
            const char *colon = strrchr(f, ':');
            if (colon && strchr(f, ':') == colon) {
                size_t hl = (size_t)(colon - f);
                if (hl >= sizeof forward_host) hl = sizeof forward_host - 1;
                memcpy(forward_host, f, hl); forward_host[hl] = 0;
                forward_port = atoi(colon + 1);
            } else {
                snprintf(forward_host, sizeof forward_host, "%s", f);
            }
            continue;
        }
        usage(argv[0]);
        return 2;
    }
    if (i >= argc) { usage(argv[0]); return 2; }

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return 1; }
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(53);
    if (inet_pton(AF_INET, listen_ip, &addr.sin_addr) != 1) { fprintf(stderr, "bad listen ip\n"); return 1; }
    if (bind(sock, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind :53");
        close(sock);
        /* still exec user command so containers start without DNS helper */
        execvp(argv[i], &argv[i]);
        perror("exec");
        return 127;
    }

    dns_sock = sock;
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child == 0) {
        /* DNS server child */
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
        serve_loop(sock);
        if ((int)dns_sock >= 0) {
            close((int)dns_sock);
            dns_sock = -1;
        }
        _exit(0);
    }
    /* Parent keeps its own sock fd closed; the child owns dns_sock. */
    close(sock);
    dns_sock = -1;
    /* Parent: run user command; on exit, kill DNS child */
    signal(SIGCHLD, SIG_DFL);
    pid_t cmd = fork();
    if (cmd < 0) { kill(child, SIGTERM); return 1; }
    if (cmd == 0) {
        execvp(argv[i], &argv[i]);
        perror("exec");
        _exit(127);
    }
    int status = 0;
    while (waitpid(cmd, &status, 0) < 0 && errno == EINTR) {}
    kill(child, SIGTERM);
    /* Closing the child's UDP socket (via SIGTERM handler) should unblock recvfrom.
       Fall back to SIGKILL so a stuck DNS child cannot keep PID 1 alive forever. */
    int reaped = 0;
    for (int attempt = 0; attempt < 50; attempt++) {
        pid_t r = waitpid(child, NULL, WNOHANG);
        if (r == child) {
            reaped = 1;
            break;
        }
        if (r < 0 && errno != EINTR) break;
        usleep(10000);
    }
    if (!reaped) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
