// The App's built-in Linux. See LedgerLinux.h.
//
// This file is the App's own glue over the engine's kernel API, written for
// the ledger assistant's one-command-at-a-time use: no terminal, no sessions,
// stdout and stderr captured through a host pipe. It is compiled against the
// headers of the pinned engine revision (scripts/build-linux-ios.sh).

#ifndef _GNU_SOURCE
#define _GNU_SOURCE // nftw on glibc, for the syntax check on Linux
#endif

#include "LedgerLinux.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#if LEDGER_LINUX_ENGINE

#include <fcntl.h>
#include <ftw.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/mm.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/real.h"

// ---------------------------------------------------------------------------
// Host signals
//
// The engine runs guest code with memory accesses that may fault on purpose;
// it recovers by catching SIGSEGV/SIGBUS on its own threads and moving the
// thread to a trampoline. Anything else that faults is not the engine's: the
// handler passes it to whatever was installed before — the Go runtime's
// handler, which LedgerCore installed at launch — exactly as if this one were
// not there. SA_ONSTACK because Go requires it of any handler installed after
// it.

extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;
extern void jit_crash_trampoline(void);
// What the engine reports when a guest fault cannot be resolved.
extern __thread volatile uint64_t jit_last_host_fault;
extern __thread volatile uint64_t jit_last_x7;
extern __thread volatile uint64_t jit_last_x10;
extern __thread volatile int jit_crash_count;

// Offsets into the engine's cpu_state and fiber frame for the pinned engine
// revision (ShellBox v1.0.55, generated cpu-offsets.h; main.c carries the same
// values). They change only with the engine, and the build pins that.
#define CRASH_CPU_pc 272
#define CRASH_CPU_segfault_addr 832
#define CRASH_CPU_segfault_was_write 840
#define CRASH_LOCAL_jit_exit_sp 920

static struct sigaction previous_segv, previous_bus;

static void forward_signal(int sig, siginfo_t *info, void *context) {
    struct sigaction *previous = sig == SIGSEGV ? &previous_segv : &previous_bus;
    if (previous->sa_flags & SA_SIGINFO) {
        if (previous->sa_sigaction != NULL) {
            previous->sa_sigaction(sig, info, context);
            return;
        }
    } else if (previous->sa_handler == SIG_IGN) {
        return;
    } else if (previous->sa_handler != SIG_DFL && previous->sa_handler != NULL) {
        previous->sa_handler(sig);
        return;
    }
    // Nothing to forward to: fall back to the default action, which the
    // faulting instruction meets again as soon as this returns.
    struct sigaction fallback = {0};
    fallback.sa_handler = SIG_DFL;
    sigemptyset(&fallback.sa_mask);
    sigaction(sig, &fallback, NULL);
}

static void guest_fault_handler(int sig, siginfo_t *info, void *context) {
#if defined(__aarch64__) && defined(__APPLE__)
    if (in_jit) {
        ucontext_t *uc = (ucontext_t *)context;
        uint64_t cpu = uc->uc_mcontext->__ss.__x[1];
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        uint64_t guest_address = (x7 - x10) & 0xffffffffffffULL;
        uint64_t esr = uc->uc_mcontext->__es.__esr;
        jit_last_host_fault = (uint64_t)info->si_addr;
        jit_last_x7 = x7;
        jit_last_x10 = x10;
        jit_crash_count++;
        *(uint64_t *)(cpu + CRASH_CPU_segfault_addr) = guest_address;
        *(int *)(cpu + CRASH_CPU_segfault_was_write) = (esr & 0x40) != 0;
        *(uint64_t *)(cpu + CRASH_CPU_pc) = (uint64_t)jit_saved_pc;
        uc->uc_mcontext->__ss.__sp = *(uint64_t *)(cpu + CRASH_LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return;
    }
#endif
    forward_signal(sig, info, context);
}

static void install_signal_handlers(void) {
    struct sigaction action = {0};
    action.sa_sigaction = guest_fault_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, &previous_segv);
    sigaction(SIGBUS, &action, &previous_bus);
    // When the guest's init dies the engine halts the machine, and its last
    // resort is a host SIGTERM to a guest thread that would not die. That must
    // not end the App. iOS itself never asks an app to stop with SIGTERM.
    signal(SIGTERM, SIG_IGN);
}

