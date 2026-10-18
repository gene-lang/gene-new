#ifndef GENE_PROCESS_LAUNCH_H
#define GENE_PROCESS_LAUNCH_H
#include <stddef.h>
void gene_process_init(void);

#ifdef GENE_EXEC_TESTS
int gene_process_test_pin(int slot);
void gene_process_test_unpin(int slot);
int gene_process_test_group_pid(int slot);
int gene_process_test_signals(void);
int gene_process_test_unsafe_reaps(void);
void gene_process_test_hold_spawn(int hold);
int gene_process_test_spawn_waiting(void);
#endif

/* Private native ABI. A process's single owner observes before reaping. */
int gene_process_spawn(const char *path, char *const argv[], char *const envp[],
                       const char *directory, int inherit_stdio, int merge_stderr,
                       int own_group, int *pid, int fds[3]);
int gene_process_spawn_detached(const char *path, char *const argv[],
                                char *const envp[], const char *directory,
                                const char *output, int *pid);
int gene_process_observe(int pid, int *status);
int gene_process_reap(int pid, int *status);
int gene_process_exit_fd(int pid, int force_poll);
int gene_process_group_register(int pid);
void gene_process_group_retire(int slot);
int gene_process_signal(int pid, int group, int signal_number);
int gene_process_write(int fd, const void *data, size_t size);
int gene_process_cloexec_pipe(int fds[2]);
int gene_process_spawn_begin(void);
void gene_process_spawn_end(void);
const char *gene_process_default_path(void);
#endif
