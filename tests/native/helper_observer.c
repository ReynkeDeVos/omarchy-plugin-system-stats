#define _GNU_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static bool observing_helper = false;
static const char *trace_path = NULL;

static void record_event(const char *event) {
  if (!observing_helper || trace_path == NULL)
    return;

  int descriptor =
      open(trace_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (descriptor < 0)
    return;
  dprintf(descriptor, "%s %ld\n", event, (long)getpid());
  close(descriptor);
}

__attribute__((constructor)) static void initialize_observer(void) {
  const char *helper_path = getenv("SYSTEM_STATS_TRACE_EXECUTABLE");
  trace_path = getenv("SYSTEM_STATS_TRACE_FILE");
  if (helper_path == NULL || trace_path == NULL)
    return;

  char executable[4096];
  ssize_t length =
      readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (length < 0)
    return;
  executable[length] = '\0';
  observing_helper = strcmp(executable, helper_path) == 0;
  record_event("launch");
}

int clock_nanosleep(clockid_t clock_id, int flags,
                    const struct timespec *request,
                    struct timespec *remaining) {
  typedef int (*ClockNanosleep)(clockid_t, int, const struct timespec *,
                                struct timespec *);
  static ClockNanosleep real_clock_nanosleep = NULL;
  if (real_clock_nanosleep == NULL) {
    void *symbol = dlsym(RTLD_NEXT, "clock_nanosleep");
    memcpy(&real_clock_nanosleep, &symbol, sizeof(real_clock_nanosleep));
  }

  record_event("wait");
  return real_clock_nanosleep(clock_id, flags, request, remaining);
}
