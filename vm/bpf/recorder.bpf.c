// pratico's flight recorder: every exec and exit in the container, and the process behind
// each TCP connection it opens, into a ring buffer vminitd reads (vminitd/Sources/
// VminitdCore/Recorder.swift). Built by scripts/build-bpf.sh against the shipped kernel's
// own types, so fields are read at fixed offsets and the loader relocates only maps.
// Raw tracepoints: no tracefs, no kprobes, nothing the kernel config would have to add.

// The types are this one kernel's: no CO-RE relocations for a loader to resolve.
#define BPF_NO_PRESERVE_ACCESS_INDEX
#include "vmlinux.h"
#include "recorder.h"

#define SEC(name) __attribute__((section(name), used))
// One function per program: the loader relocates maps, not calls.
#define __always_inline inline __attribute__((always_inline))

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)BPF_FUNC_map_lookup_elem;
static long (*bpf_map_update_elem)(void *map, const void *key, const void *value, __u64 flags) = (void *)BPF_FUNC_map_update_elem;
static long (*bpf_map_delete_elem)(void *map, const void *key) = (void *)BPF_FUNC_map_delete_elem;
static long (*bpf_probe_read_kernel)(void *dst, __u32 size, const void *src) = (void *)BPF_FUNC_probe_read_kernel;
static long (*bpf_probe_read_kernel_str)(void *dst, __u32 size, const void *src) = (void *)BPF_FUNC_probe_read_kernel_str;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *src) = (void *)BPF_FUNC_probe_read_user;
static __u64 (*bpf_ktime_get_boot_ns)(void) = (void *)BPF_FUNC_ktime_get_boot_ns;
static __u64 (*bpf_get_current_uid_gid)(void) = (void *)BPF_FUNC_get_current_uid_gid;
static long (*bpf_get_current_comm)(void *buf, __u32 size) = (void *)BPF_FUNC_get_current_comm;
static __u64 (*bpf_get_current_task)(void) = (void *)BPF_FUNC_get_current_task;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *)BPF_FUNC_ringbuf_reserve;
static void (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *)BPF_FUNC_ringbuf_submit;

char LICENSE[] SEC("license") = "Dual MIT/GPL";

// 1 MiB, about 2,700 records waiting for vminitd (whose cgroup the map's memory counts
// against); past that they are dropped and counted.
struct pratico_map events SEC(".maps.pratico") = { BPF_MAP_TYPE_RINGBUF, 0, 0, 1 << 20 };
struct pratico_map drops SEC(".maps.pratico") = { BPF_MAP_TYPE_ARRAY, 4, 8, 1 };
// Sockets between SYN_SENT and their next state: who connected, by socket.
struct pratico_map connecting SEC(".maps.pratico") = { BPF_MAP_TYPE_LRU_HASH, 8, sizeof(struct pratico_event), 1024 };

static __always_inline struct pratico_event *reserve(void) {
    struct pratico_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        __u32 zero = 0;
        __u64 *n = bpf_map_lookup_elem(&drops, &zero);
        if (n) __sync_fetch_and_add(n, 1);
    }
    return e;
}

// A task's PID namespace depth (0 is the VM's own: vminitd, vmexec before it enters the
// container, kernel threads) and its PID there.
static __always_inline __u32 ns_level(struct task_struct *t, __u32 *nr) {
    struct pid *p = 0;
    __u32 level = 0;
    *nr = 0;
    bpf_probe_read_kernel(&p, sizeof(p), &t->thread_pid);
    if (!p) return 0;
    bpf_probe_read_kernel(&level, sizeof(level), &p->level);
    bpf_probe_read_kernel(nr, sizeof(*nr), &p->numbers[level & 31].nr);
    return level;
}

// Fills in who `t` is; false for a task outside the container, which is not recorded.
static __always_inline int identify(struct pratico_event *e, struct task_struct *t, __u32 kind) {
    __u32 pid = 0, ppid = 0;
    __u32 level = ns_level(t, &pid);
    if (level == 0) return 0;
    struct task_struct *parent = 0;
    bpf_probe_read_kernel(&parent, sizeof(parent), &t->real_parent);
    __u32 parent_level = parent ? ns_level(parent, &ppid) : 0;
    e->kind = kind;
    e->pid = pid;
    e->ppid = parent_level == level ? ppid : 0;
    e->uid = (__u32)bpf_get_current_uid_gid();
    e->time_ns = bpf_ktime_get_boot_ns();
    e->value = 0;
    e->daddr = 0;
    e->sport = e->dport = 0;
    e->file_len = e->args_len = 0;
    e->reserved = 0;
    bpf_get_current_comm(e->comm, sizeof(e->comm));
    return 1;
}

