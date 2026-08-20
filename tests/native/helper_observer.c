#define _GNU_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static bool observing_helper = false;
static const char *trace_path = NULL;
static _Thread_local bool sampler_thread_recorded = false;

static void record_event(const char *event) {
  if (!observing_helper || trace_path == NULL)
    return;

  int descriptor =
      open(trace_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (descriptor < 0)
    return;
  dprintf(descriptor, "%s %ld %ld\n", event, (long)getpid(),
          (long)syscall(SYS_gettid));
  close(descriptor);
}

static void record_sampler_thread(void) {
  if (sampler_thread_recorded)
    return;
  sampler_thread_recorded = true;
  record_event("sampler");
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

  record_sampler_thread();
  return real_clock_nanosleep(clock_id, flags, request, remaining);
}

int timerfd_create(int clock_id, int flags) {
  typedef int (*TimerfdCreate)(int, int);
  static TimerfdCreate real_timerfd_create = NULL;
  if (real_timerfd_create == NULL) {
    void *symbol = dlsym(RTLD_NEXT, "timerfd_create");
    memcpy(&real_timerfd_create, &symbol, sizeof(real_timerfd_create));
  }

  record_event("sampler");
  return real_timerfd_create(clock_id, flags);
}

int timer_create(clockid_t clock_id, struct sigevent *event,
                 timer_t *timer_id) {
  typedef int (*TimerCreate)(clockid_t, struct sigevent *, timer_t *);
  static TimerCreate real_timer_create = NULL;
  if (real_timer_create == NULL) {
    void *symbol = dlsym(RTLD_NEXT, "timer_create");
    memcpy(&real_timer_create, &symbol, sizeof(real_timer_create));
  }

  record_event("sampler");
  return real_timer_create(clock_id, event, timer_id);
}

int setitimer(__itimer_which_t which, const struct itimerval *new_value,
              struct itimerval *old_value) {
  typedef int (*Setitimer)(__itimer_which_t, const struct itimerval *,
                           struct itimerval *);
  static Setitimer real_setitimer = NULL;
  if (real_setitimer == NULL) {
    void *symbol = dlsym(RTLD_NEXT, "setitimer");
    memcpy(&real_setitimer, &symbol, sizeof(real_setitimer));
  }

  record_event("sampler");
  return real_setitimer(which, new_value, old_value);
}
