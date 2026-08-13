#define _GNU_SOURCE
#include "pty_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

extern char **environ;

static void gene_pty_error(char *buffer, size_t size, const char *operation,
                           int error_number) {
  if (buffer == NULL || size == 0)
    return;
  snprintf(buffer, size, "%s: %s", operation, strerror(error_number));
  buffer[size - 1] = '\0';
}

static int gene_pty_status(int wait_status) {
  if (WIFEXITED(wait_status))
    return WEXITSTATUS(wait_status);
  if (WIFSIGNALED(wait_status))
    return 128 + WTERMSIG(wait_status);
  return -1;
}

static void gene_pty_set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags >= 0)
    (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void gene_pty_kill_helper_or_group(pid_t pid) {
  /* The helper becomes a session/process-group leader after setsid(). Setup
     can fail on either side of that call, so cover both identities. */
  (void)kill(-pid, SIGKILL);
  (void)kill(pid, SIGKILL);
}

static void gene_pty_helper_fail(const char *operation) {
  char message[512];
  int error_number = errno;
  int length = snprintf(message, sizeof(message), "%s: %s", operation,
                        strerror(error_number));
  if (length > 0) {
    size_t count = (size_t)length < sizeof(message) ? (size_t)length
                                                   : sizeof(message) - 1;
    (void)write(3, message, count);
  }
  _exit(127);
}

void gene_pty_helper_exec(const char *cwd, char *const child_argv[]) {
  gene_pty_set_cloexec(3);

  long max_fd = sysconf(_SC_OPEN_MAX);
  if (max_fd < 4 || max_fd > 65536)
    max_fd = 65536;
  for (int fd = 4; fd < max_fd; fd++)
    (void)close(fd);

  sigset_t empty;
  sigemptyset(&empty);
  (void)sigprocmask(SIG_SETMASK, &empty, NULL);
  int reset_signals[] = {SIGINT,  SIGQUIT, SIGTERM, SIGCHLD,
                         SIGHUP,  SIGTSTP, SIGTTIN, SIGTTOU};
  for (size_t i = 0; i < sizeof(reset_signals) / sizeof(reset_signals[0]); i++)
    (void)signal(reset_signals[i], SIG_DFL);

  if (setsid() < 0)
    gene_pty_helper_fail("setsid");
  if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0)
    gene_pty_helper_fail("TIOCSCTTY");
  if (tcsetpgrp(STDIN_FILENO, getpgrp()) < 0)
    gene_pty_helper_fail("tcsetpgrp");
  if (cwd != NULL && cwd[0] != '\0' && chdir(cwd) < 0)
    gene_pty_helper_fail("chdir");
  if (child_argv == NULL || child_argv[0] == NULL || child_argv[0][0] == '\0') {
    errno = EINVAL;
    gene_pty_helper_fail("empty terminal command");
  }
  execvp(child_argv[0], child_argv);
  gene_pty_helper_fail("execvp");
}