// Whether the current task is in a container: checked before a record is reserved.
static __always_inline int in_container(struct task_struct *t) {
    __u32 nr = 0;
    return ns_level(t, &nr) > 0;
}

SEC("raw_tracepoint/sched_process_exec")
int on_exec(struct bpf_raw_tracepoint_args *ctx) {
    struct task_struct *t = (void *)ctx->args[0];
    struct linux_binprm *bprm = (void *)ctx->args[2];
    if (!in_container(t)) return 0;
    struct pratico_event *e = reserve();
    if (!e) return 0;
    identify(e, t, PRATICO_EVENT_EXEC);
    const char *file = 0;
    bpf_probe_read_kernel(&file, sizeof(file), &bprm->filename);
    long n = bpf_probe_read_kernel_str(e->text, PRATICO_FILE_MAX, file);
    __u32 file_len = n > 0 ? (__u32)n : 0;
    if (file_len > PRATICO_FILE_MAX) file_len = PRATICO_FILE_MAX;
    e->file_len = file_len;
    // The new image's argv, NUL-separated, from its stack.
    struct mm_struct *mm = 0;
    bpf_probe_read_kernel(&mm, sizeof(mm), &t->mm);
    unsigned long start = 0, end = 0;
    if (mm) {
        bpf_probe_read_kernel(&start, sizeof(start), &mm->arg_start);
        bpf_probe_read_kernel(&end, sizeof(end), &mm->arg_end);
    }
    __u32 len = end > start ? (__u32)(end - start) : 0;
    if (len > PRATICO_ARGS_MAX) len = PRATICO_ARGS_MAX;
    if (len > 0 && bpf_probe_read_user(e->text + file_len, len, (void *)start) == 0) e->args_len = len;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("raw_tracepoint/sched_process_exit")
int on_exit(struct bpf_raw_tracepoint_args *ctx) {
    struct task_struct *t = (void *)ctx->args[0];
    int pid = 0, tgid = 0;
    bpf_probe_read_kernel(&pid, sizeof(pid), &t->pid);
    bpf_probe_read_kernel(&tgid, sizeof(tgid), &t->tgid);
    if (pid != tgid || !in_container(t)) return 0;  // a thread, not the process
    struct pratico_event *e = reserve();
    if (!e) return 0;
    identify(e, t, PRATICO_EVENT_EXIT);
    int code = 0;
    bpf_probe_read_kernel(&code, sizeof(code), &t->exit_code);
    e->value = (__u32)code;
    bpf_ringbuf_submit(e, 0);
    return 0;
}

SEC("raw_tracepoint/inet_sock_set_state")
int on_tcp_state(struct bpf_raw_tracepoint_args *ctx) {
    struct sock *sk = (void *)ctx->args[0];
    int old = (int)ctx->args[1], state = (int)ctx->args[2];
    __u64 key = (__u64)sk;
    if (state == TCP_SYN_SENT) {
        // In connect(): the current task is the one connecting. Its source port is
        // picked after this, so the record waits for the socket's next state.
        struct pratico_event pending = {};
        if (identify(&pending, (struct task_struct *)bpf_get_current_task(), PRATICO_EVENT_CONNECT))
            bpf_map_update_elem(&connecting, &key, &pending, BPF_ANY);
        return 0;
    }
    if (old != TCP_SYN_SENT) return 0;
    struct pratico_event *pending = bpf_map_lookup_elem(&connecting, &key);
    if (!pending) return 0;
    struct pratico_event *e = reserve();
    if (e) {
        __builtin_memcpy(e, pending, sizeof(*e));
        e->value = (__u32)state;
        bpf_probe_read_kernel(&e->daddr, sizeof(e->daddr), &sk->__sk_common.skc_daddr);
        __u16 dport = 0;
        bpf_probe_read_kernel(&dport, sizeof(dport), &sk->__sk_common.skc_dport);
        e->dport = __builtin_bswap16(dport);
        bpf_probe_read_kernel(&e->sport, sizeof(e->sport), &sk->__sk_common.skc_num);
        bpf_ringbuf_submit(e, 0);
    }
    bpf_map_delete_elem(&connecting, &key);
    return 0;
}
