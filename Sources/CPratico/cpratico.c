#if defined(__linux__)
#define _GNU_SOURCE
#include <unistd.h>
#include "cpratico.h"

long long pratico_seek_data(int fd, long long offset) { return lseek(fd, offset, SEEK_DATA); }
long long pratico_seek_hole(int fd, long long offset) { return lseek(fd, offset, SEEK_HOLE); }
long long pratico_copy_file_range(int in, long long *in_off, int out, long long *out_off, unsigned long len) {
    off_t i = *in_off, o = *out_off;
    ssize_t n = copy_file_range(in, &i, out, &o, len, 0);
    *in_off = i;
    *out_off = o;
    return n;
}
#endif
