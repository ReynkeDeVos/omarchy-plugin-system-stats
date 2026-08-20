#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { CPU_FIELD_COUNT = 8 };

typedef struct {
  uint64_t user;
  uint64_t nice;
  uint64_t system;
  uint64_t idle;
  uint64_t iowait;
  uint64_t irq;
  uint64_t softirq;
  uint64_t steal;
} CpuCounters;

typedef struct {
  const char *frames_path;
  long interval_ms;
} Options;

typedef enum {
  PARSE_OK,
  PARSE_MISSING_FIELD,
  PARSE_MALFORMED,
  PARSE_SOURCE_UNREADABLE
} ParseResult;

static void fail(const char *message) {
  fprintf(stderr, "system-stats-helper: %s\n", message);
  exit(EXIT_FAILURE);
}

static Options parse_options(int argc, char **argv) {
  const char *frames_path = getenv("SYSTEM_STATS_FRAMES");
  const char *interval_text = getenv("SYSTEM_STATS_INTERVAL_MS");
  Options options = {
      .frames_path =
          frames_path != NULL && *frames_path != '\0' ? frames_path : NULL,
      .interval_ms = 2000,
  };

  if (interval_text != NULL && *interval_text != '\0') {
    char *end = NULL;
    errno = 0;
    long value = strtol(interval_text, &end, 10);
    if (errno != 0 || end == interval_text || *end != '\0' || value <= 0) {
      fail("SYSTEM_STATS_INTERVAL_MS must be a positive integer");
    }
    options.interval_ms = value;
  }

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
      options.frames_path = argv[++i];
    } else if (strcmp(argv[i], "--interval-ms") == 0 && i + 1 < argc) {
      char *end = NULL;
      errno = 0;
      long value = strtol(argv[++i], &end, 10);
      if (errno != 0 || end == argv[i] || *end != '\0' || value <= 0) {
        fail("--interval-ms must be a positive integer");
      }
      options.interval_ms = value;
    } else {
      fail("usage: system-stats-helper [--frames PATH] [--interval-ms N]");
    }
  }

  return options;
}

static ParseResult parse_cpu_line(char *line, CpuCounters *counters) {
  char *cursor = line;
  while (isspace((unsigned char)*cursor))
    cursor++;
  if (strncmp(cursor, "cpu", 3) != 0 || !isspace((unsigned char)cursor[3])) {
    return PARSE_MALFORMED;
  }
  cursor += 3;

  uint64_t *fields[CPU_FIELD_COUNT] = {
      &counters->user,   &counters->nice, &counters->system,  &counters->idle,
      &counters->iowait, &counters->irq,  &counters->softirq, &counters->steal,
  };

  for (size_t i = 0; i < CPU_FIELD_COUNT; i++) {
    while (isspace((unsigned char)*cursor))
      cursor++;
    if (*cursor == '\0')
      return PARSE_MISSING_FIELD;
    if (!isdigit((unsigned char)*cursor))
      return PARSE_MALFORMED;

    errno = 0;
    char *end = NULL;
    uintmax_t value = strtoumax(cursor, &end, 10);
    if (errno == ERANGE || end == cursor || value > UINT64_MAX)
      return PARSE_MALFORMED;
    if (*end != '\0' && !isspace((unsigned char)*end))
      return PARSE_MALFORMED;

    *fields[i] = (uint64_t)value;
    cursor = end;
  }

  return PARSE_OK;
}

static ParseResult read_counters(FILE *frames, CpuCounters *counters) {
  FILE *stream = frames;
  if (stream == NULL) {
    stream = fopen("/proc/stat", "re");
    if (stream == NULL)
      return PARSE_SOURCE_UNREADABLE;
  }

  char *line = NULL;
  size_t capacity = 0;
  ssize_t length = getline(&line, &capacity, stream);
  ParseResult result =
      length < 0 ? PARSE_SOURCE_UNREADABLE : parse_cpu_line(line, counters);
  free(line);

  if (frames == NULL)
    fclose(stream);
  return result;
}

static int64_t monotonic_ms(struct timespec instant) {
  return (int64_t)instant.tv_sec * 1000 + instant.tv_nsec / 1000000;
}

static struct timespec add_ms(struct timespec instant, long milliseconds) {
  instant.tv_sec += milliseconds / 1000;
  instant.tv_nsec += (milliseconds % 1000) * 1000000L;
  if (instant.tv_nsec >= 1000000000L) {
    instant.tv_sec++;
    instant.tv_nsec -= 1000000000L;
  }
  return instant;
}

static int compare_timespec(struct timespec left, struct timespec right) {
  if (left.tv_sec != right.tv_sec)
    return left.tv_sec < right.tv_sec ? -1 : 1;
  if (left.tv_nsec == right.tv_nsec)
    return 0;
  return left.tv_nsec < right.tv_nsec ? -1 : 1;
}

static void sleep_until(struct timespec deadline) {
  int result;
  do {
    result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL);
  } while (result == EINTR);
  if (result != 0)
    fail("monotonic timer failed");
}

