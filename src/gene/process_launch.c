#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "process_launch.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <paths.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <sys/event.h>
#include <Availability.h>
#endif
#ifdef __linux__
#include <sys/syscall.h>
#endif

extern char **environ;

/* A slot reader pins signalling authority, not the allocation containing it.
 * Retirement clears the PID first, then waits out readers that loaded it.
 * Reaping is allowed only after retirement, while the PID is still reserved. */
enum { GENE_GROUP_SLOTS = 4096 };
static struct {
  atomic_int pid;
  atomic_uint readers;
} gene_groups[GENE_GROUP_SLOTS];
static atomic_int gene_groups_closing;
static atomic_int gene_groups_spawning;
static pthread_once_t gene_groups_once = PTHREAD_ONCE_INIT;
static pthread_once_t gene_shutdown_once = PTHREAD_ONCE_INIT;
static _Thread_local sigset_t gene_spawn_old_mask;
static const int gene_group_signals[3] = {SIGINT, SIGTERM, SIGHUP};
static struct sigaction gene_group_old_actions[3];
#ifdef GENE_EXEC_TESTS
static atomic_int gene_test_signals, gene_test_unsafe_reaps;
static atomic_int gene_test_hold_spawn, gene_test_spawn_waiting;
void gene_process_test_hold_spawn(int hold) { atomic_store(&gene_test_hold_spawn, hold); }
int gene_process_test_spawn_waiting(void) { return atomic_load(&gene_test_spawn_waiting); }
int gene_process_test_pin(int slot) {
  atomic_fetch_add(&gene_groups[slot].readers, 1);
  return atomic_load(&gene_groups[slot].pid);
}
void gene_process_test_unpin(int slot) { atomic_fetch_sub(&gene_groups[slot].readers, 1); }
int gene_process_test_group_pid(int slot) { return atomic_load(&gene_groups[slot].pid); }
int gene_process_test_signals(void) { return atomic_load(&gene_test_signals); }
int gene_process_test_unsafe_reaps(void) { return atomic_load(&gene_test_unsafe_reaps); }
#endif

static void gene_process_groups_cleanup(void) {
  atomic_store(&gene_groups_closing, 1);
  for (int i = 0; i < GENE_GROUP_SLOTS; ++i) {
    atomic_fetch_add(&gene_groups[i].readers, 1);
    int pid = atomic_load(&gene_groups[i].pid);
    if (pid > 0) (void)kill(-pid, SIGKILL);
    atomic_fetch_sub(&gene_groups[i].readers, 1);
  }
}

static void gene_process_groups_shutdown(void) {
  atomic_store(&gene_groups_closing, 1);
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (atomic_load(&gene_groups_spawning)) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if ((now.tv_sec - start.tv_sec) * 1000000000LL +
        now.tv_nsec - start.tv_nsec > 1000000000LL) break;
  }
  gene_process_groups_cleanup();
}

static void gene_process_register_shutdown(void) {
  atexit(gene_process_groups_shutdown);
}
void gene_process_init(void) {
  pthread_once(&gene_shutdown_once, gene_process_register_shutdown);
}

static void gene_process_groups_signal(int signal_number, siginfo_t *info,
                                      void *context) {
  int index = 0;
  while (index < 3 && gene_group_signals[index] != signal_number) ++index;
  if (index == 3) return;
  struct sigaction *old = &gene_group_old_actions[index];
  if (old->sa_handler == SIG_IGN) return;
  if (old->sa_handler != SIG_DFL) {
    gene_process_groups_shutdown();
    if (old->sa_flags & SA_SIGINFO) old->sa_sigaction(signal_number, info, context);
    else old->sa_handler(signal_number);
    atomic_store(&gene_groups_closing, 0);
    return;
  }
  gene_process_groups_shutdown();
  sigaction(signal_number, old, NULL);
  raise(signal_number);
}