// ---------------------------------------------------------------------------
// State

static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static bool booted, dead;
static int running_pid;
static bool running_exited;
static int running_status;
static atomic_bool cancel_requested;
static char *mounted_workspace;

static void machine_exit_hook(struct task *task, int code) {
    pthread_mutex_lock(&state_lock);
    if (task->parent == NULL) {
        dead = true;
    } else if (running_pid != 0 && task->tgid == running_pid) {
        running_exited = true;
        running_status = code;
    }
    pthread_mutex_unlock(&state_lock);
}

bool ledger_linux_available(void) { return true; }

bool ledger_linux_running(void) {
    pthread_mutex_lock(&state_lock);
    bool running = booted && !dead;
    pthread_mutex_unlock(&state_lock);
    return running;
}

static int remove_entry(const char *path, const struct stat *info, int type, struct FTW *ftw) {
    (void)info; (void)type; (void)ftw;
    remove(path);
    return 0;
}

static void make_device(const char *path, int major, int minor) {
    generic_mknodat(AT_PWD, path, S_IFCHR | 0666, dev_make(major, minor));
}

// Points the current task's stdin, stdout and stderr at /dev/null, or stdout
// and stderr at a host pipe when `output_fd` is not -1.
static int set_stdio(int output_fd) {
    struct fd *null = generic_open("/dev/null", O_RDWR_, 0);
    if (IS_ERR(null))
        return (int)PTR_ERR(null);
    current->files->files[0] = null;
    if (output_fd < 0) {
        current->files->files[1] = fd_retain(null);
        current->files->files[2] = fd_retain(null);
        return 0;
    }
    // The guest gets its own copy of the host descriptor and closes it when
    // the last guest process holding it does; the caller keeps the original.
    int guest_fd = fcntl(output_fd, F_DUPFD_CLOEXEC, 3);
    if (guest_fd < 0)
        return _EMFILE;
    struct fd *out = adhoc_fd_create(&realfs_fdops);
    if (out == NULL) {
        close(guest_fd);
        return _ENOMEM;
    }
    out->real_fd = guest_fd;
    out->dir = NULL;
    struct stat host;
    if (fstat(output_fd, &host) == 0) {
        out->stat.mode = host.st_mode;
        out->stat.inode = host.st_ino;
    }
    // One description behind both descriptors, as a shell's 2>&1 would have it.
    out->refcount = 0;
    current->files->files[1] = fd_retain(out);
    current->files->files[2] = fd_retain(out);
    return 0;
}

// argv/envp in the engine's format: NUL-separated strings, then one more NUL.
static const char machine_environment[] =
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
    "HOME=/root\0"
    "TERM=dumb\0"
    "LANG=C.UTF-8\0"
    "PYTHONDONTWRITEBYTECODE=1\0"
    "MPLBACKEND=Agg\0"
    "\0";