static const char *parse_error(ParseResult result) {
  if (result == PARSE_SOURCE_UNREADABLE)
    return "sourceUnreadable";
  return result == PARSE_MISSING_FIELD ? "missingRequiredField"
                                       : "malformedCounter";
}

static bool cpu_percent(const CpuCounters *before, const CpuCounters *after,
                        int *percent, const char **error) {
  if (after->user < before->user || after->nice < before->nice ||
      after->system < before->system || after->idle < before->idle ||
      after->iowait < before->iowait || after->irq < before->irq ||
      after->softirq < before->softirq || after->steal < before->steal) {
    *error = "counterReset";
    return false;
  }

  uint64_t active =
      (after->user - before->user) + (after->nice - before->nice) +
      (after->system - before->system) + (after->irq - before->irq) +
      (after->softirq - before->softirq) + (after->steal - before->steal);
  uint64_t inactive =
      (after->idle - before->idle) + (after->iowait - before->iowait);
  uint64_t total = active + inactive;
  if (total == 0) {
    *error = "malformedCounter";
    return false;
  }

  long double value = (long double)active * 100.0L / (long double)total;
  *percent = (int)floorl(value + 0.5L);
  return true;
}

static void emit_hello(uint64_t generation) {
  printf("{\"type\":\"hello\",\"schemaVersion\":1,\"generation\":%" PRIu64
         "}\n",
         generation);
  fflush(stdout);
}

static void emit_snapshot(uint64_t generation, uint64_t sequence,
                          struct timespec sampled_at, int64_t window_ms,
                          const CpuCounters *before, const CpuCounters *after,
                          ParseResult current_result,
                          ParseResult previous_result) {
  int percent = 0;
  const char *error = NULL;
  bool available = false;

  if (previous_result != PARSE_OK) {
    error = parse_error(previous_result);
  } else if (current_result != PARSE_OK) {
    error = parse_error(current_result);
  } else {
    available = cpu_percent(before, after, &percent, &error);
  }

  int64_t sampled_at_ms = monotonic_ms(sampled_at);
  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"phase\":\"%s\",\"publishedAtMs\":%" PRId64
         ",\"cpu\":",
         generation, sequence, available ? "live" : "degraded", sampled_at_ms);
  if (available) {
    printf("{\"status\":\"available\",\"value\":{\"percent\":%d,"
           "\"actualWindowMs\":%" PRId64 "},"
           "\"sampledAtMs\":%" PRId64 ",\"window\":{\"actualMs\":%" PRId64 "},"
           "\"evidence\":\"hardwareConfirmed\",\"path\":\"proc-stat\"}",
           percent, window_ms, sampled_at_ms, window_ms);
  } else {
    printf("{\"status\":\"unavailable\","
           "\"error\":{\"code\":\"%s\",\"scope\":\"cpu\","
           "\"retryability\":\"retryable\",\"pathId\":\"proc-stat\"},"
           "\"since\":%" PRId64 "}",
           error, sampled_at_ms);
  }
  printf(",\"ram\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"ram\","
         "\"retryability\":\"nonRetryable\"},\"since\":%" PRId64 "},"
         "\"gpu\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"gpu\","
         "\"retryability\":\"nonRetryable\"},\"since\":%" PRId64 "},"
         "\"source\":{\"status\":\"running\"}}\n",
         sampled_at_ms, sampled_at_ms);
  fflush(stdout);
}

int main(int argc, char **argv) {
  Options options = parse_options(argc, argv);
  FILE *frames =
      options.frames_path == NULL ? NULL : fopen(options.frames_path, "re");
  if (options.frames_path != NULL && frames == NULL)
    fail("could not open fixture frames");

  CpuCounters previous = {0};
  ParseResult previous_result = read_counters(frames, &previous);
  struct timespec previous_at;
  if (clock_gettime(CLOCK_MONOTONIC, &previous_at) != 0)
    fail("could not read monotonic clock");
  struct timespec deadline = add_ms(previous_at, options.interval_ms);
  uint64_t generation = (uint64_t)monotonic_ms(previous_at);
  uint64_t sequence = 0;

  emit_hello(generation);

  for (;;) {
    sleep_until(deadline);

    CpuCounters current = {0};
    ParseResult current_result = read_counters(frames, &current);
    struct timespec sampled_at;
    if (clock_gettime(CLOCK_MONOTONIC, &sampled_at) != 0)
      fail("could not read monotonic clock");

    if (frames != NULL && feof(frames)) {
      for (;;)
        pause();
    }

    emit_snapshot(generation, ++sequence, sampled_at,
                  monotonic_ms(sampled_at) - monotonic_ms(previous_at),
                  &previous, &current, current_result, previous_result);

    previous = current;
    previous_result = current_result;
    previous_at = sampled_at;
    deadline = add_ms(deadline, options.interval_ms);
    if (compare_timespec(deadline, sampled_at) <= 0)
      deadline = add_ms(sampled_at, options.interval_ms);
  }
}