static void gene_process_groups_init(void) {
  for (int i = 0; i < 3; ++i) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    for (int j = 0; j < 3; ++j) sigaddset(&action.sa_mask, gene_group_signals[j]);
    action.sa_flags = SA_SIGINFO;
    action.sa_sigaction = gene_process_groups_signal;
    sigaction(gene_group_signals[i], &action, &gene_group_old_actions[i]);
  }
}

int gene_process_spawn_begin(void) {
  pthread_once(&gene_groups_once, gene_process_groups_init);
  sigset_t mask;
  sigemptyset(&mask);
  for (int i = 0; i < 3; ++i) sigaddset(&mask, gene_group_signals[i]);
  pthread_sigmask(SIG_BLOCK, &mask, &gene_spawn_old_mask);
  atomic_fetch_add(&gene_groups_spawning, 1);
  return atomic_load(&gene_groups_closing) ? ECANCELED : 0;
}

void gene_process_spawn_end(void) {
  atomic_fetch_sub(&gene_groups_spawning, 1);
  pthread_sigmask(SIG_SETMASK, &gene_spawn_old_mask, NULL);
}

int gene_process_group_register(int pid) {
  for (int i = 0; i < GENE_GROUP_SLOTS; ++i) {
    int empty = 0;
    if (atomic_compare_exchange_strong(&gene_groups[i].pid, &empty, pid)) {
      if (atomic_load(&gene_groups_closing)) (void)kill(-pid, SIGKILL);
      return i;
    }
  }
  return -1;
}

void gene_process_group_retire(int slot) {
  if (slot < 0) return;
  atomic_store(&gene_groups[slot].pid, 0);
  while (atomic_load(&gene_groups[slot].readers)) {
    /* Ordinary owner thread only; never called by the signal handler. */
    sched_yield();
  }
}

int gene_process_cloexec_pipe(int fds[2]) {
#if defined(__linux__)
  if (pipe2(fds, O_CLOEXEC) != 0) return errno;
#else
  if (pipe(fds) != 0) return errno;
#endif
  for (int i = 0; i < 2; ++i) {
    if (fds[i] <= STDERR_FILENO) {
      int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
      if (moved < 0) {
        int error = errno;
        close(fds[0]); close(fds[1]);
        return error;
      }
      close(fds[i]);
      fds[i] = moved;
    }
    if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) {
      int error = errno;
      close(fds[0]); close(fds[1]);
      return error;
    }
  }
  return 0;
}

static int gene_spawn_addchdir(posix_spawn_file_actions_t *actions,
                              const char *directory) {
  if (!directory || !*directory) return 0;
#ifdef __APPLE__
  if (__builtin_available(macOS 10.15, *))
    return posix_spawn_file_actions_addchdir_np(actions, directory);
  return ENOSYS;
#elif defined(__GLIBC__)
#if __GLIBC_PREREQ(2, 29)
  return posix_spawn_file_actions_addchdir_np(actions, directory);
#else
  return ENOSYS;
#endif
#else
  return ENOSYS;
#endif
}

/* The fallback has no Nim/runtime calls after fork. Its error pipe makes
 * launch failures observable before publishing a live process handle. */
