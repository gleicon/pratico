#if defined(__linux__)
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netpacket/packet.h>
#include <net/ethernet.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include "cpratico.h"

#ifndef PACKET_IGNORE_OUTGOING
#define PACKET_IGNORE_OUTGOING 23
#endif

// The kernel's TUN ABI (include/uapi/linux/if_tun.h): the static musl SDK the host build
// uses has no kernel headers. Where they are installed, they must agree.
#define PRATICO_TUNSETIFF _IOW('T', 202, int)
#define PRATICO_TUNSETPERSIST _IOW('T', 203, int)
#define PRATICO_IFF_TAP 0x0002
#define PRATICO_IFF_NO_PI 0x1000
#define PRATICO_IFF_VNET_HDR 0x4000
#if __has_include(<linux/if_tun.h>)
#include <linux/if_tun.h>
_Static_assert(TUNSETIFF == PRATICO_TUNSETIFF && TUNSETPERSIST == PRATICO_TUNSETPERSIST, "if_tun.h ioctls");
_Static_assert(IFF_TAP == PRATICO_IFF_TAP && IFF_NO_PI == PRATICO_IFF_NO_PI && IFF_VNET_HDR == PRATICO_IFF_VNET_HDR, "if_tun.h flags");
#else
#define TUNSETIFF PRATICO_TUNSETIFF
#define TUNSETPERSIST PRATICO_TUNSETPERSIST
#define IFF_TAP PRATICO_IFF_TAP
#define IFF_NO_PI PRATICO_IFF_NO_PI
#define IFF_VNET_HDR PRATICO_IFF_VNET_HDR
#endif

struct report {
    int step;
    int error;
};

static int write_file(const char *path, const char *data) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(data);
    ssize_t n = write(fd, data, len);
    int saved = errno;
    close(fd);
    errno = saved;
    return n == (ssize_t)len ? 0 : -1;
}

// The TAP named `name`: persistent, so cloud-hypervisor attaches to it by name, and up.
// Returns its interface index.
static int make_tap(const char *name, int ctl) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI | IFF_VNET_HDR;
    int tun = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (tun < 0) return -1;
    if (ioctl(tun, TUNSETIFF, &ifr) < 0 || ioctl(tun, TUNSETPERSIST, 1) < 0) {
        int saved = errno;
        close(tun);
        errno = saved;
        return -1;
    }
    close(tun);
    if (ioctl(ctl, SIOCGIFFLAGS, &ifr) < 0) return -1;
    ifr.ifr_flags |= IFF_UP;
    if (ioctl(ctl, SIOCSIFFLAGS, &ifr) < 0) return -1;
    if (ioctl(ctl, SIOCGIFINDEX, &ifr) < 0) return -1;
    return ifr.ifr_ifindex;
}

// A packet socket on interface `index` that sees only the frames arriving there (what the
// VM sends), not what this namespace's own stack sends.
static int packet_socket(int index) {
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, htons(ETH_P_ALL));
    if (fd < 0) return -1;
    struct sockaddr_ll addr;
    memset(&addr, 0, sizeof addr);
    addr.sll_family = AF_PACKET;
    addr.sll_protocol = htons(ETH_P_ALL);
    addr.sll_ifindex = index;
    int on = 1;
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
        setsockopt(fd, SOL_PACKET, PACKET_IGNORE_OUTGOING, &on, sizeof on) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

