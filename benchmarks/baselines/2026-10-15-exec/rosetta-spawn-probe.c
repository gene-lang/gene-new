#define _GNU_SOURCE
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(void) {
  char *args[] = {"true", NULL};
  pid_t pid;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  printf("addchdir=%d\n", posix_spawn_file_actions_addchdir_np(&actions, "/gene-missing-cwd"));
  int code = posix_spawn(&pid, "/usr/bin/true", &actions, NULL, args, environ);
  printf("spawn bad cwd=%d pid=%d\n", code, pid);
  int status;
  if (code == 0) {waitpid(pid, &status, 0); printf("wait status=%d\n", WEXITSTATUS(status));}
  code = posix_spawn(&pid, "/dev/null", NULL, NULL, args, environ);
  printf("spawn no exec=%d pid=%d\n", code, pid);
  if (code == 0) {waitpid(pid, &status, 0); printf("wait status=%d\n", WEXITSTATUS(status));}
  return 0;
}