int ledger_linux_boot(const char *rootfs, const char *dev_dir) {
    if (rootfs == NULL || dev_dir == NULL)
        return -EINVAL;
    pthread_mutex_lock(&run_lock);
    pthread_mutex_lock(&state_lock);
    bool already = booted;
    pthread_mutex_unlock(&state_lock);
    if (already) {
        pthread_mutex_unlock(&run_lock);
        return -EEXIST;
    }
    // From here on the kernel's globals change; a failure leaves a machine
    // that cannot be booted again in this process, so it is marked dead.
    pthread_mutex_lock(&state_lock);
    booted = true;
    pthread_mutex_unlock(&state_lock);

    install_signal_handlers();
    int err = mount_root(&realfs, rootfs);
    if (err < 0)
        goto fail;
    err = become_first_process();
    if (err < 0)
        goto fail;

    // /dev needs a filesystem that can hold device nodes, which the realfs
    // root cannot: it gets a small fakefs of its own, rebuilt every boot.
    nftw(dev_dir, remove_entry, 8, FTW_DEPTH | FTW_PHYS);
    err = fake_db_create(dev_dir);
    if (err < 0)
        goto fail;
    char source[4096];
    snprintf(source, sizeof(source), "%s/data", dev_dir);
    generic_mkdirat(AT_PWD, "/dev", 0755);
    err = do_mount(&fakefs, source, "/dev", "", 0);
    if (err < 0)
        goto fail;
    make_device("/dev/null", MEM_MAJOR, DEV_NULL_MINOR);
    make_device("/dev/zero", MEM_MAJOR, DEV_ZERO_MINOR);
    make_device("/dev/full", MEM_MAJOR, DEV_FULL_MINOR);
    make_device("/dev/random", MEM_MAJOR, DEV_RANDOM_MINOR);
    make_device("/dev/urandom", MEM_MAJOR, DEV_URANDOM_MINOR);
    make_device("/dev/tty", TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR);
    generic_symlinkat("/proc/self/fd/0", AT_PWD, "/dev/stdin");
    generic_symlinkat("/proc/self/fd/1", AT_PWD, "/dev/stdout");
    generic_symlinkat("/proc/self/fd/2", AT_PWD, "/dev/stderr");
    generic_mkdirat(AT_PWD, "/proc", 0755);
    do_mount(&procfs, "proc", "/proc", "", 0);
    generic_mkdirat(AT_PWD, "/workspace", 0755);

    err = set_stdio(-1);
    if (err < 0)
        goto fail;
    // init never waits for anyone: with SIGCHLD ignored, the processes it
    // inherits are released as they exit instead of staying zombies. The
    // setting survives exec, which resets only caught signals.
    current->sighand->action[SIGCHLD_].handler = SIG_IGN_;
    static const char init_argv[] = "sleep\0" "2147483647\0";
    err = do_execve("/bin/sleep", 2, init_argv, machine_environment);
    if (err < 0)
        goto fail;
    exit_hook = machine_exit_hook;
    task_start(current);
    current = NULL;
    pthread_mutex_unlock(&run_lock);
    return 0;

fail:
    current = NULL;
    pthread_mutex_lock(&state_lock);
    dead = true;
    pthread_mutex_unlock(&state_lock);
    pthread_mutex_unlock(&run_lock);
    return err;
}

// ---------------------------------------------------------------------------
// Running a command

void ledger_linux_cancel(void) { atomic_store(&cancel_requested, true); }