// The forked child: only system calls from here, as the parent has other threads.
static void netns_child(int sock, const char *const names[], int count, const char *uid_map, const char *gid_map) {
    struct report r = {0, 0};
    int fds[2 + PRATICO_NETNS_MAX_TAPS];
    int ctl = -1;

    r.step = 1;
    if (unshare(CLONE_NEWUSER | CLONE_NEWNET) < 0) goto fail;
    r.step = 2;
    if (write_file("/proc/self/setgroups", "deny") < 0 || write_file("/proc/self/uid_map", uid_map) < 0 ||
        write_file("/proc/self/gid_map", gid_map) < 0) goto fail;
    // pratico-net is IPv4: the namespace's stack sends nothing on the TAPs (no addresses,
    // so no ARP; no IPv6, so no autoconfiguration).
    if (write_file("/proc/sys/net/ipv6/conf/default/disable_ipv6", "1") < 0 && errno != ENOENT) {
        r.step = 3;
        goto fail;
    }
    r.step = 4;
    ctl = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (ctl < 0) goto fail;
    for (int i = 0; i < count; i++) {
        r.step = 5;
        int index = make_tap(names[i], ctl);
        if (index < 0) goto fail;
        r.step = 6;
        fds[2 + i] = packet_socket(index);
        if (fds[2 + i] < 0) goto fail;
    }
    r.step = 7;
    fds[0] = open("/proc/self/ns/user", O_RDONLY | O_CLOEXEC);
    fds[1] = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
    if (fds[0] < 0 || fds[1] < 0) goto fail;

    r.step = 0;
    char control[CMSG_SPACE(sizeof fds)];
    memset(control, 0, sizeof control);
    struct iovec iov = {.iov_base = &r, .iov_len = sizeof r};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control,
                         .msg_controllen = CMSG_SPACE(sizeof(int) * (2 + count))};
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int) * (2 + count));
    memcpy(CMSG_DATA(c), fds, sizeof(int) * (2 + count));
    _exit(sendmsg(sock, &msg, 0) < 0 ? 1 : 0);
fail:
    r.error = errno;
    (void)send(sock, &r, sizeof r, 0);
    _exit(1);
}

int pratico_vm_netns(const char *const names[], int count, int *userns, int *netns, int packets[], int *step) {
    *step = 0;
    if (count < 0 || count > PRATICO_NETNS_MAX_TAPS) {
        errno = EINVAL;
        return -1;
    }
    for (int i = 0; i < count; i++) {
        if (names[i] == NULL || strlen(names[i]) == 0 || strlen(names[i]) >= IFNAMSIZ) {
            errno = EINVAL;
            return -1;
        }
    }
    char uid_map[32], gid_map[32];
    snprintf(uid_map, sizeof uid_map, "0 %u 1\n", (unsigned)geteuid());
    snprintf(gid_map, sizeof gid_map, "0 %u 1\n", (unsigned)getegid());
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(pair[0]);
        close(pair[1]);
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        close(pair[0]);
        netns_child(pair[1], names, count, uid_map, gid_map);
    }
    close(pair[1]);

    struct report r = {-1, EPROTO};
    int fds[2 + PRATICO_NETNS_MAX_TAPS];
    char control[CMSG_SPACE(sizeof fds)];
    struct iovec iov = {.iov_base = &r, .iov_len = sizeof r};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
    ssize_t n;
    do { n = recvmsg(pair[0], &msg, MSG_CMSG_CLOEXEC); } while (n < 0 && errno == EINTR);
    int saved = errno;
    close(pair[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    struct cmsghdr *c = n == (ssize_t)sizeof r ? CMSG_FIRSTHDR(&msg) : NULL;
    int got = c && c->cmsg_type == SCM_RIGHTS ? (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int)) : 0;
    if (got > 0) memcpy(fds, CMSG_DATA(c), sizeof(int) * (size_t)got);
    if (n != (ssize_t)sizeof r || r.step != 0 || got != 2 + count) {
        for (int i = 0; i < got; i++) close(fds[i]);
        *step = n == (ssize_t)sizeof r ? r.step : -1;
        errno = n == (ssize_t)sizeof r ? r.error : (n < 0 ? saved : EPROTO);
        return -1;
    }
    *userns = fds[0];
    *netns = fds[1];
    for (int i = 0; i < count; i++) packets[i] = fds[2 + i];
    return 0;
}
#endif