static int gene_spawn_fork(const char *path, char *const argv[],
                           char *const envp[], const char *directory,
                           int inherit_stdio, int merge_stderr, int own_group,
                           int pipes[3][2], pid_t *pid) {
  int errors[2];
  int result = gene_process_cloexec_pipe(errors);
  if (result) return result;
  sigset_t all_signals, previous_mask;
  sigfillset(&all_signals);
  result = pthread_sigmask(SIG_BLOCK, &all_signals, &previous_mask);
  if (result) { close(errors[0]); close(errors[1]); return result; }
  *pid = fork();
  if (*pid < 0) {
    result = errno;
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
    close(errors[0]); close(errors[1]);
    return result;
  }
  if (*pid == 0) {
    close(errors[0]);
    /* Match exec's caught-handler reset before unblocking: inherited runtime
     * handlers (including the parent's child registry) must never run here. */
    struct sigaction current, default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    for (int number = 1; number < NSIG; ++number) {
      if (sigaction(number, NULL, &current) == 0 &&
          current.sa_handler != SIG_DFL && current.sa_handler != SIG_IGN)
        if (sigaction(number, &default_action, NULL) < 0) goto child_fail;
    }
    sigset_t mask;
    sigemptyset(&mask);
    if ((own_group && setpgid(0, 0) < 0) ||
        (directory && *directory && chdir(directory) < 0)) goto child_fail;
    if (!inherit_stdio) {
      if (dup2(pipes[0][0], STDIN_FILENO) < 0 ||
          dup2(pipes[1][1], STDOUT_FILENO) < 0 ||
          dup2(merge_stderr ? pipes[1][1] : pipes[2][1], STDERR_FILENO) < 0)
        goto child_fail;
      for (int i = 0; i < 3; ++i) { close(pipes[i][0]); close(pipes[i][1]); }
    }
    if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) goto child_fail;
    execve(path, argv, envp ? envp : environ);
child_fail:
    result = errno;
    while (write(errors[1], &result, sizeof(result)) < 0 && errno == EINTR) {}
    _exit(127);
  }
  pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
  close(errors[1]);
  ssize_t count;
  do { count = read(errors[0], &result, sizeof(result)); }
  while (count < 0 && errno == EINTR);
  int read_error = errno;
  close(errors[0]);
  if (count == 0) return 0;
  if (count < 0) result = read_error;
  (void)kill(*pid, SIGKILL);
  while (waitpid(*pid, NULL, 0) < 0 && errno == EINTR) {}
  return result ? result : EIO;
}

int gene_process_spawn(const char *path, char *const argv[], char *const envp[],
                       const char *directory, int inherit_stdio, int merge_stderr,
                       int own_group, int *pid_out, int fds[3]) {
  int pipes[3][2], made = 0, error = 0;
  /* Zombie identity is part of the handle's signalling/reaping contract.
   * A host that enables automatic reaping cannot provide that contract. */
  struct sigaction child_action;
  if (sigaction(SIGCHLD, NULL, &child_action) != 0) return errno;
  if (child_action.sa_handler == SIG_IGN || (child_action.sa_flags & SA_NOCLDWAIT))
    return ENOTSUP;
  /* Skip missing PATH candidates before allocating pipes. Spawn remains
   * authoritative when the filesystem changes after this check. */
  struct stat file;
  if (stat(path, &file) != 0) return errno;
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int actions_ready = 0, attributes_ready = 0;
  pid_t pid = -1;
  fds[0] = fds[1] = fds[2] = -1;
  if (!inherit_stdio) {
    for (; made < 3; ++made) {
      error = gene_process_cloexec_pipe(pipes[made]);
      if (error) goto finish;
    }
  }
  error = posix_spawn_file_actions_init(&actions);
  if (error) goto finish;
  actions_ready = 1;
  error = posix_spawnattr_init(&attributes);
  if (error) goto finish;
  attributes_ready = 1;
  error = gene_spawn_addchdir(&actions, directory);
#ifdef GENE_EXEC_FORCE_FORK
  error = ENOSYS;
#endif
  if (error == ENOSYS) {
    error = gene_spawn_fork(path, argv, envp, directory, inherit_stdio,
                            merge_stderr, own_group, pipes, &pid);
    goto spawned;
  }
  if (error) goto finish;
  sigset_t mask;
  sigemptyset(&mask);
  error = posix_spawnattr_setsigmask(&attributes, &mask);
  if (error) goto finish;
  short flags = POSIX_SPAWN_SETSIGMASK;
  if (own_group) {
    flags |= POSIX_SPAWN_SETPGROUP;
    error = posix_spawnattr_setpgroup(&attributes, 0);
    if (error) goto finish;
  }
  error = posix_spawnattr_setflags(&attributes, flags);
  if (error) goto finish;
  if (!inherit_stdio) {
    for (int i = 0; i < 3; ++i) {
      int source = i == 0 ? pipes[0][0] :
        (i == 2 && merge_stderr ? pipes[1][1] : pipes[i][1]);
      error = posix_spawn_file_actions_adddup2(&actions, source, i);
      if (error) goto finish;
    }
    for (int i = 0; i < 3; ++i) {
      error = posix_spawn_file_actions_addclose(&actions, pipes[i][0]);
      if (!error) error = posix_spawn_file_actions_addclose(&actions, pipes[i][1]);
      if (error) goto finish;
    }
  }
  error = posix_spawn(&pid, path, &actions, &attributes, argv, envp ? envp : environ);
spawned:
  if (!error) {
#ifdef GENE_EXEC_TESTS
    if (atomic_load(&gene_test_hold_spawn)) {
      atomic_store(&gene_test_spawn_waiting, 1);
      struct timespec pause = {0, 1000000};
      while (atomic_load(&gene_test_hold_spawn)) nanosleep(&pause, NULL);
      atomic_store(&gene_test_spawn_waiting, 0);
    }
#endif
    *pid_out = pid;
    if (!inherit_stdio) {
      close(pipes[0][0]); close(pipes[1][1]); close(pipes[2][1]);
      fds[0] = pipes[0][1]; fds[1] = pipes[1][0]; fds[2] = pipes[2][0];
      made = 0;
    }
  }
finish:
  if (attributes_ready) posix_spawnattr_destroy(&attributes);
  if (actions_ready) posix_spawn_file_actions_destroy(&actions);
  for (int i = 0; i < made; ++i) { close(pipes[i][0]); close(pipes[i][1]); }
  return error;
}

