/* Deterministic external process used by Gene and native exec measurements. */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int write_all(int fd, const char *bytes, size_t count) {
  while (count) {
    ssize_t written = write(fd, bytes, count);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return 1;
    bytes += written;
    count -= (size_t)written;
  }
  return 0;
}

static void wait_ms(long milliseconds) {
  struct timespec remaining = {milliseconds / 1000, milliseconds % 1000 * 1000000};
  while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "noop") == 0) return 0;
  if (strcmp(argv[1], "sleep") == 0) {
    wait_ms(argc > 2 ? strtol(argv[2], NULL, 10) : 20);
    return 0;
  }
  if (strcmp(argv[1], "lines") == 0) {
    if (write_all(1, "first\n", 6)) return 2;
    wait_ms(20);
    return write_all(1, "last\n", 5);
  }
  if (strcmp(argv[1], "input") == 0) {
    char buffer[65536];
    unsigned long long total = 0;
    while (1) {
      ssize_t count = read(0, buffer, sizeof(buffer));
      if (count < 0 && errno == EINTR) continue;
      if (count < 0) return 2;
      if (!count) break;
      for (ssize_t i = 0; i < count; ++i) if (buffer[i] != 'x') return 3;
      total += (unsigned long long)count;
    }
    printf("%llu\n", total);
    return 0;
  }
  if (strcmp(argv[1], "output") == 0 && argc >= 3) {
    char buffer[16384];
    memset(buffer, 'x', sizeof(buffer));
    size_t remaining = (size_t)strtoull(argv[2], NULL, 10);
    int both = argc > 3 && strcmp(argv[3], "both") == 0;
    while (remaining) {
      size_t count = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
      if (write_all(1, buffer, count)) return 2;
      if (both && write_all(2, buffer, count)) return 2;
      remaining -= count;
    }
    return 0;
  }
  return 2;
}
