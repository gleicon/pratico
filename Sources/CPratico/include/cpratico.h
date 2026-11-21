#ifndef CPRATICO_H
#define CPRATICO_H

// GNU calls Swift's Glibc module does not expose (they need _GNU_SOURCE), for pratico's
// Linux hosts. No system header here: Clang modules would see two definitions of its types.
#if defined(__linux__)
long long pratico_seek_data(int fd, long long offset);
long long pratico_seek_hole(int fd, long long offset);
long long pratico_copy_file_range(int in, long long *in_off, int out, long long *out_off, unsigned long len);
#endif

#endif