void ledger_linux_result_free(ledger_linux_result *result) {
    if (result == NULL)
        return;
    free(result->output);
    result->output = NULL;
    result->output_length = 0;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Keeps the first `head` and the last `tail` bytes of a stream.
struct capture {
    char *head;
    size_t head_cap, head_len;
    char *tail;
    size_t tail_cap, tail_len, tail_start;
    long long total;
};

static void capture_add(struct capture *c, const char *data, size_t length) {
    c->total += (long long)length;
    size_t take = c->head_cap - c->head_len;
    if (take > length)
        take = length;
    memcpy(c->head + c->head_len, data, take);
    c->head_len += take;
    data += take;
    length -= take;
    for (size_t i = 0; i < length && c->tail_cap > 0; i++) {
        size_t at = (c->tail_start + c->tail_len) % c->tail_cap;
        c->tail[at] = data[i];
        if (c->tail_len < c->tail_cap)
            c->tail_len++;
        else
            c->tail_start = (c->tail_start + 1) % c->tail_cap;
    }
}

static void kill_group(int pgid) {
    if (pgid > 1)
        send_group_signal((dword_t)pgid, SIGKILL_, SIGINFO_NIL);
}

static int mount_workspace(const char *workspace) {
    if (mounted_workspace != NULL && strcmp(mounted_workspace, workspace) == 0)
        return 0;
    if (mounted_workspace != NULL) {
        int err = do_umount("/workspace");
        if (err < 0 && err != _EINVAL)
            return err;
        free(mounted_workspace);
        mounted_workspace = NULL;
    }
    char resolved[4096];
    if (realpath(workspace, resolved) == NULL)
        return -errno;
    int err = do_mount(&realfs, resolved, "/workspace", "", 0);
    if (err < 0)
        return err;
    mounted_workspace = strdup(workspace);
    return 0;
}

// Takes back a task that was built but never started, the way the engine's
// own construct_task unwinds a failure: its descriptors (and with them the
// guest's copy of the output pipe), fs, signal table, memory, session, group,
// and finally its pid.
static void discard_unstarted_task(struct task *task) {
    if (task == NULL)
        return;
    if (task->files != NULL) {
        fdtable_release(task->files);
        task->files = NULL;
    }
    if (task->fs != NULL) {
        fs_info_release(task->fs);
        task->fs = NULL;
    }
    if (task->sighand != NULL) {
        sighand_release(task->sighand);
        task->sighand = NULL;
    }
    if (task->mm != NULL) {
        mm_release(task->mm);
        task->mm = NULL;
        task->mem = NULL;
        task->cpu.mmu = NULL;
    }
    task_leave_session(task);
    list_remove(&task->group_links);
    free(task->group);
    task->group = NULL;
    lock(&pids_lock);
    task_destroy(task);
    unlock(&pids_lock);
}

static int start_command(const char *command, int output_fd, int *pid) {
    int err = become_new_init_child();
    if (err < 0)
        return err;
    err = set_stdio(output_fd);
    if (err < 0)
        goto fail;
    struct fd *pwd = generic_open("/workspace", O_RDONLY_, 0);
    if (IS_ERR(pwd)) {
        err = (int)PTR_ERR(pwd);
        goto fail;
    }
    fs_chdir(current->fs, pwd);
    size_t command_length = strlen(command);
    char *argv = malloc(command_length + 16);
    if (argv == NULL) {
        err = _ENOMEM;
        goto fail;
    }
    memcpy(argv, "sh\0-c\0", 6);
    memcpy(argv + 6, command, command_length + 1);
    argv[6 + command_length + 1] = '\0';
    err = do_execve("/bin/sh", 3, argv, machine_environment);
    free(argv);
    if (err < 0)
        goto fail;
    *pid = current->pid;
    pthread_mutex_lock(&state_lock);
    running_pid = current->pid;
    running_exited = false;
    running_status = 0;
    pthread_mutex_unlock(&state_lock);
    task_start(current);
    current = NULL;
    return 0;

fail:
    discard_unstarted_task(current);
    current = NULL;
    return err;
}

int ledger_linux_run(const char *workspace, const char *command, int timeout_ms, int max_output,
                     ledger_linux_result *result) {
    if (result == NULL)
        return -EINVAL;
    memset(result, 0, sizeof(*result));
    if (workspace == NULL || command == NULL)
        return -EINVAL;
    if (max_output < 1024)
        max_output = 1024;
    pthread_mutex_lock(&run_lock);
    if (!ledger_linux_running()) {
        pthread_mutex_unlock(&run_lock);
        return -ESRCH;
    }
    atomic_store(&cancel_requested, false);
    int err = mount_workspace(workspace);
    if (err < 0) {
        pthread_mutex_unlock(&run_lock);
        return err;
    }
    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        err = -errno;
        pthread_mutex_unlock(&run_lock);
        return err;
    }
    fcntl(pipe_fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipe_fds[0], F_SETFL, fcntl(pipe_fds[0], F_GETFL) | O_NONBLOCK);
    int pid = 0;
    err = start_command(command, pipe_fds[1], &pid);
    // The guest holds its own copy of the write end; with this one closed the
    // read end sees EOF once every guest process holding it has gone.
    close(pipe_fds[1]);
    if (err < 0) {
        close(pipe_fds[0]);
        pthread_mutex_unlock(&run_lock);
        return err;
    }

    struct capture capture = {0};
    capture.head_cap = (size_t)max_output / 2;
    capture.tail_cap = (size_t)max_output - capture.head_cap;
    capture.head = malloc(capture.head_cap);
    capture.tail = malloc(capture.tail_cap);
    char buffer[16384];
    long long deadline = now_ms() + (timeout_ms > 0 ? timeout_ms : 120000);
    long long exited_at = 0;
    bool killed = false;
    for (;;) {
        struct pollfd poller = {.fd = pipe_fds[0], .events = POLLIN};
        poll(&poller, 1, 100);
        ssize_t n;
        bool eof = false;
        while ((n = read(pipe_fds[0], buffer, sizeof(buffer))) > 0)
            capture_add(&capture, buffer, (size_t)n);
        if (n == 0)
            eof = true;
        pthread_mutex_lock(&state_lock);
        bool exited = running_exited;
        bool machine_dead = dead;
        pthread_mutex_unlock(&state_lock);
        if (eof && exited)
            break;
        if (machine_dead)
            break;
        long long now = now_ms();
        if (exited && exited_at == 0)
            exited_at = now;
        if (!killed && (atomic_load(&cancel_requested) || now > deadline)) {
            if (atomic_load(&cancel_requested))
                result->cancelled = true;
            else
                result->timed_out = true;
            kill_group(pid);
            killed = true;
            deadline = now + 5000;
        } else if (killed && now > deadline) {
            break;
        }
        // The shell is gone but something it started in the background still
        // holds the output open: give it a second, then end the group.
        if (exited && !killed && now - exited_at > 1000) {
            kill_group(pid);
            killed = true;
            deadline = now + 5000;
        }
    }
    close(pipe_fds[0]);

    pthread_mutex_lock(&state_lock);
    int status = running_status;
    bool exited = running_exited;
    running_pid = 0;
    pthread_mutex_unlock(&state_lock);
    if (!exited)
        result->exit_code = 137;
    else if (status & 0xff)
        result->exit_code = 128 + (status & 0x7f);
    else
        result->exit_code = (status >> 8) & 0xff;

    result->output_bytes = capture.total;
    result->truncated = capture.total > (long long)(capture.head_len + capture.tail_len);
    size_t length = capture.head_len + capture.tail_len + (result->truncated ? 32 : 0);
    result->output = malloc(length + 1);
    if (result->output != NULL) {
        size_t at = 0;
        memcpy(result->output, capture.head, capture.head_len);
        at += capture.head_len;
        if (result->truncated) {
            const char marker[] = "\n…（中间省略）…\n";
            memcpy(result->output + at, marker, sizeof(marker) - 1);
            at += sizeof(marker) - 1;
        }
        for (size_t i = 0; i < capture.tail_len; i++)
            result->output[at++] = capture.tail[(capture.tail_start + i) % capture.tail_cap];
        result->output[at] = '\0';
        result->output_length = (int)at;
    }
    free(capture.head);
    free(capture.tail);
    pthread_mutex_unlock(&run_lock);
    return 0;
}

#else // !LEDGER_LINUX_ENGINE

bool ledger_linux_available(void) { return false; }
bool ledger_linux_running(void) { return false; }
int ledger_linux_boot(const char *rootfs, const char *dev_dir) {
    (void)rootfs; (void)dev_dir;
    return -ENOSYS;
}
int ledger_linux_run(const char *workspace, const char *command, int timeout_ms, int max_output,
                     ledger_linux_result *result) {
    (void)workspace; (void)command; (void)timeout_ms; (void)max_output;
    if (result != NULL)
        memset(result, 0, sizeof(*result));
    return -ENOSYS;
}
void ledger_linux_cancel(void) {}
void ledger_linux_result_free(ledger_linux_result *result) {
    if (result != NULL) {
        free(result->output);
        result->output = NULL;
    }
}

#endif
