#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

static const char *trace_path;

static int64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    exit(90);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void sleep_ms(long milliseconds) {
  struct timespec duration = {
      .tv_sec = milliseconds / 1000,
      .tv_nsec = (milliseconds % 1000) * 1000000L,
  };
  while (nanosleep(&duration, &duration) != 0 && errno == EINTR)
    ;
}

static void trace(const char *event, int launch) {
  int descriptor =
      open(trace_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (descriptor < 0)
    exit(91);
  dprintf(descriptor, "%s %d %ld %" PRId64 "\n", event, launch, (long)getpid(),
          monotonic_ms());
  close(descriptor);
}

static int next_launch(const char *count_path) {
  int descriptor = open(count_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (descriptor < 0 || flock(descriptor, LOCK_EX) != 0)
    exit(92);

  char text[32] = {0};
  ssize_t length = read(descriptor, text, sizeof(text) - 1);
  int launch = length > 0 ? atoi(text) + 1 : 1;
  if (ftruncate(descriptor, 0) != 0 || lseek(descriptor, 0, SEEK_SET) < 0)
    exit(93);
  dprintf(descriptor, "%d\n", launch);
  flock(descriptor, LOCK_UN);
  close(descriptor);
  return launch;
}

static int hold_source_lock(const char *lock_path, int launch) {
  int descriptor = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (descriptor < 0)
    exit(94);
  if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
    trace("OVERLAP", launch);
    exit(95);
  }
  return descriptor;
}

static void emit_hello(uint64_t generation) {
  int64_t now = monotonic_ms();
  printf("{\"type\":\"hello\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"publishedAtMs\":%" PRId64 "}\n",
         generation, now);
  fflush(stdout);
}

static void emit_snapshot_at(uint64_t generation, uint64_t sequence,
                             int percent, int64_t published_at_ms,
                             int64_t sampled_at_ms) {
  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":0,\"phase\":\"live\","
         "\"publishedAtMs\":%" PRId64 ",\"cpu\":{\"status\":\"available\","
         "\"value\":{\"percent\":%d,\"actualWindowMs\":10},"
         "\"sampledAtMs\":%" PRId64
         ",\"window\":{\"actualMs\":10},\"evidence\":\"fixtureTested\","
         "\"path\":\"scripted\"},"
         "\"ram\":{\"status\":\"available\","
         "\"value\":{\"percent\":63,\"usedBytes\":10737418240,"
         "\"totalBytes\":17179869184},\"sampledAtMs\":%" PRId64 ","
         "\"window\":{\"actualMs\":10},\"evidence\":\"fixtureTested\","
         "\"path\":\"scripted\"},"
         "\"gpu\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"gpu\","
         "\"retryability\":\"nonRetryable\"},\"since\":%" PRId64 "},"
         "\"source\":{\"status\":\"running\"}}\n",
         generation, sequence, published_at_ms, percent, sampled_at_ms,
         sampled_at_ms, published_at_ms);
  fflush(stdout);
}

static void emit_snapshot(uint64_t generation, uint64_t sequence, int percent) {
  int64_t now = monotonic_ms();
  emit_snapshot_at(generation, sequence, percent, now, now);
}

static void run_protocol(uint64_t generation) {
  emit_hello(generation);
  int64_t now = monotonic_ms();
  const char *second_text = getenv("SYSTEM_STATS_SECOND_MS");
  long second_ms = strtol(second_text, NULL, 10);
  emit_snapshot_at(generation, 1, 88, now, now - 5 * second_ms);
  emit_snapshot(generation, 2, 37);
  emit_snapshot(generation - 1, 3, 99);
  printf("{\"type\":\"snapshot\",\"schemaVersion\":2}\n");
  emit_snapshot(generation, 2, 99);
  for (int i = 0; i < 70000; i++)
    putchar('x');
  putchar('\n');
  emit_snapshot(generation, 3, 101);
  emit_snapshot(generation, 3, 42);
  for (;;)
    pause();
}

static void run_backoff_reset(uint64_t generation, int launch, long second_ms) {
  emit_hello(generation);
  if (launch <= 7)
    exit(17);

  emit_snapshot(generation, 1, 37);
  if (launch == 8) {
    int64_t deadline = monotonic_ms() + 65 * second_ms;
    uint64_t sequence = 1;
    while (monotonic_ms() < deadline) {
      sleep_ms(second_ms);
      emit_snapshot(generation, ++sequence, 37);
    }
    exit(18);
  }

  for (;;)
    pause();
}

static void run_unresponsive(uint64_t generation, int launch) {
  emit_hello(generation);
  emit_snapshot(generation, 1, launch == 1 ? 37 : 55);
  if (launch == 1)
    signal(SIGTERM, SIG_IGN);
  for (;;)
    pause();
}

int main(void) {
  const char *scenario = getenv("SYSTEM_STATS_SCENARIO");
  const char *count_path = getenv("SYSTEM_STATS_COUNT_FILE");
  const char *lock_path = getenv("SYSTEM_STATS_LOCK_FILE");
  const char *second_text = getenv("SYSTEM_STATS_SECOND_MS");
  trace_path = getenv("SYSTEM_STATS_TRACE_FILE");
  if (scenario == NULL || count_path == NULL || lock_path == NULL ||
      trace_path == NULL || second_text == NULL)
    return 96;

  long second_ms = strtol(second_text, NULL, 10);
  int launch = next_launch(count_path);
  int source_lock = hold_source_lock(lock_path, launch);
  (void)source_lock;
  trace("START", launch);
  uint64_t generation = UINT64_C(4503599627370496) + (uint64_t)launch;

  if (strcmp(scenario, "protocol") == 0)
    run_protocol(generation);
  if (strcmp(scenario, "backoff-reset") == 0)
    run_backoff_reset(generation, launch, second_ms);
  if (strcmp(scenario, "unresponsive") == 0)
    run_unresponsive(generation, launch);
  return 97;
}