/* A detached child is deliberately absent from the captured-group registry.
 * The intermediate child is reaped here; init owns the eventual executable.
 * All runtime allocation and PATH lookup happen before entering this helper.
 * The CLOEXEC report pipe distinguishes successful exec from a later startup
 * failure written to the output file. No runtime callbacks run after fork. */
struct gene_detached_report { int kind, value; };
static void gene_detached_report(int fd, int kind, int value) {
  struct gene_detached_report report = {kind, value};
  ssize_t size;
  do { size = write(fd, &report, sizeof(report)); }
  while (size < 0 && errno == EINTR);
}

int gene_process_spawn_detached(const char *path, char *const argv[],
                                char *const envp[], const char *directory,
                                const char *output, int *pid_out) {
  struct stat file;
  if (stat(path, &file) != 0) return errno;
  int reports[2];
  int error = gene_process_cloexec_pipe(reports);
  if (error) return error;
  sigset_t all, previous;
  sigfillset(&all);
  error = pthread_sigmask(SIG_BLOCK, &all, &previous);
  if (error) { close(reports[0]); close(reports[1]); return error; }
  pid_t intermediate = fork();
  if (intermediate < 0) {
    error = errno;
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    close(reports[0]); close(reports[1]);
    return error;
  }
  if (intermediate == 0) {
    close(reports[0]);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int number = 1; number < NSIG; ++number)
      if (number != SIGKILL && number != SIGSTOP)
        (void)sigaction(number, &action, NULL);
    pid_t child = fork();
    if (child < 0) goto detached_fail;
    if (child > 0) {
      gene_detached_report(reports[1], 1, child);
      _exit(0);
    }
    if (setsid() < 0 || (directory && *directory && chdir(directory) < 0))
      goto detached_fail;
    int input = open("/dev/null", O_RDONLY);
    if (input < 0) goto detached_fail;
    int destination = open(output, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (destination < 0) goto detached_fail;
    if (fchmod(destination, 0600) < 0 || dup2(input, STDIN_FILENO) < 0 ||
        dup2(destination, STDOUT_FILENO) < 0 ||
        dup2(destination, STDERR_FILENO) < 0) goto detached_fail;
    if (input > STDERR_FILENO) close(input);
    if (destination > STDERR_FILENO) close(destination);
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) goto detached_fail;
    execve(path, argv, envp ? envp : environ);
detached_fail:
    gene_detached_report(reports[1], 2, errno);
    _exit(127);
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  close(reports[1]);
  *pid_out = 0;
  for (;;) {
    struct gene_detached_report report;
    size_t read_size = 0;
    while (read_size < sizeof(report)) {
      ssize_t count = read(reports[0], (char *)&report + read_size,
                           sizeof(report) - read_size);
      if (count < 0 && errno == EINTR) continue;
      if (count < 0) { error = errno; break; }
      if (count == 0) break;
      read_size += count;
    }
    if (read_size == 0 || error) break;
    if (read_size != sizeof(report)) { error = EIO; break; }
    if (report.kind == 1) *pid_out = report.value;
    else if (report.kind == 2) error = report.value;
    else error = EIO;
  }
  close(reports[0]);
  while (waitpid(intermediate, NULL, 0) < 0 && errno == EINTR) {}
  return error ? error : (*pid_out > 0 ? 0 : EIO);
}

