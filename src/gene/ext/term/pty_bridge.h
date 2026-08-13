#ifndef GENE_PTY_BRIDGE_H
#define GENE_PTY_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int master_fd;
  int pid;
} GenePtySpawnResult;

int gene_pty_spawn(const char *helper_path, const char *cwd,
                   char *const child_argv[], char *const child_env[], int rows,
                   int cols, GenePtySpawnResult *result, char *error,
                   size_t error_size);
void gene_pty_helper_exec(const char *cwd, char *const child_argv[]);

long gene_pty_read(int master_fd, char *buffer, size_t size, int *eof);
long gene_pty_write(int master_fd, const char *buffer, size_t size);
int gene_pty_resize(int master_fd, int rows, int cols);
int gene_pty_signal(int master_fd, int pid, int signal_number);
int gene_pty_signal_session(int master_fd, int pid, int signal_number);
int gene_pty_process_identity(int master_fd, int pid, int *session_id,
                              int *process_group_id,
                              int *foreground_process_group_id);
int gene_pty_signal_number(int signal_kind);
int gene_pty_poll_exit(int pid, int *status, int *exited);
int gene_pty_wait_exit(int pid, int *status);
void gene_pty_close_fd(int fd);

#ifdef __cplusplus
}
#endif

#endif
