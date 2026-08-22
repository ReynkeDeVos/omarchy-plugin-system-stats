#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

static int fixture_counter(uint64_t config, uint64_t values[3]) {
  if (config == 1) {
    values[0] = UINT64_C(100000000);
    values[1] = UINT64_C(140000000);
    values[2] = UINT64_C(180000000);
    return 0;
  }
  if (config == 2) {
    values[0] = 0;
    values[1] = UINT64_C(100000000);
    values[2] = UINT64_C(200000000);
    return 0;
  }
  if (config == 3) {
    values[0] = UINT64_C(200000000);
    values[1] = UINT64_C(220000000);
    values[2] = UINT64_C(240000000);
    return 0;
  }
  errno = EINVAL;
  return -1;
}

long syscall(long number, ...) {
  if (number != SYS_perf_event_open) {
    errno = ENOSYS;
    return -1;
  }

  va_list arguments;
  va_start(arguments, number);
  const struct perf_event_attr *attributes =
      va_arg(arguments, const struct perf_event_attr *);
  va_end(arguments);
  const char *denied = getenv("SYSTEM_STATS_PERF_DENY_CONFIG");
  if (denied != NULL && strtoull(denied, NULL, 0) == attributes->config) {
    errno = EACCES;
    return -1;
  }

  uint64_t values[3];
  if (fixture_counter(attributes->config, values) != 0)
    return -1;
  const char *reset = getenv("SYSTEM_STATS_PERF_RESET_CONFIG");
  if (reset != NULL && strtoull(reset, NULL, 0) == attributes->config) {
    values[1] = UINT64_C(50000000);
    values[2] = UINT64_C(90000000);
  }
  int descriptors[2];
  if (pipe2(descriptors, O_CLOEXEC) != 0)
    return -1;
  if (write(descriptors[1], values, sizeof(values)) !=
      (ssize_t)sizeof(values)) {
    close(descriptors[0]);
    close(descriptors[1]);
    errno = EIO;
    return -1;
  }
  close(descriptors[1]);
  return descriptors[0];
}