int gene_process_observe(int pid, int *status) {
  siginfo_t info;
  memset(&info, 0, sizeof(info));
  int result;
  do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT); }
  while (result < 0 && errno == EINTR);
  if (result < 0) return -errno;
  if (info.si_pid == 0) return 0;
  *status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
  return 1;
}

int gene_process_reap(int pid, int *status) {
#ifdef GENE_EXEC_TESTS
  for (int i = 0; i < GENE_GROUP_SLOTS; i++)
    if (atomic_load(&gene_groups[i].pid) == pid)
      atomic_fetch_add(&gene_test_unsafe_reaps, 1);
#endif
  int value;
  pid_t waited;
  do { waited = waitpid(pid, &value, 0); } while (waited < 0 && errno == EINTR);
  if (waited < 0) return errno;
  *status = WIFEXITED(value) ? WEXITSTATUS(value) :
    (WIFSIGNALED(value) ? 128 + WTERMSIG(value) : -1);
  return 0;
}

int gene_process_exit_fd(int pid, int force_poll) {
  if (force_poll) return -1;
#ifdef __APPLE__
  int fd = kqueue();
  if (fd < 0) return -1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return -1; }
  struct kevent change;
  EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_CLEAR, NOTE_EXIT, 0, NULL);
  if (kevent(fd, &change, 1, NULL, 0, NULL) < 0) { close(fd); return -1; }
  return fd;
#elif defined(__linux__) && defined(SYS_pidfd_open)
  return (int)syscall(SYS_pidfd_open, pid, 0);
#else
  return -1;
#endif
}

int gene_process_signal(int pid, int group, int signal_number) {
#ifdef GENE_EXEC_TESTS
  atomic_fetch_add(&gene_test_signals, 1);
#endif
  if (kill(group ? -pid : pid, signal_number) == 0) return 0;
  return errno;
}

int gene_process_write(int fd, const void *data, size_t size) {
  sigset_t mask, old, pending;
  sigemptyset(&mask);
  sigaddset(&mask, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &mask, &old);
  sigpending(&pending);
  int was_pending = sigismember(&pending, SIGPIPE);
  ssize_t count = write(fd, data, size);
  int saved = errno;
  if (count < 0 && saved == EPIPE && !was_pending) {
    sigset_t after;
    sigpending(&after);
    if (sigismember(&after, SIGPIPE)) {
      int received;
      (void)sigwait(&mask, &received);
    }
  }
  pthread_sigmask(SIG_SETMASK, &old, NULL);
  errno = saved;
  return (int)count;
}

#ifdef __GLIBC__
static pthread_once_t gene_default_path_once = PTHREAD_ONCE_INIT;
static char gene_default_path_buffer[4096];
static const char *gene_default_path = _PATH_DEFPATH;
static void gene_process_init_default_path(void) {
  size_t needed = confstr(_CS_PATH, gene_default_path_buffer,
                          sizeof(gene_default_path_buffer));
  if (needed > 0 && needed <= sizeof(gene_default_path_buffer))
    gene_default_path = gene_default_path_buffer;
}
#endif

const char *gene_process_default_path(void) {
#ifdef __GLIBC__
  /* glibc's execvpe uses CS_PATH, whose order differs from _PATH_DEFPATH. */
  pthread_once(&gene_default_path_once, gene_process_init_default_path);
  return gene_default_path;
#else
  return _PATH_DEFPATH;
#endif
}