int gene_pty_spawn(const char *helper_path, const char *cwd,
                   char *const child_argv[], char *const child_env[], int rows,
                   int cols, GenePtySpawnResult *result, char *error,
                   size_t error_size) {
  if (helper_path == NULL || helper_path[0] == '\0' || child_argv == NULL ||
      child_argv[0] == NULL || rows <= 0 || cols <= 0 || result == NULL) {
    gene_pty_error(error, error_size, "invalid PTY launch arguments", EINVAL);
    return -1;
  }

  result->master_fd = -1;
  result->pid = -1;
  int master = -1;
  int slave = -1;
  int status_pipe[2] = {-1, -1};
  struct winsize size = {.ws_row = (unsigned short)rows,
                         .ws_col = (unsigned short)cols};
  if (openpty(&master, &slave, NULL, NULL, &size) < 0) {
    gene_pty_error(error, error_size, "openpty", errno);
    return -1;
  }
  gene_pty_set_cloexec(master);
  gene_pty_set_cloexec(slave);
  if (pipe(status_pipe) < 0) {
    gene_pty_error(error, error_size, "pipe", errno);
    close(master);
    close(slave);
    return -1;
  }
  gene_pty_set_cloexec(status_pipe[0]);
  gene_pty_set_cloexec(status_pipe[1]);

  size_t child_count = 0;
  while (child_argv[child_count] != NULL)
    child_count++;
  char **helper_argv = calloc(child_count + 4, sizeof(*helper_argv));
  if (helper_argv == NULL) {
    gene_pty_error(error, error_size, "allocating helper argv", ENOMEM);
    close(master);
    close(slave);
    close(status_pipe[0]);
    close(status_pipe[1]);
    return -1;
  }
  helper_argv[0] = (char *)helper_path;
  helper_argv[1] = "--gene-internal-pty-helper";
  helper_argv[2] = (char *)(cwd == NULL ? "" : cwd);
  for (size_t i = 0; i < child_count; i++)
    helper_argv[i + 3] = child_argv[i];

  posix_spawn_file_actions_t actions;
  int spawn_error = posix_spawn_file_actions_init(&actions);
  if (spawn_error == 0)
    spawn_error = posix_spawn_file_actions_adddup2(&actions, slave,
                                                    STDIN_FILENO);
  if (spawn_error == 0)
    spawn_error = posix_spawn_file_actions_adddup2(&actions, slave,
                                                    STDOUT_FILENO);
  if (spawn_error == 0)
    spawn_error = posix_spawn_file_actions_adddup2(&actions, slave,
                                                    STDERR_FILENO);
  if (spawn_error == 0)
    spawn_error = posix_spawn_file_actions_adddup2(&actions, status_pipe[1], 3);
  if (spawn_error == 0 && master != 3)
    spawn_error = posix_spawn_file_actions_addclose(&actions, master);
  if (spawn_error == 0 && slave > 3)
    spawn_error = posix_spawn_file_actions_addclose(&actions, slave);
  if (spawn_error == 0 && status_pipe[0] != 3)
    spawn_error = posix_spawn_file_actions_addclose(&actions, status_pipe[0]);
  if (spawn_error == 0 && status_pipe[1] != 3)
    spawn_error = posix_spawn_file_actions_addclose(&actions, status_pipe[1]);

  pid_t pid = -1;
  if (spawn_error == 0)
    spawn_error = posix_spawn(&pid, helper_path, &actions, NULL, helper_argv,
                              child_env == NULL ? environ : child_env);
  posix_spawn_file_actions_destroy(&actions);
  free(helper_argv);
  close(slave);
  close(status_pipe[1]);

  if (spawn_error != 0) {
    gene_pty_error(error, error_size, "posix_spawn PTY helper", spawn_error);
    close(master);
    close(status_pipe[0]);
    return -1;
  }

  struct pollfd ready = {.fd = status_pipe[0], .events = POLLIN | POLLHUP};
  int polled;
  do {
    polled = poll(&ready, 1, 5000);
  } while (polled < 0 && errno == EINTR);
  if (polled <= 0) {
    gene_pty_error(error, error_size, "PTY helper startup timeout",
                   polled == 0 ? ETIMEDOUT : errno);
    gene_pty_kill_helper_or_group(pid);
    (void)waitpid(pid, NULL, 0);
    close(master);
    close(status_pipe[0]);
    return -1;
  }

  char helper_error[512];
  ssize_t error_length;
  do {
    error_length = read(status_pipe[0], helper_error, sizeof(helper_error) - 1);
  } while (error_length < 0 && errno == EINTR);
  close(status_pipe[0]);
  if (error_length > 0) {
    helper_error[error_length] = '\0';
    if (error != NULL && error_size > 0) {
      strncpy(error, helper_error, error_size - 1);
      error[error_size - 1] = '\0';
    }
    (void)waitpid(pid, NULL, 0);
    close(master);
    return -1;
  }
  if (error_length < 0) {
    gene_pty_error(error, error_size, "reading PTY helper status", errno);
    gene_pty_kill_helper_or_group(pid);
    (void)waitpid(pid, NULL, 0);
    close(master);
    return -1;
  }

  int flags = fcntl(master, F_GETFL);
  if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0) {
    gene_pty_error(error, error_size, "configuring PTY master", errno);
    gene_pty_kill_helper_or_group(pid);
    (void)waitpid(pid, NULL, 0);
    close(master);
    return -1;
  }
  gene_pty_set_cloexec(master);
  result->master_fd = master;
  result->pid = (int)pid;
  return 0;
}

long gene_pty_read(int master_fd, char *buffer, size_t size, int *eof) {
  if (eof != NULL)
    *eof = 0;
  ssize_t count = read(master_fd, buffer, size);
  if (count > 0)
    return (long)count;
  if (count == 0) {
    if (eof != NULL)
      *eof = 1;
    return 0;
  }
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
    return 0;
  if (errno == EIO) {
    if (eof != NULL)
      *eof = 1;
    return 0;
  }
  return -errno;
}

