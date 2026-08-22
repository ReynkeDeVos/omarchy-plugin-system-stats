#define _GNU_SOURCE

#include <errno.h>
#include <linux/perf_event.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static bool parse_unsigned(const char *text, unsigned long long *value) {
  char *end = NULL;
  errno = 0;
  *value = strtoull(text, &end, 0);
  return errno == 0 && end != text && *end == '\0';
}

static long double elapsed_ns(struct timespec start, struct timespec end) {
  return (long double)(end.tv_sec - start.tv_sec) * 1000000000.0L +
         (long double)(end.tv_nsec - start.tv_nsec);
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s PMU_TYPE EVENT_CONFIG CPU\n", argv[0]);
    return 2;
  }

  unsigned long long type = 0;
  unsigned long long config = 0;
  unsigned long long cpu = 0;
  if (!parse_unsigned(argv[1], &type) || type > UINT32_MAX ||
      !parse_unsigned(argv[2], &config) || !parse_unsigned(argv[3], &cpu) ||
      cpu > INT32_MAX) {
    fprintf(stderr, "invalid numeric argument\n");
    return 2;
  }

  struct perf_event_attr attributes = {
      .type = (uint32_t)type,
      .size = sizeof(attributes),
      .config = config,
  };
  int descriptor = (int)syscall(SYS_perf_event_open, &attributes, -1, (int)cpu,
                                -1, PERF_FLAG_FD_CLOEXEC);
  if (descriptor < 0) {
    fprintf(stderr, "perf_event_open: %s\n", strerror(errno));
    return 1;
  }

  uint64_t before = 0;
  uint64_t after = 0;
  struct timespec start = {0};
  struct timespec end = {0};
  if (read(descriptor, &before, sizeof(before)) != (ssize_t)sizeof(before) ||
      clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
    fprintf(stderr, "initial counter read: %s\n", strerror(errno));
    close(descriptor);
    return 1;
  }

  struct timespec delay = {.tv_sec = 1};
  while (nanosleep(&delay, &delay) != 0) {
    if (errno == EINTR)
      continue;
    fprintf(stderr, "sample delay: %s\n", strerror(errno));
    close(descriptor);
    return 1;
  }
  if (read(descriptor, &after, sizeof(after)) != (ssize_t)sizeof(after) ||
      clock_gettime(CLOCK_MONOTONIC, &end) != 0) {
    fprintf(stderr, "final counter read: %s\n", strerror(errno));
    close(descriptor);
    return 1;
  }
  close(descriptor);

  if (after < before) {
    fprintf(stderr, "counter reset during sample\n");
    return 1;
  }
  long double window = elapsed_ns(start, end);
  if (window <= 0.0L) {
    fprintf(stderr, "invalid sample window\n");
    return 1;
  }
  long double percent = (long double)(after - before) * 100.0L / window;
  if (percent > 100.0L)
    percent = 100.0L;
  printf("busy_delta_ns=%llu elapsed_ns=%.0Lf busy_percent=%.2Lf\n",
         (unsigned long long)(after - before), window, percent);
  return 0;
}
