#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "native_wake.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

struct GeneNativeWake {
  struct GeneNativeWake *next;
  int64_t lane;
  const void *key;
  unsigned references;
  int reader, writer;
};
static pthread_mutex_t gene_wake_lock = PTHREAD_MUTEX_INITIALIZER;
static GeneNativeWake *gene_wakes;
#ifdef GENE_EXEC_TESTS
static atomic_uint_fast64_t gene_wake_wait_count;
uint64_t gene_wake_test_waits(void) { return atomic_load(&gene_wake_wait_count); }
#endif

GeneNativeWake *gene_wake_new(int64_t lane, const void *key) {
  GeneNativeWake *wake = calloc(1, sizeof(*wake));
  if (!wake) return NULL;
  int fds[2];
#ifdef __linux__
  if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) { free(wake); return NULL; }
#else
  if (pipe(fds) != 0) { free(wake); return NULL; }
#endif
  for (int i = 0; i < 2; ++i) {
    if (fds[i] <= STDERR_FILENO) {
      int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
      if (moved < 0) goto fail;
      close(fds[i]);
      fds[i] = moved;
    }
    if (fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL, 0) | O_NONBLOCK) < 0 ||
        fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) goto fail;
  }
  wake->reader = fds[0];
  wake->writer = fds[1];
  wake->lane = lane;
  wake->key = key;
  wake->references = 1;
  pthread_mutex_lock(&gene_wake_lock);
  /* A lane may already be polling a snapshot of its other applications.
   * Interrupt that snapshot so it can include this newly registered owner. */
  if (lane >= 0)
    for (GeneNativeWake *existing = gene_wakes; existing; existing = existing->next)
      if (existing->lane == lane) gene_wake_signal(existing);
  wake->next = gene_wakes;
  gene_wakes = wake;
  pthread_mutex_unlock(&gene_wake_lock);
  return wake;
fail: {
    int saved = errno;
    close(fds[0]); close(fds[1]);
    free(wake);
    errno = saved;
    return NULL;
  }
}

void gene_wake_signal(GeneNativeWake *wake) {
  if (!wake) return;
  char byte = 'w';
  ssize_t result;
  do { result = write(wake->writer, &byte, 1); }
  while (result < 0 && errno == EINTR);
  /* EAGAIN means there is already a pending notification. The caller holds
   * a lifetime lease, so the reader cannot be closed during this write. */
}

void gene_wake_retain(GeneNativeWake *wake) {
  if (!wake) return;
  pthread_mutex_lock(&gene_wake_lock);
  ++wake->references;
  pthread_mutex_unlock(&gene_wake_lock);
}

void gene_wake_signal_lanes(void) {
  /* Pending-work classification is process-wide. Wake every runtime lane on
   * its transitions, including lanes awaiting the last unrelated operation.
   * Data/completion notifications remain targeted; control endpoints (lane -1)
   * do not participate in this broadcast. */
  pthread_mutex_lock(&gene_wake_lock);
  for (GeneNativeWake *wake = gene_wakes; wake; wake = wake->next)
    if (wake->lane >= 0) gene_wake_signal(wake);
  pthread_mutex_unlock(&gene_wake_lock);
}

void gene_wake_release(GeneNativeWake *wake) {
  if (!wake) return;
  /* Wake a waiter whose predicate may have changed as an owner retires. */
  gene_wake_signal(wake);
  pthread_mutex_lock(&gene_wake_lock);
  if (--wake->references == 0) {
    GeneNativeWake **entry = &gene_wakes;
    while (*entry && *entry != wake) entry = &(*entry)->next;
    if (*entry) *entry = wake->next;
    close(wake->reader);
    close(wake->writer);
    free(wake);
  }
  pthread_mutex_unlock(&gene_wake_lock);
}

void gene_wake_signal_key(const void *key) {
  /* Weak-key lookup is used by foreign ingress producers. It pins under the
   * registry lock before touching an endpoint that its owner may retire. */
  GeneNativeWake *found = NULL;
  pthread_mutex_lock(&gene_wake_lock);
  for (GeneNativeWake *wake = gene_wakes; wake; wake = wake->next) {
    if (wake->key == key) {
      ++wake->references;
      found = wake;
      break;
    }
  }
  pthread_mutex_unlock(&gene_wake_lock);
  if (found) {
    gene_wake_signal(found);
    gene_wake_release(found);
  }
}

int gene_wake_fd(GeneNativeWake *wake) {
  return wake ? wake->reader : -1;
}

void gene_wake_drain(GeneNativeWake *wake) {
  char bytes[256];
  while (1) {
    ssize_t count = read(wake->reader, bytes, sizeof(bytes));
    if (count > 0) continue;
    if (count < 0 && errno == EINTR) continue;
    return;
  }
}

int gene_wake_wait(int64_t lane, int timeout_ms) {
  pthread_mutex_lock(&gene_wake_lock);
  size_t count = 0;
  for (GeneNativeWake *wake = gene_wakes; wake; wake = wake->next)
    if (wake->lane == lane) ++count;
  struct pollfd *fds = count ? calloc(count, sizeof(*fds)) : NULL;
  GeneNativeWake **owners = count ? malloc(count * sizeof(*owners)) : NULL;
  if (count && (!fds || !owners)) {
    free(fds); free(owners);
    pthread_mutex_unlock(&gene_wake_lock);
    return -ENOMEM;
  }
  size_t index = 0;
  for (GeneNativeWake *wake = gene_wakes; wake; wake = wake->next) {
    if (wake->lane == lane) {
      ++wake->references; /* Pin descriptors for this entire wait snapshot. */
      owners[index] = wake;
      fds[index].fd = wake->reader;
      fds[index].events = POLLIN;
      ++index;
    }
  }
  pthread_mutex_unlock(&gene_wake_lock);
#ifdef GENE_EXEC_TESTS
  /* Also a deterministic test barrier: the wait snapshot is now pinned. */
  atomic_fetch_add(&gene_wake_wait_count, 1);
#endif
  int ready = poll(fds, (nfds_t)count, timeout_ms);
  int saved = errno;
  if (ready > 0)
    for (size_t i = 0; i < count; ++i)
      if (fds[i].revents) gene_wake_drain(owners[i]);
  /* Do not signal on the waiter's own temporary-lease release: that would
   * turn every completed wait into the next spurious wake. */
  pthread_mutex_lock(&gene_wake_lock);
  for (size_t i = 0; i < count; ++i) {
    GeneNativeWake *wake = owners[i];
    if (--wake->references == 0) {
      GeneNativeWake **entry = &gene_wakes;
      while (*entry && *entry != wake) entry = &(*entry)->next;
      if (*entry) *entry = wake->next;
      close(wake->reader); close(wake->writer); free(wake);
    }
  }
  pthread_mutex_unlock(&gene_wake_lock);
  free(fds); free(owners);
  if (ready < 0) return saved == EINTR ? 1 : -saved;
  return ready;
}
