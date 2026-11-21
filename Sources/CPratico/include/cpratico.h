#ifndef CPRATICO_H
#define CPRATICO_H

// GNU calls Swift's Glibc module does not expose (they need _GNU_SOURCE), for pratico's
// Linux hosts. No system header here: Clang modules would see two definitions of its types.
#if defined(__linux__)
long long pratico_seek_data(int fd, long long offset);
long long pratico_seek_hole(int fd, long long offset);
long long pratico_copy_file_range(int in, long long *in_off, int out, long long *out_off, unsigned long len);

#define PRATICO_NETNS_MAX_TAPS 4
/// A VM's private network (docs/design/remote.md): a user namespace mapping the caller's
/// uid and gid to root, a network namespace it owns, and in it a persistent TAP per name,
/// up, each with a packet socket that sees what the VM sends. Made in a forked child, as
/// only a single-threaded process can enter a new user namespace; no host privilege.
/// 0 with the namespaces' fds and a packet socket per TAP; -1 with errno, and in `step`
/// what failed (1 unshare, 2 id maps, 3 IPv6 off, 4 control socket, 5 TAP, 6 packet
/// socket, 7 namespace fds, -1 no answer from the child).
int pratico_vm_netns(const char *const names[], int count, int *userns, int *netns, int packets[], int *step);
#endif

#endif
