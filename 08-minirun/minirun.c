// minirun: a minimal container runtime for the series "Linux containers by hand".
//
// It does with system calls what the earlier parts did with commands:
//   part 3  clone() with CLONE_NEW* flags, pivot_root(), /proc, /sys and /dev
//   part 5  a cgroup v2 group with limits on memory, CPU and processes
//   part 6  a hook program that connects the network namespace (like CNI)
//   part 7  dropped capabilities, no_new_privs, a seccomp filter, a user namespace
//
// Build:  gcc -O2 -Wall -o minirun minirun.c
// Usage:  minirun [-n hostname] [-m memory] [-c cpus] [-p pids] [-H hook] [-U] <rootfs> <command> [args...]
//   -H hook  a shell command run on the host with the PID of the container as $1,
//            after the namespaces are created and before the command starts
//   -U       a user namespace: root in the container is UID 100000 on the host
// Run as root on a Linux host with cgroup v2.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <net/if.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define STACK_SIZE (1024 * 1024)
#define CGROUP_PARENT "/sys/fs/cgroup/lab"
#define USERNS_HOST_ID 100000
#define USERNS_SIZE 65536

struct config {
    const char *rootfs;
    const char *hostname;
    const char *memory;
    const char *cpus;
    const char *pids;
    const char *hook;
    int userns;
    char **argv;
    int sync[2];  // the parent closes sync[1] when the child may go on
};

static void die(const char *what) {
    fprintf(stderr, "minirun: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void write_file(const char *path, const char *data) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0 || write(fd, data, strlen(data)) < 0)
        die(path);
    close(fd);
}

// a file of a cgroup: <group>/<name>
static void cg_write(const char *cg, const char *name, const char *data) {
    char p[PATH_MAX];
    if ((size_t)snprintf(p, sizeof p, "%s/%s", cg, name) >= sizeof p) {
        errno = ENAMETOOLONG;
        die(cg);
    }
    write_file(p, data);
}

static void do_mount(const char *src, const char *dst, const char *type,
                     unsigned long flags, const char *data) {
    if (mount(src, dst, type, flags, data) < 0)
        die(dst);
}

// ---------------------------------------------------------------- the child

// /dev on tmpfs. The device files are bind mounts of the host ones: in a user
// namespace mknod() of devices is not allowed, and this way works in both cases.
static void setup_dev(const char *r) {
    static const char *devices[] = {"null", "zero", "full", "random", "urandom", "tty", NULL};
    char p[PATH_MAX], src[64];

    snprintf(p, sizeof p, "%s/dev", r);
    do_mount("tmpfs", p, "tmpfs", MS_NOSUID, "mode=755,size=64k");
    for (const char **d = devices; *d; d++) {
        snprintf(p, sizeof p, "%s/dev/%s", r, *d);
        snprintf(src, sizeof src, "/dev/%s", *d);
        int fd = open(p, O_CREAT | O_WRONLY | O_CLOEXEC, 0666);
        if (fd < 0)
            die(p);
        close(fd);
        do_mount(src, p, NULL, MS_BIND, NULL);
    }
    snprintf(p, sizeof p, "%s/dev/pts", r);
    mkdir(p, 0755);
    do_mount("devpts", p, "devpts", MS_NOSUID | MS_NOEXEC, "newinstance,ptmxmode=0666,mode=0620");
    snprintf(p, sizeof p, "%s/dev/shm", r);
    mkdir(p, 01777);
    do_mount("shm", p, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");

    static const char *links[][2] = {
        {"pts/ptmx", "ptmx"}, {"/proc/self/fd", "fd"}, {"/proc/self/fd/0", "stdin"},
        {"/proc/self/fd/1", "stdout"}, {"/proc/self/fd/2", "stderr"}, {NULL, NULL}};
    for (int i = 0; links[i][0]; i++) {
        snprintf(p, sizeof p, "%s/dev/%s", r, links[i][1]);
        if (symlink(links[i][0], p) < 0)
            die(p);
    }
}

// A read-only bind remount has to keep the flags the kernel locked on the
// original mount (nosuid, nodev, noexec, atime): in a user namespace it may
// not drop them. statvfs() flags have the same values as mount() flags.
static void remount_ro(const char *p) {
    struct statvfs sv;
    if (statvfs(p, &sv) < 0)
        die(p);
    unsigned long keep = sv.f_flag & (ST_NOSUID | ST_NODEV | ST_NOEXEC | ST_NOATIME |
                                      ST_NODIRATIME | ST_RELATIME);
    do_mount(NULL, p, NULL, MS_REMOUNT | MS_BIND | MS_RDONLY | keep, NULL);
}

static void setup_root(const char *r) {
    char p[PATH_MAX];

    // nothing we mount may leak to the host
    do_mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL);
    // pivot_root() needs the new root to be a mount point
    do_mount(r, r, NULL, MS_BIND | MS_REC, NULL);

    snprintf(p, sizeof p, "%s/proc", r);
    do_mount("proc", p, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    snprintf(p, sizeof p, "%s/sys", r);
    do_mount("sysfs", p, "sysfs", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    snprintf(p, sizeof p, "%s/sys/fs/cgroup", r);
    do_mount("cgroup2", p, "cgroup2", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    setup_dev(r);

    // maskedPaths and readonlyPaths of runc, two of them
    char null[PATH_MAX];
    snprintf(null, sizeof null, "%s/dev/null", r);
    snprintf(p, sizeof p, "%s/proc/kcore", r);
    do_mount(null, p, NULL, MS_BIND, NULL);
    snprintf(p, sizeof p, "%s/proc/sys", r);
    do_mount(p, p, NULL, MS_BIND, NULL);
    remount_ro(p);
    remount_ro(r);

    // the old root goes on top of the new one and is detached right away
    if (chdir(r) < 0)
        die(r);
    if (syscall(SYS_pivot_root, ".", ".") < 0)
        die("pivot_root");
    if (umount2(".", MNT_DETACH) < 0)
        die("umount old root");
    if (chdir("/") < 0)
        die("chdir /");
}

static void loopback_up(void) {
    struct ifreq ifr = {0};
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0)
        die("socket");
    strcpy(ifr.ifr_name, "lo");
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0)
        die("SIOCGIFFLAGS lo");
    ifr.ifr_flags |= IFF_UP;
    if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0)
        die("SIOCSIFFLAGS lo");
    close(s);
}

// The same three capabilities as in the template of `runc spec`. For a process
// with UID 0, execve() makes the permitted and effective sets equal to the
// bounding set, so dropping the rest from the bounding set is enough.
static void drop_capabilities(void) {
    static const int keep[] = {CAP_KILL, CAP_NET_BIND_SERVICE, CAP_AUDIT_WRITE};
    int last = CAP_LAST_CAP;
    FILE *f = fopen("/proc/sys/kernel/cap_last_cap", "r");
    if (f) {
        if (fscanf(f, "%d", &last) != 1)
            last = CAP_LAST_CAP;
        fclose(f);
    }
    for (int cap = 0; cap <= last; cap++) {
        int kept = 0;
        for (size_t i = 0; i < sizeof keep / sizeof keep[0]; i++)
            kept |= keep[i] == cap;
        if (!kept && prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) < 0)
            die("PR_CAPBSET_DROP");
    }
}

