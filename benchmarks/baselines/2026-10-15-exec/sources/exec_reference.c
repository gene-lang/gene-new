/* Independent native launch/I/O/wait reference. No Gene process code is linked.
 * Compare identical executable/argv, pipes, inherited environment and group
 * policy. Pipe rows measure direct native transfer; Gene's adapter boundary
 * and its additional pipe/copy are deliberately visible in the comparison. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;

static void require(int ok, const char *operation) {
  if (!ok) { perror(operation); exit(2); }
}
static int64_t ns(void) {
  struct timespec t;
  require(clock_gettime(CLOCK_MONOTONIC, &t) == 0, "clock");
  return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
struct child { pid_t pid; int input, output, error; };
static struct child start(const char *exe, char **args, int inherited, int group) {
  struct child c = { .input = -1, .output = -1, .error = -1 };
  int pipes[3][2];
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  require(posix_spawn_file_actions_init(&actions) == 0, "actions");
  require(posix_spawnattr_init(&attr) == 0, "attributes");
  sigset_t mask;
  sigemptyset(&mask);
  posix_spawnattr_setsigmask(&attr, &mask);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK |
    (group ? POSIX_SPAWN_SETPGROUP : 0));
  if (group) posix_spawnattr_setpgroup(&attr, 0);
  if (!inherited) {
    for (int i = 0; i < 3; i++) {
      require(pipe(pipes[i]) == 0, "pipe");
      for (int j = 0; j < 2; j++) fcntl(pipes[i][j], F_SETFD, FD_CLOEXEC);
    }
    for (int i = 0; i < 3; i++)
      posix_spawn_file_actions_adddup2(&actions, pipes[i][i == 0 ? 0 : 1], i);
    for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++)
      posix_spawn_file_actions_addclose(&actions, pipes[i][j]);
  }
  int error = posix_spawn(&c.pid, exe, &actions, &attr, args, environ);
  if (error) { errno = error; require(0, "spawn"); }
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  if (!inherited) {
    close(pipes[0][0]); close(pipes[1][1]); close(pipes[2][1]);
    c.input = pipes[0][1]; c.output = pipes[1][0]; c.error = pipes[2][0];
    fcntl(c.input, F_SETFL, O_NONBLOCK);
    fcntl(c.output, F_SETFL, O_NONBLOCK);
    fcntl(c.error, F_SETFL, O_NONBLOCK);
  }
  return c;
}
static void append(char **text, size_t *capacity, size_t length,
                   const char *bytes, size_t count) {
  if (length + count > *capacity) {
    size_t grown = *capacity ? *capacity * 2 : 64;
    if (grown < length + count) grown = length + count;
    *text = realloc(*text, grown);
    require(*text != NULL, "capture allocation");
    *capacity = grown;
  }
  memcpy(*text + length, bytes, count);
}
static void finish(struct child c, size_t input, size_t expectedOut,
                   size_t expectedErr, int64_t *first, int capture) {
  char buffer[65536], payload[65536];
  memset(payload, 'x', sizeof(payload));
  size_t out = 0, err = 0;
  char *outText = NULL, *errText = NULL;
  size_t outCapacity = 0, errCapacity = 0;
  if (input == 0 && c.input >= 0) { close(c.input); c.input = -1; }
  while (c.output >= 0 || c.error >= 0 || c.input >= 0) {
    struct pollfd fds[3] = {{c.output, POLLIN, 0}, {c.error, POLLIN, 0},
                             {c.input, POLLOUT, 0}};
    int ready = poll(fds, 3, -1);
    if (ready < 0 && errno == EINTR) continue;
    require(ready >= 0, "poll");
    for (int i = 0; i < 2; i++) if (fds[i].revents) {
      int *fd = i == 0 ? &c.output : &c.error;
      ssize_t n;
      while ((n = read(*fd, buffer, sizeof(buffer))) > 0) {
        if (i == 0) {
          if (capture) append(&outText, &outCapacity, out, buffer, (size_t)n);
          out += n;
          if (first && *first == 0 && memchr(buffer, '\n', n)) *first = ns();
        } else {
          if (capture) append(&errText, &errCapacity, err, buffer, (size_t)n);
          err += n;
        }
      }
      if (n == 0) { close(*fd); *fd = -1; }
      else require(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR, "read");
    }
    if (c.input >= 0 && fds[2].revents) {
      ssize_t n = write(c.input, payload, input < sizeof(payload) ? input : sizeof(payload));
      if (n > 0) input -= n;
      else require(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR, "write");
      if (input == 0) { close(c.input); c.input = -1; }
    }
  }
  int status;
  while (waitpid(c.pid, &status, 0) < 0) require(errno == EINTR, "waitpid");
  require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child status");
  require(out == expectedOut && err == expectedErr, "output bytes");
  free(outText); free(errText);
}
static char *quote(const char *text) {
  char *out = malloc(strlen(text) * 4 + 3), *p = out;
  *p++ = '\'';
  for (; *text; text++) {
    if (*text == '\'') { memcpy(p, "'\\''", 4); p += 4; }
    else *p++ = *text;
  }
  *p++ = '\''; *p = 0;
  return out;
}
static int64_t run(const char *fixture, const char *name) {
  char *args[] = {(char *)fixture, "noop", NULL, NULL, NULL};
  int inherited = strncmp(name, "stdio_", 6) == 0;
  int group = strcmp(name, "capture_root") && strncmp(name, "stream_callback", 15) &&
              strcmp(name, "stdout_bulk_root") && strncmp(name, "shell_", 6) && !inherited;
  size_t input = 0, out = 0, err = 0;
  const char *exe = fixture;
  char *shell = NULL;
  if (!strcmp(name, "clock_control")) return 0;
  if (strstr(name, "bulk")) {
    args[1] = "output"; args[2] = "1048576"; out = 1048576;
    if (!strcmp(name, "both_streams_bulk")) { args[3] = "both"; err = out; }
    if (!strcmp(name, "stdin_pipe_bulk")) {
      args[1] = "input"; args[2] = NULL; input = 1048576; out = 8;
    }
  }
  if (!strncmp(name, "shell_", 6)) {
    char *quoted = quote(fixture);
    shell = malloc(strlen(quoted) * 2 + 32);
    sprintf(shell, "%s noop %s %s noop", quoted,
      !strcmp(name, "shell_sequence") ? ";" : "|", quoted);
    free(quoted);
    exe = "/bin/sh"; args[0] = "/bin/sh"; args[1] = "-c"; args[2] = shell;
  }
  int count = !strncmp(name, "concurrent_", 11) ? atoi(name + 11) : 1;
  require(count > 0 && count <= 64, "count");
  if (count > 1 || !strcmp(name, "concurrent_1")) { args[1] = "sleep"; args[2] = "20"; }
  int firstLine = !strcmp(name, "first_line");
  if (firstLine) { args[1] = "lines"; out = 11; }
  struct child children[64];
  int64_t first = 0, started = ns();
  for (int i = 0; i < count; i++) children[i] = start(exe, args, inherited, group);
  for (int i = 0; i < count; i++) finish(children[i], input, out, err,
    firstLine ? &first : NULL, strcmp(name, "stdout_pipe_bulk") != 0);
  int64_t elapsed = (firstLine ? first : ns()) - started;
  free(shell);
  return elapsed;
}
int main(int argc, char **argv) {
  require(argc == 4, "usage: exec_reference CHILD COUNT CASE");
  int count = atoi(argv[2]);
  require(count > 0, "iterations");
  (void)run(argv[1], argv[3]);
  printf("{\"name\":\"%s\",\"iterations\":%d,\"samples_ns\":[", argv[3], count);
  for (int i = 0; i < count; i++) {
    int64_t elapsed = run(argv[1], argv[3]);
    printf("%s%lld", i ? "," : "", (long long)elapsed);
  }
  puts("]}");
  return 0;
}
