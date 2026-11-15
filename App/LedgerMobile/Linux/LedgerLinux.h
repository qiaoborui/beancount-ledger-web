// The App's built-in Linux: an Alpine userland run by the iSH AArch64 engine
// (lollipopkit/ShellBox), linked in as static libraries.
//
// iOS gives an app no fork/exec, so the guest is interpreted in-process: each
// guest instruction dispatches to pre-compiled native code, nothing is
// generated at run time, and no JIT is needed. One machine per process; it
// runs one command at a time for the ledger assistant's bash tool.
//
// Built without the engine (the x86_64 simulator, or a build that leaves it
// out), every function is a stub and ledger_linux_available() is false.

#ifndef LEDGER_LINUX_H
#define LEDGER_LINUX_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether this build carries the engine.
bool ledger_linux_available(void);

/// Whether the machine has booted and is still alive.
bool ledger_linux_running(void);

/// Boots the machine with `rootfs` (an unpacked Alpine tree) as its root.
/// `dev_dir` is a scratch directory for the guest's /dev database; it is
/// recreated on every boot. Each run mounts its workspace at /workspace.
///
/// Returns 0, or a negative errno. A second call answers -EEXIST.
int ledger_linux_boot(const char *rootfs, const char *dev_dir);

typedef struct {
    int exit_code;
    bool timed_out;
    bool cancelled;
    bool truncated;
    long long output_bytes;
    /// stdout and stderr together, at most `max_output` bytes: the start and
    /// the end of what was printed. Free with ledger_linux_result_free.
    char *output;
    int output_length;
} ledger_linux_result;

/// Runs `/bin/sh -c command` with the host directory `workspace` mounted at
/// /workspace and as the working directory, stdin from /dev/null. Blocks
/// until the command and everything it started has ended, `timeout_ms`
/// passes, or ledger_linux_cancel() is called; in the last two cases the
/// whole process group is killed.
///
/// Returns 0 with `result` filled, or a negative errno (and `result` is
/// zeroed). Runs are serialized.
int ledger_linux_run(const char *workspace, const char *command, int timeout_ms, int max_output,
                     ledger_linux_result *result);

/// Stops the run in progress, if any. Safe from any thread.
void ledger_linux_cancel(void);

void ledger_linux_result_free(ledger_linux_result *result);

// ---------------------------------------------------------------------------
// Terminals: an interactive login shell (`/bin/sh -l` in /root) on a
// pseudo-terminal of its own, for the App's terminal screen. Several can be
// open at once, alongside the assistant's runs.

/// Receives what the terminal prints, on a guest thread. Copy the bytes and
/// return; never block.
typedef void (*ledger_linux_terminal_output)(void *context, const char *data, int length);
/// Called once, on a guest thread, when the shell exits.
typedef void (*ledger_linux_terminal_exit)(void *context, int exit_code);

/// Opens a terminal of `cols` x `rows`. Returns its id (> 0), or a negative
/// errno. `context` is passed back to both callbacks and must stay valid until
/// ledger_linux_terminal_close() returns.
int ledger_linux_terminal_open(int cols, int rows, ledger_linux_terminal_output output,
                               ledger_linux_terminal_exit on_exit, void *context);

/// Types `data` into the terminal. Returns how many bytes it took (fewer when
/// its input buffer is full; send the rest later), or a negative errno.
int ledger_linux_terminal_write(int id, const char *data, int length);

void ledger_linux_terminal_resize(int id, int cols, int rows);

/// Hangs the terminal up and kills what runs in it. No callback runs for it
/// after this returns.
void ledger_linux_terminal_close(int id);

#ifdef __cplusplus
}
#endif

#endif