long gene_pty_write(int master_fd, const char *buffer, size_t size) {
  ssize_t count = write(master_fd, buffer, size);
  if (count >= 0)
    return (long)count;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
    return 0;
  return -errno;
}

int gene_pty_resize(int master_fd, int rows, int cols) {
  if (rows <= 0 || cols <= 0)
    return EINVAL;
  struct winsize size = {.ws_row = (unsigned short)rows,
                         .ws_col = (unsigned short)cols};
  return ioctl(master_fd, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

static int gene_pty_signal_group(pid_t group, int signal_number) {
  if (group <= 0)
    return EINVAL;
  if (kill(-group, signal_number) == 0 || errno == ESRCH)
    return 0;
  int group_error = errno;
  /* The process-group leader is also a useful last-resort target when a
     platform temporarily refuses the group form while job control is
     changing the foreground owner. A live process group keeps its numeric
     leader id reserved, so this cannot target an unrelated reused pid. */
  if (kill(group, signal_number) == 0 || errno == ESRCH)
    return 0;
  return group_error;
}

int gene_pty_signal(int master_fd, int pid, int signal_number) {
  if (master_fd < 0 || pid <= 0)
    return EINVAL;
  pid_t foreground = tcgetpgrp(master_fd);
  if (foreground < 0) {
    if (errno != ENOTTY && errno != EIO)
      return errno;
    foreground = (pid_t)pid;
  }
  return gene_pty_signal_group(foreground, signal_number);
}

int gene_pty_signal_session(int master_fd, int pid, int signal_number) {
  if (pid <= 0)
    return EINVAL;
  pid_t foreground = -1;
  if (master_fd >= 0) {
    foreground = tcgetpgrp(master_fd);
    if (foreground < 0 && errno != ENOTTY && errno != EIO)
      return errno;
  }
  int foreground_error = 0;
  if (foreground > 0 && foreground != (pid_t)pid)
    foreground_error = gene_pty_signal_group(foreground, signal_number);
  int leader_error = gene_pty_signal_group((pid_t)pid, signal_number);
  return foreground_error != 0 ? foreground_error : leader_error;
}

int gene_pty_process_identity(int master_fd, int pid, int *session_id,
                              int *process_group_id,
                              int *foreground_process_group_id) {
  if (master_fd < 0 || pid <= 0 || session_id == NULL ||
      process_group_id == NULL || foreground_process_group_id == NULL)
    return EINVAL;
  pid_t sid = getsid((pid_t)pid);
  if (sid < 0)
    return errno;
  pid_t group = getpgid((pid_t)pid);
  if (group < 0)
    return errno;
  pid_t foreground = tcgetpgrp(master_fd);
  if (foreground < 0)
    return errno;
  *session_id = (int)sid;
  *process_group_id = (int)group;
  *foreground_process_group_id = (int)foreground;
  return 0;
}

int gene_pty_signal_number(int signal_kind) {
  switch (signal_kind) {
  case 1:
    return SIGHUP;
  case 2:
    return SIGINT;
  case 3:
    return SIGTERM;
  case 4:
    return SIGWINCH;
  case 5:
    return SIGKILL;
  default:
    return 0;
  }
}

int gene_pty_poll_exit(int pid, int *status, int *exited) {
  if (pid <= 0 || status == NULL || exited == NULL)
    return EINVAL;
  int wait_status = 0;
  pid_t found = waitpid((pid_t)pid, &wait_status, WNOHANG);
  if (found == 0) {
    *exited = 0;
    return 0;
  }
  if (found < 0) {
    if (errno == ECHILD) {
      *exited = 1;
      return 0;
    }
    return errno;
  }
  *status = gene_pty_status(wait_status);
  *exited = 1;
  return 0;
}

int gene_pty_wait_exit(int pid, int *status) {
  if (pid <= 0 || status == NULL)
    return EINVAL;
  int wait_status = 0;
  pid_t found;
  do {
    found = waitpid((pid_t)pid, &wait_status, 0);
  } while (found < 0 && errno == EINTR);
  if (found < 0)
    return errno;
  *status = gene_pty_status(wait_status);
  return 0;
}

void gene_pty_close_fd(int fd) {
  if (fd >= 0)
    (void)close(fd);
}