// A seccomp filter in classic BPF: kill a process of a foreign architecture or
// using x32 system call numbers, return EPERM for calls that rearrange
// namespaces and mounts or reach into the kernel, allow the rest.
#define DENY(nr) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA))

static void install_seccomp(void) {
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        DENY(__NR_mount),
        DENY(__NR_umount2),
        DENY(__NR_pivot_root),
        DENY(__NR_unshare),
        DENY(__NR_setns),
        DENY(__NR_keyctl),
        DENY(__NR_add_key),
        DENY(__NR_request_key),
        DENY(__NR_ptrace),
        DENY(__NR_kexec_load),
        DENY(__NR_bpf),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {.len = sizeof filter / sizeof filter[0], .filter = filter};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
        die("PR_SET_NO_NEW_PRIVS");
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) < 0)
        die("seccomp");
}

static int child(void *arg) {
    struct config *c = arg;
    char buf;

    // wait until the parent has written the ID maps, moved us into the
    // cgroup and run the hook: it closes its end of the pipe
    close(c->sync[1]);
    if (read(c->sync[0], &buf, 1) < 0)
        die("sync");
    close(c->sync[0]);

    if (c->userns) {
        // root of the user namespace, without the supplementary groups of the host
        if (setgroups(0, NULL) < 0 || setgid(0) < 0 || setuid(0) < 0)
            die("setuid 0");
    }
    // now that we are in our cgroup, it becomes / for us
    if (unshare(CLONE_NEWCGROUP) < 0)
        die("unshare cgroup");
    if (sethostname(c->hostname, strlen(c->hostname)) < 0)
        die("sethostname");
    loopback_up();
    setup_root(c->rootfs);
    drop_capabilities();
    install_seccomp();

    execvp(c->argv[0], c->argv);
    fprintf(stderr, "minirun: %s: %s\n", c->argv[0], strerror(errno));
    return 127;
}

