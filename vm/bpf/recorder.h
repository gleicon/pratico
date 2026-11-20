// The flight recorder's record, shared by the probes (recorder.bpf.c), their reader in
// vminitd (Recorder.swift), and the shim, which read it at these offsets. Little-endian,
// 384 bytes.
#ifndef PRATICO_RECORDER_H
#define PRATICO_RECORDER_H

#define PRATICO_EVENT_EXEC 1
#define PRATICO_EVENT_EXIT 2
#define PRATICO_EVENT_CONNECT 3
#define PRATICO_EVENT_DROPS 4  // vminitd: `value` records dropped so far
#define PRATICO_EVENT_ERROR 5  // vminitd: the probes could not be loaded; `text` says why
#define PRATICO_EVENT_UDP 6    // a process's first datagram to an address and port, per source port

#define PRATICO_FILE_MAX 128
#define PRATICO_ARGS_MAX 192

struct pratico_event {
    __u32 kind;
    __u32 pid;      // in the container's PID namespace
    __u32 ppid;     // 0 when the parent is outside it
    __u32 uid;
    __u64 time_ns;  // CLOCK_BOOTTIME from the probes; vminitd sends CLOCK_REALTIME
    __u64 value;    // exit: wait status; connect: TCP state reached (1 up, 7 failed); drops: count
    __u32 daddr;    // connect, udp: network byte order
    __u16 sport;    // connect, udp: host byte order
    __u16 dport;
    __u16 file_len; // exec: bytes of `text` that are the file (with its NUL), then argv
    __u16 args_len;
    __u32 reserved;
    char comm[16];
    char text[PRATICO_FILE_MAX + PRATICO_ARGS_MAX];
};

// A map as the loader creates it: the probes' maps are globals of this type in
// SEC(".maps.pratico"), found by name.
struct pratico_map {
    __u32 type;
    __u32 key_size;
    __u32 value_size;
    __u32 max_entries;
};

#endif
