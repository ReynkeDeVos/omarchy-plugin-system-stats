#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

enum { CPU_FIELD_COUNT = 8, MAX_COMMAND_BYTES = 65536 };

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
  long second_ms;
} Options;

typedef struct {
  uint64_t generation;
  uint64_t command_id;
  uint64_t config_revision;
  long interval_seconds;
} ConfigureCommand;

typedef struct {
  const char *code;
  int64_t since_ms;
} CpuFailureState;

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
  const char *second_text = getenv("SYSTEM_STATS_SECOND_MS");
  Options options = {
      .frames_path =
          frames_path != NULL && *frames_path != '\0' ? frames_path : NULL,
      .interval_ms = 2000,
      .second_ms = 1000,
  };

  if (second_text != NULL && *second_text != '\0') {
    char *end = NULL;
    errno = 0;
    long value = strtol(second_text, &end, 10);
    if (errno != 0 || end == second_text || *end != '\0' || value <= 0 ||
        value > LONG_MAX / 10) {
      fail("SYSTEM_STATS_SECOND_MS must be a positive integer");
    }
    options.second_ms = value;
    options.interval_ms = 2 * value;
  }

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

static uint64_t new_generation(void) {
  uint64_t entropy = 0;
  unsigned char *cursor = (unsigned char *)&entropy;
  size_t remaining = sizeof(entropy);
  while (remaining > 0) {
    ssize_t received = getrandom(cursor, remaining, 0);
    if (received < 0 && errno == EINTR)
      continue;
    if (received <= 0)
      fail("could not create helper generation");
    cursor += (size_t)received;
    remaining -= (size_t)received;
  }

  const uint64_t safe_integer_high_bit = UINT64_C(1) << 52;
  return safe_integer_high_bit | (entropy & (safe_integer_high_bit - 1));
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

static struct timespec monotonic_now(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    fail("could not read monotonic clock");
  return now;
}

static int milliseconds_until(struct timespec deadline, struct timespec now) {
  int64_t nanoseconds = (int64_t)(deadline.tv_sec - now.tv_sec) * 1000000000LL +
                        deadline.tv_nsec - now.tv_nsec;
  if (nanoseconds <= 0)
    return 0;
  int64_t milliseconds = (nanoseconds + 999999LL) / 1000000LL;
  return milliseconds > INT_MAX ? INT_MAX : (int)milliseconds;
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

static void emit_hello(uint64_t generation, int64_t published_at_ms) {
  printf("{\"type\":\"hello\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"publishedAtMs\":%" PRId64 "}\n",
         generation, published_at_ms);
  fflush(stdout);
}

static void emit_ack(uint64_t generation, const ConfigureCommand *command) {
  printf("{\"type\":\"ack\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"intervalSeconds\":%ld}\n",
         generation, command->command_id, command->config_revision,
         command->interval_seconds);
  fflush(stdout);
}

static void emit_reject(uint64_t generation, uint64_t command_id) {
  printf("{\"type\":\"reject\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"commandId\":%" PRIu64 ",\"error\":\"invalidConfiguration\"}\n",
         generation, command_id);
  fflush(stdout);
}

static bool parse_configure(char *line, ConfigureCommand *command) {
  int consumed = 0;
  int matched =
      sscanf(line,
             "{\"type\":\"configure\",\"schemaVersion\":1,\"generation\":"
             "%" SCNu64 ",\"commandId\":%" SCNu64 ",\"configRevision\":%" SCNu64
             ",\"intervalSeconds\":%ld}%n",
             &command->generation, &command->command_id,
             &command->config_revision, &command->interval_seconds, &consumed);
  if (matched != 4)
    return false;
  while (isspace((unsigned char)line[consumed]))
    consumed++;
  return line[consumed] == '\0';
}

static void emit_unavailable_dependencies(int64_t unavailable_since_ms) {
  printf(",\"ram\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"ram\","
         "\"retryability\":\"nonRetryable\","
         "\"diagnostic\":\"metric provider is outside the CPU-only "
         "slice\"},\"since\":%" PRId64 "},"
         "\"gpu\":{\"status\":\"unavailable\","
         "\"error\":{\"code\":\"dependencyMissing\",\"scope\":\"gpu\","
         "\"retryability\":\"nonRetryable\","
         "\"diagnostic\":\"metric provider is outside the CPU-only "
         "slice\"},\"since\":%" PRId64 "},"
         "\"source\":{\"status\":\"running\"}}\n",
         unavailable_since_ms, unavailable_since_ms);
}

static void emit_initializing_snapshot(uint64_t generation, uint64_t sequence,
                                       uint64_t config_revision,
                                       int64_t initialized_at_ms,
                                       int64_t unavailable_since_ms) {
  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"phase\":\"initializing\",\"publishedAtMs\":%" PRId64
         ",\"cpu\":{\"status\":\"initializing\",\"since\":%" PRId64 "}",
         generation, sequence, config_revision, initialized_at_ms,
         initialized_at_ms);
  emit_unavailable_dependencies(unavailable_since_ms);
  fflush(stdout);
}

static void emit_snapshot(uint64_t generation, uint64_t sequence,
                          uint64_t config_revision, struct timespec sampled_at,
                          int64_t window_ms, int64_t unavailable_since_ms,
                          CpuFailureState *cpu_failure,
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
  if (available) {
    cpu_failure->code = NULL;
  } else if (cpu_failure->code == NULL ||
             strcmp(cpu_failure->code, error) != 0) {
    cpu_failure->code = error;
    cpu_failure->since_ms = sampled_at_ms;
  }

  printf("{\"type\":\"snapshot\",\"schemaVersion\":1,\"generation\":%" PRIu64
         ",\"sequence\":%" PRIu64 ",\"configRevision\":%" PRIu64
         ",\"phase\":\"%s\",\"publishedAtMs\":%" PRId64 ",\"cpu\":",
         generation, sequence, config_revision, available ? "live" : "degraded",
         sampled_at_ms);
  if (available) {
    printf("{\"status\":\"available\",\"value\":{\"percent\":%d,"
           "\"actualWindowMs\":%" PRId64 "},"
           "\"sampledAtMs\":%" PRId64 ",\"window\":{\"actualMs\":%" PRId64 "},"
           "\"evidence\":\"fixtureTested\",\"path\":\"proc-stat\"}",
           percent, window_ms, sampled_at_ms, window_ms);
  } else {
    printf("{\"status\":\"unavailable\","
           "\"error\":{\"code\":\"%s\",\"scope\":\"cpu\","
           "\"retryability\":\"retryable\",\"pathId\":\"proc-stat\"},"
           "\"since\":%" PRId64 "}",
           error, cpu_failure->since_ms);
  }
  emit_unavailable_dependencies(unavailable_since_ms);
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
  struct timespec previous_at = monotonic_now();
  struct timespec deadline = add_ms(previous_at, options.interval_ms);
  int64_t started_at_ms = monotonic_ms(previous_at);
  uint64_t generation = new_generation();
  uint64_t sequence = 0;
  uint64_t config_revision = 0;
  CpuFailureState cpu_failure = {0};
  bool accepts_commands = true;

  emit_hello(generation, monotonic_ms(monotonic_now()));

  for (;;) {
    struct timespec now = monotonic_now();
    struct pollfd input = {
        .fd = accepts_commands ? STDIN_FILENO : -1,
        .events = POLLIN,
    };
    int poll_result;
    do {
      poll_result = poll(&input, 1, milliseconds_until(deadline, now));
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result < 0)
      fail("could not wait for sampler deadline");

    if (poll_result > 0 && (input.revents & POLLIN) != 0) {
      char *line = NULL;
      size_t capacity = 0;
      ssize_t length = getline(&line, &capacity, stdin);
      if (length < 0) {
        free(line);
        accepts_commands = false;
        continue;
      }

      ConfigureCommand command = {0};
      bool parsed =
          length <= MAX_COMMAND_BYTES && parse_configure(line, &command);
      if (!parsed || command.generation != generation ||
          command.command_id == 0 ||
          command.config_revision < config_revision ||
          command.interval_seconds < 2 || command.interval_seconds > 10 ||
          command.interval_seconds > LONG_MAX / options.second_ms ||
          (command.config_revision == config_revision &&
           command.interval_seconds * options.second_ms !=
               options.interval_ms)) {
        emit_reject(generation, command.command_id);
        free(line);
        continue;
      }

      if (command.config_revision == config_revision) {
        emit_ack(generation, &command);
        free(line);
        continue;
      }

      options.interval_ms = command.interval_seconds * options.second_ms;
      config_revision = command.config_revision;
      previous_result = read_counters(frames, &previous);
      previous_at = monotonic_now();
      deadline = add_ms(previous_at, options.interval_ms);
      cpu_failure.code = NULL;
      emit_ack(generation, &command);
      emit_initializing_snapshot(generation, ++sequence, config_revision,
                                 monotonic_ms(previous_at), started_at_ms);
      free(line);
      continue;
    }
    if (poll_result > 0 &&
        (input.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      accepts_commands = false;
      continue;
    }

    CpuCounters current = {0};
    ParseResult current_result = read_counters(frames, &current);
    struct timespec sampled_at = monotonic_now();

    if (frames != NULL && feof(frames)) {
      for (;;)
        pause();
    }

    emit_snapshot(generation, ++sequence, config_revision, sampled_at,
                  monotonic_ms(sampled_at) - monotonic_ms(previous_at),
                  started_at_ms, &cpu_failure, &previous, &current,
                  current_result, previous_result);

    previous = current;
    previous_result = current_result;
    previous_at = sampled_at;
    deadline = add_ms(deadline, options.interval_ms);
    if (compare_timespec(deadline, sampled_at) <= 0)
      deadline = add_ms(sampled_at, options.interval_ms);
  }
}