// --------------------------------------------------------------- the parent

static void setup_cgroup(const char *cg, const struct config *c) {
    char v[64];

    if (mkdir(CGROUP_PARENT, 0755) < 0 && errno != EEXIST)
        die(CGROUP_PARENT);
    write_file(CGROUP_PARENT "/cgroup.subtree_control", "+memory +cpu +pids");
    if (mkdir(cg, 0755) < 0)
        die(cg);
    if (c->memory) {
        cg_write(cg, "memory.max", c->memory);
        cg_write(cg, "memory.swap.max", "0");
    }
    if (c->cpus) {
        snprintf(v, sizeof v, "%ld 100000", (long)(atof(c->cpus) * 100000));
        cg_write(cg, "cpu.max", v);
    }
    if (c->pids)
        cg_write(cg, "pids.max", c->pids);
}

static void run_hook(const char *hook, pid_t pid) {
    char spid[16];
    snprintf(spid, sizeof spid, "%d", pid);
    pid_t h = fork();
    if (h < 0)
        die("fork");
    if (h == 0) {
        execl("/bin/sh", "sh", "-c", hook, "hook", spid, (char *)NULL);
        _exit(127);
    }
    int st;
    if (waitpid(h, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fprintf(stderr, "minirun: the hook failed\n");
        kill(pid, SIGKILL);
        exit(1);
    }
}

static long oom_kills(const char *cg) {
    char p[PATH_MAX + 16], line[128];
    long n = 0;
    snprintf(p, sizeof p, "%s/memory.events", cg);
    FILE *f = fopen(p, "r");
    if (!f)
        return 0;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "oom_kill %ld", &n) == 1)
            break;
    fclose(f);
    return n;
}

static void usage(void) {
    fprintf(stderr, "usage: minirun [-n hostname] [-m memory] [-c cpus] [-p pids] [-H hook] [-U] "
                    "<rootfs> <command> [args...]\n");
    exit(1);
}

int main(int argc, char **argv) {
    struct config c = {.hostname = "box"};
    int opt;

    while ((opt = getopt(argc, argv, "+n:m:c:p:H:U")) != -1) {
        switch (opt) {
        case 'n': c.hostname = optarg; break;
        case 'm': c.memory = optarg; break;
        case 'c': c.cpus = optarg; break;
        case 'p': c.pids = optarg; break;
        case 'H': c.hook = optarg; break;
        case 'U': c.userns = 1; break;
        default: usage();
        }
    }
    if (argc - optind < 2)
        usage();
    c.rootfs = realpath(argv[optind], NULL);
    if (!c.rootfs)
        die(argv[optind]);
    c.argv = &argv[optind + 1];

    char cg[PATH_MAX];
    snprintf(cg, sizeof cg, CGROUP_PARENT "/minirun-%d", getpid());
    setup_cgroup(cg, &c);

    if (pipe2(c.sync, O_CLOEXEC) < 0)
        die("pipe");
    char *stack = mmap(NULL, STACK_SIZE, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
    if (stack == MAP_FAILED)
        die("mmap");
    int flags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWNET | SIGCHLD;
    if (c.userns)
        flags |= CLONE_NEWUSER;
    pid_t pid = clone(child, stack + STACK_SIZE, flags, &c);
    if (pid < 0)
        die("clone");
    close(c.sync[0]);

    char p[64], v[64];
    if (c.userns) {
        snprintf(v, sizeof v, "0 %d %d\n", USERNS_HOST_ID, USERNS_SIZE);
        snprintf(p, sizeof p, "/proc/%d/uid_map", pid);
        write_file(p, v);
        snprintf(p, sizeof p, "/proc/%d/gid_map", pid);
        write_file(p, v);
    }
    snprintf(v, sizeof v, "%d", pid);
    cg_write(cg, "cgroup.procs", v);
    if (c.hook)
        run_hook(c.hook, pid);
    close(c.sync[1]);  // go

    int st;
    if (waitpid(pid, &st, 0) < 0)
        die("waitpid");
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    if (WIFSIGNALED(st))
        fprintf(stderr, "minirun: killed by signal %d, oom_kill %ld\n", WTERMSIG(st), oom_kills(cg));
    else
        fprintf(stderr, "minirun: exit code %d\n", code);

    // the PID namespace is gone with its init; the group empties a moment later
    for (int i = 0; i < 50 && rmdir(cg) < 0 && errno == EBUSY; i++)
        usleep(100000);
    rmdir(CGROUP_PARENT);  // only if no other group is left there
    return code;
}
